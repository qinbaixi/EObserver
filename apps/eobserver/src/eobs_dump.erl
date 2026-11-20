%% @doc One open crash dump: its index (ETS), the scan that fills it, and
%% the reader API the views use.
%%
%% The gen_server only owns the tables and the scan; readers work on the
%% tables and on their own raw fds, so they run concurrently and never
%% wait for the scan. A handle stays usable until the dump is closed;
%% after that, reads return {error, not_found} or raise badarg.
-module(eobs_dump).
-behaviour(gen_server).

-export([open/1, close/1, cancel/1, list/0, handle/1, id/1, path/1]).
-export([info/1, sections/2, lookup/3, count/2, read/3, reads/2, open_fd/1, pread_fd/3,
         summaries/2, summary/3, entries/2, cache/3]).
-export([start_link/3, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REG, eobs_dump_reg).
%% Largest single read; views page anything bigger.
-define(MAX_READ, 67108864).
%% At most this many progress events per second (plus a final one).
-define(PROGRESS_MS, 250).
%% How long a cached result computed during the scan is reused.
-define(SCAN_CACHE_MS, 2000).
%% Maximum per-process heap/line indices retained in Meta before evicting oldest.
-define(PROC_CACHE_MAX, 64).

-record(h, {id, pid, idx, meta, path}).

-opaque handle() :: #h{}.
-export_type([handle/0]).

%% Opens Path (or returns the id it is already open under) and starts
%% indexing it.
-spec open(binary() | string()) -> {ok, binary()} | {error, atom()}.
open(Path0) ->
    case normalize(Path0) of
        {ok, Path} ->
            case eobs_dump_files:allowed(Path) of
                false ->
                    {error, eacces};
                true ->
                    case eobs_dump_scan:check(Path) of
                        {ok, #{size := Size, mtime := Mtime}} ->
                            case catch claim(Path, 250) of
                                {error, _} = Error ->
                                    Error;
                                {existing, Id} ->
                                    {ok, Id};
                                claimed ->
                                    Pending = {pending, self()},
                                    try start(Path, Size) of
                                        {ok, _} = Ok ->
                                            eobs_dump_files:add(Path, Size, Mtime),
                                            Ok;
                                        Error ->
                                            ets:delete_object(?REG, {{path, Path}, Pending}),
                                            Error
                                    catch
                                        C:R:St ->
                                            ets:delete_object(?REG, {{path, Path}, Pending}),
                                            erlang:raise(C, R, St)
                                    end
                            end;
                        Error ->
                            Error
                    end
            end;
        Error ->
            Error
    end.

%% Opens are serialised per path through the registry: the first caller
%% inserts {path, P} => {pending, self()}; others wait for its id or
%% evict the claim if the opener died.
claim(_Path, 0) ->
    throw({error, busy});
claim(Path, Tries) ->
    Key = {path, Path},
    case ets:insert_new(?REG, {Key, {pending, self()}}) of
        true ->
            claimed;
        false ->
            case ets:lookup(?REG, Key) of
                [{_, Id}] when is_binary(Id) ->
                    case handle(Id) of
                        {ok, _} -> {existing, Id};
                        {error, not_found} ->
                            ets:delete_object(?REG, {Key, Id}),
                            claim(Path, Tries - 1)
                    end;
                [{_, {pending, Owner} = Claim}] ->
                    case is_process_alive(Owner) of
                        false ->
                            ets:delete_object(?REG, {Key, Claim}),
                            claim(Path, Tries - 1);
                        true ->
                            timer:sleep(20),
                            claim(Path, Tries - 1)
                    end;
                _ ->
                    timer:sleep(20),
                    claim(Path, Tries - 1)
            end
    end.

start(Path, Size) ->
    Id = <<"d", (integer_to_binary(ets:update_counter(?REG, seq, 1, {seq, 0})))/binary>>,
    case supervisor:start_child(eobs_dump_sup, [Id, Path, Size]) of
        {ok, _Pid} -> {ok, Id};
        {error, _} -> {error, open_failed}
    end.

%% Stops the scan and frees the index.
-spec close(binary()) -> ok | {error, not_found}.
close(Id) ->
    case handle(Id) of
        {ok, #h{pid = Pid}} ->
            _ = supervisor:terminate_child(eobs_dump_sup, Pid),
            ok;
        Error ->
            Error
    end.

%% Stops a running scan, keeping what was indexed so far.
-spec cancel(binary()) -> ok | {error, not_found}.
cancel(Id) ->
    case handle(Id) of
        {ok, #h{pid = Pid}} ->
            try gen_server:call(Pid, cancel)
            catch exit:_ -> {error, not_found}
            end;
        Error ->
            Error
    end.

%% Infos of all open dumps, oldest first.
-spec list() -> [map()].
list() ->
    Hs = case ets:whereis(?REG) of
             undefined -> [];
             _ -> [H || {{id, _}, H} <- ets:tab2list(?REG)]
         end,
    Infos = [I || H <- Hs, I <- [catch info(H)], is_map(I)],
    lists:sort(fun(#{started := A}, #{started := B}) -> A =< B end, Infos).

-spec handle(binary()) -> {ok, handle()} | {error, not_found}.
handle(Id) when is_binary(Id) ->
    case ets:whereis(?REG) =/= undefined andalso ets:lookup(?REG, {id, Id}) of
        [{_, #h{pid = Pid} = H}] ->
            case is_process_alive(Pid) of
                true -> {ok, H};
                false -> {error, not_found}
            end;
        _ ->
            {error, not_found}
    end;
handle(_) ->
    {error, not_found}.

id(#h{id = Id}) -> Id.
path(#h{path = Path}) -> Path.

-spec info(handle()) -> map().
info(#h{id = Id, idx = Idx, meta = Meta}) ->
    Get = fun(K, D) ->
                  case ets:lookup(Meta, K) of
                      [{_, V}] -> V;
                      [] -> D
                  end
          end,
    Static = Get(static, #{}),
    #{scanned := Scanned} = Progress =
        Get(progress, #{scanned => 0, sections => 0, skipped => 0}),
    Result = Get(result, #{truncated => false, last_tag => null, last_id => null}),
    Status = Get(status, scanning),
    Size = maps:get(size, Static, 0),
    Started = maps:get(started, Static, 0),
    Elapsed = max(1, Get(finished, erlang:monotonic_time(millisecond)) - Started),
    Rate = round(Scanned * 1000 / Elapsed),
    Eta = case Status of
              scanning when Rate > 0 -> round(max(0, Size - Scanned) / Rate);
              _ -> null
          end,
    Words = case {ets:info(Idx, memory), ets:info(Meta, memory)} of
                {W1, W2} when is_integer(W1), is_integer(W2) -> W1 + W2;
                _ -> error(badarg)
            end,
    maps:merge(maps:remove(started, Static),
               maps:merge(maps:merge(Progress, maps:with([truncated, last_tag, last_id], Result)),
                          #{id => Id, status => Status, error => Get(error, null),
                            elapsed_ms => Elapsed, rate => Rate, eta => Eta,
                            memory => Words * erlang:system_info(wordsize),
                            started => Get(started_at, null)})).

%% Sections of a tag in file order: [{Id, Offset, Len}].
-spec sections(handle(), binary()) -> [{binary() | null, integer(), integer()}].
sections(#h{idx = Idx} = H, Tag) ->
    case tag_no(H, Tag) of
        undefined -> [];
        No ->
            L = ets:select(Idx, [{{{No, '$1', '$2'}, '$3'}, [], [{{'$1', '$2', '$3'}}]},
                                 {{{No, '$1', '$2'}, '$3', '_'}, [], [{{'$1', '$2', '$3'}}]}]),
            [{eobs_dump_scan:key_id(I), O, Len} || {I, O, Len} <- lists:keysort(2, L)]
    end.

%% All sections with this tag and id: [{Offset, Len}].
-spec lookup(handle(), binary(), binary() | null) -> [{integer(), integer()}].
lookup(#h{idx = Idx} = H, Tag, Id) ->
    case tag_no(H, Tag) of
        undefined -> [];
        No ->
            Key = eobs_dump_scan:id_key(Id),
            lookup_next(Idx, No, Key, ets:next(Idx, {No, Key, -1}))
    end.

lookup_next(Idx, No, Id, {No, Id, Off} = Key) ->
    [{Off, element(2, hd(ets:lookup(Idx, Key)))} | lookup_next(Idx, No, Id, ets:next(Idx, Key))];
lookup_next(_, _, _, _) ->
    [].

-spec count(handle(), binary()) -> non_neg_integer().
count(#h{meta = Meta} = H, Tag) ->
    case tag_no(H, Tag) of
        undefined -> 0;
        No ->
            case ets:lookup(Meta, {count, No}) of
                [{_, N}] -> N;
                [] -> 0
            end
    end.

%% Reads Len bytes at Offset (fewer at the end of the file).
-spec read(handle(), integer(), integer()) -> {ok, binary()} | {error, term()}.
read(_H, Off, Len) when not is_integer(Off); not is_integer(Len); Off < 0; Len < 0 ->
    {error, badarg};
read(_H, _Off, Len) when Len > ?MAX_READ ->
    {error, too_large};
read(#h{} = H, Off, Len) ->
    case reads(H, [{Off, Len}]) of
        [Result] -> Result;
        {error, _} = Error -> Error
    end.

%% Several reads on one fd: [{ok, Bin} | {error, _}], in order. The total
%% is capped like a single read.
-spec reads(handle(), [{integer(), integer()}]) -> [{ok, binary()} | {error, term()}] | {error, term()}.
reads(#h{path = Path} = H, Locs) ->
    Valid = lists:all(fun({O, L}) -> is_integer(O) andalso O >= 0 andalso is_integer(L) andalso L >= 0;
                         (_) -> false
                      end, Locs),
    case Valid andalso lists:sum([L || {_, L} <- Locs]) =< ?MAX_READ of
        _ when not Valid -> {error, badarg};
        false -> {error, too_large};
        true ->
            alive(H),
            case file:open(Path, [read, raw, binary]) of
                {ok, Fd} ->
                    try [pread(Fd, O, L) || {O, L} <- Locs]
                    after file:close(Fd)
                    end;
                Error ->
                    Error
            end
    end.

open_fd(#h{path = Path} = H) ->
    alive(H),
    file:open(Path, [read, raw, binary]).

pread_fd(_Fd, _Off, 0) -> {ok, <<>>};
pread_fd(Fd, Off, Len) when is_integer(Off), Off >= 0, is_integer(Len), Len > 0, Len =< ?MAX_READ ->
    pread(Fd, Off, Len);
pread_fd(_Fd, _Off, Len) when is_integer(Len), Len > ?MAX_READ ->
    {error, too_large};
pread_fd(_Fd, _Off, _Len) ->
    {error, badarg}.

pread(_Fd, _Off, 0) -> {ok, <<>>};
pread(Fd, Off, Len) ->
    case file:pread(Fd, Off, Len) of
        eof -> {ok, <<>>};
        Other -> Other
    end.

%% Summaries of a tag in file order: [{Id, Map}].
-spec summaries(handle(), binary()) -> [{binary() | null, map()}].
summaries(#h{idx = Idx, meta = Meta} = H, Tag) ->
    case tag_no(H, Tag) of
        undefined -> [];
        No ->
            L = lists:keysort(1, ets:select(Idx, [{{{No, '$1', '$2'}, '_', '$3'}, [],
                                                   [{{'$2', '$1', '$3'}}]}])),
            Schemas = load_schemas(Meta),
            [{eobs_dump_scan:key_id(Id), eobs_dump_scan:expand_summary(S, Schemas)}
             || {_, Id, S} <- L]
    end.

load_schemas(Meta) ->
    case ets:lookup(Meta, schema_seq) of
        [{_, Max}] when is_integer(Max), Max > 0 ->
            maps:from_list([{N, K} || N <- lists:seq(1, Max),
                                      [{_, K}] <- [ets:lookup(Meta, {schema, N})]]);
        _ ->
            #{}
    end.

-spec summary(handle(), binary(), binary() | null) -> {ok, map()} | not_found.
summary(#h{idx = Idx, meta = Meta} = H, Tag, Id) ->
    case tag_no(H, Tag) of
        undefined -> not_found;
        No ->
            IdKey = eobs_dump_scan:id_key(Id),
            case ets:next(Idx, {No, IdKey, -1}) of
                {No, IdKey, _} = Key ->
                    case ets:lookup(Idx, Key) of
                        [{_, _, S}] -> {ok, eobs_dump_scan:expand_summary(S, Meta)};
                        _ -> not_found
                    end;
                _ ->
                    not_found
            end
    end.

%% Memoises Fun() under Key for this dump. While the scan runs the index
%% is still growing, so a result is only reused for ?SCAN_CACHE_MS; one
%% computed (started) after the scan is kept for good. Per-process heap
%% and line indices are bounded so browsing many processes cannot OOM.
-spec cache(handle(), term(), fun(() -> T)) -> T.
cache(#h{meta = Meta}, Key, Fun) ->
    Now = erlang:monotonic_time(millisecond),
    Scanning = ets:lookup(Meta, status) =:= [{status, scanning}],
    case ets:lookup(Meta, {cache, Key}) of
        [{_, Value, final}] ->
            Value;
        [{_, Value, T}] when Scanning, Now - T < ?SCAN_CACHE_MS ->
            Value;
        _ ->
            Value = Fun(),
            ets:insert(Meta, {{cache, Key}, Value, case Scanning of true -> Now; false -> final end}),
            maybe_track_proc_cache(Meta, Key),
            Value
    end.

maybe_track_proc_cache(Meta, Key) when is_tuple(Key),
                                       (element(1, Key) =:= eobs_heap orelse
                                        element(1, Key) =:= eobs_lines) ->
    Seq = ets:update_counter(Meta, proc_cache_seq, 1, {proc_cache_seq, 0}),
    ets:insert(Meta, {{proc_cache, Seq}, Key}),
    case Seq > ?PROC_CACHE_MAX andalso Seq rem 8 =:= 0 of
        true ->
            Cutoff = Seq - ?PROC_CACHE_MAX,
            Start = max(1, Cutoff - 16),
            evict_proc_cache(Meta, Start, Cutoff);
        false ->
            ok
    end;
maybe_track_proc_cache(_, _) ->
    ok.

evict_proc_cache(_Meta, S, Cutoff) when S > Cutoff ->
    ok;
evict_proc_cache(Meta, S, Cutoff) ->
    case ets:take(Meta, {proc_cache, S}) of
        [{_, OldKey}] -> ets:delete(Meta, {cache, OldKey});
        [] -> ok
    end,
    evict_proc_cache(Meta, S + 1, Cutoff).

%% All sections of a tag with their summaries, from one pass over the
%% index (so the two always agree, even during the scan), in file order:
%% [{Id, Offset, Len, map() | none}].
-spec entries(handle(), binary()) -> [{binary() | null, integer(), integer(), map() | none}].
entries(#h{idx = Idx, meta = Meta} = H, Tag) ->
    case tag_no(H, Tag) of
        undefined -> [];
        No ->
            L = ets:select(Idx, [{{{No, '$1', '$2'}, '$3'}, [], [{{'$2', '$1', '$3', none}}]},
                                 {{{No, '$1', '$2'}, '$3', '$4'}, [], [{{'$2', '$1', '$3', '$4'}}]}]),
            Schemas = load_schemas(Meta),
            [{eobs_dump_scan:key_id(Id), Off, Len,
              case S of
                  none -> none;
                  _ -> eobs_dump_scan:expand_summary(S, Schemas)
              end} || {Off, Id, Len, S} <- lists:keysort(1, L)]
    end.

tag_no(#h{meta = Meta}, Tag) ->
    case ets:lookup(Meta, {tag, Tag}) of
        [{_, No}] -> No;
        [] -> undefined
    end.

alive(#h{meta = Meta}) ->
    %% Raises badarg once the dump is closed, like the table reads.
    _ = ets:info(Meta, size) =:= undefined andalso error(badarg),
    ok.

normalize(Path) when is_binary(Path), Path =/= <<>> ->
    case eobs_dump_files:valid_path(Path) of
        true ->
            {ok, unicode:characters_to_binary(eobs_dump_files:absolute(unicode:characters_to_list(Path)))};
        false ->
            {error, badarg}
    end;
normalize([_ | _] = Path) ->
    case eobs_dump_files:valid_path(Path) of
        true -> {ok, unicode:characters_to_binary(eobs_dump_files:absolute(Path))};
        false -> {error, badarg}
    end;
normalize(_) ->
    {error, badarg}.

%% gen_server

start_link(Id, Path, Size) ->
    gen_server:start_link(?MODULE, {Id, Path, Size}, []).

init({Id, Path, Size}) ->
    process_flag(trap_exit, true),
    Idx = ets:new(eobs_dump_idx, [ordered_set, public, {read_concurrency, true}]),
    Meta = ets:new(eobs_dump_meta, [set, public, {read_concurrency, true}]),
    H = #h{id = Id, pid = self(), idx = Idx, meta = Meta, path = Path},
    ets:insert(Meta, [{static, #{path => Path, name => filename:basename(Path), size => Size,
                                 started => erlang:monotonic_time(millisecond)}},
                      {started_at, erlang:system_time(second)},
                      {status, scanning}]),
    ets:insert(?REG, [{{id, Id}, H}, {{path, Path}, Id}]),
    Scanner = spawn_scan(H),
    {ok, #{h => H, scanner => Scanner}}.

spawn_scan(#h{path = Path, idx = Idx, meta = Meta} = H) ->
    {Pid, Ref} = spawn_monitor(
                   fun() ->
                           Progress = fun(P) -> progress(H, P) end,
                           exit({scan, eobs_dump_scan:scan(Path, Idx, Meta, #{progress => Progress})})
                   end),
    {Pid, Ref}.

%% Runs in the scanner: records progress and publishes it, throttled.
progress(#h{meta = Meta} = H, P) ->
    ets:insert(Meta, {progress, P}),
    Now = erlang:monotonic_time(millisecond),
    case get(last_progress) of
        Last when is_integer(Last), Now - Last < ?PROGRESS_MS -> ok;
        _ ->
            put(last_progress, Now),
            publish(H)
    end.

publish(H) ->
    catch eobs_events:publish(dump_progress, info(H)),
    ok.

handle_call(cancel, _From, #{h := #h{meta = Meta} = H, scanner := Scanner} = State) ->
    case Scanner of
        {Pid, Ref} ->
            stop_scanner(Pid, Ref, Meta),
            ets:insert(Meta, [{status, cancelled}, {finished, erlang:monotonic_time(millisecond)}]),
            publish(H);
        undefined ->
            ok
    end,
    {reply, ok, State#{scanner := undefined}};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, Reason}, #{h := #h{meta = Meta} = H, scanner := {_, Ref}} = State) ->
    Now = erlang:monotonic_time(millisecond),
    case Reason of
        {scan, {ok, Result}} ->
            ets:insert(Meta, [{result, Result}, {status, ready}, {finished, Now}]);
        {scan, {error, Error}} ->
            ets:insert(Meta, [{status, failed}, {error, Error}, {finished, Now}]);
        _ ->
            logger:warning("crash dump scan of ~ts crashed: ~p", [H#h.path, Reason]),
            ets:insert(Meta, [{status, failed}, {error, scan_crashed}, {finished, Now}])
    end,
    publish(H),
    {noreply, State#{scanner := undefined}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{h := #h{id = Id, path = Path, meta = Meta}, scanner := Scanner}) ->
    case Scanner of
        {Pid, Ref} -> stop_scanner(Pid, Ref, Meta);
        undefined -> ok
    end,
    catch ets:delete(?REG, {id, Id}),
    catch ets:delete_object(?REG, {{path, Path}, Id}),
    ok.

%% Kills the scanner and any summary workers and waits for all of them to
%% exit so no late ETS writes occur after status flips or tables close.
stop_scanner(Pid, Ref, Meta) ->
    Workers = case catch ets:take(Meta, scan_workers) of
                  [{_, Ws}] when is_list(Ws) -> Ws;
                  _ -> []
              end,
    WRefs = [{W, monitor(process, W)} || W <- Workers],
    exit(Pid, kill),
    [exit(W, kill) || {W, _} <- WRefs],
    receive {'DOWN', Ref, process, Pid, _} -> ok after 5000 -> demonitor(Ref, [flush]) end,
    [receive {'DOWN', R, process, W, _} -> ok after 5000 -> demonitor(R, [flush]) end
     || {W, R} <- WRefs],
    ok.
