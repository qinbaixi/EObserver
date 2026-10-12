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
