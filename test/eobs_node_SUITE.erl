-module(eobs_node_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([busy_loop/1, sink/0, hold/1, grow/1, hold_binaries/1, hold_many_binaries/1,
         start_crash_sup/0, log_flood/2, call_kinds/3]).
%% A tiny gen_server for the message trace test, run on the peer; init/1
%% also serves as the supervisor of the logs test.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([connect_loads_agent/1, tool_is_hidden/1, disconnect_unloads_agent/1,
         unreachable_node_retries/1, api_requests/1, load_sampling/1,
         process_list/1, process_detail_and_actions/1, applications/1,
         ports_and_sockets/1, ets_tables/1, mnesia_tables/1, allocators/1,
         read_only_mode/1, cluster_topology/1, http_password_and_origin/1,
         local_discovery/1, saved_cookies/1, saved_nodes/1,
         message_trace/1, message_trace_limits/1,
         trace_call_stats/1, trace_call_stats_limits/1,
         diagnosis/1, diagnosis_many_processes/1,
         logs_and_crashes/1, logs_flood/1, logs_removed_with_tool/1]).

all() ->
    [connect_loads_agent, tool_is_hidden, disconnect_unloads_agent,
     unreachable_node_retries, api_requests, load_sampling, process_list,
     process_detail_and_actions, applications, ports_and_sockets, ets_tables,
     mnesia_tables, allocators, read_only_mode, cluster_topology,
     http_password_and_origin, local_discovery, saved_cookies, saved_nodes,
     message_trace, message_trace_limits, trace_call_stats, trace_call_stats_limits,
     diagnosis, diagnosis_many_processes,
     logs_and_crashes, logs_flood, logs_removed_with_tool].

init_per_suite(Config) ->
    application:load(eobserver),
    application:set_env(eobserver, http_port, 0),
    application:set_env(eobserver, config_dir, ?config(priv_dir, Config)),
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
    %% Spins until the peer stops, so it stays the busiest process between
    %% the two samples (a finite job could finish or be outrun).
    Busy = peer:call(Peer, erlang, spawn, [?MODULE, busy_loop, [0]]),
    Base = #{<<"node">> => atom_to_binary(Node, utf8), <<"limit">> => 10},
    {ok, First, S} = eobs_api:collect(<<"node.processes">>, Base, undefined),
    ?assertNot(maps:get(has_delta, First)),
    ?assertEqual(10, length(maps:get(rows, First))),
    timer:sleep(200),
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
    ?assert(is_binary(eobs_json:encode(Tabs))),
    %% View, change, add and delete single objects by their opaque key.
    #{keys := [Key117]} = Found,
    Obj = Rows#{<<"kind">> => <<"ets">>},
    {ok, [#{text := <<"{117,<<\"value117\">>}">>, ref := Ref117, editable := true}]} =
        eobs_api:request(<<"table.object">>, Obj#{<<"key">> => Key117}),
    ok = eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"{117, changed}">>,
                                                  <<"ref">> => Ref117}),
    ?assertEqual([{117, changed}], peer:call(Peer, ets, lookup, [eobs_ct_tab, 117])),
    %% Changing the key moves the object.
    {ok, [#{ref := Ref117b}]} = eobs_api:request(<<"table.object">>, Obj#{<<"key">> => Key117}),
    ok = eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"{1170, moved}">>,
                                                  <<"ref">> => Ref117b}),
    ?assertEqual([], peer:call(Peer, ets, lookup, [eobs_ct_tab, 117])),
    ok = eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"{999, new}">>}),
    ?assertMatch({error, <<"invalid_term", _/binary>>},
                 eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"{1,">>})),
    ?assertEqual({error, bad_object}, eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"x">>})),
    {ok, Moved} = eobs_api:request(<<"ets.rows">>, Rows#{<<"search">> => <<"moved">>}),
    #{keys := [Key1170]} = Moved,
    {ok, [#{ref := Ref1170}]} = eobs_api:request(<<"table.object">>, Obj#{<<"key">> => Key1170}),
    ok = eobs_api:request(<<"table.delete">>, Obj#{<<"ref">> => Ref1170}),
    ?assertEqual(121 - 1, peer:call(Peer, ets, info, [eobs_ct_tab, size])),
    %% Objects holding pids cannot be edited as text.
    true = peer:call(Peer, ets, insert, [eobs_ct_tab, {pid, self()}]),
    {ok, WithPid} = eobs_api:request(<<"ets.rows">>, Rows#{<<"search">> => <<"{pid,">>}),
    #{keys := [PidKey]} = WithPid,
    {ok, [#{editable := false}]} = eobs_api:request(<<"table.object">>, Obj#{<<"key">> => PidKey}),
    ?assertEqual({error, private},
                 eobs_api:request(<<"table.object">>, Obj#{<<"table">> => maps:get(id, Private),
                                                            <<"key">> => Key117})).

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
    #{keys := [Key7]} = Found,
    Obj = Rows#{<<"kind">> => <<"mnesia">>},
    {ok, [#{text := <<"{eobs_user,7,\"user7\"}">>, ref := Ref7}]} =
        eobs_api:request(<<"table.object">>, Obj#{<<"key">> => Key7}),
    ok = eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"{eobs_user, 7, \"seven\"}">>,
                                                  <<"ref">> => Ref7}),
    ?assertEqual([{eobs_user, 7, "seven"}], peer:call(Peer, mnesia, dirty_read, [eobs_user, 7])),
    ?assertMatch({error, {bad_record, eobs_user, 3}},
                 eobs_api:request(<<"table.write">>, Obj#{<<"object">> => <<"{eobs_user, 8}">>})),
    {ok, [#{ref := Ref7b}]} = eobs_api:request(<<"table.object">>, Obj#{<<"key">> => Key7}),
    ok = eobs_api:request(<<"table.delete">>, Obj#{<<"ref">> => Ref7b}),
    ?assertEqual([], peer:call(Peer, mnesia, dirty_read, [eobs_user, 7])),
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
    ?assertEqual({error, read_only}, eobs_api:request(<<"table.delete">>, Req#{<<"table">> => <<"t">>, <<"ref">> => <<>>})),
    ?assertEqual({error, read_only}, eobs_api:request(<<"table.write">>, Req#{<<"table">> => <<"t">>, <<"object">> => <<"{a}">>})),
    ?assertEqual({error, read_only}, eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [<<"init">>]})),
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

local_discovery(Config) ->
    Node = ?config(target, Config),
    connect(Node),
    {ok, R} = eobs_api:request(<<"nodes.discover">>, #{}),
    #{epmd := true, nodes := Found, host := Host, hosts := Hosts} = R,
    ?assertEqual(Host, hd(Hosts)),
    %% The tool runs in the peer's name domain, so its host is the default
    %% and the discovered name is the peer's node name.
    ?assert(lists:member(atom_to_binary(Node), [N || #{node := N} <- Found])),
    ?assertNot(lists:member(atom_to_binary(node()), [N || #{node := N} <- Found])),
    {ok, #{nodes := Other}} = eobs_api:request(<<"nodes.discover">>, #{<<"host">> => <<"127.0.0.1">>}),
    ?assert(lists:all(fun(#{node := N}) -> binary:match(N, <<"@127.0.0.1">>) =/= nomatch end, Other)).

saved_cookies(Config) ->
    Node = ?config(target, Config),
    {ok, #{id := Id}} = eobs_api:request(<<"cookies.save">>,
                                         #{<<"cookie">> => <<"eobs_ct">>, <<"label">> => <<"dev">>}),
    %% Saving the same cookie again keeps one entry.
    {ok, #{id := Id}} = eobs_api:request(<<"cookies.save">>, #{<<"cookie">> => <<"eobs_ct">>}),
    {ok, [Entry]} = eobs_api:request(<<"cookies.list">>, #{}),
    ?assertMatch(#{id := Id, label := <<"dev">>, hint := <<"••••"/utf8>>}, Entry),
    ?assertNot(maps:is_key(cookie, Entry)),
    ok = eobs_api:request(<<"nodes.connect">>, #{<<"node">> => atom_to_binary(Node),
                                                 <<"cookie_id">> => Id}),
    wait_for(Node, fun(#{status := S}) -> S =:= connected end),
    %% The file survives a restart of the cookie store.
    ?assert(filelib:is_regular(eobs_cookies:file())),
    ok = supervisor:terminate_child(eobs_sup, eobs_cookies),
    {ok, _} = supervisor:restart_child(eobs_sup, eobs_cookies),
    {ok, [#{id := Id}]} = eobs_api:request(<<"cookies.list">>, #{}),
    ok = eobs_api:request(<<"cookies.rename">>, #{<<"id">> => Id, <<"label">> => <<"本地"/utf8>>}),
    {ok, [#{label := <<"本地"/utf8>>}]} = eobs_api:request(<<"cookies.list">>, #{}),
    ?assertEqual({error, not_found},
                 eobs_api:request(<<"cookies.rename">>, #{<<"id">> => <<"nope">>, <<"label">> => <<"x">>})),
    ok = eobs_api:request(<<"cookies.delete">>, #{<<"id">> => Id}),
    {ok, []} = eobs_api:request(<<"cookies.list">>, #{}),
    ?assertEqual({error, cookie_not_found},
                 eobs_api:request(<<"nodes.connect">>, #{<<"node">> => atom_to_binary(Node),
                                                         <<"cookie_id">> => Id})).

saved_nodes(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    {ok, #{id := Id}} = eobs_api:request(<<"cookies.save">>, #{<<"cookie">> => <<"eobs_ct">>}),
    ok = eobs_api:request(<<"nodes.connect">>, #{<<"node">> => atom_to_binary(Node),
                                                 <<"cookie_id">> => Id}),
    wait_for(Node, fun(#{status := S}) -> S =:= connected end),
    %% A retry without a cookie keeps the saved entry.
    ok = eobs_api:request(<<"nodes.connect">>, #{<<"node">> => atom_to_binary(Node)}),
    {ok, Saved} = file:consult(eobs_nodes:file()),
    ?assertEqual([{Node, {cookie_id, Id}}], Saved),
    %% Restarting the registry reconnects the node with the saved cookie.
    restart_nodes(),
    wait_for(Node, fun(#{status := S}) -> S =:= connected end),
    %% Removing it unloads the agent, drops the connection and forgets it.
    ok = eobs_nodes:disconnect(Node),
    ?assertNot(lists:member(Node, nodes(hidden))),
    ?assertEqual(false, peer:call(Peer, code, is_loaded, [eobs_agent])),
    {ok, []} = file:consult(eobs_nodes:file()),
    restart_nodes(),
    timer:sleep(300),
    ?assertEqual([], eobs_nodes:list()),
    %% A cookie that was not saved is not remembered.
    ok = eobs_api:request(<<"nodes.connect">>, #{<<"node">> => atom_to_binary(Node),
                                                 <<"cookie">> => <<"eobs_ct">>}),
    wait_for(Node, fun(#{status := S}) -> S =:= connected end),
    {ok, []} = file:consult(eobs_nodes:file()),
    ok = eobs_api:request(<<"cookies.delete">>, #{<<"id">> => Id}).

message_trace(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    {ok, Echo} = peer:call(Peer, gen_server, start, [{local, trace_echo}, ?MODULE, [], []]),
    Req = #{<<"node">> => atom_to_binary(Node)},
    {ok, #{id := Id, processes := [#{name := trace_echo}],
           refused := [#{target := <<"nope">>, reason := not_found}]}} =
        eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [<<"trace_echo">>, <<"nope">>]}),
    2 = peer:call(Peer, gen_server, call, [trace_echo, {double, 1}]),
    ok = peer:call(Peer, gen_server, cast, [trace_echo, hello]),
    peer:call(Peer, erlang, send, [trace_echo, plain]),
    peer:call(Peer, erlang, send, [trace_echo, {'EXIT', Peer, normal}]),
    timer:sleep(300),
    {ok, #{id := Id, status := running, events := Events}, {Id, Next}} =
        eobs_api:collect(<<"trace.events">>, Req, undefined),
    Brief = [{D, C, K, S} || #{dir := D, cat := C, kind := K, summary := S} <- Events],
    ?assertMatch([{in, business, call, <<"{double,1}">>},
                  {out, business, reply, <<"2">>},
                  {in, business, cast, <<"hello">>},
                  {in, business, info, <<"plain">>},
                  {in, system, exit, _}], Brief),
    %% The call and its reply carry the same reference.
    [#{ref := Ref, peer := <<"<", _/binary>>}, #{ref := Ref} | _] = Events,
    ?assert(is_binary(Ref)),
    ?assert(is_binary(eobs_json:encode(Events))),
    %% Later collections only return newer events.
    {ok, #{events := []}, {Id, Next}} = eobs_api:collect(<<"trace.events">>, Req, {Id, Next}),
    %% A process another tool already traces is left alone.
    Other = peer:call(Peer, erlang, spawn, [timer, sleep, [infinity]]),
    Tracer = peer:call(Peer, erlang, spawn, [timer, sleep, [infinity]]),
    1 = peer:call(Peer, erlang, trace, [Other, true, [send, {tracer, Tracer}]]),
    {ok, #{refused := [#{reason := already_traced}]}} =
        eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [target_pid(Peer, Other)]}),
    {flags, [send]} = peer:call(Peer, erlang, trace_info, [Other, flags]),
    %% Stopping removes our flags; removing the node does too.
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [<<"trace_echo">>]}),
    {flags, [_ | _]} = peer:call(Peer, erlang, trace_info, [Echo, flags]),
    ok = eobs_api:request(<<"trace.stop">>, Req),
    {flags, []} = peer:call(Peer, erlang, trace_info, [Echo, flags]),
    {ok, #{status := stopped, reason := stopped_by_user}, _} =
        eobs_api:collect(<<"trace.events">>, Req, undefined),
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [<<"trace_echo">>]}),
    ok = eobs_nodes:disconnect(Node),
    timer:sleep(200),
    {flags, []} = peer:call(Peer, erlang, trace_info, [Echo, flags]).

message_trace_limits(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    Req = #{<<"node">> => atom_to_binary(Node)},
    Sink = peer:call(Peer, erlang, spawn, [?MODULE, sink, []]),
    SinkBin = target_pid(Peer, Sink),
    %% Count limit.
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [SinkBin],
                                                       <<"max_events">> => 3}),
    [peer:call(Peer, erlang, send, [Sink, N]) || N <- lists:seq(1, 5)],
    timer:sleep(300),
    {ok, #{status := stopped, reason := max_events, count := 3}, _} =
        eobs_api:collect(<<"trace.events">>, Req, undefined),
    {flags, []} = peer:call(Peer, erlang, trace_info, [Sink, flags]),
    %% A flood stops the trace long before the cap on events, removes the
    %% flags, and the node stays responsive with its memory in check.
    Before = peer:call(Peer, erlang, memory, [total]),
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [SinkBin],
                                                       <<"max_events">> => 100000}),
    peer:call(Peer, erlang, apply,
              [fun() -> [Sink ! {flood, N, lists:seq(1, 20)} || N <- lists:seq(1, 300000)], ok end, []]),
    timer:sleep(500),
    {ok, #{status := stopped, reason := Reason, count := Count}, _} =
        eobs_api:collect(<<"trace.events">>, Req, undefined),
    ct:pal("flood stopped: ~p after ~p events", [Reason, Count]),
    ?assert(lists:member(Reason, [backlog, max_rate, overload])),
    ?assert(Count =< 5000),
    {flags, []} = peer:call(Peer, erlang, trace_info, [Sink, flags]),
    %% The flood itself sits in the sink's queue until it is read; on a busy
    %% machine that takes a while, and it is not the trace's memory.
    wait_drained(Peer, Sink, 200),
    timer:sleep(500),
    After = peer:call(Peer, erlang, memory, [total]),
    ct:pal("memory before ~p after ~p", [Before, After]),
    ?assert(After - Before < 64 * 1024 * 1024),
    %% Duration limit.
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [SinkBin],
                                                       <<"max_seconds">> => 1}),
    timer:sleep(1500),
    {ok, #{status := stopped, reason := max_seconds}, _} =
        eobs_api:collect(<<"trace.events">>, Req, undefined).

trace_call_stats(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    {ok, _} = peer:call(Peer, gen_server, start, [{local, trace_echo}, ?MODULE, [], []]),
    Req = #{<<"node">> => atom_to_binary(Node)},
    {ok, #{id := Id}} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [<<"trace_echo">>]}),
    %% 3000 calls of one kind, 6000 events: more than the event ring keeps,
    %% paced to stay under the rate limit.
    [begin
         ok = peer:call(Peer, erlang, apply,
                        [fun() -> [gen_server:call(trace_echo, {double, N}) || N <- lists:seq(1, 375)], ok end, []]),
         timer:sleep(500)
     end || _ <- lists:seq(1, 8)],
    [pong = peer:call(Peer, gen_server, call, [trace_echo, ping]) || _ <- lists:seq(1, 3)],
    [ok = peer:call(Peer, gen_server, call, [trace_echo, {sleep, 50}]) || _ <- lists:seq(1, 2)],
    42 = peer:call(Peer, gen_server, call, [trace_echo, 42]),
    {'EXIT', {timeout, _}} =
        peer:call(Peer, erlang, apply, [fun() -> catch gen_server:call(trace_echo, noreply, 100) end, []]),
    timer:sleep(300),
    {ok, #{dropped := Dropped}, _} = eobs_api:collect(<<"trace.events">>, Req, undefined),
    ?assert(Dropped > 0),
    {ok, #{id := Id, status := running, kinds := 5, max_kinds := 200, rows := Rows}, _} =
        eobs_api:collect(<<"trace.stats">>, Req, undefined),
    Row = fun(Rs, K) -> hd([R || #{kind := Kd} = R <- Rs, Kd =:= K]) end,
    %% Counts are exact although the ring dropped events.
    #{calls := 3000, answered := 3000, unanswered := 0, pending := 0, dir := in, group := named,
      p95 := P95, max := Max, row := DoubleRow} = Row(Rows, <<"double">>),
    ?assert(P95 =< Max),
    #{calls := 3, answered := 3} = Row(Rows, <<"ping">>),
    #{calls := 2, answered := 2, avg := SleepAvg, p95 := SleepP95} = Row(Rows, <<"sleep">>),
    ?assert(SleepAvg >= 50000 andalso SleepP95 >= 50000),
    #{calls := 1, answered := 1, group := other} = Row(Rows, null),
    %% The unanswered call is still waiting while the trace runs.
    #{calls := 1, answered := 0, pending := 1, unanswered := 0, avg := null} = Row(Rows, <<"noreply">>),
    %% Details of one row: the histogram holds every answered call, the
    %% slowest ten come first.
    {ok, #{rows := [#{hist := Hist, slowest := Slow}]}} =
        eobs_api:request(<<"trace.stats">>, Req#{<<"row">> => DoubleRow}),
    3000 = lists:sum([N || #{count := N} <- Hist]),
    10 = length(Slow),
    Lats = [L || #{latency := L} <- Slow],
    ?assertEqual(lists:reverse(lists:sort(Lats)), Lats),
    ?assertEqual(Max, hd(Lats)),
    %% Once stopped, a call still waiting counts as unanswered.
    ok = eobs_api:request(<<"trace.stop">>, Req),
    {ok, #{status := stopped, rows := All}} = eobs_api:request(<<"trace.stats">>, Req),
    5 = length(All),
    #{unanswered := 1, pending := 0} = Row(All, <<"noreply">>),
    #{slowest := [#{summary := <<"{sleep,50}">>}, _]} = Row(All, <<"sleep">>),
    ?assert(is_binary(eobs_json:encode(All))).

%% Sends N gen calls that are never answered to Sink, of 300 kinds.
call_kinds(Sink, From, N) ->
    [Sink ! {'$gen_call', {self(), make_ref()}, {list_to_atom("kind_" ++ integer_to_list(I rem 300)), I}}
     || I <- lists:seq(From, From + N - 1)],
    ok.

trace_call_stats_limits(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    Req = #{<<"node">> => atom_to_binary(Node)},
    Sink = peer:call(Peer, erlang, spawn, [?MODULE, sink, []]),
    SinkBin = target_pid(Peer, Sink),
    %% 1500 calls of 300 kinds, never answered, paced under the rate limit:
    %% 200 kinds get a row, the rest is merged; at most 1000 calls wait for
    %% a reply, older ones count as unanswered.
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [SinkBin]}),
    [begin
         ok = peer:call(Peer, ?MODULE, call_kinds, [Sink, B * 100, 100]),
         timer:sleep(100)
     end || B <- lists:seq(0, 14)],
    timer:sleep(300),
    {ok, #{status := running, kinds := 200, rows := Rows}, _} =
        eobs_api:collect(<<"trace.stats">>, Req, undefined),
    201 = length(Rows),
    [#{calls := 500}] = [R || #{group := overflow} = R <- Rows],
    Sum = fun(Rs, K) -> lists:sum([maps:get(K, R) || R <- Rs]) end,
    1500 = Sum(Rows, calls),
    ?assert(Sum(Rows, pending) =< 1000),
    1500 = Sum(Rows, pending) + Sum(Rows, unanswered),
    ok = eobs_api:request(<<"trace.stop">>, Req),
    {ok, #{rows := Stopped}, _} = eobs_api:collect(<<"trace.stats">>, Req, undefined),
    1500 = Sum(Stopped, unanswered),
    0 = Sum(Stopped, pending),
    %% A flood of calls of many kinds still stops the trace, and memory
    %% stays in check.
    Before = peer:call(Peer, erlang, memory, [total]),
    {ok, _} = eobs_api:request(<<"trace.start">>, Req#{<<"targets">> => [SinkBin],
                                                       <<"max_events">> => 100000}),
    ok = peer:call(Peer, ?MODULE, call_kinds, [Sink, 0, 300000]),
    timer:sleep(500),
    {ok, #{status := stopped, reason := Reason, count := Count}, _} =
        eobs_api:collect(<<"trace.events">>, Req, undefined),
    ct:pal("call flood stopped: ~p after ~p events", [Reason, Count]),
    ?assert(lists:member(Reason, [backlog, max_rate, overload])),
    {flags, []} = peer:call(Peer, erlang, trace_info, [Sink, flags]),
    {ok, #{rows := Flood}, _} = eobs_api:collect(<<"trace.stats">>, Req, undefined),
    ?assert(length(Flood) =< 201),
    ?assert(Sum(Flood, calls) =< Count),
    timer:sleep(500),
    After = peer:call(Peer, erlang, memory, [total]),
    ct:pal("memory before ~p after ~p", [Before, After]),
    ?assert(After - Before < 64 * 1024 * 1024).

sink() ->
    receive _ -> sink() end.

%% Keeps a big term alive.
hold(N) ->
    L = lists:seq(1, N),
    receive stop -> length(L) end.

%% Keeps N 1 MB binaries alive.
hold_binaries(N) ->
    Bins = [binary:copy(<<I>>, 1024 * 1024) || I <- lists:seq(1, N)],
    receive stop -> length(Bins) end.

%% Keeps N small refc binaries (68 bytes each) alive.
hold_many_binaries(N) ->
    Bins = [binary:copy(<<I:32>>, 17) || I <- lists:seq(1, N)],
    receive stop -> length(Bins) end.

%% Keeps growing its heap.
grow(Acc) ->
    receive stop -> length(Acc)
    after 10 -> grow(lists:seq(1, 2000) ++ Acc)
    end.

init(crash_sup) ->
    {ok, {#{intensity => 100, period => 1},
          [#{id => crashy, start => {gen_server, start_link, [{local, eobs_crashy}, ?MODULE, [], []]}}]}};
init([]) -> {ok, #{}}.
handle_call({double, N}, _From, St) -> {reply, 2 * N, St};
handle_call(ping, _From, St) -> {reply, pong, St};
handle_call({sleep, Ms}, _From, St) -> timer:sleep(Ms), {reply, ok, St};
handle_call(noreply, _From, St) -> {noreply, St};
handle_call(N, _From, St) when is_integer(N) -> {reply, N, St}.
handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Msg, St) -> {noreply, St}.

restart_nodes() ->
    ok = supervisor:terminate_child(eobs_sup, eobs_nodes),
    %% The node processes outlive the registry; stop them like a real
    %% shutdown of the tool would.
    [supervisor:terminate_child(eobs_node_sup, P) || {_, P, _, _} <- supervisor:which_children(eobs_node_sup)],
    {ok, _} = supervisor:restart_child(eobs_sup, eobs_nodes).

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

busy_loop(N) ->
    busy_loop(N + 1).

diagnosis(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    Req = #{<<"node">> => atom_to_binary(Node)},
    %% A process that never reads its 2000 messages, and a big one.
    Stuck = peer:call(Peer, erlang, spawn, [timer, sleep, [infinity]]),
    peer:call(Peer, erlang, apply, [fun() -> [Stuck ! {msg, N} || N <- lists:seq(1, 2000)], ok end, []]),
    Big = peer:call(Peer, erlang, spawn, [?MODULE, hold, [3000000]]),
    Bins = peer:call(Peer, erlang, spawn, [?MODULE, hold_binaries, [60]]),
    [wait_waiting(Peer, P) || P <- [Big, Bins]],
    StuckBin = target_pid(Peer, Stuck),
    BigBin = target_pid(Peer, Big),
    {ok, #{checks := Checks, took_ms := Took} = Report} = eobs_api:request(<<"diag.check">>, Req),
    ct:pal("health check took ~p ms", [Took]),
    ?assert(is_binary(eobs_json:encode(Report))),
    Find = fun(Id) -> hd([C || #{id := I} = C <- Checks, I =:= Id]) end,
    Pids = fun(#{items := Items}) -> [P || #{pid := P} <- Items] end,
    ?assertMatch(#{level := warn, value := 1}, Find(message_queue)),
    ?assertEqual([StuckBin], Pids(Find(message_queue))),
    ?assertMatch(#{level := crit}, Find(stuck)),
    ?assert(lists:member(StuckBin, Pids(Find(stuck)))),
    ?assert(lists:member(BigBin, Pids(Find(process_memory)))),
    ?assertMatch(#{level := warn}, Find(binary_holders)),
    ?assertEqual([target_pid(Peer, Bins)], Pids(Find(binary_holders))),
    %% A process with too many binaries to list is reported, and the scan
    %% still finds the others.
    Many = peer:call(Peer, erlang, spawn, [?MODULE, hold_many_binaries, [500000]]),
    wait_waiting(Peer, Many),
    {ok, #{checks := Checks2}} = eobs_api:request(<<"diag.check">>, Req),
    #{level := crit, items := [#{pid := ManyBin, value := null}, #{pid := BinsBin}]} =
        hd([C || #{id := binary_holders} = C <- Checks2]),
    ?assertEqual({target_pid(Peer, Many), target_pid(Peer, Bins)}, {ManyBin, BinsBin}),
    peer:call(Peer, erlang, exit, [Many, kill]),
    ?assertMatch(#{level := ok}, Find(process_count)),
    ?assertMatch(#{level := ok}, Find(atom_count)),
    12 = length(Checks),
    %% Window: a busy and a growing process come out on top.
    Busy = peer:call(Peer, erlang, spawn, [?MODULE, busy_loop, [0]]),
    Grow = peer:call(Peer, erlang, spawn, [?MODULE, grow, [[]]]),
    Self = self(),
    spawn(fun() -> Self ! {window, eobs_api:request(<<"diag.window">>, Req#{<<"seconds">> => 2})} end),
    timer:sleep(200),
    %% One diagnosis at a time per node.
    {error, busy} = eobs_api:request(<<"diag.check">>, Req),
    {ok, Window} = receive {window, W} -> W after 30000 -> error(window_timeout) end,
    ?assert(is_binary(eobs_json:encode(Window))),
    #{reductions := [#{pid := TopReds} | _], memory := Mem, created := Created} = Window,
    ?assertEqual(target_pid(Peer, Busy), TopReds),
    ?assert(lists:member(target_pid(Peer, Grow), [P || #{pid := P} <- Mem])),
    ?assert(Created >= 0),
    peer:call(Peer, erlang, exit, [Busy, kill]),
    %% The worker goes away with the tool node.
    spawn(fun() -> eobs_api:request(<<"diag.window">>, Req#{<<"seconds">> => 30}) end),
    timer:sleep(300),
    ?assert(is_pid(peer:call(Peer, erlang, whereis, [eobs_agent_diag]))),
    ok = eobs_nodes:disconnect(Node),
    timer:sleep(500),
    ?assertEqual(undefined, peer:call(Peer, erlang, whereis, [eobs_agent_diag])).

%% 100k processes: both diagnoses finish, the node stays responsive and
%% its memory goes back down.
diagnosis_many_processes(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    peer:call(Peer, erlang, apply,
              [fun() -> [spawn(timer, sleep, [infinity]) || _ <- lists:seq(1, 100000)], ok end, []]),
    connect(Node),
    Req = #{<<"node">> => atom_to_binary(Node)},
    Before = peer:call(Peer, erlang, memory, [total]),
    Self = self(),
    spawn(fun() -> Self ! {check, eobs_api:request(<<"diag.check">>, Req)} end),
    Pings = ping_while(Peer, check),
    {ok, #{took_ms := Took}} = receive {check, R} -> R end,
    spawn(fun() -> Self ! {window, eobs_api:request(<<"diag.window">>, Req#{<<"seconds">> => 2})} end),
    Pings2 = ping_while(Peer, window),
    {ok, #{process_count := Count}} = receive {window, W} -> W end,
    ct:pal("check ~p ms, window over ~p processes; slowest ping ~p us / ~p us",
           [Took, Count, lists:max(Pings), lists:max(Pings2)]),
    ?assert(Count > 100000),
    ?assert(lists:max(Pings ++ Pings2) < 500000),
    timer:sleep(500),
    After = peer:call(Peer, erlang, memory, [total]),
    ct:pal("memory before ~p after ~p", [Before, After]),
    ?assert(After - Before < 32 * 1024 * 1024).

wait_drained(_Peer, _Pid, 0) ->
    error(queue_not_drained);
wait_drained(Peer, Pid, N) ->
    case peer:call(Peer, erlang, process_info, [Pid, message_queue_len]) of
        {message_queue_len, 0} -> ok;
        _ -> timer:sleep(50), wait_drained(Peer, Pid, N - 1)
    end.

%% Waits until a process on the peer is done setting up and waits in receive.
wait_waiting(Peer, Pid) ->
    case peer:call(Peer, erlang, process_info, [Pid, status]) of
        {status, waiting} -> ok;
        _ -> timer:sleep(50), wait_waiting(Peer, Pid)
    end.

%% Times round trips to the peer until the Tag message arrives (put back
%% for the caller).
ping_while(Peer, Tag) ->
    receive
        {Tag, _} = M -> self() ! M, [0]
    after 0 ->
        {T, _} = timer:tc(fun() -> peer:call(Peer, erlang, node, []) end),
        timer:sleep(50),
        [T | ping_while(Peer, Tag)]
    end.

%% A supervisor with one gen_server child (eobs_crashy), kept alive by a
%% process of its own.
start_crash_sup() ->
    Self = self(),
    spawn(fun() ->
                  {ok, Sup} = supervisor:start_link({local, eobs_ct_sup}, ?MODULE, crash_sup),
                  Self ! {sup, Sup},
                  receive stop -> ok end
          end),
    receive {sup, Sup} -> Sup end.

%% Logs as fast as it can until Until (monotonic ms); returns the count.
log_flood(Until, N) ->
    case N rem 1000 =:= 0 andalso erlang:monotonic_time(millisecond) >= Until of
        true ->
            N;
        false ->
            case N rem 50 of
                0 -> logger:error("flood ~p", [N]);
                1 -> logger:warning("flood ~p", [N]);
                _ -> logger:notice("flood ~p", [N])
            end,
            log_flood(Until, N + 1)
    end.

logs_collect(Node, State) ->
    {ok, Data, State1} = eobs_api:collect(<<"logs.events">>, #{<<"node">> => atom_to_binary(Node)},
                                          State),
    ?assert(is_binary(eobs_json:encode(Data))),
    {Data, State1}.

%% Pulls until Pred holds for the accumulated logs, crashes and restarts.
logs_until(Node, State, Acc, Pred) ->
    logs_until(Node, State, Acc, Pred, 50).

logs_until(_Node, _State, Acc, _Pred, 0) ->
    ct:fail({logs_timeout, Acc});
logs_until(Node, State, {Logs, Crashes, Restarts}, Pred, N) ->
    {#{logs := L, crashes := C, restarts := R}, State1} = logs_collect(Node, State),
    Upsert = fun(New, Old) -> maps:merge(Old, maps:from_list([{Id, G} || #{id := Id} = G <- New])) end,
    Acc = {Logs ++ L, Upsert(C, Crashes), Upsert(R, Restarts)},
    case Pred(Acc) of
        true -> {Acc, State1};
        false -> timer:sleep(100), logs_until(Node, State1, Acc, Pred, N - 1)
    end.

logs_and_crashes(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    Handlers = fun() -> peer:call(Peer, logger, get_handler_ids, []) end,
    %% Nothing is installed until the logs are read.
    ?assertNot(lists:member(eobs_agent_logs, Handlers())),
    %% Collecting is allowed in read-only mode: it only records.
    application:set_env(eobserver, read_only, true),
    {#{status := running, primary_level := notice, logs := []}, S0} = logs_collect(Node, undefined),
    application:set_env(eobserver, read_only, false),
    ?assert(lists:member(eobs_agent_logs, Handlers())),
    %% Every level that the node's primary level lets through.
    ok = peer:call(Peer, logger, set_primary_config, [level, all]),
    Levels = [debug, info, notice, warning, error, critical],
    [peer:call(Peer, logger, Level, ["level ~p", [Level]]) || Level <- Levels],
    %% A gen_server under a supervisor that crashes three times, and a
    %% plain process that crashes.
    peer:call(Peer, ?MODULE, start_crash_sup, []),
    [begin
         catch peer:call(Peer, gen_server, call, [eobs_crashy, crash]),
         timer:sleep(50),
         wait_registered(Peer, eobs_crashy)
     end || _ <- [1, 2, 3]],
    peer:call(Peer, erlang, spawn, [erlang, error, [plain_crash]]),
    Done = fun({Logs, Crashes, Restarts}) ->
                   length([L || #{text := <<"level ", _/binary>>} = L <- Logs]) =:= length(Levels)
                       andalso map_size(Crashes) =:= 2
                       andalso [C || #{count := 3} = C <- maps:values(Restarts)] =/= []
                       andalso [C || #{count := 3} = C <- maps:values(Crashes)] =/= []
           end,
    {{Logs, Crashes, Restarts}, S1} = logs_until(Node, S0, {[], #{}, #{}}, Done),
    ?assertEqual(Levels, [Lv || #{text := <<"level ", _/binary>>, level := Lv} <- Logs]),
    Seqs = [Seq || #{seq := Seq} <- Logs],
    ?assertEqual(lists:usort(Seqs), Seqs),
    [#{who := <<"eobs_crashy">>, count := 3, class := Class, reason := Reason, stack := [_ | _]}] =
        [C || #{who := <<"eobs_crashy">>} = C <- maps:values(Crashes)],
    ?assertEqual(error, Class),
    ?assertMatch(<<"function_clause", _/binary>>, Reason),
    [#{count := 1, reason := <<"plain_crash">>}] = [C || #{who := null} = C <- maps:values(Crashes)],
    [#{supervisor := <<"eobs_ct_sup">>, child := <<"crashy">>, count := 3, times := Times,
       gave_up := false, restart_type := permanent}] = maps:values(Restarts),
    ?assertEqual(3, length(Times)),
    %% The cursor moves on: nothing is read twice.
    {#{logs := [], crashes := [], restarts := []}, _} = logs_collect(Node, S1),
    %% Disconnecting removes the handler before the agent is unloaded.
    ok = eobs_nodes:disconnect(Node),
    ?assertNot(lists:member(eobs_agent_logs, Handlers())),
    ?assertEqual(undefined, peer:call(Peer, erlang, whereis, [eobs_agent_logs])),
    ?assertEqual(false, peer:call(Peer, code, is_loaded, [eobs_agent])).

%% The target logs as fast as it can from several processes: events are
%% dropped, not queued, memory stays flat and the node stays responsive.
logs_flood(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    connect(Node),
    %% Our handler alone: the default one would print every event.
    ok = peer:call(Peer, logger, remove_handler, [default]),
    {_, S0} = logs_collect(Node, undefined),
    {ok, #{config := #{collector := Collector}}} =
        peer:call(Peer, logger, get_handler_config, [eobs_agent_logs]),
    garbage_collect_all(Peer),
    Before = peer:call(Peer, erlang, memory, [total]),
    Seconds = 4,
    Until = peer:call(Peer, erlang, monotonic_time, [millisecond]) + Seconds * 1000,
    Self = self(),
    Flooders = 8,
    peer:call(Peer, erlang, apply,
              [fun() ->
                       [spawn(fun() -> Self ! {flooded, log_flood(Until, 0)} end)
                        || _ <- lists:seq(1, Flooders)],
                       ok
               end, []]),
    Watch = fun Loop(S, Acc) ->
                    receive
                        {flooded, _} = M -> self() ! M, {S, Acc}
                    after 0 ->
                        {T, _} = timer:tc(fun() -> peer:call(Peer, erlang, node, []) end),
                        Mem = peer:call(Peer, erlang, memory, [total]),
                        {message_queue_len, Q} =
                            peer:call(Peer, erlang, process_info, [Collector, message_queue_len]),
                        {_, S1} = logs_collect(Node, S),
                        timer:sleep(200),
                        Loop(S1, [{T, Mem, Q} | Acc])
                    end
            end,
    {S1, Samples} = Watch(S0, []),
    Produced = lists:sum([receive {flooded, N} -> N end || _ <- lists:seq(1, Flooders)]),
    timer:sleep(1500),
    {#{status := running, received := Received, dropped := Dropped, limited := Limited}, _} =
        logs_collect(Node, S1),
    garbage_collect_all(Peer),
    After = peer:call(Peer, erlang, memory, [total]),
    MaxPing = lists:max([T || {T, _, _} <- Samples]),
    MaxMem = lists:max([M || {_, M, _} <- Samples]),
    MaxQueue = lists:max([Q || {_, _, Q} <- Samples]),
    ct:pal("~p events in ~p s (~p/s): kept ~p, dropped ~p, below warning over the rate ~p; "
           "collector queue max ~p; memory before ~p, peak ~p, after ~p; slowest ping ~p us",
           [Produced, Seconds, Produced div Seconds, Received, Dropped, Limited, MaxQueue,
            Before, MaxMem, After, MaxPing]),
    ?assert(Produced div Seconds > 50000),
    %% Every event is accounted for: kept, or dropped and counted.
    ?assert(Received + Dropped + Limited >= Produced),
    ?assert(Dropped + Limited > 0),
    %% At most LOG_HARD_RATE events a second are kept.
    ?assert(Received =< (Seconds + 2) * 5000),
    ?assert(MaxQueue =< 1100),
    ?assert(MaxMem - Before < 64 * 1024 * 1024),
    ?assert(After - Before < 16 * 1024 * 1024),
    ?assert(MaxPing < 500000).

%% A tool node that goes away (killed, crashed, network gone) takes the
%% handler and the collector with it.
logs_removed_with_tool(Config) ->
    Node = ?config(target, Config),
    Peer = ?config(peer, Config),
    {Mod, Bin, File} = code:get_object_code(eobs_agent),
    {module, Mod} = peer:call(Peer, code, load_binary, [Mod, File, Bin]),
    {ok, Tool, ToolNode} = peer:start(#{name => peer:random_name(eobs_tool),
                                        connection => standard_io,
                                        args => ["-setcookie", "eobs_ct", "-hidden"]}),
    {ok, #{status := running}} = peer:call(Tool, erpc, call,
                                           [Node, eobs_agent, logs_events, [ToolNode, null]]),
    {ok, #{config := #{collector := Collector}}} =
        peer:call(Peer, logger, get_handler_config, [eobs_agent_logs]),
    Keeper = peer:call(Peer, erlang, whereis, [eobs_agent_logs]),
    ?assert(is_pid(Keeper)),
    peer:stop(Tool),
    timer:sleep(500),
    ?assertNot(lists:member(eobs_agent_logs, peer:call(Peer, logger, get_handler_ids, []))),
    ?assertNot(peer:call(Peer, erlang, is_process_alive, [Keeper])),
    ?assertNot(peer:call(Peer, erlang, is_process_alive, [Collector])),
    %% The node keeps logging without it.
    ok = peer:call(Peer, logger, error, ["after the tool left", []]).

wait_registered(Peer, Name) ->
    case peer:call(Peer, erlang, whereis, [Name]) of
        undefined -> timer:sleep(20), wait_registered(Peer, Name);
        _ -> ok
    end.

garbage_collect_all(Peer) ->
    peer:call(Peer, erlang, apply,
              [fun() -> [erlang:garbage_collect(P) || P <- erlang:processes()], ok end, []]).
