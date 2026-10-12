-module(eobs_node_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([connect_loads_agent/1, tool_is_hidden/1, disconnect_unloads_agent/1,
         unreachable_node_retries/1, api_requests/1, load_sampling/1]).

all() ->
    [connect_loads_agent, tool_is_hidden, disconnect_unloads_agent,
     unreachable_node_retries, api_requests, load_sampling].

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
    [{peer, Peer}, {target, Node} | Config].

end_per_testcase(_Case, Config) ->
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
                                         [eobs_agent_swt])),
    ?assert(is_binary(eobs_json:encode(Second))).

%% helpers

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
