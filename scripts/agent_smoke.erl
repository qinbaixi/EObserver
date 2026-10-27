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
    Echo ! {'$gen_call', {self(), make_ref()}, {get, 1}},
    timer:sleep(100),
    {ok, #{rows := [#{kind := <<"get">>, calls := 1, pending := 1}]}} = eobs_agent:trace_stats(null, rows),
    {ok, #{rows := [#{hist := [], slowest := []}]}} = eobs_agent:trace_stats(null, all),
    ok = eobs_agent:trace_stop(),
    {flags, []} = erlang:trace_info(Echo, flags),
    #{allocators := [_ | _]} = eobs_agent:alloc_info(),
    #{connections := _} = eobs_agent:dist_info(),
    {ok, #{checks := [_ | _]}} = eobs_agent:diag_check(node()),
    {ok, #{reductions := _, memory := _}} = eobs_agent:diag_window(node(), 1),
    [{ok, #{items := [_ | _]}} = eobs_agent:recon_proc_count(node(), A, 5)
     || A <- [memory, reductions, message_queue_len, total_heap_size]],
    Leaky = spawn(fun() ->
                          Bins = [binary:copy(<<I>>, 100000) || I <- lists:seq(1, 20)],
                          _ = [byte_size(B) || B <- Bins],
                          receive stop -> ok end
                  end),
    timer:sleep(100),
    LeakyBin = list_to_binary(pid_to_list(Leaky)),
    {ok, #{items := BinItems}} = eobs_agent:recon_proc_count(node(), binary_memory, 50),
    true = lists:member(LeakyBin, [P || #{pid := P} <- BinItems]),
    {ok, #{items := LeakItems, gc_count := Gc, complete := true}} = eobs_agent:recon_bin_leak(node(), 50),
    true = Gc > 0,
    [#{freed := Freed}] = [I || I = #{pid := P} <- LeakItems, P =:= LeakyBin],
    true = Freed >= 2000000,
    Leaky ! stop,
    {ok, L2} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, Port2} = inet:port(L2),
    {ok, C2} = gen_tcp:connect({127, 0, 0, 1}, Port2, [{active, false}]),
    {ok, S2} = gen_tcp:accept(L2),
    ok = gen_tcp:send(C2, <<"hello">>),
    {ok, #{items := [#{type := tcp, value := 5} | _]}} = eobs_agent:recon_inet_count(node(), send_oct, 5, 0),
    spawn(fun() -> timer:sleep(300), gen_tcp:send(S2, <<"window">>) end),
    {ok, #{items := [#{value := 6, send_oct := 6} | _], socket_count := 3}} =
        eobs_agent:recon_inet_count(node(), oct, 5, 1),
    gen_tcp:close(S2),
    gen_tcp:close(C2),
    gen_tcp:close(L2),
    #{total := Total, types := [_ | _]} = eobs_agent:recon_port_types(),
    true = Total > 0,
    #{allocators := Frag, cache_hit_rates := _} = eobs_agent:recon_alloc(),
    [_ | _] = [X || X = #{type := eheap_alloc, mbcs_carrier_count := MCC} <- Frag, MCC > 0],
    {ok, #{schedulers := [#{type := normal} | _]}} = eobs_agent:recon_scheduler_usage(node(), 1),
    {ok, #{status := running, cursor := Cursor}} = eobs_agent:logs_events(node(), null),
    true = lists:member(eobs_agent_logs, logger:get_handler_ids()),
    logger:error("smoke ~p", [error]),
    spawn(fun() -> erlang:error(smoke_crash) end),
    timer:sleep(300),
    {ok, #{logs := [#{text := <<"smoke error">>} | _], crashes := [#{reason := <<"smoke_crash">>}]}} =
        eobs_agent:logs_events(node(), Cursor),
    ok = eobs_agent:logs_stop(),
    false = lists:member(eobs_agent_logs, logger:get_handler_ids()),
    lager_smoke(),
    logfile_smoke(),
    ok.

%% A logger file handler's file can be listed, read, searched and nothing
%% else can be read.
logfile_smoke() ->
    File = filename:absname("eobs_smoke.log"),
    ok = logger:add_handler(eobs_smoke_file, logger_std_h,
                            #{level => notice, config => #{file => File}}),
    logger:notice("smoke file line ~p", [1]),
    timer:sleep(500),
    Path = list_to_binary(File),
    {ok, Files} = eobs_agent:logfile_list(),
    [#{source := logger, index := null}] = [F || #{path := P} = F <- Files, P =:= Path],
    {ok, #{entries := Entries}} = eobs_agent:logfile_read(Path, eof, back, 65536),
    [#{level := notice}] = [E || #{text := T} = E <- Entries, binary:match(T, <<"smoke file line 1">>) =/= nomatch],
    {ok, #{hits := [_ | _]}} = eobs_agent:logfile_search(Path, eof, back, <<"smoke file">>, null),
    {error, not_a_log_file} = eobs_agent:logfile_read(<<"/etc/hosts">>, 0, fwd, 4096),
    ok = logger:remove_handler(eobs_smoke_file),
    ok.

%% A stand-in for lager's default sink: the agent joins it as a backend,
%% keeps lager's level alone and leaves when collecting stops.
lager_smoke() ->
    {ok, Sink} = gen_event:start({local, lager_event}),
    {ok, #{status := running, lager := true, cursor := Cursor}} = eobs_agent:logs_events(node(), null),
    [{eobs_agent, eobs_agent_logs}] = gen_event:which_handlers(lager_event),
    {mask, 0} = gen_event:call(lager_event, {eobs_agent, eobs_agent_logs}, get_loglevel),
    Bytes = binary_to_list(<<"lager ", (unicode:characters_to_binary([20013, 25991]))/binary>>),
    gen_event:notify(lager_event, {log, {lager_msg, [], [{pid, pid_to_list(self())}, {module, agent_smoke}],
                                         debug, {"", ""}, os:timestamp(), Bytes}}),
    timer:sleep(300),
    Text = unicode:characters_to_binary([$l, $a, $g, $e, $r, $\s, 20013, 25991]),
    {ok, #{logs := [#{text := Text, level := debug, module := agent_smoke, source := lager}]}} =
        eobs_agent:logs_events(node(), Cursor),
    ok = eobs_agent:logs_stop(),
    [] = gen_event:which_handlers(lager_event),
    gen_event:stop(Sink),
    ok.
