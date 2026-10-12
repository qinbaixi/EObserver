-module(eobs_node_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([connect_loads_agent/1, tool_is_hidden/1, disconnect_unloads_agent/1,
         unreachable_node_retries/1, api_requests/1, load_sampling/1,
         process_list/1, process_detail_and_actions/1, applications/1,
         ports_and_sockets/1, ets_tables/1, mnesia_tables/1, allocators/1,
         read_only_mode/1, cluster_topology/1, http_password_and_origin/1]).

all() ->
    [connect_loads_agent, tool_is_hidden, disconnect_unloads_agent,
     unreachable_node_retries, api_requests, load_sampling, process_list,
     process_detail_and_actions, applications, ports_and_sockets, ets_tables,
     mnesia_tables, allocators, read_only_mode, cluster_topology,
     http_password_and_origin].

init_per_suite(Config) ->
    application:load(eobserver),
    application:set_env(eobserver, http_port, 0),
    {ok, _} = application:ensure_all_started(eobserver),
    Config.

end_per_suite(_Config) ->
    application:stop(eobserver).

init_per_testcase(unreachable_node_retries, Config) ->
    Config;
init_per_testcase(_Case, Config) ->
    Name = peer:random_name(?MODULE),
    {ok, Peer, Node} = peer:start(#{name => Name, connection => standard_io,
                                    args => ["-setcookie", "eobs_ct"]}),
    %% Funs from this suite run on the peer, so it needs the module.
    {Mod, Bin, File} = code:get_object_code(?MODULE),
    {module, Mod} = peer:call(Peer, code, load_binary, [Mod, File, Bin]),
    [{peer, Peer}, {target, Node} | Config].

