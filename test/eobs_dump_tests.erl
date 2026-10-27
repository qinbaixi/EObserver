-module(eobs_dump_tests).
-include_lib("eunit/include/eunit.hrl").

%% This module doubles as the summary hook (eobs_dump_parse stand-in).
-export([summary_tags/0, summary/3]).

-define(CHUNK, 4194304).

summary_tags() -> [<<"proc">>, <<"port">>].

summary(<<"proc">>, Id, Body) ->
    case binary:match(Body, <<"crash me">>) of
        nomatch -> #{id => Id, len => byte_size(Body), first => hd(binary:split(Body, <<"\n">>))};
        _ -> error(boom)
    end;
summary(<<"port">>, _Id, _Body) ->
    skip.

%% helpers

tmp_dir() ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
                        lists:concat(["eobs_dump_tests_", os:getpid(), "_",
                                     erlang:unique_integer([positive])])),
    ok = filelib:ensure_path(Dir),
    Dir.

write(Dir, Name, Data) ->
    File = filename:join(Dir, Name),
    ok = file:write_file(File, Data),
    File.

new_tables() ->
    {ets:new(idx, [ordered_set, public]), ets:new(meta, [set, public])}.

scan(File) ->
    {Idx, Meta} = new_tables(),
    {ok, Result} = eobs_dump_scan:scan(File, Idx, Meta, #{summary_mod => ?MODULE}),
    {Idx, Meta, Result}.

%% All sections as {Tag, Id, Off, Len}, in file order, from the index.
indexed(Idx, Meta) ->
    Tags = maps:from_list([{No, T} || [T, No] <- ets:match(Meta, {{tag, '$1'}, '$2'})]),
    L = [{Off, maps:get(No, Tags), eobs_dump_scan:key_id(Id), element(2, O)}
         || O <- ets:tab2list(Idx), {No, Id, Off} <- [element(1, O)]],
    [{T, I, O, Len} || {O, T, I, Len} <- lists:sort(L)].

%% The same, computed naively from the whole file in memory.
reference(Bin0) ->
    Bin = <<"\n", Bin0/binary>>,
    Heads = [begin
                 {Q, 1} = binary:match(Bin, <<"\n">>, [{scope, {P + 2, byte_size(Bin) - P - 2}}]),
                 Line = binary:part(Bin, P + 2, Q - P - 2),
                 {Tag, Id} = case binary:split(Line, <<":">>) of
                                 [T, I] -> {T, I};
                                 [T] -> {T, null}
                             end,
                 {P, Tag, Id, Q + 1}
             end || {P, 2} <- binary:matches(Bin, <<"\n=">>)],
    End = case binary:last(Bin) of
              $\n -> byte_size(Bin) - 1;
              _ -> byte_size(Bin)
          end,
    Ends = [P || {P, _, _, _} <- tl(Heads)] ++ [End],
    %% Offsets in Bin are one past the file's (the leading newline).
    [{Tag, Id, Start - 1, max(0, E - Start)} || {{_, Tag, Id, Start}, E} <- lists:zip(Heads, Ends)].

filler(N) when N =< 0 -> <<>>;
filler(N) -> <<(binary:copy(<<"0123456789abcdef">>, N div 16))/binary,
               (binary:copy(<<"x">>, N rem 16))/binary>>.

%% A body that fills the file up to Pos, so that the next header's
%% newline sits at file offset Pos.
pad_to(Acc, Pos) ->
    Cur = iolist_size(Acc),
    [Acc, filler(Pos - Cur)].

%% scanner

boundaries_test() ->
    Dir = tmp_dir(),
    Big = iolist_to_binary(lists:join(<<"\n">>, [binary:copy(<<"L">>, 5000) || _ <- lists:seq(1, 30)])),
    Parts0 = [<<"=erl_crash_dump:0.5\nMon Oct 27 2026\n">>,
              <<"=proc:<0.0.0>\nState: Running\nName: init">>],
    %% "\n" is the last byte of the first chunk, "=" the first of the next.
    P1 = pad_to(Parts0, ?CHUNK - 1),
    P2 = [P1, <<"\n=proc:<0.1.0>\nState: Waiting\nfirst chunk two">>],
    %% A header line split by the second chunk boundary.
    P3 = pad_to(P2, 2 * ?CHUNK - 5),
    P4 = [P3, <<"\n=proc:<0.2.0>\nState: Garbing\n">>],
    %% A summarised body that spans the third boundary.
    P5 = pad_to(P4, 3 * ?CHUNK - 100),
    P6 = [P5, <<"\n=proc:<0.3.0>\nState: Exiting\n">>, filler(300)],
    %% A body too big to keep, and one whose summary crashes.
    %% A big summarised body across the fourth boundary (read back).
    P7 = [pad_to([P6, <<"\n=proc:<0.4.0>\nState: Big\n">>, Big], 4 * ?CHUNK - 50000),
          <<"\n=proc:<0.6.0>\nState: Spans\n">>, Big,
          <<"\n=proc:<0.5.0>\ncrash me\n=port:#Port<0.1>\nSlot: 1\n=ets:<0.1.0>\nTable: a\n=ets:<0.1.0>\nTable: b\n">>,
          <<"=hash_table:atom_tab\n=index_table:atom_tab\nsize: 1\n=end\n">>],
    Bin = iolist_to_binary(P7),
    File = write(Dir, "b.dump", Bin),
    {Idx, Meta, Result} = scan(File),
    ?assertEqual(reference(Bin), indexed(Idx, Meta)),
    ?assertMatch(#{truncated := false, last_tag := <<"end">>, skipped := 1,
                   scanned := S} when S =:= byte_size(Bin), Result),
    Schemas = maps:from_list([{N, K} || [N, K] <- ets:match(Meta, {{schema, '$1'}, '$2'})]),
    Sums = maps:from_list([{eobs_dump_scan:key_id(Id), eobs_dump_scan:expand_summary(Sum, Schemas)}
                           || {{_, Id, _}, _, Sum} <- ets:tab2list(Idx)]),
    ?assertEqual([<<"<0.0.0>">>, <<"<0.1.0>">>, <<"<0.2.0>">>, <<"<0.3.0>">>, <<"<0.4.0>">>,
                  <<"<0.6.0>">>],
                 lists:sort(maps:keys(Sums))),
    ?assertEqual(<<"State: Exiting">>, maps:get(first, maps:get(<<"<0.3.0>">>, Sums))),
    ?assertEqual(<<"State: Garbing">>, maps:get(first, maps:get(<<"<0.2.0>">>, Sums))),
    %% The big body was passed with its long lines cut.
    #{len := BigLen} = maps:get(<<"<0.4.0>">>, Sums),
    ?assertEqual(byte_size(<<"State: Big\n">>) + 30 * (4096 + 3) + 29, BigLen),
    #{len := SpansLen, first := <<"State: Spans">>} = maps:get(<<"<0.6.0>">>, Sums),
    ?assertEqual(byte_size(<<"State: Spans\n">>) + 30 * (4096 + 3) + 29, SpansLen),
    ok = file:del_dir_r(Dir).

