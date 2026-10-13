%% Exercises every eobs_agent entry point on the running OTP release.
%% CI compiles the agent with each supported release (22 and newer) and
%% runs `erl -noshell -pa OUT -s agent_smoke run`, so an API that an old
%% release lacks fails here instead of on a user's node.
-module(agent_smoke).
-export([run/0]).

run() ->
    try
        check(),
        io:format("agent smoke test passed on OTP ~s~n", [erlang:system_info(otp_release)]),
        halt(0)
    catch C:R:S ->
        io:format("agent smoke test FAILED: ~p:~p~n~p~n", [C, R, S]),
        halt(1)
    end.

check() ->
    Self = list_to_binary(pid_to_list(self())),
    true = is_integer(eobs_agent:version()),
    #{process_count := _} = eobs_agent:node_summary(),
    #{} = eobs_agent:load_sample(node()),
    #{} = eobs_agent:load_sample(node()),
    Session = {node(), self(), 1},
    [{reds, desc}, {memory, desc}, {name, asc}, {message_queue_len, desc}] =
        [begin
             #{rows := [_ | _]} = eobs_agent:process_list(node(), Session,
                                                          #{sort => Sort, order => Order,
                                                            filter => <<>>, offset => 0, limit => 20}),
             {Sort, Order}
         end || {Sort, Order} <- [{reds, desc}, {memory, desc}, {name, asc}, {message_queue_len, desc}]],
    #{rows := _} = eobs_agent:process_list(node(), Session, #{sort => reds, order => desc,
                                                              filter => <<"code">>, offset => 0, limit => 20}),
    {ok, #{pid := Self}} = eobs_agent:process_detail(Self),
    {ok, _} = eobs_agent:process_state(list_to_binary(pid_to_list(whereis(application_controller))), 5000),
    Victim = spawn(timer, sleep, [infinity]),
    VictimBin = list_to_binary(pid_to_list(Victim)),
    ok = eobs_agent:process_send(VictimBin, hello),
    ok = eobs_agent:process_kill(VictimBin),
    [_ | _] = eobs_agent:app_list(),
    {ok, #{root := #{}}} = eobs_agent:app_tree(kernel),
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    [_ | _] = eobs_agent:port_list(),
    [Inet | _] = eobs_agent:inet_list(),
    {ok, #{}} = eobs_agent:port_detail(maps:get(id, Inet)),
    gen_tcp:close(L),
    case eobs_agent:socket_list() of
        {ok, _} -> ok;
        {error, _} -> ok
    end,
    T = ets:new(smoke, [public]),
    ets:insert(T, [{K, K * 2} || K <- lists:seq(1, 100)]),
    Tabs = eobs_agent:ets_list(),
    [#{id := Id}] = [X || X = #{name := smoke} <- Tabs],
    {ok, #{total := 100, rows := Rows}} = eobs_agent:ets_rows(Id, #{offset => 10, limit => 20}),
    20 = length(Rows),
    {ok, #{total := 1, keys := [Key]}} = eobs_agent:ets_rows(Id, #{search => <<"{42,84}">>}),
    {ok, [#{text := <<"{42,84}">>, ref := Ref, editable := true}]} = eobs_agent:table_object(ets, Id, Key),
    ok = eobs_agent:table_write(ets, Id, {42, changed}, Ref),
    [{42, changed}] = ets:lookup(T, 42),
    {ok, [#{ref := Ref2}]} = eobs_agent:table_object(ets, Id, Key),
    ok = eobs_agent:table_delete(ets, Id, Ref2),
    [] = ets:lookup(T, 42),
    {error, not_running} = eobs_agent:mnesia_list(),
    Echo = spawn(fun Loop() -> receive {From, ping} -> From ! pong, Loop() end end),
    EchoBin = list_to_binary(pid_to_list(Echo)),
    {ok, #{processes := [_]}} = eobs_agent:trace_start(node(), [EchoBin], #{}),
    Echo ! {self(), ping},
    receive pong -> ok end,
    timer:sleep(100),
    {ok, #{events := [#{dir := in}, #{dir := out}]}} = eobs_agent:trace_events(null, 0),
    ok = eobs_agent:trace_stop(),
    {flags, []} = erlang:trace_info(Echo, flags),
    #{allocators := [_ | _]} = eobs_agent:alloc_info(),
    #{connections := _} = eobs_agent:dist_info(),
    ok.
