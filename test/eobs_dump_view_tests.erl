-module(eobs_dump_view_tests).
-include_lib("eunit/include/eunit.hrl").

%% The fixture is a real OTP 26 dump (erlang:halt("test slogan: rich dump"))
%% of a node with a registered worker holding messages, a dictionary with
%% maps/binaries/bignums/funs/refs, a flooded process, ETS tables,
%% persistent terms, timers and ports; trimmed (allocators, funs, atoms,
%% module attributes) to keep it small.
-define(FIXTURE, filename:join([filename:dirname(?FILE), "fixtures", "rich.dump.gz"])).

%% ---------------------------------------------------------------------
%% Setup: open the fixture with the real reader

fixture_path(Name, Fun) ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"),
                        lists:concat(["eobs_dump_view_tests_", os:getpid()])),
    ok = filelib:ensure_path(Dir),
    Path = filename:join(Dir, Name),
    {ok, Gz} = file:read_file(?FIXTURE),
    ok = file:write_file(Path, Fun(zlib:gunzip(Gz))),
    Path.

open(Path) ->
    case whereis(eobs_dump_sup) of
        undefined ->
            {ok, Sup} = eobs_dump_sup:start_link(),
            unlink(Sup);
        _ -> ok
    end,
    Id = <<"vt", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Size = filelib:file_size(Path),
    {ok, _} = supervisor:start_child(eobs_dump_sup, [Id, list_to_binary(Path), Size]),
    {ok, H} = eobs_dump:handle(Id),
    wait(H, 500),
    H.

wait(_, 0) -> error(scan_timeout);
wait(H, N) ->
    case maps:get(status, eobs_dump:info(H)) of
        scanning -> timer:sleep(20), wait(H, N - 1);
        _ -> ok
    end.

json(T) -> eobs_json:encode(T).

rich_test_() ->
    {setup,
     fun() -> open(fixture_path("rich.dump", fun(B) -> B end)) end,
     fun(H) -> eobs_dump:close(element(2, H)) end,
     fun(H) ->
             [{"overview", fun() -> overview(H) end},
              {"process table", fun() -> processes(H) end},
              {"all kinds", fun() -> kinds(H) end},
              {"process detail", fun() -> process(H) end},
              {"terms", fun() -> terms(H) end},
              {"expand", fun() -> expand(H) end},
              {"details", fun() -> details(H) end},
              {"search", fun() -> search(H) end},
              {"bad input", fun() -> bad_input(H) end}]
     end}.