truncated_test() ->
    Dir = tmp_dir(),
    Bin = <<"=erl_crash_dump:0.5\nnow\n=proc:<0.0.0>\nState: Running\n=proc_heap:<0.0.0>\nA:t2:H1,H2\nB:lI1">>,
    {Idx, Meta, Result} = scan(write(Dir, "t.dump", Bin)),
    ?assertMatch(#{truncated := true, last_tag := <<"proc_heap">>, last_id := <<"<0.0.0>">>}, Result),
    ?assertEqual(reference(Bin), indexed(Idx, Meta)),
    %% Cut off inside a header line.
    Bin2 = <<"=erl_crash_dump:0.5\nnow\n=proc:<0.0.0>\nState: Running\n=proc_st">>,
    {Idx2, Meta2, Result2} = scan(write(Dir, "t2.dump", Bin2)),
    ?assertMatch(#{truncated := true, last_tag := <<"proc_st">>, last_id := null}, Result2),
    ?assertMatch([_, {<<"proc">>, <<"<0.0.0>">>, _, 14}, {<<"proc_st">>, null, _, 0}],
                 indexed(Idx2, Meta2)),
    ok = file:del_dir_r(Dir).

crlf_and_empty_bodies_test() ->
    Dir = tmp_dir(),
    Bin = <<"=erl_crash_dump:0.5\r\nnow\r\n=atoms\r\n=loaded_modules\r\nx\r\n=end\r\n">>,
    {Idx, Meta, _} = scan(write(Dir, "c.dump", Bin)),
    ?assertMatch([{<<"erl_crash_dump">>, <<"0.5">>, _, _}, {<<"atoms">>, null, _, 0},
                  {<<"loaded_modules">>, null, _, _}, {<<"end">>, null, _, _}],
                 indexed(Idx, Meta)),
    ok = file:del_dir_r(Dir).

check_test() ->
    Dir = tmp_dir(),
    ?assertEqual({error, eisdir}, eobs_dump_scan:check(Dir)),
    ?assertEqual({error, enoent}, eobs_dump_scan:check(filename:join(Dir, "nope"))),
    ?assertEqual({error, empty}, eobs_dump_scan:check(write(Dir, "e", <<>>))),
    ?assertEqual({error, not_a_dump}, eobs_dump_scan:check(write(Dir, "n", <<"hello world, not a dump">>))),
    ?assertMatch({ok, #{size := 21}}, eobs_dump_scan:check(write(Dir, "d", <<"=erl_crash_dump:0.5\nx">>))),
    ok = file:del_dir_r(Dir).

%% A dump written by this very emulator, compared with the naive index.
real_dump_test_() ->
    {timeout, 60,
     fun() ->
             case os:type() of
                 {unix, _} ->
                     Dir = tmp_dir(),
                     File = filename:join(Dir, "erl_crash.dump"),
                     Erl = filename:join([code:root_dir(), "bin", "erl"]),
                     _ = os:cmd("ERL_CRASH_DUMP=" ++ File ++ " " ++ Erl ++
                                    " -noshell -eval 'erlang:halt(\"eunit dump\")' 2>&1"),
                     {ok, Bin} = file:read_file(File),
                     {Idx, Meta, Result} = scan(File),
                     ?assertEqual(reference(Bin), indexed(Idx, Meta)),
                     ?assertMatch(#{truncated := false, skipped := 0}, Result),
                     ok = file:del_dir_r(Dir);
                 _ ->
                     ok
             end
     end}.

id_key_test() ->
    [?assertEqual(Id, eobs_dump_scan:key_id(eobs_dump_scan:id_key(Id)))
     || Id <- [<<"<0.0.0>">>, <<"<0.123456.7>">>, <<"<0.01.0>">>, <<"<0.1.0">>, <<"<0.1.2.3>">>,
               <<"<0.-1.0>">>, <<"<1.2.3>">>, <<"#Port<0.5>">>, <<"<0.>">>, <<"<0.1.>">>, <<>>]],
    ?assert(is_integer(eobs_dump_scan:id_key(<<"<0.123456.7>">>))),
    ?assert(is_binary(eobs_dump_scan:id_key(<<"<0.01.0>">>))),
    ?assertEqual(null, eobs_dump_scan:id_key(null)).

%% eobs_dump + eobs_dump_files + eobs_api

dump_server_test_() ->
    {setup, fun start_servers/0, fun stop_servers/1,
     fun(Dir) ->
             {inorder,
              [{"lifecycle", fun() -> lifecycle(Dir) end},
              {"api", fun() -> api(Dir) end},
              {"browse", fun() -> browse(Dir) end},
               {"cancel", {timeout, 60, fun() -> cancel(Dir) end}}]}
     end}.

start_servers() ->
    Dir = tmp_dir(),
    application:set_env(eobserver, config_dir, filename:join(Dir, "config")),
    {ok, F} = eobs_dump_files:start_link(),
    {ok, S} = eobs_dump_sup:start_link(),
    unlink(F),
    unlink(S),
    Dir.

stop_servers(Dir) ->
    [begin
         Ref = monitor(process, whereis(P)),
         exit(whereis(P), shutdown),
         receive {'DOWN', Ref, _, _, _} -> ok end
     end || P <- [eobs_dump_sup, eobs_dump_files]],
    application:unset_env(eobserver, config_dir),
    ok = file:del_dir_r(Dir).

wait_ready(H) ->
    wait_ready(H, 500).
wait_ready(H, 0) ->
    eobs_dump:info(H);
wait_ready(H, N) ->
    case eobs_dump:info(H) of
        #{status := scanning} -> timer:sleep(20), wait_ready(H, N - 1);
        Info -> Info
    end.

sample() ->
    <<"=erl_crash_dump:0.5\nnow\nSlogan: test\n=proc:<0.0.0>\nState: Running\n",
      "=ets:<0.0.0>\nTable: a\n=ets:<0.0.0>\nTable: b\n=ets:<0.1.0>\nTable: c\n=end\n">>.

lifecycle(Dir) ->
    File = write(Dir, "erl_crash.dump", sample()),
    {ok, Id} = eobs_dump:open(list_to_binary(File)),
    %% The same file (spelt differently) is not opened twice.
    {ok, Id} = eobs_dump:open(list_to_binary(filename:join([Dir, ".", "erl_crash.dump"]))),
    {ok, H} = eobs_dump:handle(Id),
    #{status := ready, truncated := false, size := Size, scanned := Size, sections := 6,
      name := <<"erl_crash.dump">>, memory := Mem} = wait_ready(H),
    ?assert(Mem > 0),
    ?assertEqual(3, eobs_dump:count(H, <<"ets">>)),
    ?assertEqual(0, eobs_dump:count(H, <<"nope">>)),
    [{<<"<0.0.0>">>, O1, L1}, {<<"<0.0.0>">>, O2, _}, {<<"<0.1.0>">>, _, _}] =
        eobs_dump:sections(H, <<"ets">>),
    ?assertEqual([{O1, L1}, {O2, 8}], eobs_dump:lookup(H, <<"ets">>, <<"<0.0.0>">>)),
    ?assertEqual([], eobs_dump:lookup(H, <<"ets">>, <<"<0.9.0>">>)),
    ?assertEqual({ok, <<"Table: a">>}, eobs_dump:read(H, O1, L1)),
    ?assertEqual([{ok, <<"Table: a">>}, {ok, <<"Table: b">>}],
                 eobs_dump:reads(H, [{O1, L1}, {O2, 8}])),
    ?assertEqual({ok, <<>>}, eobs_dump:read(H, Size + 10, 5)),
    ?assertEqual({error, too_large}, eobs_dump:read(H, 0, 1 bsl 40)),
    ?assertEqual({error, badarg}, eobs_dump:read(H, -1, 5)),
    ?assertEqual(not_found, eobs_dump:summary(H, <<"nope">>, <<"x">>)),
    ?assertEqual([], eobs_dump:summaries(H, <<"nope">>)),
    ?assertMatch([{<<"<0.0.0>">>, O1, L1, _}, {<<"<0.0.0>">>, O2, 8, _}, {<<"<0.1.0>">>, _, _, _}],
                 eobs_dump:entries(H, <<"ets">>)),
    ?assertEqual(42, eobs_dump:cache(H, k, fun() -> 42 end)),
    ?assertEqual(42, eobs_dump:cache(H, k, fun() -> 43 end)),
    [#{status := ready}] = [I || #{id := Id0} = I <- eobs_dump:list(), Id0 =:= Id],
    [#{path := P, size := Size} | _] = eobs_dump_files:recent(),
    ?assertEqual(list_to_binary(File), P),
    ok = eobs_dump:close(Id),
    ?assertEqual({error, not_found}, eobs_dump:handle(Id)),
    ?assertEqual({error, not_found}, eobs_dump:close(Id)),
    ?assertError(badarg, eobs_dump:count(H, <<"ets">>)),
    ?assertEqual([], [I || #{id := Id0} = I <- eobs_dump:list(), Id0 =:= Id]),
    %% Reopening gives a new id; errors come back as atoms.
    {ok, Id2} = eobs_dump:open(list_to_binary(File)),
    ?assertNotEqual(Id, Id2),
    ok = eobs_dump:close(Id2),
    ?assertEqual({error, not_a_dump}, eobs_dump:open(list_to_binary(write(Dir, "x.dump", <<"nope">>)))),
    ?assertEqual({error, enoent}, eobs_dump:open(<<"/nonexistent/erl_crash.dump">>)),
    ?assertEqual({error, badarg}, eobs_dump:open(<<>>)),
    %% Recent files persist, missing ones are dropped.
    {ok, Terms} = file:consult(eobs_dump_files:file()),
    ?assertEqual([maps:get(path, T) || T <- Terms], [maps:get(path, T) || T <- eobs_dump_files:recent()]),
    Gone = write(Dir, "gone.dump", sample()),
    {ok, Id3} = eobs_dump:open(list_to_binary(Gone)),
    ok = eobs_dump:close(Id3),
    N = length(eobs_dump_files:recent()),
    ok = file:delete(Gone),
    ?assertEqual(N - 1, length(eobs_dump_files:recent())).

api(Dir) ->
    File = list_to_binary(write(Dir, "api.dump", sample())),
    {ok, #{id := Id, info := #{path := File}}} =
        eobs_api:request(<<"dump.open">>, #{<<"path">> => File}),
    {ok, Open} = eobs_api:request(<<"dump.list">>, #{}),
    ?assertEqual([Id], [I || #{id := I} <- Open, I =:= Id]),
    {ok, #{id := Id}} = eobs_api:request(<<"dump.info">>, #{<<"id">> => Id}),
    {ok, [_ | _]} = eobs_api:request(<<"dump.recent">>, #{}),
    {error, not_found} = eobs_api:request(<<"dump.overview">>, #{<<"id">> => <<"nope">>}),
    ok = eobs_api:request(<<"dump.close">>, #{<<"id">> => Id}),
    {error, not_found} = eobs_api:request(<<"dump.close">>, #{<<"id">> => Id}),
    {ok, #{entries := _}} = eobs_api:request(<<"dump.browse">>, #{<<"path">> => list_to_binary(Dir)}),
    %% Results encode as JSON.
    {ok, Recent} = eobs_api:request(<<"dump.recent">>, #{}),
    ?assert(is_binary(eobs_json:encode(Recent))).

browse(Dir0) ->
    Dir = filename:join(Dir0, "browse"),
    ok = filelib:ensure_path(filename:join(Dir, "sub")),
    ok = filelib:ensure_path(filename:join(Dir, "Alpha")),
    _ = write(Dir, ".hidden", <<>>),
    _ = write(Dir, "erl_crash.dump", <<>>),
    _ = write(Dir, "node.DUMP", <<>>),
    _ = write(Dir, "notes.txt", <<"abc">>),
    {ok, #{path := P, parent := Parent, entries := Entries, roots := Roots}} =
        eobs_dump_files:browse(list_to_binary(Dir)),
    ?assertEqual(list_to_binary(Dir), P),
    ?assertEqual(list_to_binary(Dir0), Parent),
    ?assertEqual([{<<"Alpha">>, true, false}, {<<"sub">>, true, false},
                  {<<"erl_crash.dump">>, false, true}, {<<"node.DUMP">>, false, true},
                  {<<"notes.txt">>, false, false}],
                 [{N, D, Dp} || #{name := N, dir := D, dump := Dp} <- Entries]),
    ?assertMatch([#{size := 3}], [E || #{name := <<"notes.txt">>} = E <- Entries]),
    ?assertMatch([#{kind := home}, #{kind := cwd} | _], Roots),
    {ok, #{path := P}} = eobs_dump_files:browse(list_to_binary(filename:join([Dir, "sub", ".."]))),
    {ok, #{parent := null}} = eobs_dump_files:browse(<<"/">>),
    {ok, #{path := _}} = eobs_dump_files:browse(null),
    ?assertEqual({error, enoent}, eobs_dump_files:browse(list_to_binary(filename:join(Dir, "nope")))),
    ?assertEqual({error, enotdir}, eobs_dump_files:browse(list_to_binary(filename:join(Dir, "notes.txt")))).

cancel(Dir) ->
    %% Big enough to still be scanning when cancelled.
    File = filename:join(Dir, "big.dump"),
    {ok, Fd} = file:open(File, [write, raw, binary]),
    ok = file:write(Fd, <<"=erl_crash_dump:0.5\nnow\n">>),
    Block = iolist_to_binary([[<<"=proc:<0.">>, integer_to_binary(N), <<".0>\nState: Waiting\n">>]
                              || N <- lists:seq(1, 20000)]),
    [ok = file:write(Fd, Block) || _ <- lists:seq(1, 100)],
    ok = file:close(Fd),
    {ok, Id} = eobs_dump:open(list_to_binary(File)),
    {ok, H} = eobs_dump:handle(Id),
    ok = eobs_dump:cancel(Id),
    #{status := Status, scanned := Scanned, size := Size} = eobs_dump:info(H),
    case Status of
        cancelled -> ?assert(Scanned < Size);
        ready -> ok   % a fast machine finished first
    end,
    ok = eobs_dump:close(Id).
