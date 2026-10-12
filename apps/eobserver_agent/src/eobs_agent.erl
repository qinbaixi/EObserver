%% @doc Collector code that EObserver loads into the observed node.
%%
%% This module is shipped to the target with code:load_binary/3, so it
%% must only depend on kernel/stdlib APIs available in OTP 22 and must not
%% reference any other EObserver module. Everything returned is plain
%% Erlang terms; the tool node is responsible for turning them into JSON.
-module(eobs_agent).

-export([version/0, node_summary/0]).

%% Bump whenever the exported API or return shapes change, so the tool
%% replaces an older copy that is still loaded on the target.
-define(VERSION, 1).

version() ->
    ?VERSION.

node_summary() ->
    {UptimeMs, _} = erlang:statistics(wall_clock),
    #{node => node(),
      otp_release => list_to_binary(erlang:system_info(otp_release)),
      erts_version => list_to_binary(erlang:system_info(version)),
      system_architecture => list_to_binary(erlang:system_info(system_architecture)),
      word_size => erlang:system_info(wordsize),
      logical_processors => erlang:system_info(logical_processors_available),
      schedulers => erlang:system_info(schedulers),
      schedulers_online => erlang:system_info(schedulers_online),
      dirty_cpu_schedulers => erlang:system_info(dirty_cpu_schedulers),
      dirty_io_schedulers => erlang:system_info(dirty_io_schedulers),
      process_count => erlang:system_info(process_count),
      process_limit => erlang:system_info(process_limit),
      port_count => erlang:system_info(port_count),
      port_limit => erlang:system_info(port_limit),
      atom_count => erlang:system_info(atom_count),
      atom_limit => erlang:system_info(atom_limit),
      ets_count => length(ets:all()),
      memory_total => erlang:memory(total),
      uptime_ms => UptimeMs,
      features => features()}.

features() ->
    #{socket => has_which_sockets(),
      mnesia => lists:keymember(mnesia, 1, application:which_applications())}.

has_which_sockets() ->
    case code:ensure_loaded(socket) of
        {module, socket} -> erlang:function_exported(socket, which_sockets, 0);
        _ -> false
    end.