overview(H) ->
    O = eobs_dump_view:overview(H),
    _ = json(O),
    #{reason := Reason, general := G, counts := C, findings := Fs, top := Top} = O,
    ?assertEqual(#{code => halt, params => #{text => <<"test slogan: rich dump">>}}, Reason),
    ?assertEqual(<<"fixnode@", (lists:last(binary:split(maps:get(node, G), <<"@">>)))/binary>>,
                 maps:get(node, G)),
    ?assertEqual(<<"26">>, maps:get(otp_release, G)),
    ?assert(maps:get(processes, C) > 50),
    ?assertEqual(3, maps:get(timers, C)),
    #{memory := [_ | _], mql := [Q1 | _]} = Top,
    ?assertEqual(1500, maps:get(mq, Q1)),
    Codes = [Code || #{code := Code} <- Fs],
    ?assert(lists:member(long_message_queue, Codes)),
    ?assert(lists:member(calling_process, Codes)),
    ?assert(lists:member(top_memory_process, Codes)).

processes(H) ->
    Q = fun(Opts) -> eobs_dump_view:query(H, <<"processes">>, Opts) end,
    #{total := N, rows := Rows, columns := Cols} = Q(#{offset => 0, limit => 10}),
    _ = json(Rows),
    ?assertEqual(10, length(Rows)),
    ?assert(lists:member(#{key => memory, type => bytes, sortable => true}, Cols)),
    Mems = [M || #{memory := M} <- Rows],
    ?assertEqual(lists:reverse(lists:sort(Mems)), Mems),
    %% filter is case-insensitive over the text columns
    #{total := 1, rows := [#{name := <<"worker_one">>}]} = Q(#{filter => <<"WORKER_ONE">>}),
    %% pid sort is numeric, both directions, with paging
    #{rows := Asc} = Q(#{sort => <<"pid">>, order => asc, limit => 1000}),
    ?assertEqual(N, length(Asc)),
    ?assertEqual(<<"<0.0.0>">>, maps:get(pid, hd(Asc))),
    #{rows := [Last]} = Q(#{sort => <<"pid">>, order => desc, limit => 1}),
    ?assertEqual(maps:get(pid, lists:last(Asc)), maps:get(pid, Last)),
    #{rows := Page} = Q(#{sort => <<"pid">>, order => asc, offset => 5, limit => 3}),
    ?assertEqual(lists:sublist(Asc, 6, 3), Page),
    %% unknown sort keys fall back to memory
    #{rows := [_ | _]} = Q(#{sort => <<"nope">>}),
    %% binary-keyed options are accepted too
    #{rows := [_]} = Q(#{<<"limit">> => 1}).

kinds(H) ->
    Kinds = [<<"processes">>, <<"ports">>, <<"ets">>, <<"timers">>, <<"schedulers">>,
             <<"nodes">>, <<"modules">>, <<"funs">>, <<"atoms">>, <<"persistent_terms">>,
             <<"allocators">>, <<"memory">>, <<"allocated_areas">>, <<"hash_tables">>,
             <<"index_tables">>, <<"internal_tables">>],
    [begin
         R = eobs_dump_view:query(H, K, #{offset => 0, limit => 20, filter => <<>>}),
         ?assertMatch({K, #{total := _, columns := [_ | _], rows := _}}, {K, R}),
         _ = json(R)
     end || K <- Kinds],
    #{rows := Ets} = eobs_dump_view:query(H, <<"ets">>, #{filter => <<"my_table">>}),
    ?assertMatch([#{name := <<"my_table">>, objects := 2000, owner := <<"<0.9.0>">>}], Ets),
    #{rows := Timers} = eobs_dump_view:query(H, <<"timers">>, #{sort => <<"time_left">>, order => asc}),
    ?assertEqual([<<"timer_msg">>, <<"other_timer">>, <<"refresh_timeout">>],
                 [M || #{message := M} <- Timers]),
    #{total := NA, rows := [#{index := 1, name := <<"children_any1">>} | _]} =
        eobs_dump_view:query(H, <<"atoms">>, #{sort => <<"index">>, order => asc, limit => 3}),
    ?assertEqual(3000, NA),
    #{total := 1, rows := [#{name := <<"set_flags">>}]} =
        eobs_dump_view:query(H, <<"atoms">>, #{filter => <<"SET_FLAGS">>}),
    #{rows := PTs} = eobs_dump_view:query(H, <<"persistent_terms">>, #{filter => <<"my_pt_key">>}),
    ?assertMatch([#{key := #{text := <<"my_pt_key">>}, value := #{text := _}}], PTs),
    #{rows := Allocs} = eobs_dump_view:query(H, <<"allocators">>, #{}),
    ?assert(lists:any(fun(#{name := N, carriers_size := C}) -> N =:= <<"binary_alloc">> andalso C > 0 end,
                      Allocs)),
    #{rows := Idx} = eobs_dump_view:query(H, <<"index_tables">>, #{}),
    ?assert(lists:member(<<"atom_tab">>, [N || #{name := N} <- Idx])).

process(H) ->
    P = eobs_dump_view:process(H, <<"<0.90.0>">>),
    _ = json(P),
    #{summary := #{name := <<"worker_one">>, mq := 500}, parts := Parts, info := Info,
      parent := <<"<0.9.0>">>, monitored_by := [<<"<0.9.0>">>]} = P,
    ?assertEqual(#{messages => 500, dictionary => 10, stack => 3, heap => true}, Parts),
    ?assert(lists:member(#{key => state, value => <<"Waiting">>, type => text}, Info)),
    H9 = eobs_dump_view:process(H, <<"<0.9.0>">>),
    ?assert(lists:member(<<"<0.91.0>">>, maps:get(links, H9))),
    ?assert(lists:member(<<"<0.90.0>">>, maps:get(monitors, H9))).

terms(H) ->
    Pid = <<"<0.90.0>">>,
    #{total := 500, items := [M1, M2 | _]} =
        eobs_dump_view:process_part(H, Pid, <<"messages">>, 0, 3),
    ?assertMatch(#{text := <<"{msg,1,[1],<<\"payload\">>}">>, more := null}, M1),
    ?assertMatch(#{text := <<"{msg,2,[1,2],<<\"payload\">>}">>}, M2),
    #{items := [Last]} = eobs_dump_view:process_part(H, Pid, <<"messages">>, 499, 10),
    ?assertMatch(#{text := <<"{msg,500,[],<<\"payload\">>}">>}, Last),
    #{total := 10, items := Dict} = eobs_dump_view:process_part(H, Pid, <<"dictionary">>, 0, 100),
    _ = json(Dict),
    D = maps:from_list([{K, V} || #{key := #{text := K}, value := #{text := V}} <- Dict]),
    ?assertEqual(<<"{some,value,\"a string\",3.14}">>, maps:get(<<"dict_key">>, D)),
    ?assertEqual(<<"#{map => 1,nested => #{deep => [1,2,3]}}">>, maps:get(<<"<<\"binkey\">>">>, D)),
    ?assertEqual(integer_to_binary(1 bsl 200), maps:get(<<"bigint">>, D)),
    ?assertEqual(integer_to_binary(-(1 bsl 100)), maps:get(<<"neg">>, D)),
    ?assertEqual(<<"fun lists:map/2">>, maps:get(<<"fn">>, D)),
    ?assertMatch(<<"#Fun<dgen.", _/binary>>, maps:get(<<"lfn">>, D)),
    ?assertMatch(<<"#Ref<0.", _/binary>>, maps:get(<<"ref">>, D)),
    ?assertEqual(<<"{<0.90.0>,#Port<0.0>}">>, maps:get(<<"self">>, D)),
    %% refc binary, sub binary of it, heap binary
    ?assertMatch(<<"{\n  <<\"abcdefgh", _/binary>>, maps:get(<<"bins">>, D)),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"bins">>, D), <<"<<\"cdefghabcdefghabcdef\">>">>)),
    ?assertNotEqual(nomatch, binary:match(maps:get(<<"bins">>, D), <<"16000 bytes">>)),
    %% hashmap keys come out in term order, truncated at the item limit
    Big = maps:get(<<"bigmap">>, D),
    ?assertMatch(<<"#{\n  ", _/binary>>, Big),
    ?assertEqual(20, length(binary:matches(Big, <<" => ">>))),
    Keys = [binary_to_integer(K) || [K] <- element(2, re:run(Big, "(\\d+) =>", [global, {capture, all_but_first, binary}]))],
    ?assertEqual(lists:sort(Keys), Keys),
    #{items := Stack} = eobs_dump_view:process_part(H, Pid, <<"stack">>, 0, 10),
    ?assertMatch([#{kind := <<"var">>, addr := <<"y0">>}, #{kind := <<"var">>},
                  #{kind := <<"return">>, text := <<"<terminate process normally>">>}], Stack),
    %% flooded process: paging deep into the queue
    #{total := 1500, items := [#{text := <<"{flood,1500}">>}]} =
        eobs_dump_view:process_part(H, <<"<0.91.0>">>, <<"messages">>, 1499, 5).

expand(H) ->
    #{items := Dict} = eobs_dump_view:process_part(H, <<"<0.90.0>">>, <<"dictionary">>, 0, 100),
    [#{more := Tok}] = [V || #{key := #{text := <<"bigmap">>}, value := V} <- Dict],
    ?assert(is_binary(Tok)),
    {ok, #{text := T1, more := More}} = eobs_dump_view:expand(H, Tok),
    ?assertEqual(null, More),
    ?assertEqual(100, length(binary:matches(T1, <<" => ">>))),
    ?assertEqual({error, bad_token}, eobs_dump_view:expand(H, <<"garbage">>)),
    ?assertEqual({error, bad_token}, eobs_dump_view:expand(H, 42)),
    %% a well-formed token naming something else is refused
    Evil = base64:encode(term_to_binary({1, <<"proc_heap">>, <<"<0.90.0>">>, 0, <<"line">>, 0})),
    ?assertEqual({error, bad_token}, eobs_dump_view:expand(H, Evil)).

details(H) ->
    [begin
         R = eobs_dump_view:detail(H, K, Key),
         ?assertMatch({K, #{title := _, fields := [_ | _]}}, {K, R}),
         _ = json(R)
     end || {K, Key} <- [{<<"port">>, <<"#Port<0.0>">>}, {<<"ets">>, <<"my_table">>},
                         {<<"node">>, <<"3">>}, {<<"module">>, <<"dgen">>},
                         {<<"allocator">>, <<"binary_alloc">>}, {<<"scheduler">>, <<"1">>},
                         {<<"timer">>, <<"worker_one">>}]],
    #{terms := Terms} = eobs_dump_view:detail(H, <<"module">>, <<"dgen">>),
    ?assertMatch([#{key := <<"cur_attrib">>, value := #{text := <<"[{vsn,", _/binary>>}} | _], Terms).

search(H) ->
    [#{kind := process, key := <<"<0.90.0>">>}] = eobs_dump_view:search(H, <<"worker_ONE">>),
    [#{kind := process, key := <<"<0.91.0>">>} | _] = eobs_dump_view:search(H, <<"0.91.0">>),
    Mods = [K || #{kind := module, key := K} <- eobs_dump_view:search(H, <<"dgen">>)],
    ?assertEqual([<<"dgen">>], Mods),
    ?assertEqual([], eobs_dump_view:search(H, <<>>)),
    ?assert(length(eobs_dump_view:search(H, <<"e">>)) =< 50).

bad_input(H) ->
    ?assertEqual({error, unknown_kind}, eobs_dump_view:query(H, <<"no_such_kind">>, #{})),
    ?assertEqual({error, unknown_kind}, eobs_dump_view:query(H, not_binary, #{})),
    ?assertEqual({error, not_found}, eobs_dump_view:process(H, <<"<9.9.9>">>)),
    ?assertEqual({error, not_found}, eobs_dump_view:process(H, <<"junk">>)),
    ?assertEqual({error, unknown_part}, eobs_dump_view:process_part(H, <<"<0.90.0>">>, <<"x">>, 0, 1)),
    ?assertEqual(#{total => 0, items => []},
                 eobs_dump_view:process_part(H, <<"<9.9.9>">>, <<"messages">>, 0, 10)),
    ?assertEqual({error, not_found}, eobs_dump_view:detail(H, <<"port">>, <<"#Port<9.9>">>)),
    ?assertEqual({error, not_found}, eobs_dump_view:detail(H, <<"bogus">>, <<"x">>)),
    #{rows := []} = eobs_dump_view:query(H, <<"processes">>, #{offset => 100000}),
    #{rows := [_]} = eobs_dump_view:query(H, <<"processes">>, #{offset => -5, limit => 1}),
    #{rows := []} = eobs_dump_view:query(H, <<"processes">>, #{limit => -1}).

%% A dump cut in the middle of a process heap.
truncated_test_() ->
    {setup,
     fun() -> open(fixture_path("trunc.dump", fun(B) -> binary:part(B, 0, byte_size(B) * 2 div 5) end)) end,
     fun(H) -> eobs_dump:close(element(2, H)) end,
     fun(H) ->
             fun() ->
                     O = eobs_dump_view:overview(H),
                     _ = json(O),
                     ?assertMatch([#{level := warning, params := #{last_tag := _}}],
                                  [F || F = #{code := truncated} <- maps:get(findings, O)]),
                     %% everything still answers
                     [_ = json(eobs_dump_view:query(H, K, #{}))
                      || K <- [<<"processes">>, <<"ets">>, <<"atoms">>, <<"persistent_terms">>]],
                     #{rows := Rows} = eobs_dump_view:query(H, <<"processes">>, #{limit => 1000}),
                     [begin
                          _ = json(eobs_dump_view:process(H, P)),
                          [_ = json(eobs_dump_view:process_part(H, P, Part, 0, 50))
                           || Part <- [<<"messages">>, <<"dictionary">>, <<"stack">>]]
                      end || #{pid := P} <- Rows]
             end
     end}.

%% ---------------------------------------------------------------------
%% Pure parts

classify_test_() ->
    C = fun(S) -> eobs_dump_view:classify(S, none_handle) end,
    [?_assertMatch(#{code := out_of_memory_heap,
                     params := #{allocator := <<"eheap_alloc">>, size := 49515520, type := <<"old_heap">>}},
                   C(<<"eheap_alloc: Cannot allocate 49515520 bytes of memory (of type \"old_heap\").">>)),
     ?_assertMatch(#{code := oom, params := #{allocator := <<"binary_alloc">>, size := 1024}},
                   C(<<"binary_alloc: Cannot reallocate 1024 bytes of memory (of type \"binary\").">>)),
     ?_assertMatch(#{code := kernel_pid_terminated,
                     params := #{process := <<"application_controller">>, reason := <<"killed">>}},
                   C(<<"Kernel pid terminated (application_controller) (killed)">>)),
     ?_assertMatch(#{code := kernel_pid_terminated, params := #{app := <<"mnesia">>}},
                   C(<<"Kernel pid terminated (application_controller) ({application_start_failure,mnesia,{bad,x}})">>)),
     ?_assertMatch(#{code := init_terminating, params := #{reason := <<"{undef,[]}">>}},
                   C(<<"Runtime terminating during boot ({undef,[]})">>)),
     ?_assertMatch(#{code := init_terminating}, C(<<"init terminating in do_boot ({undef,[]})">>)),
     ?_assertMatch(#{code := system_limit, params := #{what := <<"atoms">>, max := 20000}},
                   C(<<"no more index entries in atom_tab (max=20000)">>)),
     ?_assertMatch(#{code := sigusr1}, C(<<"Received SIGUSR1">>)),
     ?_assertMatch(#{code := system_process_terminated, params := #{process := <<"erts_code_purger">>}},
                   C(<<"System process erts_code_purger terminated: boom">>)),
     ?_assertMatch(#{code := unknown, params := #{text := <<"whatever">>}}, C(<<"whatever">>))].

summary_test() ->
    Body = <<"State: Waiting\nName: foo\nSpawned as: proc_lib:init_p/5\n"
             "Message queue length: 7\nLink list: [<0.1.0>]\nReductions: 99\n"
             "Stack+heap: 233\nOldHeap: 10\nBinVHeap: 3\nOldBinVHeap: 4\nMemory: 2680\n"
             "Program counter: 0x00007f (gen_server:loop/7 + 544)\n">>,
    S = eobs_dump_parse:summary(<<"proc">>, <<"<0.5.0>">>, Body),
    ?assertEqual(#{state => <<"Waiting">>, name => <<"foo">>, init => <<"proc_lib:init_p/5">>,
                   mq => 7, reds => 99, sh => 233, oh => 10, bin => 7, mem => 2680,
                   pc => <<"gen_server:loop/7 + 544">>}, S),
    %% no sub-binaries of the scanner's chunk are kept
    ?assertEqual(byte_size(maps:get(state, S)), binary:referenced_byte_size(maps:get(state, S))),
    ?assertEqual(skip, eobs_dump_parse:summary(<<"nope">>, null, <<>>)).

links_test() ->
    ?assertEqual(#{links => [<<"<0.85.0>">>, <<"#Port<0.4>">>],
                   monitors => [<<"<0.7.0>">>, <<"{reg,'n@h'}">>],
                   monitored_by => [<<"<0.78.0>">>]},
                 eobs_dump_parse:links(<<"[<0.85.0>, #Port<0.4>, {to,<0.7.0>,#Ref<0.1.2.3>}, "
                                         "{to,{reg,'n@h'},#Ref<0.1.2.4>}, {from,<0.78.0>,#Ref<0.1.2.5>}]">>)).

general_test() ->
    G = eobs_dump_parse:general(<<"Mon Jan 1 00:00:00 2024\nSlogan: line one\nline two\n"
                                  "System version: Erlang/OTP 22 [erts-10.4] [64-bit]\n"
                                  "Compiled: Mon Jan 1\nTaints: \nAtoms: 12\n">>),
    ?assertMatch(#{slogan := <<"line one\nline two">>, atoms := 12, compiled := <<"Mon Jan 1">>}, G),
    ?assertEqual(8, eobs_dump_parse:word_size(maps:get(system_version, G))).

etf_test_() ->
    T = fun(Term) -> maps:get(text, eobs_dump_term:etf_text(term_to_binary(Term), 1)) end,
    [?_assertEqual(<<"{a,1,-5,3.5,\"str\",<<\"bin\">>,[1|2],#{k => v}}">>,
                   T({a, 1, -5, 3.5, "str", <<"bin">>, [1 | 2], #{k => v}})),
     ?_assertEqual(<<"['Quoted atom','and',a@b,'_x']">>, T(['Quoted atom', 'and', a@b, '_x'])),
     ?_assertEqual(integer_to_binary(1 bsl 300), T(1 bsl 300)),
     ?_assertEqual(<<"fun lists:map/2">>, T(fun lists:map/2)),
     ?_assertEqual(<<"<<1,2,3>>">>, T(<<1, 2, 3>>)),
     ?_assertMatch(<<"[\n  1,2,3,", _/binary>>, T(lists:seq(1, 1000))),
     ?_assertEqual(<<"<external term, 3 bytes>">>,
                   maps:get(text, eobs_dump_term:etf_text(<<131, 255, 0>>, 0)))].

parse_ref_test() ->
    ?assertEqual({{atom, <<"a|b">>}, <<"|N">>}, eobs_dump_term:parse_ref(<<"A3:a|b|N">>)),
    ?assertEqual({{ptr, 16#7FA8}, <<",I1">>}, eobs_dump_term:parse_ref(<<"H7FA8,I1">>)),
    ?assertEqual({{int, <<"-12">>}, <<>>}, eobs_dump_term:parse_ref(<<"I-12">>)),
    ?assertEqual({{pid, <<"<0.1.0>">>}, <<>>}, eobs_dump_term:parse_ref(<<"P<0.1.0>">>)),
    ?assertMatch({{bad, _}, <<>>}, eobs_dump_term:parse_ref(<<"?">>)).
