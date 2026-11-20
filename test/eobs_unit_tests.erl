-module(eobs_unit_tests).
-include_lib("eunit/include/eunit.hrl").

cli_parse_test() ->
    ?assertEqual(#{browser => false, node => 'a@h', cookie => c, http_port => 9000,
                   http_ip => {0, 0, 0, 0}},
                 eobs_cli:parse(["--node", "a@h", "--cookie", "c", "--port", "9000",
                                 "--listen", "0.0.0.0", "--no-browser"])),
    ?assertEqual(#{browser => true}, eobs_cli:parse([])).

name_domain_test() ->
    ?assertEqual(shortnames, eobs_dist:name_domain('a@host')),
    ?assertEqual(longnames, eobs_dist:name_domain('a@host.example.com')),
    ?assertEqual(longnames, eobs_dist:name_domain('a@10.0.0.1')).

json_test() ->
    Json = eobs_json:to_json(#{pid => self(), list => "abc", nums => [1, 2],
                               tuple => {a, 1}, undef => undefined, bin => <<"x">>}),
    ?assert(is_binary(maps:get(<<"pid">>, Json))),
    ?assertEqual(<<"abc">>, maps:get(<<"list">>, Json)),
    ?assertEqual([1, 2], maps:get(<<"nums">>, Json)),
    ?assertEqual(<<"{a,1}">>, maps:get(<<"tuple">>, Json)),
    ?assertEqual(null, maps:get(<<"undef">>, Json)),
    ?assertEqual(<<"x">>, maps:get(<<"bin">>, Json)).

