%% @doc Collector code that EObserver loads into the observed node.
%%
%% This module is shipped to the target with code:load_binary/3, so it
%% must only depend on kernel/stdlib APIs available in OTP 22 and must not
%% reference any other EObserver module. Everything returned is plain
%% Erlang terms; the tool node is responsible for turning them into JSON.
-module(eobs_agent).

-export([version/0, node_summary/0, load_sample/1]).

%% Bump whenever the exported API or return shapes change, so the tool
%% replaces an older copy that is still loaded on the target.
-define(VERSION, 2).

%% Process that keeps scheduler_wall_time enabled while a tool observes us.
-define(SWT_HOLDER, eobs_agent_swt).

version() ->
    ?VERSION.

node_summary() ->
    {UptimeMs, _} = erlang:statistics(wall_clock),
    {{input, In}, {output, Out}} = erlang:statistics(io),
    {Reductions, _} = erlang:statistics(reductions),
    {ContextSwitches, _} = erlang:statistics(context_switches),
    {GcCount, GcWords, _} = erlang:statistics(garbage_collection),
    #{node => node(),
      otp_release => list_to_binary(erlang:system_info(otp_release)),
      erts_version => list_to_binary(erlang:system_info(version)),
      system_architecture => list_to_binary(erlang:system_info(system_architecture)),
      emu_flavor => safe(fun() -> erlang:system_info(emu_flavor) end),
      word_size => erlang:system_info(wordsize),
      kernel_poll => erlang:system_info(kernel_poll),
      thread_pool_size => erlang:system_info(thread_pool_size),
      logical_processors => erlang:system_info(logical_processors_available),
      schedulers => erlang:system_info(schedulers),
      schedulers_online => erlang:system_info(schedulers_online),
      dirty_cpu_schedulers => erlang:system_info(dirty_cpu_schedulers),
      dirty_cpu_schedulers_online => erlang:system_info(dirty_cpu_schedulers_online),
      dirty_io_schedulers => erlang:system_info(dirty_io_schedulers),
      process_count => erlang:system_info(process_count),
      process_limit => erlang:system_info(process_limit),
      port_count => erlang:system_info(port_count),
      port_limit => erlang:system_info(port_limit),
      atom_count => erlang:system_info(atom_count),
      atom_limit => erlang:system_info(atom_limit),
      ets_count => length(ets:all()),
      ets_limit => safe(fun() -> erlang:system_info(ets_limit) end),
      memory => maps:from_list(erlang:memory()),
      memory_total => erlang:memory(total),
      uptime_ms => UptimeMs,
      run_queue => erlang:statistics(run_queue),
      io_input => In,
      io_output => Out,
      reductions => Reductions,
      context_switches => ContextSwitches,
      gc_count => GcCount,
      gc_words_reclaimed => GcWords,
      features => features()}.

%% One raw sample for the load charts. Counters are cumulative; the tool
%% computes rates from consecutive samples. Owner is the observing node:
%% scheduler wall time stays enabled until that node goes away.
load_sample(Owner) ->
    ensure_swt(Owner),
    {{input, In}, {output, Out}} = erlang:statistics(io),
    {Reductions, _} = erlang:statistics(reductions),
    #{time => erlang:monotonic_time(microsecond),
      scheduler_wall_time => swt(),
      schedulers => erlang:system_info(schedulers),
      dirty_cpu_schedulers => erlang:system_info(dirty_cpu_schedulers),
      io_input => In,
      io_output => Out,
      reductions => Reductions,
      run_queue => erlang:statistics(run_queue),
      process_count => erlang:system_info(process_count),
      memory => maps:from_list(erlang:memory())}.

swt() ->
    case erlang:statistics(scheduler_wall_time_all) of
        undefined -> undefined;
        List -> lists:sort(List)
    end.

%% scheduler_wall_time is reference counted per process that enabled it,
%% so a short-lived rpc process cannot hold it; a small holder process does.
ensure_swt(Owner) ->
    case whereis(?SWT_HOLDER) of
        undefined ->
            Parent = self(),
            {Pid, Ref} = spawn_monitor(fun() -> swt_holder(Parent, Owner) end),
            receive
                {Pid, ready} -> erlang:demonitor(Ref, [flush]), ok;
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end;
        _ ->
            ok
    end.

swt_holder(Parent, Owner) ->
    try register(?SWT_HOLDER, self()) of
        true ->
            erlang:system_flag(scheduler_wall_time, true),
            erlang:monitor_node(Owner, true),
            Parent ! {self(), ready},
            receive
                {nodedown, Owner} -> ok;
                stop -> ok
            end
    catch
        error:badarg -> Parent ! {self(), ready}
    end.

features() ->
    #{socket => has_which_sockets(),
      mnesia => lists:keymember(mnesia, 1, application:which_applications())}.

has_which_sockets() ->
    case code:ensure_loaded(socket) of
        {module, socket} -> erlang:function_exported(socket, which_sockets, 0);
        _ -> false
    end.

safe(Fun) ->
    try Fun()
    catch _:_ -> undefined
    end.
