#!/usr/bin/env escript
%%! +S 4 -env ERL_CRASH_DUMP_SECONDS 600
%% Synthetic multi-GB erl_crash.dump for benchmarking the crash dump viewer.
%%
%%   gen_big_dump.escript OUT SIZE_MB [BASE [heavy | many]]
%%
%% Writes a real dump of a busy node to BASE (default OUT.base.dump,
%% reused if present): `heavy` (default) has 20,000 varied processes with
%% sizeable heaps, ETS tables, message queues, dictionaries and deep
%% stacks; `many` has 200,000 small processes, for a section-dense dump.
%% Then it grows the dump to about SIZE_MB by
%% replicating the per-process sections (=proc, =proc_dictionary,
%% =proc_messages, =proc_stack, =proc_heap) and =ets/=timer with fresh pids
%% (<0.N.K> for copy K). Everything else is written once, in its place.
%%
%%   gen_big_dump.escript --bench FILE [EBIN...]
%%
%% Scans FILE with eobs_dump_scan and prints wall time, throughput and
%% index memory. EBIN defaults to _build/default/lib/*/ebin.
-mode(compile).

main(["--base", Out, Kind]) ->
    base_node(Out, Kind);
main(["--bench", File | Ebin]) ->
    bench(File, Ebin);
main([Out, SizeMb]) ->
    main([Out, SizeMb, Out ++ ".base.dump"]);
main([Out, SizeMb, Base]) ->
    main([Out, SizeMb, Base, "heavy"]);
main([Out, SizeMb, Base, Kind]) when Kind =:= "heavy"; Kind =:= "many" ->
    case filelib:is_regular(Base) of
        true -> ok;
        false ->
            io:format("writing base dump ~s~n", [Base]),
            Cmd = io_lib:format("escript ~s --base ~s ~s", [escript:script_name(), Base, Kind]),
            io:format("~s", [os:cmd(lists:flatten(Cmd))])
    end,
    grow(Base, Out, list_to_integer(SizeMb) * 1048576);
main(_) ->
    io:format("usage: gen_big_dump.escript OUT SIZE_MB [BASE [heavy | many]]~n"
              "       gen_big_dump.escript --bench FILE [EBIN...]~n"),
    halt(1).

%% base dump

base_node(Out, "many") ->
    os:putenv("ERL_CRASH_DUMP", Out),
    _ = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 200000)],
    timer:sleep(1000),
    erlang:halt("synthetic benchmark dump (many processes)");
base_node(Out, "heavy") ->
    os:putenv("ERL_CRASH_DUMP", Out),
    Shared = binary:copy(<<"shared refc binary ">>, 1000),
    Tabs = [begin
                T = ets:new(list_to_atom("bench_tab_" ++ integer_to_list(I)), [set, public]),
                ets:insert(T, [{K, <<"value ", K:32>>, lists:seq(1, 5)} || K <- lists:seq(1, 1000)]),
                T
            end || I <- lists:seq(1, 50)],
    Pids = [spawn(fun() -> worker(I, Shared) end) || I <- lists:seq(1, 20000)],
    [P ! {msg, I, lists:seq(1, 10)} || {P, I} <- lists:zip(Pids, lists:seq(1, 20000)),
                                      I rem 10 =:= 7, _ <- lists:seq(1, 50)],
    [erlang:send_after(3600000, P, wake) || {P, I} <- lists:zip(Pids, lists:seq(1, 20000)),
                                            I rem 100 =:= 0],
    timer:sleep(2000),
    _ = Tabs,
    erlang:halt("synthetic benchmark dump").

worker(I, Shared) ->
    State = [{N, <<"name-", N:32>>, [a, b, c], #{k => N, bin => Shared}} || N <- lists:seq(1, 50)],
    case I rem 10 of
        6 -> [put({key, N}, {value, N, "a string"}) || N <- lists:seq(1, 20)], idle(State);
        8 -> register(list_to_atom("bench_worker_" ++ integer_to_list(I)), self()), idle(State);
        9 -> deep(50, State);
        _ -> idle(State)
    end.

idle(State) ->
    receive stop -> State end.

deep(0, State) -> idle(State);
deep(N, State) -> [N | deep(N - 1, State)].

%% growing

-define(REPLICATED, [<<"proc">>, <<"proc_dictionary">>, <<"proc_messages">>, <<"proc_stack">>,
                     <<"proc_heap">>, <<"ets">>, <<"timer">>]).

grow(Base, Out, Target) ->
    {ok, Bin} = file:read_file(Base),
    Sections = split(Bin),
    Rep = [S || {T, _, _} = S <- Sections, lists:member(T, ?REPLICATED)],
    RepSize = lists:sum([section_size(S) || S <- Rep]),
    Static = byte_size(Bin) - RepSize,
    Copies = max(1, (Target - Static + RepSize - 1) div RepSize),
    io:format("base ~B MB, ~B sections, ~B replicated (~B MB) x ~B~n",
              [byte_size(Bin) div 1048576, length(Sections), length(Rep), RepSize div 1048576, Copies]),
    {ok, Fd} = file:open(Out, [write, raw, binary, {delayed_write, 8388608, 2000}]),
    %% Runs of replicated sections are written Copies times, each copy
    %% with its own pids, so the file keeps the emulator's section order.
    write_runs(Fd, runs(Sections), Copies),
    ok = file:close(Fd),
    io:format("wrote ~s: ~B MB~n", [Out, filelib:file_size(Out) div 1048576]).

runs(Sections) ->
    lists:reverse(runs(Sections, [])).
runs([], Acc) -> Acc;
runs([{T, _, _} = S | Rest], [{Kind, L} | Acc]) ->
    case {lists:member(T, ?REPLICATED), Kind} of
        {true, rep} -> runs(Rest, [{rep, [S | L]} | Acc]);
        {false, static} -> runs(Rest, [{static, [S | L]} | Acc]);
        {true, static} -> runs(Rest, [{rep, [S]}, {static, L} | Acc]);
        {false, rep} -> runs(Rest, [{static, [S]}, {rep, L} | Acc])
    end;
runs([{T, _, _} = S | Rest], []) ->
    runs(Rest, [{case lists:member(T, ?REPLICATED) of true -> rep; false -> static end, [S]}]).

write_runs(Fd, Runs, Copies) ->
    lists:foreach(
      fun({static, L}) -> [write_section(Fd, S, 0) || S <- lists:reverse(L)];
         ({rep, L}) -> [write_section(Fd, S, K) || K <- lists:seq(0, Copies - 1),
                                                   S <- lists:reverse(L)]
      end, Runs).

write_section(Fd, {Tag, Id, Body}, K) ->
    Head = case Id of
               null -> [$=, Tag];
               _ -> [$=, Tag, $:, repid(Id, K)]
           end,
    ok = file:write(Fd, [Head, $\n, Body]).

section_size({Tag, Id, Body}) ->
    2 + byte_size(Tag) + byte_size(Body) + case Id of null -> 0; _ -> 1 + byte_size(Id) end.

%% <0.N.0> -> <0.N.K>
repid(Id, 0) -> Id;
repid(<<"<0.", Rest/binary>> = Id, K) ->
    case binary:split(Rest, <<".">>) of
        [N, <<"0>">>] -> [<<"<0.">>, N, $., integer_to_binary(K), $>];
        _ -> Id
    end;
repid(Id, _) -> Id.

%% Sections as {Tag, Id, Body}; Body keeps its trailing newline.
split(Bin) ->
    Starts = [0 | [P + 1 || {P, _} <- binary:matches(Bin, <<"\n=">>)]],
    Ends = tl(Starts) ++ [byte_size(Bin)],
    [begin
         Sec = binary:part(Bin, S, E - S),
         [<<"=", Head/binary>>, Body] = case binary:split(Sec, <<"\n">>) of
                                            [H, B] -> [H, B];
                                            [H] -> [H, <<>>]
                                        end,
         {Tag, Id} = case binary:split(Head, <<":">>) of
                         [T, I] -> {T, I};
                         [T] -> {T, null}
                     end,
         {Tag, Id, Body}
     end || {S, E} <- lists:zip(Starts, Ends)].

%% benchmark

bench(File, Ebin0) ->
    Ebin = case Ebin0 of
               [] -> filelib:wildcard("_build/default/lib/*/ebin");
               _ -> Ebin0
           end,
    code:add_pathsa(Ebin),
    Size = filelib:file_size(File),
    Idx = ets:new(idx, [ordered_set, public, {read_concurrency, true}]),
    Meta = ets:new(meta, [set, public, {read_concurrency, true}]),
    M0 = erlang:memory(total),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Result} = eobs_dump_scan:scan(File, Idx, Meta, #{}),
    T = erlang:monotonic_time(millisecond) - T0,
    garbage_collect(),
    Words = ets:info(Idx, memory) + ets:info(Meta, memory),
    IdxBytes = Words * erlang:system_info(wordsize),
    Sections = maps:get(sections, Result),
    Summaries = length(ets:select(Idx, [{{'_', '_', '_'}, [], [true]}])),
    io:format("file      ~.2f GB (~B bytes)~n"
              "summaries from ~p~n"
              "scan      ~.1f s, ~.1f s/GB, ~.1f MB/s~n"
              "sections  ~B (~B with a summary), skipped ~B, truncated ~p~n"
              "index     ~.1f MB, ~.1f bytes/section~n"
              "memory    total ~.1f MB (~.1f MB more than before the scan)~n",
              [Size / 1073741824, Size, code:which(eobs_dump_parse),
               T / 1000, T / 1000 / (Size / 1073741824), Size / 1048576 / (T / 1000),
               Sections, Summaries, maps:get(skipped, Result), maps:get(truncated, Result),
               IdxBytes / 1048576, IdxBytes / max(1, Sections),
               erlang:memory(total) / 1048576, (erlang:memory(total) - M0) / 1048576]).