end_per_testcase(_Case, Config) ->
    application:set_env(eobserver, read_only, false),
    application:unset_env(eobserver, password),
    [eobs_nodes:disconnect(N) || #{node := N} <- eobs_nodes:list()],
    case ?config(peer, Config) of
        undefined -> ok;
        Peer -> peer:stop(Peer)
    end.

connect_loads_agent(Config) ->
    Node = ?config(target, Config),
    Info = connect(Node),
    ?assertMatch(#{loaded := true}, maps:get(agent, Info)),
    #{summary := Summary} = Info,
    ?assertEqual(Node, maps:get(node, Summary)),
    ?assertEqual(list_to_binary(erlang:system_info(otp_release)),
                 maps:get(otp_release, Summary)).

tool_is_hidden(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    ?assert(lists:member(Node, nodes(hidden))),
    ?assertEqual([], peer:call(?config(peer, Config), erlang, nodes, [])).

disconnect_unloads_agent(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    ?assertMatch({file, _}, peer:call(Peer, code, is_loaded, [eobs_agent])),
    ok = eobs_nodes:disconnect(Node),
    ?assertEqual(false, peer:call(Peer, code, is_loaded, [eobs_agent])).

unreachable_node_retries(_Config) ->
    %% Short host name: the suite's peers already put the tool in shortnames
    %% mode (net_adm:localhost/0 may return an FQDN, e.g. on CI runners).
    {ok, Host} = inet:gethostname(),
    Node = list_to_atom("nobody_here@" ++ Host),
    {ok, _} = eobs_nodes:connect(Node, eobs_ct),
    Info = wait_for(Node, fun(#{status := S}) -> S =:= disconnected end),
    ?assertNotEqual(null, maps:get(error, Info)).

api_requests(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    NodeBin = atom_to_binary(Node, utf8),
    {ok, [#{node := Node}]} = eobs_api:request(<<"nodes.list">>, #{}),
    {ok, #{process_count := N}} = eobs_api:request(<<"node.summary">>, #{<<"node">> => NodeBin}),
    ?assert(N > 0),
    ?assertMatch({error, {unknown_method, _}}, eobs_api:request(<<"nope">>, #{})),
    %% The JSON layer must cope with everything the summary contains.
    {ok, Summary} = eobs_api:collect(<<"node.summary">>, #{<<"node">> => NodeBin}),
    ?assert(is_binary(eobs_json:encode(Summary))).

load_sampling(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Params = #{<<"node">> => atom_to_binary(Node, utf8)},
    {ok, First, State} = eobs_api:collect(<<"node.load">>, Params, undefined),
    ?assertEqual(null, maps:get(schedulers, First)),
    timer:sleep(200),
    {ok, Second, _} = eobs_api:collect(<<"node.load">>, Params, State),
    Scheds = maps:get(schedulers, Second),
    ?assert(length(Scheds) >= erlang:system_info(schedulers)),
    ?assert(lists:all(fun(#{util := U}) -> U >= 0 andalso U =< 1 end, Scheds)),
    %% The holder keeps scheduler_wall_time enabled on the target.
    ?assertNotEqual(undefined, peer:call(?config(peer, Config), erlang, whereis,
                                         [eobs_agent_srv])),
    ?assert(is_binary(eobs_json:encode(Second))).

process_list(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    Busy = peer:call(Peer, erlang, spawn, [lists, seq, [1, 100000000]]),
    Base = #{<<"node">> => atom_to_binary(Node, utf8), <<"limit">> => 10},
    {ok, First, S} = eobs_api:collect(<<"node.processes">>, Base, undefined),
    ?assertNot(maps:get(has_delta, First)),
    ?assertEqual(10, length(maps:get(rows, First))),
    {ok, Second, _} = eobs_api:collect(<<"node.processes">>, Base, S),
    ?assert(maps:get(has_delta, Second)),
    [Top | _] = maps:get(rows, Second),
    ?assertEqual(target_pid(Peer, Busy), maps:get(pid, Top)),
    %% Filtering by registered name, sorting by name ascending.
    {ok, Filtered, _} = eobs_api:collect(<<"node.processes">>,
                                         Base#{<<"filter">> => <<"code_SERVER">>,
                                               <<"sort">> => <<"name">>,
                                               <<"order">> => <<"asc">>}, S),
    ?assertMatch([#{name := code_server}], maps:get(rows, Filtered)),
    %% Paging returns disjoint rows.
    {ok, P2, _} = eobs_api:collect(<<"node.processes">>,
                                   Base#{<<"sort">> => <<"pid">>, <<"offset">> => 10}, S),
    {ok, P1, _} = eobs_api:collect(<<"node.processes">>, Base#{<<"sort">> => <<"pid">>}, S),
    Pids = fun(P) -> [maps:get(pid, R) || R <- maps:get(rows, P)] end,
    ?assertEqual([], Pids(P1) -- (Pids(P1) -- Pids(P2))),
    exit(Busy, kill).

process_detail_and_actions(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    NodeBin = atom_to_binary(Node, utf8),
    Target = peer:call(Peer, erlang, spawn,
                       [timer, sleep, [infinity]]),
    PidBin = target_pid(Peer, Target),
    Req = #{<<"node">> => NodeBin, <<"pid">> => PidBin},
    ok = eobs_api:request(<<"process.send">>, Req#{<<"message">> => <<"{hello, [1, 2]}">>}),
    {ok, Info} = eobs_api:request(<<"process.info">>, Req),
    ?assertEqual(PidBin, maps:get(pid, Info)),
    ?assertEqual([<<"{hello,[1,2]}">>], maps:get(messages, Info)),
    ?assertMatch({error, _}, eobs_api:request(<<"process.send">>,
                                              Req#{<<"message">> => <<"{broken">>})),
    {ok, State} = eobs_api:request(<<"process.state">>,
                                   Req#{<<"pid">> => target_pid(Peer,
                                         peer:call(Peer, erlang, whereis, [logger_sup]))}),
    ?assert(is_binary(State)),
    ok = eobs_api:request(<<"process.kill">>, Req),
    timer:sleep(100),
    ?assertEqual({error, not_found}, eobs_api:request(<<"process.info">>, Req)).

applications(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Req = #{<<"node">> => atom_to_binary(Node, utf8)},
    {ok, Apps} = eobs_api:request(<<"apps.list">>, Req),
    ?assertMatch([#{running := true} | _], [A || A = #{name := kernel} <- Apps]),
    {ok, #{root := Root}} = eobs_api:request(<<"apps.tree">>, Req#{<<"app">> => <<"kernel">>}),
    ?assertMatch(#{name := kernel_sup, type := supervisor}, Root),
    Names = tree_names(Root),
    ?assert(lists:member(code_server, Names)),
    ?assert(lists:member(net_kernel, Names)),
    %% Library applications have no supervision tree.
    ?assertMatch({ok, #{root := null}},
                 eobs_api:request(<<"apps.tree">>, Req#{<<"app">> => <<"stdlib">>})),
    ?assert(is_binary(eobs_json:encode(Root))).

ports_and_sockets(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    NodeBin = atom_to_binary(Node, utf8),
    Req = #{<<"node">> => NodeBin},
    %% A listening socket owned by a long-lived process on the target.
    Owner = peer:call(Peer, erlang, spawn,
                      [erlang, apply, [fun() ->
                                               {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
                                               receive stop -> gen_tcp:close(L) end
                                       end, []]]),
    timer:sleep(200),
    {ok, Ports} = eobs_api:collect(<<"node.ports">>, Req),
    ?assert(lists:any(fun(#{name := N}) -> N =:= "tcp_inet" orelse N =:= <<"tcp_inet">> end, Ports)),
    {ok, Inet} = eobs_api:collect(<<"node.inet">>, Req),
    OwnerBin = target_pid(Peer, Owner),
    [Listen] = [P || P = #{connected := C} <- Inet, C =:= OwnerBin],
    ?assertMatch(#{protocol := _, local := _}, Listen),
    PortId = maps:get(id, Listen),
    {ok, Detail} = eobs_api:request(<<"port.info">>, Req#{<<"port">> => PortId}),
    ?assertEqual(PortId, maps:get(id, Detail)),
    ok = eobs_api:request(<<"port.close">>, Req#{<<"port">> => PortId}),
    ?assertEqual({error, not_found}, eobs_api:request(<<"port.info">>, Req#{<<"port">> => PortId})),
    %% socket module listing: either a list or a clean error on old releases.
    case eobs_api:collect(<<"node.sockets">>, Req) of
        {ok, Sockets} -> ?assert(is_list(Sockets));
        {error, _} -> ok
    end,
    ?assert(is_binary(eobs_json:encode(Inet))).

ets_tables(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    Req = #{<<"node">> => atom_to_binary(Node, utf8)},
    peer:call(Peer, erlang, spawn,
              [erlang, apply, [fun() ->
                                       T = ets:new(eobs_ct_tab, [named_table, public]),
                                       ets:insert(T, [{K, <<"value", (integer_to_binary(K))/binary>>}
                                                      || K <- lists:seq(1, 120)]),
                                       _ = ets:new(eobs_ct_private, [private]),
                                       receive stop -> ok end
                               end, []]]),
    timer:sleep(200),
    {ok, Tabs} = eobs_api:collect(<<"node.ets">>, Req),
    [Tab] = [T || T = #{name := eobs_ct_tab} <- Tabs],
    ?assertMatch(#{size := 120, type := set, system := false, protection := public}, Tab),
    Rows = Req#{<<"table">> => <<"eobs_ct_tab">>},
    {ok, Page1} = eobs_api:request(<<"ets.rows">>, Rows#{<<"limit">> => 50}),
    ?assertMatch(#{total := 120, columns := 2, keypos := 1, complete := true}, Page1),
    ?assertEqual(50, length(maps:get(rows, Page1))),
    {ok, Page3} = eobs_api:request(<<"ets.rows">>, Rows#{<<"offset">> => 100, <<"limit">> => 50}),
    ?assertEqual(20, length(maps:get(rows, Page3))),
    {ok, Found} = eobs_api:request(<<"ets.rows">>, Rows#{<<"search">> => <<"VALUE117">>}),
    ?assertMatch(#{total := 1, rows := [[<<"117">>, _]]}, Found),
    [Private] = [T || T = #{protection := private, owner := O} <- Tabs,
                      O =:= maps:get(owner, Tab)],
    ?assertEqual({error, private},
                 eobs_api:request(<<"ets.rows">>, Req#{<<"table">> => maps:get(id, Private)})),
    ?assertEqual({error, not_found},
                 eobs_api:request(<<"ets.rows">>, Req#{<<"table">> => <<"no_such_table">>})),
    ?assert(is_binary(eobs_json:encode(Tabs))).

mnesia_tables(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    Req = #{<<"node">> => atom_to_binary(Node, utf8)},
    ?assertEqual({error, not_running}, eobs_api:collect(<<"node.mnesia">>, Req)),
    ok = peer:call(Peer, mnesia, start, []),
    {atomic, ok} = peer:call(Peer, mnesia, create_table,
                             [eobs_user, [{attributes, [id, name]}, {ram_copies, [Node]}]]),
    [ok = peer:call(Peer, mnesia, dirty_write, [{eobs_user, I, "user" ++ integer_to_list(I)}])
     || I <- lists:seq(1, 30)],
    {ok, Tabs} = eobs_api:collect(<<"node.mnesia">>, Req),
    ?assertMatch([#{name := eobs_user, size := 30, attributes := [<<"id">>, <<"name">>]}], Tabs),
    Rows = Req#{<<"table">> => <<"eobs_user">>},
    {ok, Page} = eobs_api:request(<<"mnesia.rows">>, Rows#{<<"limit">> => 10, <<"offset">> => 25}),
    ?assertMatch(#{total := 30, keypos := 2, attributes := [<<"id">>, <<"name">>]}, Page),
    ?assertEqual(5, length(maps:get(rows, Page))),
    {ok, Found} = eobs_api:request(<<"mnesia.rows">>, Rows#{<<"search">> => <<"\"user7\"">>}),
    ?assertMatch(#{total := 1, rows := [[<<"eobs_user">>, <<"7">>, _]]}, Found),
    stopped = peer:call(Peer, mnesia, stop, []).

allocators(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    {ok, #{allocators := Allocs, memory_total := Total}} =
        eobs_api:collect(<<"node.allocators">>, #{<<"node">> => atom_to_binary(Node, utf8)}),
    ?assert(Total > 0),
    [Eheap] = [A || A = #{type := eheap_alloc} <- Allocs],
    #{blocks := B, carriers := C, instances := I} = Eheap,
    ?assert(B > 0 andalso C >= B andalso I >= 1).

read_only_mode(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    Peer = ?config(peer, Config),
    application:set_env(eobserver, read_only, true),
    {ok, #{read_only := true}} = eobs_api:request(<<"settings.get">>, #{}),
    Target = peer:call(Peer, erlang, spawn, [timer, sleep, [infinity]]),
    Req = #{<<"node">> => atom_to_binary(Node, utf8), <<"pid">> => target_pid(Peer, Target)},
    ?assertEqual({error, read_only}, eobs_api:request(<<"process.kill">>, Req)),
    ?assertEqual({error, read_only},
                 eobs_api:request(<<"process.send">>, Req#{<<"message">> => <<"hi">>})),
    ?assertEqual({error, read_only}, eobs_api:request(<<"port.close">>, Req#{<<"port">> => <<"#Port<0.1>">>})),
    ?assert(peer:call(Peer, erlang, is_process_alive, [Target])),
    %% Reading still works.
    ?assertMatch({ok, _}, eobs_api:request(<<"process.info">>, Req)).

cluster_topology(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    {ok, #{tool := Tool, nodes := [#{node := Node, connections := Conns, error := null}]}} =
        eobs_api:collect(<<"cluster">>, #{}),
    ?assertMatch([#{node := Tool, hidden := true}], [C || C = #{node := N} <- Conns, N =:= Tool]).

http_password_and_origin(_Config) ->
    {_, Port} = ranch:get_addr(eobs_http_listener),
    ?assertMatch({200, _}, http_get(Port, "/system", [])),
    application:set_env(eobserver, password, <<"pw">>),
    ?assertMatch({401, _}, http_get(Port, "/system", [])),
    Auth = "Basic " ++ base64:encode_to_string("x:pw"),
    ?assertMatch({200, _}, http_get(Port, "/system", [{"Authorization", Auth}])),
    ?assertMatch({401, _}, http_get(Port, "/system", [{"Authorization", "Basic " ++ base64:encode_to_string("x:no")}])),
    application:unset_env(eobserver, password),
    Upgrade = [{"Connection", "Upgrade"}, {"Upgrade", "websocket"}, {"Sec-WebSocket-Version", "13"},
               {"Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="}],
    Host = "localhost:" ++ integer_to_list(Port),
    ?assertMatch({101, _}, http_get(Port, "/ws", [{"Origin", "http://" ++ Host} | Upgrade])),
    ?assertMatch({403, _}, http_get(Port, "/ws", [{"Origin", "http://evil.example"} | Upgrade])).

%% Minimal HTTP/1.1 client: returns the status code and raw response.
http_get(Port, Path, Headers) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    Lines = ["GET ", Path, " HTTP/1.1\r\nHost: localhost:", integer_to_list(Port), "\r\n",
             [[K, ": ", V, "\r\n"] || {K, V} <- Headers], "Connection: close\r\n\r\n"],
    ok = gen_tcp:send(S, Lines),
    {ok, <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Resp} = gen_tcp:recv(S, 0, 5000),
    gen_tcp:close(S),
    {binary_to_integer(Code), Resp}.

tree_names(#{name := Name, children := Children}) ->
    [Name | lists:append([tree_names(C) || C <- Children])].

%% helpers

%% Pids are exchanged as the target formats them (<0.X.Y>).
target_pid(Peer, Pid) ->
    list_to_binary(peer:call(Peer, erlang, pid_to_list, [Pid])).

connect(Node) ->
    {ok, _} = eobs_nodes:connect(Node, eobs_ct),
    wait_for(Node, fun(#{status := S}) -> S =:= connected end).

wait_for(Node, Pred) ->
    wait_for(Node, Pred, 50).

wait_for(Node, _Pred, 0) ->
    ct:fail({timeout_waiting_for, Node, eobs_nodes:list()});
wait_for(Node, Pred, N) ->
    case [I || #{node := Nd} = I <- eobs_nodes:list(), Nd =:= Node] of
        [Info] ->
            case Pred(Info) of
                true -> Info;
                false -> timer:sleep(100), wait_for(Node, Pred, N - 1)
            end;
        [] ->
            timer:sleep(100),
            wait_for(Node, Pred, N - 1)
    end.
