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
