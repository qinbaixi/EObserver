%% @doc One pass over an erl_crash.dump that indexes its sections.
%%
%% The file is read in raw 4 MB chunks; every `\n=tag[:id]\n` header
%% opens a section whose body runs up to the newline before the next
%% header. Bodies are never kept: the index holds one small object per
%% section, `{{TagNo, Id, Offset}, Len}`, plus a compact summary for the
%% tags eobs_dump_parse summarises. Tags are numbered (`{tag, Tag}` in the
%% meta table) so that the index does not repeat their names, and local
%% pids, the ids of most sections, are stored as integers (id_key/1).
%%
%% Summaries are made by a few worker processes, which get the bodies as
%% sub-binaries of the chunk (no copy) and insert their sections
%% themselves; at most a couple of chunks per worker are in flight.
%%
%% A dump cut short (no `=end`) is indexed up to where it stops; the
%% result says so.
-module(eobs_dump_scan).

-export([check/1, scan/4, summary_tags/1, expand_summary/2, id_key/1, key_id/1]).

-define(CHUNK, 4194304).
%% Bodies up to this size are passed whole to eobs_dump_parse:summary/3.
-define(SUMMARY_MAX, 65536).
%% Longer summary bodies are passed with every line cut to this size.
-define(LINE_MAX, 4096).
%% Summary bodies beyond this are not summarised at all.
-define(SUMMARY_HARD_MAX, 67108864).
%% A "\n=" with no newline within this many bytes is not a header.
-define(HEADER_MAX, 65536).
-define(MAX_WORKERS, 4).
-define(MAGIC, "=erl_crash_dump:").

-record(s, {fd, path, idx, meta, size, mod,
            want = #{},          % Tag => true, tags to summarise
            tags = #{},          % Tag => {TagNo, Want}
            counts = #{},        % TagNo => sections
            cur = none,          % {TagNo, Tag, Id, BodyStart, Want}
            sections = 0, skipped = 0,
            workers = [],
            inflight = [],       % batch refs not yet acknowledged, oldest last
            progress}).