load_rates_test() ->
    S0 = #{time => 0, scheduler_wall_time => [{1, 0, 0}, {2, 0, 0}, {3, 0, 0}],
           schedulers => 1, dirty_cpu_schedulers => 1,
           io_input => 0, io_output => 0, reductions => 0,
           run_queue => 0, process_count => 10, memory => #{total => 1}},
    S1 = S0#{time => 2000000, scheduler_wall_time => [{1, 50, 100}, {2, 0, 100}, {3, 100, 100}],
             io_input => 4000, io_output => 2000, reductions => 10},
    First = eobs_load:rates(undefined, S0),
    ?assertEqual(null, maps:get(schedulers, First)),
    ?assertEqual(null, maps:get(io_input, First)),
    R = eobs_load:rates(S0, S1),
    ?assertEqual([#{id => 1, type => normal, util => 0.5},
                  #{id => 2, type => dirty_cpu, util => 0.0},
                  #{id => 3, type => dirty_io, util => 1.0}], maps:get(schedulers, R)),
    ?assertEqual(2000.0, maps:get(io_input, R)),
    ?assertEqual(1000.0, maps:get(io_output, R)),
    ?assertEqual(5.0, maps:get(reductions, R)).

cli_password_test() ->
    ?assertEqual(#{browser => true, password => <<"s3cret">>, read_only => true},
                 eobs_cli:parse(["--password", "s3cret", "--read-only"])).

auth_check_test() ->
    Header = fun(UserPass) -> <<"Basic ", (base64:encode(UserPass))/binary>> end,
    ?assert(eobs_auth:check(Header(<<"any:pw">>), <<"pw">>)),
    ?assert(eobs_auth:check(Header(<<":pw:with:colons">>), <<"pw:with:colons">>)),
    ?assertNot(eobs_auth:check(Header(<<"any:nope">>), <<"pw">>)),
    ?assertNot(eobs_auth:check(<<"Basic !!!">>, <<"pw">>)),
    ?assertNot(eobs_auth:check(undefined, <<"pw">>)).

same_origin_test() ->
    ?assert(eobs_ws:same_origin(undefined, <<"localhost:8090">>)),
    ?assert(eobs_ws:same_origin(<<"http://localhost:8090">>, <<"localhost:8090">>)),
    ?assert(eobs_ws:same_origin(<<"http://LocalHost:8090">>, <<"localhost:8090">>)),
    ?assert(eobs_ws:same_origin(<<"http://[::1]:8090">>, <<"[::1]:8090">>)),
    ?assert(eobs_ws:same_origin(<<"http://example.com">>, <<"example.com">>)),
    ?assertNot(eobs_ws:same_origin(<<"http://evil.example">>, <<"localhost:8090">>)),
    ?assertNot(eobs_ws:same_origin(<<"http://localhost:5173">>, <<"localhost:8090">>)),
    ?assertNot(eobs_ws:same_origin(<<"null">>, <<"localhost:8090">>)).

cookie_hint_test() ->
    ?assertEqual(<<"••••"/utf8>>, eobs_cookies:hint(<<"short">>)),
    ?assertEqual(<<"AB…YZ"/utf8>>, eobs_cookies:hint(<<"ABCDEFGHIJXYZ">>)).

host_candidates_test() ->
    {ok, Host} = inet:gethostname(),
    #{default := Default, hosts := Hosts} = eobs_dist:host_candidates(),
    ?assertEqual(Default, hd(Hosts)),
    ?assert(lists:member(list_to_binary(Host), Hosts)),
    ?assert(lists:member(<<"127.0.0.1">>, Hosts)).

json_edge_cases_test() ->
    %% Improper lists and non-UTF-8 map keys must not crash encoding.
    Enc = eobs_json:encode(#{improper => [a | b], <<255, 254>> => <<"ok">>,
                             bad_val => <<255, 254>>}),
    ?assert(is_binary(Enc)).

load_rates_scheduler_change_test() ->
    S0 = #{time => 0, scheduler_wall_time => [{1, 0, 0}, {2, 0, 0}],
           schedulers => 2, dirty_cpu_schedulers => 0,
           io_input => 0, io_output => 0, reductions => 0,
           run_queue => 0, process_count => 10, memory => #{total => 1}},
    S1 = S0#{time => 1000000, scheduler_wall_time => [{1, 50, 100}], schedulers => 1},
    R = eobs_load:rates(S0, S1),
    ?assertEqual(null, maps:get(schedulers, R)).

auth_host_and_scheme_test() ->
    Header = fun(UserPass) -> <<"basic ", (base64:encode(UserPass))/binary>> end,
    ?assert(eobs_auth:check(Header(<<"any:pw">>), <<"pw">>)),
    ?assert(eobs_auth:host_allowed(<<"localhost:8090">>, {127, 0, 0, 1})),
    ?assert(eobs_auth:host_allowed(<<"127.0.0.1:8090">>, {127, 0, 0, 1})),
    ?assert(eobs_auth:host_allowed(<<"[::1]:8090">>, {127, 0, 0, 1})),
    ?assertNot(eobs_auth:host_allowed(<<"evil.example:8090">>, {127, 0, 0, 1})),
    ?assert(eobs_auth:host_allowed(<<"evil.example:8090">>, {0, 0, 0, 0})).

same_origin_proxy_and_ipv6_test() ->
    ?assert(eobs_ws:same_origin(<<"https://example.com">>, <<"example.com">>)),
    ?assert(eobs_ws:same_origin(<<"http://[::1]">>, <<"[::1]">>)),
    ?assertNot(eobs_ws:same_origin(<<"ftp://localhost:8090">>, <<"localhost:8090">>)).

cookie_hint_utf8_test() ->
    Cookie = unicode:characters_to_binary("一二三四五六七八九十"),
    Hint = eobs_cookies:hint(Cookie),
    ?assert(is_binary(unicode:characters_to_binary(Hint))),
    ?assertEqual(unicode:characters_to_binary("一二…九十"), Hint).

cli_dump_dir_test() ->
    ?assertEqual(#{browser => true, dump_dirs => ["/var/dumps"]},
                 eobs_cli:parse(["--dump-dir", "/var/dumps"])).

cannot_observe_self_test() ->
    ?assertEqual({error, cannot_observe_self}, eobs_nodes:connect(nonode@nohost, undefined)),
    ?assertEqual({error, cannot_observe_self}, eobs_nodes:connect(node(), undefined)),
    ?assertEqual({error, invalid_node_name},
                 eobs_api:request(<<"nodes.connect">>, #{<<"node">> => <<"no_at_sign">>})),
    ?assertEqual({error, invalid_node_name},
                 eobs_api:request(<<"nodes.connect">>, #{<<"node">> => <<"nonode@nohost">>})),
    ?assertEqual({error, not_observed},
                 (try eobs_api:request(<<"node.summary">>, #{<<"node">> => <<"nonode@nohost">>})
                  catch throw:E -> E end)).