%% Checks that Path is a readable, non-empty crash dump.
-spec check(file:filename_all()) -> {ok, #{size := integer(), mtime := integer()}} | {error, atom()}.
check(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, {file_info, _, directory, _, _, _, _, _, _, _, _, _, _, _}} ->
            {error, eisdir};
        {ok, {file_info, Size, regular, _, _, Mtime, _, _, _, _, _, _, _, _}} ->
            case read_magic(Path) of
                {ok, <<?MAGIC, _/binary>>} -> {ok, #{size => Size, mtime => Mtime}};
                {ok, <<>>} -> {error, empty};
                eof -> {error, empty};
                {ok, _} -> {error, not_a_dump};
                {error, _} = Error -> Error
            end;
        {ok, _} ->
            {error, not_a_file};
        {error, _} = Error ->
            Error
    end.

read_magic(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try file:read(Fd, length(?MAGIC)) after file:close(Fd) end;
        Error ->
            Error
    end.

%% The tags whose sections get a summary, as the parser (eobs_dump_parse)
%% declares them.
summary_tags(Mod) ->
    try
        _ = code:ensure_loaded(Mod),
        case erlang:function_exported(Mod, summary_tags, 0) andalso
             erlang:function_exported(Mod, summary, 3) of
            true -> [T || T <- Mod:summary_tags(), is_binary(T)];
            false -> []
        end
    catch _:_ -> []
    end.

%% Rebuilds a summary map from its stored form, with the schema keys from
%% the meta table (Schemas: SchemaNo => Keys, or the meta table itself).
expand_summary({SchemaNo, Values}, Schemas) when is_map(Schemas) ->
    maps:from_list(lists:zip(maps:get(SchemaNo, Schemas), tuple_to_list(Values)));
expand_summary({SchemaNo, Values}, Meta) ->
    [{_, Keys}] = ets:lookup(Meta, {schema, SchemaNo}),
    maps:from_list(lists:zip(Keys, tuple_to_list(Values))).

%% Indexes Path into Idx (ordered_set) and Meta. Progress is called with
%% #{scanned, sections, skipped} after every chunk.
%% Opts: summary_mod (default eobs_dump_parse), progress => fun(map()).
-spec scan(file:filename_all(), ets:tid(), ets:tid(), map()) -> {ok, map()} | {error, term()}.
scan(Path, Idx, Meta, Opts) ->
    Progress = maps:get(progress, Opts, fun(_) -> ok end),
    Mod = maps:get(summary_mod, Opts, eobs_dump_parse),
    Want = maps:from_list([{T, true} || T <- summary_tags(Mod)]),
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            {ok, Size} = file:position(Fd, eof),
            {ok, 0} = file:position(Fd, bof),
            Workers = case map_size(Want) of
                          0 -> [];
                          _ -> [spawn_link(fun() -> worker(Mod, Idx, Meta) end)
                                || _ <- lists:seq(1, min(?MAX_WORKERS, erlang:system_info(schedulers_online)))]
                      end,
            S = #s{fd = Fd, path = Path, mod = Mod, idx = Idx, meta = Meta, size = Size,
                   want = Want, workers = Workers, progress = Progress},
            try
                case file:read(Fd, ?CHUNK) of
                    {ok, <<?MAGIC, _/binary>> = First} ->
                        %% A virtual newline so that the first header looks
                        %% like every other one.
                        loop(<<$\n, First/binary>>, -1, S);
                    {ok, _} -> {error, not_a_dump};
                    eof -> {error, empty};
                    {error, _} = Error -> Error
                end
            after
                [begin unlink(W), exit(W, kill) end || W <- Workers],
                file:close(Fd)
            end;
        Error ->
            Error
    end.

%% Buf holds the file from offset BufOff on.
loop(Buf, BufOff, S) ->
    {Keep0, Entries, Jobs, S1} = headers(Buf, BufOff, binary:matches(Buf, <<"\n=">>), [], [], S),
    ets:insert(S1#s.idx, Entries),
    S2 = dispatch(Jobs, S1),
    Scanned = BufOff + byte_size(Buf),
    flush(S2),
    (S2#s.progress)(#{scanned => Scanned, sections => S2#s.sections, skipped => S2#s.skipped}),
    case file:read(S2#s.fd, ?CHUNK) of
        {ok, Chunk} ->
            Keep = keep(Keep0, BufOff, Scanned, S2),
            Rest = binary:part(Buf, Keep, byte_size(Buf) - Keep),
            loop(<<Rest/binary, Chunk/binary>>, BufOff + Keep, S2);
        eof ->
            finish(Buf, BufOff, Keep0, S2);
        {error, _} = Error ->
            Error
    end.

%% Keeps the body of the open section in the buffer while it may still be
%% summarised from memory.
keep(Keep, BufOff, End, #s{cur = {_, _, _, Start, true}}) when End - Start =< ?SUMMARY_MAX,
                                                             Start >= BufOff ->
    min(Keep, Start - BufOff);
keep(Keep, _, _, _) ->
    Keep.

%% Handles the headers at Matches (the "\n=" in Buf). Returns where the
%% unprocessed part starts (an incomplete header, or a trailing newline
%% that may begin one).
headers(Buf, _BufOff, [], Acc, Jobs, S) ->
    Size = byte_size(Buf),
    Keep = case binary:last(Buf) of
               $\n -> Size - 1;
               _ -> Size
           end,
    {Keep, Acc, Jobs, S};
headers(Buf, BufOff, [{P, 2} | Matches], Acc, Jobs, S) ->
    Size = byte_size(Buf),
    case binary:match(Buf, <<"\n">>, [{scope, {P + 2, Size - P - 2}}]) of
        {Q, 1} ->
            {Acc1, Jobs1, S1} = close_section(BufOff + P, Buf, BufOff, Acc, Jobs, S),
            S2 = open_section(binary:part(Buf, P + 2, Q - P - 2), BufOff + Q + 1, S1),
            headers(Buf, BufOff, Matches, Acc1, Jobs1, S2);
        nomatch when Size - P > ?HEADER_MAX ->
            headers(Buf, BufOff, Matches, Acc, Jobs, S);
        nomatch ->
            {P, Acc, Jobs, S}
    end.

finish(Buf, BufOff, Keep, #s{size = Size} = S) ->
    %% A header cut off without its newline still names the last section.
    {Acc, Jobs, S1} = case Keep < byte_size(Buf) andalso Buf of
                          <<_:Keep/binary, "\n=", Line/binary>> ->
                              {A, J, S0} = close_section(BufOff + Keep, Buf, BufOff, [], [], S),
                              {A, J, open_section(Line, Size, S0)};
                          _ ->
                              {[], [], S}
                      end,
    End = case Size > 0 andalso binary:last(Buf) =:= $\n of
              true -> Size - 1;
              false -> Size
          end,
    {Acc1, Jobs1, S2} = close_section(max(End, cur_start(S1)), Buf, BufOff, Acc, Jobs, S1),
    ets:insert(S2#s.idx, Acc1),
    S3 = drain(dispatch(Jobs1, S2)),
    flush(S3),
    {LastTag, LastId} = case S1#s.cur of
                            {_, T, I, _, _} -> {T, I};
                            none -> {null, null}
                        end,
    (S3#s.progress)(#{scanned => Size, sections => S3#s.sections, skipped => S3#s.skipped}),
    {ok, #{scanned => Size, sections => S3#s.sections, skipped => S3#s.skipped,
           truncated => LastTag =/= <<"end">>, last_tag => LastTag, last_id => LastId}}.

cur_start(#s{cur = {_, _, _, Start, _}}) -> Start;
cur_start(_) -> 0.

open_section(Line0, Start, #s{tags = Tags} = S) ->
    Line = case Line0 of
               <<L:(byte_size(Line0) - 1)/binary, $\r>> -> L;
               _ -> Line0
           end,
    {Tag, Id} = case binary:split(Line, <<":">>) of
                    [T, I] -> {T, I};
                    [T] -> {T, null}
                end,
    case Tags of
        #{Tag := {No, Want}} ->
            S#s{cur = {No, Tag, Id, Start, Want}};
        _ ->
            No = map_size(Tags) + 1,
            Tag1 = binary:copy(Tag),
            Want = maps:is_key(Tag1, S#s.want),
            ets:insert(S#s.meta, {{tag, Tag1}, No}),
            S#s{tags = Tags#{Tag1 => {No, Want}}, cur = {No, Tag1, Id, Start, Want}}
    end.

close_section(_End, _Buf, _BufOff, Acc, Jobs, #s{cur = none} = S) ->
    {Acc, Jobs, S};
close_section(End, Buf, BufOff, Acc, Jobs, #s{cur = {No, Tag, Id, Start, Want}, counts = Counts} = S) ->
    Len = max(0, End - Start),
    S1 = S#s{cur = none, sections = S#s.sections + 1,
             counts = Counts#{No => maps:get(No, Counts, 0) + 1}},
    Key = {No, id_key(Id), Start},
    case Want of
        false ->
            {[{Key, Len} | Acc], Jobs, S1};
        true ->
            Body = case Start >= BufOff andalso Start + Len =< BufOff + byte_size(Buf) of
                       true -> {ok, binary:part(Buf, Start - BufOff, Len)};
                       false -> read_back(Start, Len, S1)
                   end,
            {Acc, [{Key, Len, Tag, Id, Body} | Jobs], S1}
    end.

%% A summarised body no longer in the buffer (over ?SUMMARY_MAX).
read_back(_Start, Len, _S) when Len > ?SUMMARY_HARD_MAX ->
    {error, too_large};
read_back(Start, Len, #s{path = Path}) ->
    %% Rare, so a separate fd: a pread would move the scan's position.
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try file:pread(Fd, Start, Len) of
                eof -> {ok, <<>>};
                Other -> Other
            after
                file:close(Fd)
            end;
        Error ->
            Error
    end.

%% The id as stored in the index: "<0.N.S>" as N bsl 20 + S, anything
%% else as a (copied) binary. key_id/1 turns it back.
id_key(<<"<0.", Rest/binary>> = Id) when byte_size(Rest) < 24 ->
    try
        [NB, SB] = binary:split(Rest, <<".">>),
        Int = (binary_to_integer(NB) bsl 20) bor binary_to_integer(binary:part(SB, 0, byte_size(SB) - 1)),
        %% Only ids that render back exactly, so the mapping is one-to-one.
        Id = key_id(Int),
        Int
    catch _:_ -> binary:copy(Id)
    end;
id_key(null) -> null;
id_key(Id) when is_binary(Id) -> binary:copy(Id).

key_id(Int) when is_integer(Int) ->
    <<"<0.", (integer_to_binary(Int bsr 20))/binary, $., (integer_to_binary(Int band 16#fffff))/binary, $>>>;
key_id(Id) -> Id.

%% Per-tag section counts, readable while the scan runs.
flush(#s{meta = Meta, counts = Counts}) ->
    ets:insert(Meta, [{{count, No}, N} || {No, N} <- maps:to_list(Counts)]).

%% summary workers

dispatch([], S) ->
    S;
dispatch(Jobs, #s{workers = Workers, inflight = Inflight} = S) ->
    N = length(Workers),
    Slices = slices(Jobs, N),
    Refs = [begin
                Ref = make_ref(),
                W ! {summarise, self(), Ref, Slice},
                Ref
            end || {W, Slice} <- lists:zip(Workers, Slices), Slice =/= []],
    wait(S#s{inflight = Refs ++ Inflight}, 2 * N).

slices(Jobs, N) ->
    Tagged = lists:zip(lists:seq(0, length(Jobs) - 1), Jobs),
    [[J || {I, J} <- Tagged, I rem N =:= K] || K <- lists:seq(0, N - 1)].

%% Waits for the oldest batches until at most Max are in flight.
wait(#s{inflight = Inflight} = S, Max) when length(Inflight) =< Max ->
    S;
wait(#s{inflight = Inflight} = S, Max) ->
    Ref = lists:last(Inflight),
    receive
        {summarised, Ref, Skipped} ->
            wait(S#s{inflight = lists:droplast(Inflight), skipped = S#s.skipped + Skipped}, Max)
    end.

drain(S) ->
    wait(S, 0).

worker(Mod, Idx, Meta) ->
    receive
        {summarise, From, Ref, Jobs} ->
            {Entries, Skipped} = lists:foldl(fun(Job, Acc) -> summarise(Mod, Meta, Job, Acc) end,
                                             {[], 0}, Jobs),
            ets:insert(Idx, Entries),
            From ! {summarised, Ref, Skipped},
            worker(Mod, Idx, Meta)
    end.

summarise(_Mod, _Meta, {Key, Len, _Tag, _Id, {error, _}}, {Acc, Skipped}) ->
    {[{Key, Len} | Acc], Skipped + 1};
summarise(Mod, Meta, {Key, Len, Tag, Id, {ok, Body0}}, {Acc, Skipped}) ->
    Body = case Len > ?SUMMARY_MAX of
               true -> cut_lines(Body0);
               false -> Body0
           end,
    try Mod:summary(Tag, Id, Body) of
        M when is_map(M) -> {[{Key, Len, compact(M, Meta)} | Acc], Skipped};
        _ -> {[{Key, Len} | Acc], Skipped}
    catch _:_ ->
        {[{Key, Len} | Acc], Skipped + 1}
    end.

%% Bodies over ?SUMMARY_MAX are summarised with every line cut to
%% ?LINE_MAX bytes ("..." appended), so that a huge link list or the like
%% does not hide the fields after it.
cut_lines(Body) ->
    Lines = binary:split(Body, <<"\n">>, [global]),
    iolist_to_binary(lists:join(<<"\n">>, [cut_line(L) || L <- Lines])).

cut_line(L) when byte_size(L) > ?LINE_MAX -> [binary:part(L, 0, ?LINE_MAX), <<"...">>];
cut_line(L) -> L.

%% A summary is stored as {SchemaNo, ValuesTuple}; the keys are kept once
%% per schema in the meta table. Binaries are copied: a sub-binary of the
%% chunk would keep all 4 MB of it alive in the table.
compact(M, Meta) ->
    Keys = lists:sort(maps:keys(M)),
    {schema(Keys, Meta), list_to_tuple([copy_bins(maps:get(K, M)) || K <- Keys])}.

schema(Keys, Meta) ->
    case get({schema, Keys}) of
        undefined ->
            No = case ets:lookup(Meta, {schema_keys, Keys}) of
                     [{_, N}] ->
                         N;
                     [] ->
                         N0 = ets:update_counter(Meta, schema_seq, 1, {schema_seq, 0}),
                         ets:insert(Meta, {{schema, N0}, Keys}),
                         case ets:insert_new(Meta, {{schema_keys, Keys}, N0}) of
                             true -> N0;
                             false -> ets:lookup_element(Meta, {schema_keys, Keys}, 2)
                         end
                 end,
            put({schema, Keys}, No),
            No;
        No ->
            No
    end.

copy_bins(B) when is_binary(B) -> binary:copy(B);
copy_bins([H | T]) -> [copy_bins(H) | copy_bins(T)];
copy_bins(T) when is_tuple(T) -> list_to_tuple(copy_bins(tuple_to_list(T)));
copy_bins(M) when is_map(M) -> maps:map(fun(_, V) -> copy_bins(V) end, M);
copy_bins(X) -> X.
