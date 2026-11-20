%% @doc Collector code that EObserver loads into the observed node.
%%
%% This module is shipped to the target with code:load_binary/3, so it
%% must only depend on kernel/stdlib APIs available in OTP 22 and must not
%% reference any other EObserver module. Everything returned is plain
%% Erlang terms; the tool node is responsible for turning them into JSON.
-module(eobs_agent).

-export([version/0, prepare_unload/0, node_summary/0, load_sample/1]).
-export([holder_loop/2]).
-export([process_list/3, process_detail/1, process_state/2, process_kill/1,
         process_send/2]).
-export([app_list/0, app_tree/1]).
-export([port_list/0, port_detail/1, port_close/1, inet_list/0, socket_list/0]).
-export([ets_list/0, ets_rows/2, mnesia_list/0, mnesia_rows/2]).
-export([table_object/3, table_delete/3, table_write/4]).
-export([alloc_info/0, dist_info/0]).
-export([trace_start/3, trace_stop/0, trace_events/2, trace_stats/2]).
-export([diag_check/1, diag_window/2]).
-export([recon_proc_count/3, recon_bin_leak/2, recon_inet_count/4, recon_port_types/0,
         recon_alloc/0, recon_scheduler_usage/2]).
-export([logs_events/2, logs_stop/0]).
-export([logfile_list/0, logfile_read/4, logfile_seek/2, logfile_search/5, logfile_chunk/3]).
%% logger handler callback, called by logger in the logging process.
-export([log/2]).
%% gen_event callbacks: the agent is also a lager backend while the Logs
%% page is open, called in lager's event manager process.
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

%% Bump whenever the exported API or return shapes change, so the tool
%% replaces an older copy that is still loaded on the target.
-define(VERSION, 19).

%% Long-lived helper process on the observed node. It keeps
%% scheduler_wall_time enabled, builds process lists while holding the
%% per-viewer reduction snapshots in its own heap (no copying), and exits
%% when all observing tool nodes go away.
-define(HOLDER, eobs_agent_srv).
%% Snapshots of sessions not seen for this long are dropped.
-define(SNAP_TTL_MS, 120000).
-define(MAX_SNAP_SESSIONS, 8).
%% Caps on what we ship back for a single term or process detail.
-define(TERM_DEPTH, 30).
-define(TERM_CHARS, 8000).
-define(MAX_MESSAGES, 100).
-define(DETAIL_MAX_REFS, 500).
-define(DETAIL_MAX_DICT, 500).
-define(DETAIL_HEAP_WORDS, 8000000).
%% Supervision tree limits: children listed per supervisor, total nodes,
%% max active children before skipping which_children, and call timeout.
-define(TREE_MAX_CHILDREN, 200).
-define(TREE_MAX_NODES, 3000).
-define(TREE_MAX_SUP_CHILDREN, 5000).
-define(SUP_TIMEOUT, 3000).
%% Table viewer: chars per cell, and how many objects a search may scan.
-define(CELL_CHARS, 300).
-define(SEARCH_SCAN, 200000).
-define(SEARCH_HEAP_WORDS, 8000000).
-define(SEARCH_TIMEOUT_MS, 15000).
%% Full text of one object in the row viewer.
-define(OBJECT_CHARS, 1000000).
-define(MAX_REF_BYTES, 16777216).

version() ->
    ?VERSION.

%% Gracefully stops all agent-owned handlers and helper processes on the
%% observed node before code deletion/purge.
prepare_unload() ->
    _ = logs_stop(),
    _ = quit_tracer(),
    _ = stop_holder(),
    ok.

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
    ensure_holder(Owner),
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
%% so a short-lived rpc process cannot hold it; the holder process does.
ensure_holder(Owner) ->
    case whereis(?HOLDER) of
        undefined ->
            Parent = self(),
            {Pid, Ref} = spawn_opt(fun() -> holder(Parent, Owner) end,
                                   [monitor, {priority, low}]),
            receive
                {Pid, ready} -> erlang:demonitor(Ref, [flush]), ok;
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 ->
                erlang:demonitor(Ref, [flush]),
                ok
            end;
        Pid ->
            Pid ! {owner, Owner},
            ok
    end.

stop_holder() ->
    case whereis(?HOLDER) of
        undefined -> ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! stop,
            receive {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 ->
                exit(Pid, kill),
                receive {'DOWN', Ref, process, Pid, _} -> ok end
            end
    end.

monitor_owner(Owner) ->
    case Owner =:= node() orelse lists:member(Owner, nodes(connected)) of
        true ->
            erlang:monitor_node(Owner, true),
            true;
        false ->
            false
    end.

holder(Parent, Owner) ->
    try register(?HOLDER, self()) of
        true ->
            erlang:system_flag(scheduler_wall_time, true),
            Owners = case monitor_owner(Owner) of
                         true -> [Owner];
                         false -> []
                     end,
            Parent ! {self(), ready},
            case Owners of
                [] -> ok;
                _ -> ?MODULE:holder_loop(Owners, #{})
            end
    catch
        error:badarg -> Parent ! {self(), ready}
    end.

holder_loop(Owners, Snaps) ->
    Timeout = case map_size(Snaps) of
                  0 -> infinity;
                  _ -> ?SNAP_TTL_MS
              end,
    receive
        {owner, Owner} ->
            Owners1 = case lists:member(Owner, Owners) of
                          true -> Owners;
                          false ->
                              case monitor_owner(Owner) of
                                  true -> [Owner | Owners];
                                  false -> Owners
                              end
                      end,
            ?MODULE:holder_loop(Owners1, Snaps);
        {nodedown, Owner} ->
            case lists:delete(Owner, Owners) of
                [] -> ok;
                Rest -> ?MODULE:holder_loop(Rest, Snaps)
            end;
        stop ->
            ok;
        {From, Ref, {process_list, Session, Opts}} ->
            {Reply, Snaps1} = try do_process_list(Session, Opts, Snaps)
                              catch C:R -> {{error, {C, R}}, Snaps}
                              end,
            From ! {Ref, Reply},
            ?MODULE:holder_loop(Owners, Snaps1);
        _ ->
            ?MODULE:holder_loop(Owners, Snaps)
    after Timeout ->
        Now = erlang:monotonic_time(millisecond),
        Snaps1 = maps:filter(fun(_, {T, _}) -> T >= Now - ?SNAP_TTL_MS end, Snaps),
        erlang:garbage_collect(),
        ?MODULE:holder_loop(Owners, Snaps1)
    end.

holder_call(Owner, Request) ->
    ensure_holder(Owner),
    case whereis(?HOLDER) of
        undefined ->
            {error, no_holder};
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {self(), Ref, Request},
            receive
                {Ref, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
                {'DOWN', Ref, process, Pid, Reason} -> {error, {holder_down, Reason}}
            after 60000 ->
                erlang:demonitor(Ref, [flush]),
                {error, timeout}
            end
    end.

%%--------------------------------------------------------------------
%% Processes
%%--------------------------------------------------------------------

%% Returns one page of the process table. Sorting, filtering and paging
%% happen here so only the visible rows cross the network.
%%
%% Session identifies the viewer; the reductions each process had at that
%% viewer's previous call are kept so `reds` is the delta since then.
%% Opts: sort (reds | reductions | memory | message_queue_len | name | pid),
%% order (asc | desc), filter (binary), offset, limit.
process_list(Owner, Session, Opts) ->
    case holder_call(Owner, {process_list, Session, Opts}) of
        {error, Reason} -> erlang:error(Reason);
        Page -> Page
    end.

do_process_list(Session, Opts, Snaps0) ->
    Now = erlang:monotonic_time(millisecond),
    Snaps = maps:filter(fun(_, {T, _}) -> T >= Now - ?SNAP_TTL_MS end, Snaps0),
    Prev = case Snaps of
               #{Session := {_, Map}} -> Map;
               _ -> undefined
           end,
    Filter = safe_lower_list(maps:get(filter, Opts, <<>>)),
    Sort = maps:get(sort, Opts, reds),
    NeedName = Filter =/= "" orelse Sort =:= name,
    Items = collect_processes(Prev, NeedName, Sort =:= memory),
    Snap = maps:from_list([{Pid, R} || {Pid, R, _, _, _, _} <- Items]),
    Matching = case Filter of
                   "" -> Items;
                   _ -> [I || I <- Items, matches(I, Filter)]
               end,
    Offset = max(0, to_int(maps:get(offset, Opts, 0), 0)),
    Limit = max(0, min(to_int(maps:get(limit, Opts, 50), 50), 500)),
    Page = page(sort_key(Sort), maps:get(order, Opts, desc), Offset, Limit, Matching),
    Reply = #{total => length(Matching),
              process_count => length(Items),
              has_delta => Prev =/= undefined,
              rows => [row(I) || I <- Page]},
    {Reply, put_snap(Session, Now, Snap, Snaps)}.

put_snap(Session, Now, Snap, Snaps0) ->
    Snaps = Snaps0#{Session => {Now, Snap}},
    case map_size(Snaps) > ?MAX_SNAP_SESSIONS of
        false -> Snaps;
        true ->
            ByTime = lists:keysort(2, [{K, T} || {K, {T, _}} <- maps:to_list(Snaps)]),
            Drop = [K || {K, _} <- lists:sublist(ByTime, map_size(Snaps) - ?MAX_SNAP_SESSIONS)],
            maps:without(Drop, Snaps)
    end.

to_int(N, _Default) when is_integer(N) -> N;
to_int(_, Default) -> Default.

safe_lower_list(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin) of
        L when is_list(L) -> string:lowercase(L);
        _ -> ""
    end;
safe_lower_list(L) when is_list(L) ->
    try string:lowercase(L) catch _:_ -> "" end;
safe_lower_list(_) ->
    "".

%% {Pid, Reductions, RedsDelta | undefined, Memory | undefined, MsgQ, Name | undefined}
%%
%% Single-item process_info calls are several times faster than one call
%% with a list of items. `memory` is by far the most expensive item (it
%% walks heap fragments), so it is only read for every process when the
%% table is sorted by memory; otherwise just for the rows on the page.
collect_processes(Prev, NeedName, NeedMemory) ->
    lists:foldl(
      fun(Pid, Acc) ->
              case erlang:process_info(Pid, reductions) of
                  undefined ->
                      Acc;
                  {reductions, R} ->
                      M = case NeedMemory of
                              true -> info(Pid, memory, 0);
                              false -> undefined
                          end,
                      Q = info(Pid, message_queue_len, 0),
                      Name = case NeedName of
                                 true -> case info(Pid, registered_name, []) of
                                             [] -> undefined;
                                             N -> N
                                         end;
                                 false -> undefined
                             end,
                      Delta = case Prev of
                                  #{Pid := R0} -> max(0, R - R0);
                                  _ -> undefined
                              end,
                      [{Pid, R, Delta, M, Q, Name} | Acc]
              end
      end, [], erlang:processes()).

info(Pid, Item, Default) ->
    case erlang:process_info(Pid, Item) of
        {Item, V} -> V;
        _ -> Default
    end.

sort_key(reductions) -> fun({_, R, _, _, _, _}) -> R end;
sort_key(memory) -> fun({_, _, _, M, _, _}) -> M end;
sort_key(message_queue_len) -> fun({_, _, _, _, Q, _}) -> Q end;
sort_key(name) -> fun({P, _, _, _, _, N}) -> {N =:= undefined, N, P} end;
sort_key(pid) -> fun({P, _, _, _, _, _}) -> P end;
sort_key(_) -> fun({_, R, D, _, _, _}) -> {delta_key(D), R} end.

%% Returns items Offset+1 .. Offset+Limit in the requested order. Pages near
%% the top (the common case) use a bounded top-k pass instead of sorting
%% every process.
page(_Key, _Order, _Offset, Limit, _Items) when Limit =< 0 ->
    [];
page(Key, Order, Offset, Limit, Items) ->
    K = Offset + Limit,
    Keyed = [{Key(I), I} || I <- Items],
    Ordered = case K > 0 andalso K =< 2000 andalso length(Keyed) > 4 * K of
                  true -> top_k(Order, K, Keyed);
                  false -> full_sort(Order, Keyed)
              end,
    [I || {_, I} <- lists:sublist(Ordered, Offset + 1, Limit)].

full_sort(asc, Keyed) -> lists:keysort(1, Keyed);
full_sort(_, Keyed) -> lists:reverse(lists:keysort(1, Keyed)).

%% Keeps the K best entries in a gb_tree keyed on {SortKey, Pid}; an entry
%% that cannot beat the current worst is rejected with one comparison.
top_k(Order, K, Keyed) ->
    Better = case Order of
                 asc -> fun(A, B) -> A < B end;
                 _ -> fun(A, B) -> A > B end
             end,
    Worst = case Order of
                asc -> fun gb_trees:largest/1;
                _ -> fun gb_trees:smallest/1
            end,
    Take = case Order of
               asc -> fun gb_trees:take_largest/1;
               _ -> fun gb_trees:take_smallest/1
           end,
    Tree = lists:foldl(
             fun({SortKey, I}, T) ->
                     TK = {SortKey, element(1, I)},
                     case gb_trees:size(T) < K of
                         true ->
                             gb_trees:insert(TK, I, T);
                         false ->
                             {WK, _} = Worst(T),
                             case Better(TK, WK) of
                                 true -> {_, _, T1} = Take(T), gb_trees:insert(TK, I, T1);
                                 false -> T
                             end
                     end
             end, gb_trees:empty(), Keyed),
    Sorted = [{SK, I} || {{SK, _}, I} <- gb_trees:to_list(Tree)],
    case Order of
        asc -> Sorted;
        _ -> lists:reverse(Sorted)
    end.

%% A process matches when the filter occurs in its registered name, the
%% module or function of its initial call or current function, or (for
%% filters that look like a pid) its pid.
matches({Pid, _, _, _, _, Name}, Filter) ->
    (Name =/= undefined andalso match_atom(Name, Filter))
        orelse match_mfa(info(Pid, initial_call, undefined), Filter)
        orelse match_mfa(info(Pid, current_function, undefined), Filter)
        orelse (looks_like_pid(Filter) andalso match_text(pid_to_list(Pid), Filter)).

match_text(Text, Filter) ->
    string:find(string:lowercase(Text), Filter) =/= nomatch.

match_atom(A, Filter) when is_atom(A) ->
    match_text(atom_to_list(A), Filter);
match_atom(_, _) ->
    false.

match_mfa({M, F, _}, Filter) ->
    match_atom(M, Filter) orelse match_atom(F, Filter);
match_mfa(_, _) ->
    false.

looks_like_pid([C | _]) -> C =:= $< orelse (C >= $0 andalso C =< $9);
looks_like_pid(_) -> false.

delta_key(undefined) -> -1;
delta_key(D) -> D.

row({Pid, R, Delta, M0, Q, _Name}) ->
    M = case M0 of
            undefined -> info(Pid, memory, 0);
            _ -> M0
        end,
    Info = erlang:process_info(Pid, [current_function, status, registered_name]),
    {CF, Status, Name} = case Info of
                             [{current_function, C}, {status, S}, {registered_name, N}] ->
                                 {mfa(C), S, case N of [] -> undefined; _ -> N end};
                             undefined ->
                                 {"", exiting, undefined}
                         end,
    #{pid => list_to_binary(pid_to_list(Pid)),
      name => Name,
      initial_call => bin(initial_call(Pid)),
      current_function => bin(CF),
      status => Status,
      reductions => R,
      reds => Delta,
      memory => M,
      message_queue_len => Q}.

initial_call(Pid) ->
    case catch proc_lib:translate_initial_call(Pid) of
        {M, F, A} -> mfa({M, F, A});
        _ -> ""
    end.

%% Full details for the process drawer. Every term is formatted here,
%% with depth and length caps, in a heap-capped worker so a huge process
%% dictionary or queue can never OOM the observed node.
process_detail(PidBin) ->
    case safe_to_pid(PidBin) of
        {ok, Pid} ->
            capped_call(?DETAIL_HEAP_WORDS, 10000, fun() -> do_process_detail(Pid, PidBin) end);
        error ->
            {error, not_found}
    end.

do_process_detail(Pid, PidBin) ->
    Keys = [registered_name, status, initial_call, current_function, current_stacktrace,
            message_queue_len, links, monitors, monitored_by, trap_exit, priority,
            group_leader, reductions, memory, total_heap_size, heap_size, stack_size,
            garbage_collection, dictionary],
    case erlang:process_info(Pid, Keys) of
        undefined ->
            {error, not_found};
        Info0 ->
            Info = maps:from_list(Info0),
            #{dictionary := Dict, message_queue_len := QLen} = Info,
            Name = case maps:get(registered_name, Info) of [] -> undefined; N -> N end,
            Links = lists:sublist(maps:get(links, Info), ?DETAIL_MAX_REFS),
            Monitors = lists:sublist(maps:get(monitors, Info), ?DETAIL_MAX_REFS),
            MonitoredBy = lists:sublist(maps:get(monitored_by, Info), ?DETAIL_MAX_REFS),
            DictShown = lists:sublist(Dict, ?DETAIL_MAX_DICT),
            {ok, #{pid => PidBin,
                   name => Name,
                   status => maps:get(status, Info),
                   initial_call => bin(initial_call(Pid)),
                   current_function => bin(mfa(maps:get(current_function, Info))),
                   stacktrace => [format_frame(F) || F <- maps:get(current_stacktrace, Info)],
                   message_queue_len => QLen,
                   messages => messages(Pid, QLen),
                   links => [ref_bin(L) || L <- Links],
                   monitors => [monitor_bin(M) || M <- Monitors],
                   monitored_by => [ref_bin(M) || M <- MonitoredBy],
                   trap_exit => maps:get(trap_exit, Info),
                   priority => maps:get(priority, Info),
                   group_leader => ref_bin(maps:get(group_leader, Info)),
                   reductions => maps:get(reductions, Info),
                   memory => maps:get(memory, Info),
                   total_heap_size => maps:get(total_heap_size, Info),
                   heap_size => maps:get(heap_size, Info),
                   stack_size => maps:get(stack_size, Info),
                   garbage_collection => [#{key => K, value => fmt(V)}
                                          || {K, V} <- maps:get(garbage_collection, Info)],
                   dictionary => [#{key => fmt(K), value => fmt(V)} || {K, V} <- DictShown],
                   word_size => erlang:system_info(wordsize)}}
    end.

%% Reading the whole queue copies it, so only short queues are shown.
messages(Pid, QLen) when QLen =< ?MAX_MESSAGES ->
    case erlang:process_info(Pid, messages) of
        {messages, Msgs} -> [fmt(M) || M <- lists:sublist(Msgs, ?MAX_MESSAGES)];
        undefined -> []
    end;
messages(_Pid, _QLen) ->
    truncated.

process_state(PidBin, Timeout) ->
    case safe_to_pid(PidBin) of
        {ok, Pid} ->
            capped_call(?DETAIL_HEAP_WORDS, Timeout + 1000, fun() ->
                try sys:get_state(Pid, Timeout) of
                    State -> {ok, fmt(State)}
                catch
                    exit:{timeout, _} -> {error, timeout};
                    exit:{noproc, _} -> {error, not_found};
                    _:Reason -> {error, fmt(Reason)}
                end
            end);
        error ->
            {error, not_found}
    end.

capped_call(HeapWords, Timeout, Fun) ->
    {Pid, Ref} = spawn_opt(fun() -> exit({capped_ok, Fun()}) end,
                           [monitor, {priority, low},
                            {max_heap_size, #{size => HeapWords, kill => true,
                                              error_logger => false}}]),
    receive
        {'DOWN', Ref, process, Pid, {capped_ok, Result}} -> Result;
        {'DOWN', Ref, process, Pid, killed} -> {error, too_big};
        {'DOWN', Ref, process, Pid, Reason} -> {error, fmt(Reason)}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        {error, timeout}
    end.

process_kill(PidBin) ->
    case safe_to_pid(PidBin) of
        {ok, Pid} -> exit(Pid, kill), ok;
        error -> {error, not_found}
    end.

process_send(PidBin, Msg) ->
    case safe_to_pid(PidBin) of
        {ok, Pid} -> Pid ! Msg, ok;
        error -> {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Applications
%%--------------------------------------------------------------------

app_list() ->
    Running = application:which_applications(),
    RunningSet = maps:from_list([{A, true} || {A, _, _} <- Running]),
    Loaded = [{A, D, V} || {A, D, V} <- application:loaded_applications(),
                           not is_map_key(A, RunningSet)],
    [#{name => A, description => bin(D), vsn => bin(V), running => true}
     || {A, D, V} <- lists:keysort(1, Running)]
        ++ [#{name => A, description => bin(D), vsn => bin(V), running => false}
            || {A, D, V} <- lists:keysort(1, Loaded)].

%% The supervision tree of a running application, from its top
%% supervisor down. Large supervisors are truncated, see TREE_MAX_*.
app_tree(App) ->
    case application_controller:get_master(App) of
        Master when is_pid(Master) ->
            case catch application_master:get_child(Master) of
                {Root, Mod} when is_pid(Root) ->
                    RootType = case is_supervisor(Root) of
                                   true -> supervisor;
                                   false -> worker
                               end,
                    {Tree, _} = sup_node(Root, App, RootType, Mod, ?TREE_MAX_NODES),
                    {ok, #{master => ref_bin(Master), root => Tree}};
                _ ->
                    {ok, #{master => ref_bin(Master), root => null}}
            end;
        _ ->
            %% Library applications (no mod) have no master process.
            case lists:keymember(App, 1, application:which_applications()) of
                true -> {ok, #{master => null, root => null}};
                false -> {error, not_running}
            end
    end.

%% Only send supervisor calls (which_children / count_children) to
%% processes that actually run supervisor / supervisor_bridge.
is_supervisor(Pid) ->
    case catch proc_lib:translate_initial_call(Pid) of
        {supervisor, _, _} -> true;
        {supervisor_bridge, _, _} -> true;
        _ ->
            case erlang:process_info(Pid, initial_call) of
                {initial_call, {supervisor, _, _}} -> true;
                {initial_call, {supervisor_bridge, _, _}} -> true;
                _ -> false
            end
    end.

sup_node(Pid, Id, Type, Mod, Budget) ->
    Base = #{pid => ref_bin(Pid),
             id => fmt(Id),
             name => registered_name(Pid),
             type => Type,
             module => Mod},
    case Type of
        supervisor when Budget > 0 ->
            case sup_too_large(Pid) of
                {true, Active} ->
                    {Base#{children => [], hidden => Active}, Budget - 1};
                false ->
                    case sup_call(Pid, which_children) of
                        {ok, Children} when is_list(Children) ->
                            Total = length(Children),
                            Shown = lists:sublist(Children, ?TREE_MAX_CHILDREN),
                            {Nodes, Left} = lists:foldl(
                                              fun(Child, {Acc, B}) -> child_node(Child, Acc, B) end,
                                              {[], Budget - 1}, Shown),
                            {Base#{children => lists:reverse(Nodes),
                                   hidden => Total - length(Nodes)}, Left};
                        {ok, _} ->
                            {Base#{children => [], hidden => 0}, Budget - 1};
                        {error, Reason} ->
                            {Base#{children => [], hidden => 0, error => fmt(Reason)}, Budget - 1}
                    end
            end;
        _ ->
            {Base#{children => [], hidden => 0}, Budget - 1}
    end.

sup_too_large(Pid) ->
    case sup_call(Pid, count_children) of
        {ok, Counts} when is_list(Counts) ->
            Active = proplists:get_value(active, Counts, 0),
            Specs = proplists:get_value(specs, Counts, 0),
            case is_integer(Active) andalso is_integer(Specs)
                 andalso max(Active, Specs) > ?TREE_MAX_SUP_CHILDREN of
                true -> {true, max(Active, Specs)};
                false -> false
            end;
        _ ->
            false
    end.

child_node(_, Acc, Budget) when Budget =< 0 ->
    {Acc, Budget};
child_node({Id, Child, Type, Mods}, Acc, Budget) when is_pid(Child) ->
    Mod = case Mods of [M | _] -> M; _ -> Mods end,
    {Node, Left} = sup_node(Child, Id, Type, Mod, Budget),
    {[Node | Acc], Left};
child_node({Id, Child, Type, _Mods}, Acc, Budget) ->
    %% restarting or undefined (not running) children
    {[#{pid => null, id => fmt(Id), name => null, type => Type, module => null,
        status => Child, children => [], hidden => 0} | Acc], Budget - 1};
child_node(_, Acc, Budget) ->
    {Acc, Budget}.

%% supervisor:which_children/1 waits forever; a stuck supervisor must not
%% hang the page.
sup_call(Pid, Request) ->
    try gen:call(Pid, '$gen_call', Request, ?SUP_TIMEOUT) of
        {ok, Reply} -> {ok, Reply}
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:Reason -> {error, Reason}
    end.

registered_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} when is_atom(Name), Name =/= [] -> Name;
        _ -> null
    end.

%%--------------------------------------------------------------------
%% Ports and sockets
%%--------------------------------------------------------------------

port_list() ->
    [P || P <- [port_row(Port) || Port <- erlang:ports()], P =/= undefined].

port_row(Port) ->
    case erlang:port_info(Port) of
        undefined ->
            undefined;
        Info ->
            Name = proplists:get_value(name, Info),
            RegName = case proplists:get_value(registered_name, Info) of
                          undefined -> null;
                          [] -> null;
                          RN -> RN
                      end,
            #{id => ref_bin(Port),
              name => bin(Name),
              registered_name => RegName,
              connected => ref_bin(proplists:get_value(connected, Info)),
              os_pid => case proplists:get_value(os_pid, Info) of
                            undefined -> null;
                            OsPid -> OsPid
                        end,
              input => proplists:get_value(input, Info, 0),
              output => proplists:get_value(output, Info, 0),
              queue_size => port_item(Port, queue_size, 0),
              memory => port_item(Port, memory, 0),
              inet => inet_port_name(Name)}
    end.

port_item(Port, Item, Default) ->
    case catch erlang:port_info(Port, Item) of
        {Item, []} -> Default;
        {Item, V} -> V;
        _ -> Default
    end.

inet_port_name("tcp_inet") -> true;
inet_port_name("udp_inet") -> true;
inet_port_name("sctp_inet") -> true;
inet_port_name(_) -> false.

inet_proto("tcp_inet") -> tcp;
inet_proto("udp_inet") -> udp;
inet_proto("sctp_inet") -> sctp;
inet_proto(_) -> unknown.

port_detail(PortBin) ->
    case safe_to_port(PortBin) of
        error ->
            {error, not_found};
        {ok, Port} ->
            case port_row(Port) of
                undefined ->
                    {error, not_found};
                Row ->
                    Links = [ref_bin(L) || L <- lists:sublist(port_item(Port, links, []), ?DETAIL_MAX_REFS)],
                    Monitors = [monitor_bin(M) || M <- lists:sublist(port_item(Port, monitors, []), ?DETAIL_MAX_REFS)],
                    Extra = case maps:get(inet, Row) of
                                true -> inet_info(Port, undefined);
                                false -> #{}
                            end,
                    {ok, maps:merge(Row#{links => Links, monitors => Monitors,
                                         parallelism => port_item(Port, parallelism, false),
                                         locking => port_item(Port, locking, null)}, Extra)}
            end
    end.

port_close(PortBin) ->
    case safe_to_port(PortBin) of
        error -> {error, not_found};
        {ok, Port} ->
            try erlang:port_close(Port) of
                true -> ok
            catch
                error:badarg -> {error, not_found}
            end
    end.

%% gen_tcp / gen_udp / gen_sctp sockets (inet driver ports).
inet_list() ->
    [maps:merge(Row, inet_info(Port, Name))
     || Port <- erlang:ports(),
        {name, Name} <- [erlang:port_info(Port, name)],
        inet_port_name(Name),
        Row <- [port_row(Port)],
        Row =/= undefined].

inet_info(Port, Name0) ->
    Stats = case catch inet:getstat(Port, [recv_oct, send_oct, recv_cnt, send_cnt]) of
                {ok, S} -> maps:from_list(S);
                _ -> #{}
            end,
    Name = case Name0 of
               undefined ->
                   case erlang:port_info(Port, name) of
                       {name, N} -> N;
                       _ -> ""
                   end;
               N -> N
           end,
    #{local => addr(catch inet:sockname(Port)),
      remote => addr(catch inet:peername(Port)),
      protocol => inet_proto(Name),
      stats => Stats}.

%% Sockets created with the socket module (OTP 22+).
socket_list() ->
    case erlang:function_exported(socket, which_sockets, 0)
         orelse code:ensure_loaded(socket) =:= {module, socket}
                andalso erlang:function_exported(socket, which_sockets, 0) of
        false ->
            {error, unsupported};
        true ->
            {ok, [socket_row(S) || S <- socket:which_sockets()]}
    end.

socket_row(S) ->
    Info = case catch socket:info(S) of
               I when is_map(I) -> I;
               _ -> #{}
           end,
    Counters = maps:get(counters, Info, #{}),
    #{id => fmt(S),
      domain => maps:get(domain, Info, null),
      type => maps:get(type, Info, null),
      protocol => maps:get(protocol, Info, null),
      owner => ref_bin(maps:get(owner, Info, null)),
      rstates => [fmt(X) || X <- maps:get(rstates, Info, [])],
      wstates => [fmt(X) || X <- maps:get(wstates, Info, [])],
      local => addr(catch socket:sockname(S)),
      remote => addr(catch socket:peername(S)),
      read_bytes => maps:get(read_byte, Counters, 0),
      write_bytes => maps:get(write_byte, Counters, 0),
      counters => maps:from_list([{K, V} || {K, V} <- maps:to_list(Counters),
                                            is_integer(V)])}.

addr({ok, {{local, Path}, _}}) ->
    addr_path(Path);
addr({ok, {Ip, Port}}) when is_tuple(Ip), (tuple_size(Ip) =:= 4 orelse tuple_size(Ip) =:= 8),
                            is_integer(Port) ->
    case inet:ntoa(Ip) of
        {error, _} -> fmt({Ip, Port});
        Str -> bin(Str ++ ":" ++ integer_to_list(Port))
    end;
addr({ok, #{addr := Ip, port := Port}}) when is_tuple(Ip),
                                             (tuple_size(Ip) =:= 4 orelse tuple_size(Ip) =:= 8),
                                             is_integer(Port) ->
    case inet:ntoa(Ip) of
        {error, _} -> fmt({Ip, Port});
        Str -> bin(Str ++ ":" ++ integer_to_list(Port))
    end;
addr({ok, #{path := Path}}) ->
    addr_path(Path);
addr({ok, Other}) ->
    fmt(Other);
addr(_) ->
    null.

addr_path(Path) when is_binary(Path) ->
    case unicode:characters_to_binary(Path) of
        B when is_binary(B) -> B;
        _ -> fmt(Path)
    end;
addr_path(Path) when is_list(Path) ->
    case unicode:characters_to_binary(Path) of
        B when is_binary(B) -> B;
        _ -> fmt(Path)
    end;
addr_path(Path) ->
    fmt(Path).

%%--------------------------------------------------------------------
%% ETS and Mnesia tables
%%--------------------------------------------------------------------

ets_list() ->
    Word = erlang:system_info(wordsize),
    {Rows, _Cache} = lists:foldl(
                       fun(Tab, {Acc, Cache}) ->
                               case ets_row(Tab, Word, Cache) of
                                   {undefined, Cache1} -> {Acc, Cache1};
                                   {Row, Cache1} -> {[Row | Acc], Cache1}
                               end
                       end, {[], #{}}, ets:all()),
    lists:reverse(Rows).

ets_row(Tab, Word, Cache) ->
    case catch ets:info(Tab) of
        Info when is_list(Info) ->
            Owner = proplists:get_value(owner, Info),
            Name = proplists:get_value(name, Info),
            {Sys, Cache1} = system_owner(Owner, Cache),
            Row = #{id => table_id(Tab),
                    name => Name,
                    named => proplists:get_value(named_table, Info, false),
                    type => proplists:get_value(type, Info),
                    size => proplists:get_value(size, Info, 0),
                    memory => proplists:get_value(memory, Info, 0) * Word,
                    owner => ref_bin(Owner),
                    owner_name => registered_name(Owner),
                    protection => proplists:get_value(protection, Info),
                    keypos => proplists:get_value(keypos, Info, 1),
                    compressed => proplists:get_value(compressed, Info, false),
                    read_concurrency => proplists:get_value(read_concurrency, Info, false),
                    write_concurrency => fmt(proplists:get_value(write_concurrency, Info, false)),
                    system => Sys},
            {Row, Cache1};
        _ ->
            {undefined, Cache}
    end.

%% Tables owned by kernel/stdlib processes are hidden by default, as in
%% OTP's observer. Memoised per group_leader / owner to avoid scanning
%% ac_tab once per table.
system_owner(Pid, Cache) when is_pid(Pid) ->
    Key = case erlang:process_info(Pid, group_leader) of
              {group_leader, GL} -> GL;
              _ -> Pid
          end,
    case Cache of
        #{Key := Sys} ->
            {Sys, Cache};
        _ ->
            Sys = case catch application:get_application(Pid) of
                      {ok, App} -> lists:member(App, [kernel, stdlib]);
                      _ -> false
                  end,
            {Sys, Cache#{Key => Sys}}
    end;
system_owner(_, Cache) ->
    {false, Cache}.

table_id(Tab) when is_atom(Tab) -> atom_to_binary(Tab, utf8);
table_id(Tab) when is_reference(Tab) -> list_to_binary(erlang:ref_to_list(Tab));
table_id(Tab) -> fmt(Tab).

%% Opts: id (from ets_list), offset, limit, search (binary).
ets_rows(IdBin, Opts) ->
    case find_ets(IdBin) of
        undefined ->
            {error, not_found};
        Tab ->
            case ets:info(Tab, protection) of
                undefined -> {error, not_found};
                private -> {error, private};
                _ ->
                    capped_call(?SEARCH_HEAP_WORDS, ?SEARCH_TIMEOUT_MS, fun() ->
                        guarded(fun() ->
                            Size = ets:info(Tab, size),
                            KeyPos = ets:info(Tab, keypos),
                            case is_integer(Size) andalso is_integer(KeyPos) of
                                false -> {error, not_found};
                                true ->
                                    ets:safe_fixtable(Tab, true),
                                    try
                                        {ok, read_rows(fun(Spec, N) -> ets:select(Tab, Spec, N) end,
                                                       Size, KeyPos, Opts)}
                                    after
                                        catch ets:safe_fixtable(Tab, false)
                                    end
                            end
                        end)
                    end)
            end
    end.

find_ets(IdBin) when is_binary(IdBin) ->
    case (try binary_to_existing_atom(IdBin, utf8) catch error:badarg -> undefined end) of
        Atom when is_atom(Atom), Atom =/= undefined ->
            case ets:whereis(Atom) of
                undefined -> find_ets_scan(IdBin);
                _ -> Atom
            end;
        _ ->
            find_ets_scan(IdBin)
    end;
find_ets(_) ->
    undefined.

find_ets_scan(IdBin) ->
    case [T || T <- ets:all(), table_id(T) =:= IdBin] of
        [T | _] -> T;
        [] -> undefined
    end.

mnesia_list() ->
    case mnesia_running() of
        false ->
            {error, not_running};
        true ->
            Word = erlang:system_info(wordsize),
            Tabs = [T || T <- mnesia:system_info(tables), T =/= schema],
            {ok, [mnesia_row(T, Word) || T <- lists:sort(Tabs)]}
    end.

mnesia_row(Tab, Word) ->
    Info = fun(Item) -> catch mnesia:table_info(Tab, Item) end,
    Storage = Info(storage_type),
    Memory = case Info(memory) of
                 M when is_integer(M), Storage =:= disc_only_copies -> M;
                 M when is_integer(M) -> M * Word;
                 _ -> 0
             end,
    #{id => atom_to_binary(Tab, utf8),
      name => Tab,
      storage => fmt(Storage),
      type => fmt(Info(type)),
      size => case Info(size) of S when is_integer(S) -> S; _ -> 0 end,
      memory => Memory,
      record_name => fmt(Info(record_name)),
      attributes => [fmt(A) || A <- case Info(attributes) of L when is_list(L) -> L; _ -> [] end],
      where_to_read => fmt(Info(where_to_read))}.

mnesia_rows(IdBin, Opts) ->
    case mnesia_running() of
        false ->
            {error, not_running};
        true ->
            case [T || T <- mnesia:system_info(tables), atom_to_binary(T, utf8) =:= IdBin] of
                [Tab] ->
                    capped_call(?SEARCH_HEAP_WORDS, ?SEARCH_TIMEOUT_MS, fun() ->
                        guarded(fun() ->
                            Attrs = [fmt(A) || A <- mnesia:table_info(Tab, attributes)],
                            Size = mnesia:table_info(Tab, size),
                            Res = mnesia:activity(async_dirty, fun() ->
                                Select = fun(Spec, N) ->
                                                 case mnesia:select(Tab, Spec, N, read) of
                                                     '$end_of_table' -> '$end_of_table';
                                                     {Objs, Cont} -> {Objs, {mnesia_cont, Cont}}
                                                 end
                                         end,
                                read_rows(Select, Size, 2, Opts)
                            end),
                            {ok, Res#{attributes => Attrs}}
                        end)
                    end);
                _ ->
                    {error, not_found}
            end
    end.

mnesia_running() ->
    lists:keymember(mnesia, 1, application:which_applications())
        andalso (catch mnesia:system_info(is_running)) =:= yes.

%% Reads one page of objects via Select(MatchSpec, ChunkSize), which must
%% behave like ets:select/3. Without a search the page is reached by
%% skipping Offset objects; with a search every object is formatted and
%% matched, scanning at most SEARCH_SCAN objects.
read_rows(Select, Size, KeyPos, Opts) ->
    Offset = max(0, to_int(maps:get(offset, Opts, 0), 0)),
    Limit = max(0, min(to_int(maps:get(limit, Opts, 50), 50), 500)),
    Search = safe_lower_list(maps:get(search, Opts, <<>>)),
    Spec = [{'_', [], ['$_']}],
    {Objects, Matched, Scanned, Complete} =
        case Search of
            "" ->
                Objs = take(Select(Spec, 500), Offset, Limit),
                {Objs, Size, Offset + length(Objs), true};
            _ ->
                Deadline = erlang:monotonic_time(millisecond) + ?SEARCH_TIMEOUT_MS - 1000,
                search(Select(Spec, 500), Search, Offset, Limit, Deadline)
        end,
    Rows = [row_cells(O) || O <- Objects],
    #{rows => Rows,
      keys => [key_ref(O, KeyPos) || O <- Objects],
      keypos => KeyPos,
      columns => lists:max([0 | [length(R) || R <- Rows]]),
      total => Matched,
      scanned => Scanned,
      complete => Complete}.

take(Chunk, Offset, Limit) ->
    take(Chunk, Offset, Limit, []).

take(_, _, Limit, Acc) when Limit =< 0 ->
    lists:reverse(Acc);
take('$end_of_table', _, _, Acc) ->
    lists:reverse(Acc);
take({Objs, Cont}, Offset, Limit, Acc) ->
    Len = length(Objs),
    case Offset >= Len of
        true ->
            take(next(Cont), Offset - Len, Limit, Acc);
        false ->
            Page = lists:sublist(Objs, Offset + 1, Limit),
            take(next(Cont), 0, Limit - length(Page), lists:reverse(Page, Acc))
    end.

search(Chunk, Search, Offset, Limit, Deadline) ->
    search(Chunk, Search, Offset, Limit, Deadline, [], 0, 0).

search('$end_of_table', _, _, _, _, Acc, Matched, Scanned) ->
    {lists:reverse(Acc), Matched, Scanned, true};
search(_, _, _, _, _, Acc, Matched, Scanned) when Scanned >= ?SEARCH_SCAN ->
    {lists:reverse(Acc), Matched, Scanned, false};
search({Objs, Cont}, Search, Offset, Limit, Deadline, Acc0, Matched0, Scanned0) ->
    case erlang:monotonic_time(millisecond) > Deadline of
        true ->
            {lists:reverse(Acc0), Matched0, Scanned0, false};
        false ->
            {Acc, Matched} =
                lists:foldl(
                  fun(O, {A, M}) ->
                          Text = safe_lower_list(fmt_chars(O, ?TERM_DEPTH, ?TERM_CHARS)),
                          case string:find(Text, Search) =/= nomatch of
                              true when M >= Offset, M < Offset + Limit -> {[O | A], M + 1};
                              true -> {A, M + 1};
                              false -> {A, M}
                          end
                  end, {Acc0, Matched0}, Objs),
            search(next(Cont), Search, Offset, Limit, Deadline, Acc, Matched, Scanned0 + length(Objs))
    end.

next('$end_of_table') -> '$end_of_table';
next({mnesia_cont, Cont}) ->
    case mnesia:select(Cont) of
        '$end_of_table' -> '$end_of_table';
        {Objs, Cont1} -> {Objs, {mnesia_cont, Cont1}}
    end;
next(Cont) ->
    ets:select(Cont).

%% Opaque, exact reference to an object's key, handed back by the viewer
%% to read, change or delete that object.
key_ref(Obj, KeyPos) when is_tuple(Obj), tuple_size(Obj) >= KeyPos ->
    ref(element(KeyPos, Obj));
key_ref(_, _) ->
    null.

ref(Term) -> base64:encode(term_to_binary(Term)).

unref(Bin) -> binary_to_term(base64:decode(Bin), [safe]).

%% Kind: ets | mnesia. Returns every object stored under the key (several
%% for bag tables) in full, each with a ref for table_delete/table_write
%% and whether its text reads back as the same term (pids, refs and funs
%% do not), i.e. whether it can be edited as text.
table_object(Kind, IdBin, KeyRef) ->
    capped_call(?DETAIL_HEAP_WORDS, 10000, fun() ->
        with_table(Kind, IdBin, read, fun(Tab, _KeyPos) ->
            Key = unref(KeyRef),
            Objs = case Kind of
                       ets -> ets:lookup(Tab, Key);
                       mnesia -> mnesia:activity(async_dirty, fun() -> mnesia:read(Tab, Key) end)
                   end,
            {ok, [object_view(O) || O <- lists:sublist(Objs, 200)]}
        end)
    end).

object_view(Obj) ->
    {Text, Complete} = fmt_object(Obj, ?OBJECT_CHARS),
    Ref = case erlang:external_size(Obj) =< ?MAX_REF_BYTES of
              true -> ref(Obj);
              false -> null
          end,
    #{text => Text,
      ref => Ref,
      editable => Complete andalso Ref =/= null andalso is_literal_term(Obj)}.

fmt_object(Obj, Max) ->
    Ext = erlang:external_size(Obj),
    %% In OTP io_lib_pretty, ~tp (infinite depth) expands binaries in full
    %% before chars_limit applies. Use ~tp only when the term is small enough
    %% to format completely within Max without risking an OOM spike; for
    %% larger terms use bounded-depth ~tP + chars_limit.
    case Ext * 4 =< Max of
        true ->
            Bin = unicode:characters_to_binary(
                    io_lib:format("~tp", [Obj], [{chars_limit, Max + 64}])),
            case string:length(Bin) > Max of
                true -> {<<(string:slice(Bin, 0, Max))/binary, " ...">>, false};
                false -> {Bin, true}
            end;
        false ->
            Limit = min(Max, 262144),
            Bin = unicode:characters_to_binary(
                    io_lib:format("~tP", [Obj, 200], [{chars_limit, Limit + 64}])),
            Shown = case string:length(Bin) > Limit of
                        true -> <<(string:slice(Bin, 0, Limit))/binary, " ...">>;
                        false -> Bin
                    end,
            {Shown, false}
    end.

%% Pure literal terms (no pids, ports, refs, or funs) round-trip cleanly
%% through ~tp and erl_parse:parse_term without scanning 1 MB of tokens.
is_literal_term(T) when is_atom(T); is_integer(T); is_float(T); is_bitstring(T) ->
    true;
is_literal_term([]) ->
    true;
is_literal_term([H | T]) ->
    is_literal_term(H) andalso is_literal_term(T);
is_literal_term(T) when is_tuple(T) ->
    is_literal_tuple(T, tuple_size(T));
is_literal_term(M) when is_map(M) ->
    is_literal_map(maps:iterator(M));
is_literal_term(_) ->
    false.

is_literal_tuple(_T, 0) -> true;
is_literal_tuple(T, I) ->
    is_literal_term(element(I, T)) andalso is_literal_tuple(T, I - 1).

is_literal_map(Iter) ->
    case maps:next(Iter) of
        none -> true;
        {K, V, Next} ->
            is_literal_term(K) andalso is_literal_term(V) andalso is_literal_map(Next)
    end.

%% Deletes exactly the object ObjRef refers to (one of a bag's objects).
table_delete(Kind, IdBin, ObjRef) ->
    with_table(Kind, IdBin, write, fun(Tab, _KeyPos) ->
        Obj = unref(ObjRef),
        case Kind of
            ets -> true = ets:delete_object(Tab, Obj), ok;
            mnesia -> transaction(fun() -> mnesia:delete_object(Tab, Obj, write) end)
        end
    end).

%% Writes New, replacing the object OldRef refers to (null to add one).
table_write(Kind, IdBin, New, OldRef) ->
    with_table(Kind, IdBin, write, fun(Tab, KeyPos) ->
        Old = case OldRef of
                  null -> undefined;
                  _ -> unref(OldRef)
              end,
        case check_object(Kind, Tab, KeyPos, New) of
            ok when Old =:= New ->
                ok;
            ok when Kind =:= ets ->
                Type = ets:info(Tab, type),
                SameKey = Old =/= undefined
                          andalso (Type =:= set orelse Type =:= ordered_set)
                          andalso is_tuple(Old) andalso tuple_size(Old) >= KeyPos
                          andalso element(KeyPos, Old) =:= element(KeyPos, New),
                case SameKey of
                    true ->
                        %% Atomic overwrite in place: readers never see the key vanish.
                        true = ets:insert(Tab, New),
                        ok;
                    false ->
                        Old =/= undefined andalso ets:delete_object(Tab, Old),
                        true = ets:insert(Tab, New),
                        ok
                end;
            ok ->
                transaction(fun() ->
                                    Old =/= undefined andalso mnesia:delete_object(Tab, Old, write),
                                    mnesia:write(Tab, New, write)
                            end);
            {error, _} = Error ->
                Error
        end
    end).

check_object(ets, _Tab, KeyPos, New) when is_tuple(New), tuple_size(New) >= KeyPos -> ok;
check_object(ets, _Tab, _KeyPos, _New) -> {error, bad_object};
check_object(mnesia, Tab, _KeyPos, New) ->
    Name = mnesia:table_info(Tab, record_name),
    Arity = length(mnesia:table_info(Tab, attributes)) + 1,
    case New of
        _ when is_tuple(New), tuple_size(New) =:= Arity, element(1, New) =:= Name -> ok;
        _ -> {error, {bad_record, Name, Arity}}
    end.

transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic, _} -> ok;
        {aborted, Reason} -> {error, {aborted, Reason}}
    end.

%% Runs Fun(Tab, KeyPos) on the table with the given id, after checking
%% that the agent may Access (read | write) it.
with_table(ets, IdBin, Access, Fun) ->
    case find_ets(IdBin) of
        undefined ->
            {error, not_found};
        Tab ->
            Owner = ets:info(Tab, owner),
            case {ets:info(Tab, protection), Access} of
                {private, _} -> {error, private};
                {protected, write} when Owner =/= self() -> {error, protected};
                _ -> guarded(fun() -> Fun(Tab, ets:info(Tab, keypos)) end)
            end
    end;
with_table(mnesia, IdBin, _Access, Fun) ->
    case mnesia_running() of
        false ->
            {error, not_running};
        true ->
            case [T || T <- mnesia:system_info(tables), atom_to_binary(T, utf8) =:= IdBin] of
                [Tab] -> guarded(fun() -> Fun(Tab, 2) end);
                _ -> {error, not_found}
            end
    end.

guarded(Fun) ->
    try Fun()
    catch
        error:badarg -> {error, badarg};
        _:Reason -> {error, fmt(Reason)}
    end.

row_cells(Obj) when is_tuple(Obj) ->
    [cell(E) || E <- tuple_to_list(Obj)];
row_cells(Obj) ->
    [cell(Obj)].

cell(Term) ->
    fmt_chars(Term, ?TERM_DEPTH, ?CELL_CHARS).

to_port(Bin) when is_binary(Bin) ->
    Port = list_to_port(binary_to_list(Bin)),
    case node(Port) =:= node() of
        true -> Port;
        false -> erlang:error(badarg)
    end.

safe_to_port(Bin) when is_binary(Bin) ->
    try {ok, to_port(Bin)}
    catch error:badarg -> error
    end;
safe_to_port(_) ->
    error.

to_pid(Bin) when is_binary(Bin) ->
    Pid = list_to_pid(binary_to_list(Bin)),
    case node(Pid) =:= node() of
        true -> Pid;
        false -> erlang:error(badarg)
    end.

safe_to_pid(Bin) when is_binary(Bin) ->
    try {ok, to_pid(Bin)}
    catch error:badarg -> error
    end;
safe_to_pid(_) ->
    error.

format_frame({M, F, A, Loc}) ->
    Arity = if is_list(A) -> length(A); true -> A end,
    File = proplists:get_value(file, Loc),
    Line = proplists:get_value(line, Loc),
    #{mfa => bin(mfa({M, F, Arity})),
      location => case File of
                      undefined -> null;
                      _ -> bin(io_lib:format("~ts:~p", [File, Line]))
                  end}.

monitor_bin({process, P}) -> ref_bin(P);
monitor_bin({port, P}) -> ref_bin(P);
monitor_bin({_Type, {Name, Node}}) -> bin(io_lib:format("~p", [{Name, Node}]));
monitor_bin(Other) -> fmt(Other).

ref_bin(P) when is_pid(P) -> list_to_binary(pid_to_list(P));
ref_bin(P) when is_port(P) -> list_to_binary(erlang:port_to_list(P));
ref_bin(null) -> null;
ref_bin(undefined) -> null;
ref_bin(Other) -> fmt(Other).

mfa({M, F, A}) -> atom_to_list(M) ++ ":" ++ atom_to_list(F) ++ "/" ++ integer_to_list(A);
mfa(Other) -> unicode:characters_to_list(fmt_chars(Other, 10, 200)).

fmt(Term) ->
    fmt_chars(Term, ?TERM_DEPTH, ?TERM_CHARS).

%% Formats Term with bounded depth and character limit (OTP 21+ chars_limit)
%% so huge binaries or wide structures never OOM the observed node.
fmt_chars(Term, Depth, Max) ->
    Io = io_lib:format("~tP", [Term, Depth], [{chars_limit, Max + 32}]),
    Bin = unicode:characters_to_binary(Io),
    case string:length(Bin) > Max of
        true -> <<(string:slice(Bin, 0, Max))/binary, " ...">>;
        false -> Bin
    end.

bin(Chars) -> unicode:characters_to_binary(Chars).

%%--------------------------------------------------------------------
%% Message trace
%%
%% Shows what a few chosen processes send and receive, classified as
%% business, system or network messages. Built so that it cannot take the
%% node down:
%%   - only the cheap send/'receive' flags, on at most TRACE_MAX_PROCS
%%     processes chosen by the user;
%%   - trace messages go to a worker with a heap limit; if a flood of (big)
%%     messages makes it exceed that, the VM kills it, and a dead tracer's
%%     trace flags are dropped by the VM;
%%   - caps on rate, count, duration and the worker's backlog stop the
%%     trace (flags removed, pending trace messages discarded unread);
%%   - formatted events go to a bounded ETS ring the tool pulls from, so
%%     nothing accumulates when the tool or the network is slow;
%%   - the keeper process stops everything when the tool node goes away and
%%     exits after a while without being read;
%%   - gen calls are timed in the worker into a fixed-size table (at most
%%     TRACE_KINDS request kinds, a histogram instead of every latency, the
%%     TRACE_SLOWEST slowest samples) with at most TRACE_PENDING calls
%%     waiting for a reply.
%%--------------------------------------------------------------------

-define(TRACER, eobs_agent_tracer).
-define(TRACE_MAX_PROCS, 10).
-define(TRACE_BUFFER, 5000).
-define(TRACE_BACKLOG, 1000).
-define(TRACE_HEAP_WORDS, 1000000).
-define(TRACE_IDLE_MS, 600000).
-define(TRACE_TEXT_CHARS, 4000).
-define(TRACE_SUMMARY_CHARS, 240).
-define(TRACE_PAGE, 1000).
-define(TRACE_FLAGS, [send, 'receive', monotonic_timestamp]).
%% Call statistics: distinct (process, direction, request kind) rows, the
%% rest is merged into one "other" row per process and direction; calls
%% waiting for a reply, and how long before one counts as unanswered;
%% slowest samples kept per row; histogram buckets per doubling of the
%% latency (about 9% wide) and their number (up to 2^30 us, 18 minutes).
-define(TRACE_KINDS, 200).
-define(TRACE_PENDING, 1000).
-define(TRACE_CALL_EXPIRE_MS, 60000).
-define(TRACE_SLOWEST, 10).
-define(TRACE_HIST_STEPS, 8).
-define(TRACE_HIST_SIZE, 241).
%% Positions in a statistics row: {Key, RowNo, Calls, Answered, SumUs,
%% MaxUs, Pending, Unanswered, Bucket0, Bucket1, ...}.
-define(S_ROW, 2).
-define(S_CALLS, 3).
-define(S_ANSWERED, 4).
-define(S_SUM, 5).
-define(S_MAX, 6).
-define(S_PENDING, 7).
-define(S_UNANSWERED, 8).
-define(S_HIST, 9).

%% Targets: pids or registered names (binaries). Opts: max_events,
%% max_seconds, max_rate (per second). Replaces a running trace.
trace_start(Owner, Targets, Opts) ->
    ok = quit_tracer(),
    Limits = #{max_events => clamp(maps:get(max_events, Opts, 10000), 1, 100000),
               max_seconds => clamp(maps:get(max_seconds, Opts, 60), 1, 600),
               max_rate => clamp(maps:get(max_rate, Opts, 2000), 1, 5000)},
    Resolved = [{T, resolve_target(T)} || T <- lists:sublist(Targets, ?TRACE_MAX_PROCS)],
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> keeper_init(Parent, Owner, Resolved, Limits) end),
    receive
        {Pid, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, process, Pid, Reason} -> {error, {tracer_failed, fmt(Reason)}}
    after 10000 ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        {error, timeout}
    end.

trace_stop() ->
    case whereis(?TRACER) of
        undefined -> ok;
        Pid -> tracer_call(Pid, stop)
    end.

%% Events after sequence number Since of trace Id (null: whichever trace
%% is current), at most TRACE_PAGE of them, plus the trace's state.
trace_events(Id, Since) ->
    case whereis(?TRACER) of
        undefined -> {error, not_running};
        Pid -> tracer_call(Pid, {events, Id, Since})
    end.

%% Call statistics of trace Id (null: whichever trace is current). Which:
%% rows (the table only), all (with each row's histogram and slowest
%% calls) or a row number (that row with its details).
trace_stats(Id, Which) ->
    case whereis(?TRACER) of
        undefined -> {error, not_running};
        Pid -> tracer_call(Pid, {stats, Id, Which})
    end.

%% Stops the current keeper (if any) and waits until it is gone.
quit_tracer() ->
    case whereis(?TRACER) of
        undefined -> ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! quit,
            receive {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> exit(Pid, kill), receive {'DOWN', Ref, process, Pid, _} -> ok end
            end
    end.

tracer_call(Pid, Request) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {self(), Ref, Request},
    receive
        {Ref, Reply} -> erlang:demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, process, Pid, _} -> {error, not_running}
    after 10000 ->
        erlang:demonitor(Ref, [flush]),
        {error, timeout}
    end.

clamp(N, Min, Max) when is_integer(N) -> max(Min, min(N, Max));
clamp(_, _, Max) -> Max.

resolve_target(Bin) ->
    try
        case Bin of
            <<"<", _/binary>> -> {ok, to_pid(Bin)};
            _ ->
                case whereis(binary_to_existing_atom(Bin, utf8)) of
                    undefined -> {error, not_found};
                    P -> {ok, P}
                end
        end
    catch error:badarg -> {error, not_found}
    end.

%% The keeper owns the event table and the trace's state, and answers the
%% tool. It never receives trace messages itself.
keeper_init(Parent, Owner, Resolved, Limits) ->
    try register(?TRACER, self())
    catch error:badarg -> Parent ! {self(), {error, busy}}, exit(normal)
    end,
    process_flag(trap_exit, true),
    case monitor_owner(Owner) of
        true -> ok;
        false -> Parent ! {self(), {error, owner_down}}, exit(normal)
    end,
    Tab = ets:new(eobs_trace, [ordered_set, public]),
    ets:insert(Tab, {seq, 0}),
    Stats = ets:new(eobs_trace_stats, [set, public]),
    Keeper = self(),
    {Worker, WRef} = spawn_opt(fun() -> worker_init(Keeper, Tab, Stats, Limits) end,
                               [monitor, {priority, low},
                                {max_heap_size, #{size => ?TRACE_HEAP_WORDS, kill => true,
                                                  error_logger => false}}]),
    try link(Worker) catch error:noproc -> ok end,
    Results = [{T, start_one(R, Worker)} || {T, R} <- Resolved],
    Traced = [P || {_, {ok, P}} <- Results],
    Id = erlang:unique_integer([positive]),
    St0 = #{id => Id, owner => Owner, tab => Tab, stats => Stats, worker => Worker, wref => WRef,
            traced => Traced, limits => Limits, status => running, reason => null,
            started => erlang:system_time(millisecond),
            last_read => erlang:monotonic_time(millisecond)},
    St = case Traced of
             [] -> keeper_stop(no_process, St0);
             _ -> Worker ! {go, Traced}, St0
         end,
    Parent ! {self(), {ok, #{id => Id,
                             processes => [trace_proc(P) || P <- Traced],
                             refused => [#{target => T, reason => R}
                                         || {T, {error, R}} <- Results],
                             limits => Limits}}},
    keeper_loop(St).

start_one({error, R}, _Tracer) ->
    {error, R};
start_one({ok, Pid}, Tracer) ->
    case lists:member(Pid, [self(), whereis(?HOLDER)]) orelse node(Pid) =/= node() of
        true -> {error, not_allowed};
        false ->
            case erlang:trace_info(Pid, tracer) of
                {tracer, []} ->
                    try erlang:trace(Pid, true, [{tracer, Tracer} | ?TRACE_FLAGS]) of
                        1 -> {ok, Pid};
                        _ -> {error, not_found}
                    catch error:badarg -> {error, not_found}
                    end;
                {tracer, _} -> {error, already_traced};
                undefined -> {error, not_found}
            end
    end.

trace_proc(Pid) ->
    #{pid => ref_bin(Pid), name => registered_name(Pid)}.

keeper_loop(#{last_read := LastRead} = St) ->
    Idle = max(0, LastRead + ?TRACE_IDLE_MS - erlang:monotonic_time(millisecond)),
    receive
        {From, Ref, stop} ->
            St1 = keeper_stop(stopped_by_user, St),
            From ! {Ref, ok},
            keeper_loop(St1);
        {From, Ref, {events, Id, Since}} ->
            St1 = St#{last_read := erlang:monotonic_time(millisecond)},
            case Id =:= null orelse Id =:= maps:get(id, St1) of
                true -> From ! {Ref, {ok, events_since(Since, St1)}};
                false -> From ! {Ref, {error, not_found}}
            end,
            keeper_loop(St1);
        {From, Ref, {stats, Id, Which}} ->
            St1 = St#{last_read := erlang:monotonic_time(millisecond)},
            case Id =:= null orelse Id =:= maps:get(id, St1) of
                true -> From ! {Ref, {ok, stats_read(Which, St1)}};
                false -> From ! {Ref, {error, not_found}}
            end,
            keeper_loop(St1);
        {stopped, Worker, Reason} when Worker =:= map_get(worker, St) ->
            keeper_loop(keeper_stop(Reason, St));
        {'DOWN', WRef, process, _, Reason} when WRef =:= map_get(wref, St) ->
            %% killed: heap limit reached (a flood of large messages)
            Why = case Reason of
                      killed -> overload;
                      normal -> stopped;
                      _ -> crashed
                  end,
            keeper_loop(keeper_stop(Why, St#{worker := undefined}));
        quit ->
            _ = keeper_stop(stopped, St),
            exit(normal);
        {nodedown, Owner} when Owner =:= map_get(owner, St) ->
            _ = keeper_stop(owner_down, St),
            exit(normal);
        _ ->
            keeper_loop(St)
    after Idle ->
        _ = keeper_stop(idle, St),
        exit(normal)
    end.

%% Removes our trace flags and discards whatever the worker has not
%% processed yet (killing it frees its mailbox at once).
keeper_stop(_Reason, #{status := stopped} = St) ->
    St;
keeper_stop(Reason, #{traced := Traced, worker := Worker} = St) ->
    [untrace(P, Worker) || P <- Traced],
    case Worker of
        undefined -> ok;
        _ -> erlang:demonitor(maps:get(wref, St), [flush]), exit(Worker, kill)
    end,
    St#{status := stopped, reason := Reason, worker := undefined}.

%% Only touches flags that are still ours: another tool may have started
%% tracing the process after ours stopped.
untrace(Pid, Worker) ->
    case catch erlang:trace_info(Pid, tracer) of
        {tracer, T} when T =:= Worker; T =:= [] ->
            catch erlang:trace(Pid, false, ?TRACE_FLAGS);
        {tracer, T} when is_pid(T) ->
            case is_process_alive(T) of
                false -> catch erlang:trace(Pid, false, ?TRACE_FLAGS);
                true -> ok
            end;
        _ -> ok
    end.

events_since(Since0, #{id := Id, tab := Tab, status := Status, reason := Reason,
                       traced := Traced, started := Started, limits := Limits}) ->
    Since = case Since0 of
                N when is_integer(N), N >= 0 -> N;
                _ -> 0
            end,
    [{seq, Seq}] = ets:lookup(Tab, seq),
    Events = case ets:select(Tab, [{{'$1', '$2'}, [{is_integer, '$1'}, {'>', '$1', Since}], ['$2']}],
                             ?TRACE_PAGE) of
                 {Es, _} -> Es;
                 '$end_of_table' -> []
             end,
    #{id => Id, status => Status, reason => Reason, count => Seq,
      dropped => max(0, Seq - ?TRACE_BUFFER), next => next_seq(Events, Since), started => Started,
      limits => Limits, processes => [trace_proc(P) || P <- Traced],
      events => Events}.

%% The worker receives the trace messages, enforces the limits and writes
%% formatted events into the keeper's table.
worker_init(Keeper, Tab, Stats, Limits) ->
    KRef = erlang:monitor(process, Keeper),
    receive
        {go, _Traced} -> ok;
        {'DOWN', KRef, process, Keeper, _} -> exit(normal)
    end,
    Now = erlang:monotonic_time(millisecond),
    worker_loop(#{keeper => Keeper, kref => KRef, tab => Tab, limits => Limits, count => 0,
                  deadline => Now + maps:get(max_seconds, Limits) * 1000,
                  window => {Now div 1000, 0}, names => #{},
                  offset => erlang:time_offset(),
                  stats => Stats, rows => #{}, pending => #{}, swept => Now}).

worker_loop(#{deadline := Deadline, kref := KRef} = St) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', KRef, process, _, _} -> exit(normal);
        {trace_ts, Pid, 'receive', Msg, Ts} -> worker_loop(trace_event(Pid, in, Msg, undefined, Ts, St));
        {trace_ts, Pid, send, Msg, To, Ts} -> worker_loop(trace_event(Pid, out, Msg, To, Ts, St));
        {trace_ts, Pid, send_to_non_existing_process, Msg, To, Ts} ->
            worker_loop(trace_event(Pid, out_dead, Msg, To, Ts, St));
        _ -> worker_loop(St)
    after Timeout ->
        worker_done(max_seconds, St)
    end.

worker_done(Reason, #{keeper := Keeper}) ->
    Keeper ! {stopped, self(), Reason},
    %% Exit right away so the VM drops our trace flags atomically even if
    %% the keeper dies before handling {stopped, ...}.
    exit(normal).

trace_event(Pid, Dir, Msg, To, Ts, #{count := Count, limits := Limits, window := {Sec, N}} = St) ->
    NowSec = erlang:monotonic_time(second),
    Window = case NowSec of
                 Sec -> {Sec, N + 1};
                 _ -> {NowSec, 1}
             end,
    Backlog = case Count rem 20 of
                  0 -> element(2, process_info(self(), message_queue_len));
                  _ -> 0
              end,
    #{max_rate := MaxRate, max_events := MaxEvents} = Limits,
    case element(2, Window) > MaxRate of
        true -> worker_done(max_rate, St);
        false when Backlog > ?TRACE_BACKLOG -> worker_done(backlog, St);
        false ->
            {Event, St1} = make_event(Pid, Dir, Msg, To, Ts, St),
            store_event(Event, St1),
            St2 = call_stats(Pid, Dir, Msg, Ts, Event, St1#{count := Count + 1, window := Window}),
            case Count + 1 >= MaxEvents of
                true -> worker_done(max_events, St2);
                false -> St2
            end
    end.

store_event(Event, #{tab := Tab}) ->
    Seq = ets:update_counter(Tab, seq, 1),
    ets:insert(Tab, {Seq, Event#{seq => Seq}}),
    case Seq > ?TRACE_BUFFER of
        true -> ets:delete(Tab, Seq - ?TRACE_BUFFER);
        false -> ok
    end.

make_event(Pid, Dir, Msg, To, Ts, #{offset := Offset} = St) ->
    {Cat, Kind, Peer0, Shown, Ref} = classify(Msg),
    %% Replies to gen calls go to an alias (a reference) on OTP 24+; the
    %% caller is known from the paired call instead.
    Peer = case To of
               undefined -> Peer0;
               Alias when is_reference(Alias) -> undefined;
               _ -> To
           end,
    {PeerName, St1} = peer_name(Peer, St),
    Text = limited(Shown, ?TRACE_TEXT_CHARS),
    Event = #{t => erlang:convert_time_unit(Ts + Offset, native, microsecond),
              pid => ref_bin(Pid),
              dir => case Dir of out_dead -> out; _ -> Dir end,
              dead => Dir =:= out_dead,
              cat => Cat,
              kind => Kind,
              peer => peer_bin(Peer),
              peer_name => PeerName,
              ref => case Ref of undefined -> null; _ -> ref_bin_any(Ref) end,
              summary => one_line(Text, ?TRACE_SUMMARY_CHARS),
              text => Text},
    {Event, St1}.

%% Times gen calls of the traced processes: a call (received: the process
%% serves it; sent: the process waits for it) waits in `pending` until the
%% same process sends or receives the reply with its reference. Counts go
%% straight into the statistics table, so they stay exact when the event
%% ring drops events and survive the worker being killed at stop.
call_stats(Pid, Dir, Msg, Ts, Event, St) ->
    St1 = expire_calls(St),
    case call_part(Msg) of
        {call, Ref, Req} ->
            {Key, St2} = stats_row(Pid, Dir, req_kind(Req), St1),
            Tab = maps:get(stats, St2),
            ets:update_counter(Tab, Key, [{?S_CALLS, 1}, {?S_PENDING, 1}]),
            #{pending := Pending} = St3 = make_room(St2),
            case maps:find({Pid, Ref}, Pending) of
                {ok, {PrevKey, _, _, _, _, _}} ->
                    ets:update_counter(Tab, PrevKey, [{?S_PENDING, -1}, {?S_UNANSWERED, 1}]);
                error ->
                    ok
            end,
            Peer = case Event of
                       #{peer_name := Name} when Name =/= null -> Name;
                       #{peer := P} -> P
                   end,
            Call = {Key, Ts, maps:get(t, Event), Peer, maps:get(summary, Event),
                    erlang:monotonic_time(millisecond)},
            St3#{pending := Pending#{{Pid, Ref} => Call}};
        {reply, Ref} ->
            #{pending := Pending, stats := Tab} = St1,
            case maps:take({Pid, Ref}, Pending) of
                {{Key, CallTs, T, Peer, Summary, _}, Pending1} ->
                    Us = max(0, erlang:convert_time_unit(Ts - CallTs, native, microsecond)),
                    case ets:lookup_element(Tab, Key, ?S_MAX) < Us of
                        true -> ets:update_element(Tab, Key, {?S_MAX, Us});
                        false -> ok
                    end,
                    ets:update_counter(Tab, Key, [{?S_ANSWERED, 1}, {?S_SUM, Us}, {?S_PENDING, -1},
                                                  {?S_HIST + hist_bucket(Us), 1}]),
                    slowest(Tab, Key, {Us, T, Peer, Summary}),
                    St1#{pending := Pending1};
                error ->
                    St1
            end;
        none ->
            St1
    end.

call_part({'$gen_call', {_, Tag}, Req}) ->
    case call_ref(Tag) of
        undefined -> none;
        Ref -> {call, Ref, Req}
    end;
call_part({Ref, _}) when is_reference(Ref) -> {reply, Ref};
call_part({[alias | Ref], _}) when is_reference(Ref) -> {reply, Ref};
call_part({[[alias | Ref] | _], _}) when is_reference(Ref) -> {reply, Ref};
call_part(_) -> none.

%% get_info -> get_info, {buy, 1, 2} -> buy, anything else -> {other}.
req_kind(Req) when is_atom(Req) -> Req;
req_kind(Req) when is_tuple(Req), tuple_size(Req) > 0, is_atom(element(1, Req)) -> element(1, Req);
req_kind(_) -> {other}.

%% The row of a (process, direction, kind); past TRACE_KINDS rows new kinds
%% go to that process and direction's {overflow} row.
stats_row(Pid, Dir0, Kind, #{rows := Rows, stats := Tab} = St) ->
    Dir = case Dir0 of out_dead -> out; _ -> Dir0 end,
    Key0 = {Pid, Dir, Kind},
    case Rows of
        #{Key0 := _} ->
            {Key0, St};
        _ ->
            Key = case map_size(Rows) >= ?TRACE_KINDS of
                      true -> {Pid, Dir, {overflow}};
                      false -> Key0
                  end,
            case ets:member(Tab, Key) of
                true -> ok;
                false ->
                    Row = ets:update_counter(Tab, rows, 1, {rows, 0}),
                    ets:insert(Tab, list_to_tuple([Key, Row, 0, 0, 0, 0, 0, 0
                                                   | lists:duplicate(?TRACE_HIST_SIZE, 0)]))
            end,
            case Key of
                Key0 -> {Key, St#{rows := Rows#{Key => true}}};
                _ -> {Key, St}
            end
    end.

hist_bucket(Us) when Us < 2 -> 0;
hist_bucket(Us) -> min(?TRACE_HIST_SIZE - 1, trunc(math:log2(Us) * ?TRACE_HIST_STEPS)).

hist_low(0) -> 0;
hist_low(I) -> round(math:pow(2, I / ?TRACE_HIST_STEPS)).

hist_high(I) -> round(math:pow(2, (I + 1) / ?TRACE_HIST_STEPS)).

slowest(Tab, Key, {Us, _, _, _} = Sample) ->
    SKey = {slowest, Key},
    case ets:lookup(Tab, SKey) of
        [] ->
            ets:insert(Tab, {SKey, [Sample]});
        [{_, List}] when length(List) < ?TRACE_SLOWEST ->
            ets:insert(Tab, {SKey, lists:reverse(lists:sort([Sample | List]))});
        [{_, List}] ->
            case Us > element(1, lists:last(List)) of
                true ->
                    New = lists:sublist(lists:reverse(lists:sort([Sample | List])), ?TRACE_SLOWEST),
                    ets:insert(Tab, {SKey, New});
                false ->
                    ok
            end
    end.

%% Calls waiting longer than TRACE_CALL_EXPIRE_MS count as unanswered;
%% checked at most once a second.
expire_calls(#{swept := Swept} = St) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Swept >= 1000 of
        true ->
            #{pending := Pending} = St,
            Old = [K || {K, {_, _, _, _, _, At}} <- maps:to_list(Pending),
                        At < Now - ?TRACE_CALL_EXPIRE_MS],
            unanswered(Old, St#{swept := Now});
        false ->
            St
    end.

%% At TRACE_PENDING waiting calls the older half counts as unanswered.
make_room(#{pending := Pending} = St) when map_size(Pending) >= ?TRACE_PENDING ->
    ByAge = lists:keysort(2, [{K, At} || {K, {_, _, _, _, _, At}} <- maps:to_list(Pending)]),
    unanswered([K || {K, _} <- lists:sublist(ByAge, ?TRACE_PENDING div 2)], St);
make_room(St) ->
    St.

unanswered(Keys, #{stats := Tab} = St) ->
    lists:foldl(
      fun(K, #{pending := P} = Acc) ->
              {{Key, _, _, _, _, _}, P1} = maps:take(K, P),
              ets:update_counter(Tab, Key, [{?S_PENDING, -1}, {?S_UNANSWERED, 1}]),
              Acc#{pending := P1}
      end, St, Keys).

%% The statistics as plain maps, read by the keeper. Once the trace has
%% stopped, calls still waiting for a reply count as unanswered.
stats_read(Which, #{id := Id, stats := Tab, status := Status}) ->
    Rows = [R || R <- ets:tab2list(Tab), tuple_size(R) > 3],
    Stopped = Status =:= stopped,
    Maps = [stats_map(R, Tab, Stopped, Which) || R <- Rows,
                                                 Which =:= rows orelse Which =:= all
                                                     orelse element(?S_ROW, R) =:= Which],
    #{id => Id, status => Status, max_kinds => ?TRACE_KINDS,
      kinds => length([R || R <- Rows, element(3, element(1, R)) =/= {overflow}]),
      rows => lists:sort(fun(#{row := A}, #{row := B}) -> A =< B end, Maps)}.

stats_map(R, Tab, Stopped, Which) ->
    {Pid, Dir, Kind} = Key = element(1, R),
    Answered = element(?S_ANSWERED, R),
    Pending = element(?S_PENDING, R),
    Max = element(?S_MAX, R),
    Hist = [{I, element(?S_HIST + I, R)} || I <- lists:seq(0, ?TRACE_HIST_SIZE - 1),
                                            element(?S_HIST + I, R) > 0],
    {KindBin, Group} = case Kind of
                           {other} -> {null, other};
                           {overflow} -> {null, overflow};
                           _ -> {atom_to_binary(Kind, utf8), named}
                       end,
    Base = #{row => element(?S_ROW, R), pid => ref_bin(Pid), dir => Dir,
             kind => KindBin, group => Group,
             calls => element(?S_CALLS, R), answered => Answered,
             pending => case Stopped of true -> 0; false -> Pending end,
             unanswered => element(?S_UNANSWERED, R) + case Stopped of true -> Pending; false -> 0 end,
             avg => case Answered of 0 -> null; _ -> element(?S_SUM, R) div Answered end,
             p95 => percentile(Hist, Answered, 0.95, Max),
             max => case Answered of 0 -> null; _ -> Max end},
    case Which of
        rows -> Base;
        _ ->
            Slowest = case ets:lookup(Tab, {slowest, Key}) of
                          [{_, L}] -> L;
                          [] -> []
                      end,
            %% maps, not lists: the JSON encoder would print [72, 79, 8] as text
            Base#{hist => [#{low => hist_low(I), high => max(hist_low(I), min(Max, hist_high(I))), count => N}
                           || {I, N} <- Hist],
                  slowest => [#{latency => Us, t => T, peer => Peer, summary => S}
                              || {Us, T, Peer, S} <- Slowest]}
    end.

%% Upper bound of the bucket holding the percentile (never above the max).
percentile(_Hist, 0, _P, _Max) ->
    null;
percentile(Hist, Total, P, Max) ->
    percentile_walk(Hist, max(1, ceil(Total * P)), Max).

percentile_walk([{I, N} | Rest], Target, Max) ->
    case N >= Target of
        true -> min(Max, hist_high(I));
        false -> percentile_walk(Rest, Target - N, Max)
    end;
percentile_walk([], _Target, Max) ->
    Max.

%% {Category, Kind, Peer, ShownTerm, CallRef} from the message's shape.
classify({'$gen_call', {From, Tag}, Req}) ->
    {business, call, From, Req, call_ref(Tag)};
classify({'$gen_cast', Msg}) ->
    {business, cast, undefined, Msg, undefined};
classify({system, {From, _}, Req}) when is_pid(From) ->
    {system, sys, From, Req, undefined};
classify({'EXIT', From, _} = M) ->
    {system, exit, From, M, undefined};
classify({'DOWN', _, _, Obj, _} = M) ->
    {system, down, Obj, M, undefined};
classify({io_request, From, _, _} = M) ->
    {system, io, From, M, undefined};
classify({io_reply, _, _} = M) ->
    {system, io, undefined, M, undefined};
classify({timeout, Ref, _} = M) when is_reference(Ref) ->
    {system, timer, undefined, M, undefined};
classify({ack, From, _} = M) when is_pid(From) ->
    {system, proc_lib, From, M, undefined};
classify({Node, _} = M) when Node =:= nodeup; Node =:= nodedown ->
    {system, node, undefined, M, undefined};
classify({Node, _, _} = M) when Node =:= nodeup; Node =:= nodedown ->
    {system, node, undefined, M, undefined};
classify({'ETS-TRANSFER', _, From, _} = M) ->
    {system, ets_transfer, From, M, undefined};
classify({code_server, _} = M) ->
    {system, code, undefined, M, undefined};
classify({code_call, From, _} = M) ->
    {system, code, From, M, undefined};
classify(M) when is_tuple(M), tuple_size(M) >= 2 ->
    case element(1, M) of
        Tag when Tag =:= tcp; Tag =:= tcp_closed; Tag =:= tcp_error; Tag =:= tcp_passive;
                 Tag =:= udp; Tag =:= udp_closed; Tag =:= udp_error; Tag =:= udp_passive;
                 Tag =:= ssl; Tag =:= ssl_closed; Tag =:= ssl_error; Tag =:= ssl_passive;
                 Tag =:= sctp; Tag =:= http; Tag =:= inet_reply; Tag =:= inet_async;
                 Tag =:= '$socket' ->
            {network, Tag, element(2, M), M, undefined};
        Port when is_port(Port), tuple_size(M) =:= 2 ->
            %% {Port, {data, D}}, {Port, eof}, {Port, {exit_status, N}}
            {network, port, Port, M, undefined};
        Ref when is_reference(Ref), tuple_size(M) =:= 2 ->
            {business, reply, undefined, element(2, M), Ref};
        [alias | Ref] when is_reference(Ref), tuple_size(M) =:= 2 ->
            {business, reply, undefined, element(2, M), Ref};
        Pid when is_pid(Pid), tuple_size(M) =:= 2 ->
            %% {Pid, {command, Data}} and friends, sent to a port
            case element(2, M) of
                {command, _} -> {network, port, undefined, M, undefined};
                {connect, _} -> {network, port, undefined, M, undefined};
                close -> {network, port, undefined, M, undefined};
                _ -> {business, info, undefined, M, undefined}
            end;
        _ ->
            {business, info, undefined, M, undefined}
    end;
classify(M) ->
    {business, info, undefined, M, undefined}.

%% The gen tag is a reference, or [alias | Ref] on OTP 24+, possibly
%% wrapped once more by gen_statem/gen_server multicalls.
call_ref(Ref) when is_reference(Ref) -> Ref;
call_ref([alias | Ref]) when is_reference(Ref) -> Ref;
call_ref([[alias | Ref] | _]) when is_reference(Ref) -> Ref;
call_ref(_) -> undefined.

ref_bin_any(Ref) -> bin(erlang:ref_to_list(Ref)).

peer_bin(undefined) -> null;
peer_bin(P) when is_pid(P); is_port(P) -> ref_bin(P);
peer_bin(P) -> fmt(P).

%% Registered name or initial call of a local peer, cached (the cache is
%% reset when it grows, so it stays small). Checks registered_name first
%% and skips copying large process dictionaries so one peer with a big
%% dictionary cannot trip the tracer's heap cap.
peer_name(Pid, #{names := Names} = St) when is_pid(Pid), node(Pid) =:= node() ->
    case Names of
        #{Pid := Name} -> {Name, St};
        _ ->
            Name = case erlang:process_info(Pid, registered_name) of
                       {registered_name, N} when is_atom(N), N =/= [] ->
                           atom_to_binary(N, utf8);
                       {registered_name, []} ->
                           peer_initial_call(Pid);
                       _ ->
                           null
                   end,
            Names1 = case map_size(Names) >= 2000 of
                         true -> #{};
                         false -> Names
                     end,
            {Name, St#{names := Names1#{Pid => Name}}}
    end;
peer_name(Name, St) when is_atom(Name), Name =/= undefined ->
    {atom_to_binary(Name, utf8), St};
peer_name({Name, Node}, St) when is_atom(Name), is_atom(Node) ->
    {bin(io_lib:format("~ts@~ts", [Name, Node])), St};
peer_name(_, St) ->
    {null, St}.

peer_initial_call(Pid) ->
    case erlang:process_info(Pid, [initial_call, memory]) of
        [{initial_call, IC}, {memory, Mem}] when Mem < 262144 ->
            case erlang:process_info(Pid, dictionary) of
                {dictionary, D} ->
                    case proplists:get_value('$initial_call', D) of
                        undefined -> bin(mfa(IC));
                        Real -> bin(mfa(Real))
                    end;
                _ ->
                    bin(mfa(IC))
            end;
        [{initial_call, IC}, _] ->
            bin(mfa(IC));
        _ ->
            null
    end.

limited(Term, Max) ->
    fmt_chars(Term, ?TERM_DEPTH, Max).

%% Single-pass whitespace collapse capped at Max Unicode codepoints,
%% avoiding per-event regex compilation in the tracer worker.
one_line(Bin, Max) when is_binary(Bin) ->
    collapse_ws(Bin, Max, false, []);
one_line(Other, Max) ->
    one_line(bin(Other), Max).

collapse_ws(<<>>, _Left, _InWs, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
collapse_ws(_, 0, _InWs, Acc) ->
    iolist_to_binary(lists:reverse([<<"...">> | Acc]));
collapse_ws(<<C/utf8, Rest/binary>>, Left, InWs, Acc) ->
    case is_ws(C) of
        true when InWs ->
            collapse_ws(Rest, Left, true, Acc);
        true ->
            collapse_ws(Rest, Left - 1, true, [$\s | Acc]);
        false ->
            collapse_ws(Rest, Left - 1, false, [<<C/utf8>> | Acc])
    end;
collapse_ws(<<_, Rest/binary>>, Left, _InWs, Acc) ->
    collapse_ws(Rest, Left - 1, false, [$? | Acc]).

is_ws($\s) -> true;
is_ws($\t) -> true;
is_ws($\n) -> true;
is_ws($\r) -> true;
is_ws($\f) -> true;
is_ws($\v) -> true;
is_ws(_) -> false.

%%--------------------------------------------------------------------
%% Logs and crashes
%%
%% Nothing is installed when the tool connects. The first logs_events/2
%% call (the tool's Logs page) starts a keeper that adds a logger handler;
%% both the live log and the crash records come from it. Built so that it
%% cannot take the node down:
%%   - the handler (log/2) runs inside every process that logs, so it only
%%     compares the level with a limit and does one non-blocking send of
%%     the raw event to a collector; no formatting, no calls;
%%   - at most LOG_BACKLOG events may be on their way to the collector (an
%%     atomics counter the handler bumps before sending); beyond that the
%%     handler drops and counts;
%%   - above LOG_RATE events a second only warning and worse are kept for
%%     the rest of that second, above LOG_HARD_RATE nothing; the collector
%%     sets the limit the handler compares with;
%%   - the collector has a heap limit and formats with depth and length
%%     caps into fixed-size ETS rings the tool pulls from;
%%   - the keeper removes the handler and stops when the tool node goes
%%     away or after LOG_IDLE_MS without being read; logger itself removes
%%     a handler that crashes.
%%
%% lager does not log through logger: lager:log and the lager parse
%% transform send to lager's own gen_event managers (sinks). When lager
%% runs, the keeper also adds the agent to every sink as a gen_event
%% handler that does the same as log/2 (one counted send, nothing else).
%% It answers lager's get_loglevel with an empty mask, so lager's levels
%% stay as they are: we see what lager already produces, and lager:debug
%% calls that lager filters out stay as cheap as before. Every call to a
%% sink is made from a helper with a timeout, since a sink may be busy.
%% When lager redirects error_logger into itself, the logger events that
%% error_logger takes (those with error_logger metadata: error_logger
%% calls, OTP's own reports, crashes) reach us twice; their lines then
%% come from lager only, and the logger events serve the crash records.
%% Other logger calls are not passed on to lager, so they still show.
%%--------------------------------------------------------------------

%% Registered name of the keeper, and the handler id.
-define(LOGS, eobs_agent_logs).
-define(LOG_RING, 2000).
-define(LOG_GROUPS, 500).
-define(LOG_BACKLOG, 1000).
-define(LOG_RATE, 2000).
-define(LOG_HARD_RATE, 5000).
-define(LOG_IDLE_MS, 60000).
-define(LOG_HEAP_WORDS, 2000000).
-define(LOG_TEXT_CHARS, 2000).
-define(LOG_REASON_CHARS, 4000).
-define(LOG_DEPTH, 20).
-define(LOG_STACK, 30).
-define(LOG_PAGE, 1000).
-define(LOG_TIMES, 10).
%% A collector killed by its heap limit is replaced after this long.
-define(LOG_RESTART_MS, 10000).
%% Longest wait for a lager event manager to add or remove our handler.
-define(LAGER_CALL_MS, 5000).
%% Our handler id in lager's event managers.
-define(LAGER_ID, {?MODULE, ?LOGS}).
%% Slots of the atomics array shared by the handler and the collector.
-define(A_INFLIGHT, 1).
-define(A_MAXSEV, 2).
-define(A_DROPPED, 3).
-define(A_LIMITED, 4).
-define(SEV_ALL, 7).
-define(SEV_WARNING, 4).
-define(SEV_NONE, -1).

%% New log lines, crash groups and restart counters since Cursor (null, or
%% the `cursor` of the previous reply). Starts collecting on first use;
%% Owner is the tool node, collection stops when it goes away.
logs_events(Owner, Cursor) ->
    case logs_keeper(Owner, 3) of
        {ok, Pid} -> tracer_call(Pid, {logs, Owner, Cursor});
        {error, _} = Error -> Error
    end.

%% Stops collecting and removes the handler. Called before the agent is
%% unloaded, since logger would otherwise call a module that is gone.
logs_stop() ->
    case whereis(?LOGS) of
        undefined ->
            ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! quit,
            receive {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> exit(Pid, kill), receive {'DOWN', Ref, process, Pid, _} -> ok end
            end
    end,
    remove_log_handler().

logs_keeper(_Owner, 0) ->
    {error, logs_failed};
logs_keeper(Owner, Tries) ->
    case whereis(?LOGS) of
        undefined ->
            Parent = self(),
            {Pid, Ref} = spawn_monitor(fun() -> logs_init(Parent, Owner) end),
            receive
                {Pid, ok} -> erlang:demonitor(Ref, [flush]), {ok, Pid};
                {Pid, busy} -> erlang:demonitor(Ref, [flush]), logs_keeper(Owner, Tries - 1);
                {'DOWN', Ref, process, Pid, Reason} -> {error, {logs_failed, fmt(Reason)}}
            after 10000 ->
                exit(Pid, kill),
                erlang:demonitor(Ref, [flush]),
                remove_log_handler(),
                {error, timeout}
            end;
        Pid ->
            {ok, Pid}
    end.

%% The logger handler. Runs in the process that logs: keep it tiny.
log(#{level := Level} = Event, #{config := #{ref := Ref, collector := Pid}}) ->
    MaxSev = atomics:get(Ref, ?A_MAXSEV),
    case severity(Level) =< MaxSev of
        true ->
            case atomics:add_get(Ref, ?A_INFLIGHT, 1) > ?LOG_BACKLOG of
                false ->
                    Pid ! {?LOGS, Event},
                    ok;
                true ->
                    atomics:sub(Ref, ?A_INFLIGHT, 1),
                    log_dropped(Ref, ?A_DROPPED, Pid)
            end;
        false when MaxSev =:= ?SEV_NONE ->
            log_dropped(Ref, ?A_DROPPED, Pid);
        false ->
            log_dropped(Ref, ?A_LIMITED, Pid)
    end;
log(_Event, _Config) ->
    ok.

%% The lager backend. Runs in the sink's event manager: keep it tiny too.
init({Ref, Collector}) ->
    {ok, #{ref => Ref, collector => Collector}}.

handle_event({log, Msg}, #{ref := Ref, collector := Pid} = St)
  when tuple_size(Msg) =:= 7, element(1, Msg) =:= lager_msg ->
    MaxSev = atomics:get(Ref, ?A_MAXSEV),
    Kept = case severity(element(4, Msg)) =< MaxSev of
               true ->
                   case atomics:add_get(Ref, ?A_INFLIGHT, 1) > ?LOG_BACKLOG of
                       false ->
                           Pid ! {?LOGS, {lager, Msg}},
                           ok;
                       true ->
                           atomics:sub(Ref, ?A_INFLIGHT, 1),
                           lager_dropped(Ref, ?A_DROPPED, Pid)
                   end;
               false when MaxSev =:= ?SEV_NONE ->
                   lager_dropped(Ref, ?A_DROPPED, Pid);
               false ->
                   lager_dropped(Ref, ?A_LIMITED, Pid)
           end,
    case Kept of
        ok -> {ok, St};
        gone -> remove_handler
    end;
handle_event(_Event, St) ->
    {ok, St}.

%% lager ORs the masks of all its backends into the level its callers
%% check; an empty one leaves that level alone.
handle_call(get_loglevel, St) ->
    {ok, {mask, 0}, St};
handle_call(_Request, St) ->
    {ok, {error, bad_request}, St}.

handle_info(_Info, St) ->
    {ok, St}.

terminate(_Arg, _St) ->
    ok.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

%% As log_dropped/3, but a gen_event handler removes itself by returning.
lager_dropped(Ref, Slot, Pid) ->
    case atomics:add_get(Ref, Slot, 1) band 1023 of
        0 ->
            case is_process_alive(Pid) of
                true -> ok;
                false -> gone
            end;
        _ ->
            ok
    end.

%% Every 1024th drop checks that the collector is still there: one that
%% was killed with its keeper leaves nobody to remove the handler, and
%% the error makes logger remove it.
log_dropped(Ref, Slot, Pid) ->
    case atomics:add_get(Ref, Slot, 1) band 1023 of
        0 -> is_process_alive(Pid) orelse erlang:error(eobs_collector_gone), ok;
        _ -> ok
    end.

severity(emergency) -> 0;
severity(alert) -> 1;
severity(critical) -> 2;
severity(error) -> 3;
severity(warning) -> 4;
severity(notice) -> 5;
severity(info) -> 6;
severity(_) -> 7.

%% Only removes the handler if it is ours.
remove_log_handler() ->
    case catch logger:get_handler_config(?LOGS) of
        {ok, #{module := ?MODULE}} -> _ = logger:remove_handler(?LOGS), ok;
        _ -> ok
    end,
    [bounded(fun() -> gen_event:delete_handler(Sink, ?LAGER_ID, stop) end, ?LAGER_CALL_MS)
     || Sink <- lager_sinks()],
    ok.

%% The running lager sinks: the default one, the one error_logger events
%% may be redirected to, and any extra sinks lager knows about.
lager_sinks() ->
    Known = case lager_config({'_global', handlers}) of
                Handlers when is_list(Handlers) ->
                    [Sink || {_Handler, _Watcher, Sink} <- Handlers, is_atom(Sink)];
                _ ->
                    []
            end,
    [Sink || Sink <- lists:usort([lager_event, error_logger_lager_event | Known]),
             is_pid(whereis(Sink))].

%% Adds the lager backend to every sink; returns the sinks it is in.
lager_attach(Ref, Collector) ->
    [Sink || Sink <- lager_sinks(),
             bounded(fun() -> gen_event:add_handler(Sink, ?LAGER_ID, {Ref, Collector}) end,
                     ?LAGER_CALL_MS) =:= ok].

%% Whether lager forwards error_logger, and with it OTP logger, events.
lager_redirects() ->
    is_pid(whereis(error_logger)) andalso
        bounded(fun() -> lists:member(error_logger_lager_h, gen_event:which_handlers(error_logger)) end,
                ?LAGER_CALL_MS) =:= true.

%% The least severe level lager's default sink lets through, or null.
lager_level() ->
    Mask = case lager_config({lager_event, loglevel}) of
               {M, _Traces} when is_integer(M) -> M;
               _ ->
                   %% lager 2
                   case lager_config(loglevel) of
                       {M, _} when is_integer(M) -> M;
                       _ -> undefined
                   end
           end,
    case Mask of
        undefined -> null;
        _ -> lager_mask_level(Mask)
    end.

lager_mask_level(Mask) ->
    case [L || {Bit, L} <- [{128, debug}, {64, info}, {32, notice}, {16, warning},
                            {8, error}, {4, critical}, {2, alert}, {1, emergency}],
               Mask band Bit =/= 0] of
        [L | _] -> L;
        [] -> none
    end.

%% A value of lager's configuration, read without calling lager: lager 3.8
%% and later keep it in persistent_term, older ones in an ETS table.
lager_config(Key) ->
    try
        persistent_term:get({lager_config, Key})
    catch error:_ ->
        case catch ets:lookup(lager_config, Key) of
            [{_, Value}] -> Value;
            _ -> undefined
        end
    end.

%% Runs Fun in a helper and gives up after Timeout, so a busy event
%% manager cannot hold up the caller. Returns error if Fun raised.
bounded(Fun, Timeout) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({done, Fun()}) end),
    receive
        {'DOWN', Ref, process, Pid, {done, Result}} -> Result;
        {'DOWN', Ref, process, Pid, _} -> error
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        timeout
    end.

%% The keeper owns the rings and the handler, and answers the tool. It
%% never receives log events itself.
logs_init(Parent, Owner) ->
    try register(?LOGS, self())
    catch error:badarg -> Parent ! {self(), busy}, exit(normal)
    end,
    process_flag(trap_exit, true),
    %% A handler left behind by a keeper that was killed.
    remove_log_handler(),
    case monitor_owner(Owner) of
        true -> ok;
        false -> Parent ! {self(), {error, owner_down}}, exit(normal)
    end,
    Tabs = #{logs => ets:new(eobs_logs, [ordered_set, public]),
             crashes => group_store(),
             restarts => group_store()},
    ets:insert(maps:get(logs, Tabs), {seq, 0}),
    St0 = #{id => erlang:unique_integer([positive]), owners => [Owner], tabs => Tabs,
            ref => atomics:new(4, [{signed, true}]), worker => undefined, lager => [],
            status => stopped, reason => null, stopped_at => 0, collector_restarts => 0,
            started => erlang:system_time(millisecond), last_read => now_ms()},
    St = logs_start(St0),
    Parent ! {self(), ok},
    try logs_loop(St)
    after remove_log_handler()
    end.

%% Crash groups and restart counters: Key -> {Key, Seq, Group}, plus an
%% index Seq -> Key so changes since a sequence number (and the group
%% changed longest ago, evicted when full) are cheap to find.
group_store() ->
    Idx = ets:new(eobs_log_index, [ordered_set, public]),
    ets:insert(Idx, {seq, 0}),
    #{tab => ets:new(eobs_log_groups, [set, public]), idx => Idx}.

%% Rebuilds Idx from Tab after an unclean collector kill so Tab and Idx
%% never drift out of sync.
sync_group_store(#{tab := Tab, idx := Idx}) ->
    MaxSeq0 = case ets:lookup(Idx, seq) of
                  [{seq, S}] when is_integer(S) -> S;
                  _ -> 0
              end,
    Entries = ets:tab2list(Tab),
    ets:delete_all_objects(Idx),
    MaxSeq = lists:foldl(fun({Key, Seq, _}, Max) when is_integer(Seq) ->
                                 ets:insert(Idx, {Seq, Key}),
                                 max(Max, Seq);
                            (_, Max) -> Max
                         end, MaxSeq0, Entries),
    ets:insert(Idx, {seq, MaxSeq}),
    ok.

logs_start(#{tabs := Tabs} = St) ->
    sync_group_store(maps:get(crashes, Tabs)),
    sync_group_store(maps:get(restarts, Tabs)),
    Ref = atomics:new(4, [{signed, true}]),
    atomics:put(Ref, ?A_INFLIGHT, 0),
    atomics:put(Ref, ?A_MAXSEV, ?SEV_ALL),
    Sinks = lager_sinks(),
    Redirected = Sinks =/= [] andalso lager_redirects(),
    Worker = spawn_opt(fun() -> collector_init(Tabs, Ref, Redirected) end,
                       [link, {priority, low},
                        {max_heap_size, #{size => ?LOG_HEAP_WORDS, kill => true,
                                          error_logger => false}}]),
    Attached = lager_attach(Ref, Worker),
    case Attached =/= [] andalso Redirected of
        true -> ok;
        false when Redirected -> Worker ! {redirected, false};
        _ -> ok
    end,
    Config = #{level => all, filter_default => log, filters => [],
               config => #{ref => Ref, collector => Worker}},
    case logger:add_handler(?LOGS, ?MODULE, Config) of
        ok ->
            St#{ref := Ref, worker := Worker, status := running, reason := null, lager := Attached};
        {error, Reason} ->
            remove_log_handler(),
            unlink(Worker),
            exit(Worker, kill),
            St#{ref := Ref, worker := undefined, status := stopped, reason := fmt(Reason),
                stopped_at := now_ms(), lager := []}
    end.

logs_loop(#{last_read := LastRead} = St) ->
    Idle = max(0, LastRead + ?LOG_IDLE_MS - now_ms()),
    receive
        {From, Ref, {logs, Owner, Cursor}} ->
            St1 = logs_owner(Owner, logs_check(St#{last_read := now_ms()})),
            From ! {Ref, {ok, logs_read(Cursor, St1)}},
            logs_loop(St1);
        {'EXIT', Worker, Reason} when Worker =:= map_get(worker, St) ->
            %% killed: heap limit reached (a flood of large events)
            Why = case Reason of
                      killed -> overload;
                      _ -> crashed
                  end,
            logs_loop(logs_halt(Why, St#{worker := undefined}));
        {nodedown, Owner} ->
            case lists:delete(Owner, maps:get(owners, St)) of
                [] -> logs_halt(owner_down, St);
                Rest -> logs_loop(St#{owners := Rest})
            end;
        quit ->
            logs_halt(stopped, St);
        _ ->
            logs_loop(St)
    after Idle ->
        logs_halt(idle, St)
    end.

%% Every tool node reading the logs keeps them alive.
logs_owner(Owner, #{owners := Owners} = St) ->
    case lists:member(Owner, Owners) of
        true -> St;
        false ->
            case monitor_owner(Owner) of
                true -> St#{owners := [Owner | Owners]};
                false -> St
            end
    end.

%% Notices a handler logger removed (it crashed), and replaces a collector
%% that was killed for using too much memory once things calmed down.
logs_check(#{status := running} = St) ->
    case lists:member(?LOGS, logger:get_handler_ids()) of
        true -> St;
        false -> logs_halt(handler_removed, St)
    end;
logs_check(#{status := stopped, reason := Reason, stopped_at := At} = St)
  when Reason =:= overload; Reason =:= crashed; Reason =:= handler_removed ->
    case now_ms() - At >= ?LOG_RESTART_MS of
        true -> logs_start(St#{collector_restarts := maps:get(collector_restarts, St) + 1});
        false -> St
    end;
logs_check(St) ->
    St.

logs_halt(Reason, #{worker := Worker} = St) ->
    remove_log_handler(),
    case Worker of
        undefined -> ok;
        _ -> unlink(Worker), exit(Worker, kill)
    end,
    St#{worker := undefined, status := stopped, reason := Reason, stopped_at := now_ms(),
        lager := []}.

%% Cursor: {Id, LogSeq, CrashSeq, RestartSeq}. A cursor of an earlier
%% collection (or null) reads everything there is.
logs_read(Cursor, #{id := Id, tabs := #{logs := Logs, crashes := Crashes, restarts := Restarts},
                    ref := Ref} = St) ->
    {Reset, LogSince, CrashSince, RestartSince} =
        case Cursor of
            {Id, L, C, R} when is_integer(L), is_integer(C), is_integer(R) -> {false, L, C, R};
            null -> {false, 0, 0, 0};
            _ -> {true, 0, 0, 0}
        end,
    [{seq, Seq}] = ets:lookup(Logs, seq),
    Lines = case ets:select(Logs, [{{'$1', '$2'}, [{is_integer, '$1'}, {'>', '$1', LogSince}], ['$2']}],
                            ?LOG_PAGE) of
                {Ls, _} -> Ls;
                '$end_of_table' -> []
            end,
    LogNext = next_seq(Lines, LogSince),
    {CrashList, CrashNext} = group_changes(Crashes, CrashSince),
    {RestartList, RestartNext} = group_changes(Restarts, RestartSince),
    #{id => Id,
      reset => Reset,
      cursor => {Id, LogNext, CrashNext, RestartNext},
      status => maps:get(status, St),
      reason => maps:get(reason, St),
      started => maps:get(started, St),
      now => erlang:system_time(millisecond),
      primary_level => primary_level(),
      lager => maps:get(lager, St) =/= [],
      lager_level => case maps:get(lager, St) of
                         [] -> null;
                         _ -> lager_level()
                     end,
      received => Seq,
      lost => max(0, Seq - ?LOG_RING - LogSince),
      dropped => atomics:get(Ref, ?A_DROPPED),
      limited => atomics:get(Ref, ?A_LIMITED),
      collector_restarts => maps:get(collector_restarts, St),
      logs => Lines,
      crashes => CrashList,
      restarts => RestartList}.

primary_level() ->
    case catch logger:get_primary_config() of
        #{level := L} -> L;
        _ -> null
    end.

group_changes(#{tab := Tab, idx := Idx}, Since) ->
    Changed = ets:select(Idx, [{{'$1', '$2'}, [{is_integer, '$1'}, {'>', '$1', Since}], ['$_']}]),
    Next = lists:foldl(fun({S, _}, Acc) -> max(S, Acc) end, Since, Changed),
    {[G || {_, K} <- Changed, {_, _, G} <- ets:lookup(Tab, K)], Next}.

%% The cursor after a read: the last sequence number actually returned.
%% Writers bump the `seq` counter before inserting the row, so a reader
%% that took the counter could skip a row that was not there yet.
next_seq([], Since) -> Since;
next_seq(Rows, _Since) -> maps:get(seq, lists:last(Rows)).

%% The collector formats events and fills the rings.
collector_init(Tabs, Ref, Redirected) ->
    {ok, CrashRe} = re:compile("<\\d+\\.\\d+\\.\\d+>|#Ref<[\\d.]+>|#Port<[\\d.]+>"),
    collector_loop(#{tabs => Tabs, ref => Ref, sec => 0, n => 0, limited_sec => undefined,
                     redirected => Redirected, crash_re => CrashRe}).

collector_loop(#{ref := Ref} = St) ->
    receive
        {?LOGS, Event} ->
            atomics:sub(Ref, ?A_INFLIGHT, 1),
            collector_loop(collect_event(Event, St));
        {rate_reset, Sec} when Sec =:= map_get(limited_sec, St) ->
            atomics:put(Ref, ?A_MAXSEV, ?SEV_ALL),
            collector_loop(St#{limited_sec := undefined});
        {redirected, Redirected} ->
            collector_loop(St#{redirected := Redirected});
        _ ->
            collector_loop(St)
    end.

collect_event(Event, #{sec := Sec, n := N, ref := Ref} = St) ->
    Level = case Event of
                {lager, Msg} -> element(4, Msg);
                #{level := L} -> L
            end,
    NowMs = erlang:monotonic_time(millisecond),
    Now = floor_div(NowMs, 1000),
    N1 = case Now of
             Sec -> N + 1;
             _ -> 1
         end,
    St1 = St#{sec := Now, n := N1},
    Sev = severity(Level),
    if
        N1 > ?LOG_HARD_RATE ->
            atomics:add(Ref, ?A_DROPPED, 1),
            rate_limit(?SEV_NONE, Now, NowMs, St1);
        N1 > ?LOG_RATE, Sev > ?SEV_WARNING ->
            atomics:add(Ref, ?A_LIMITED, 1),
            rate_limit(?SEV_WARNING, Now, NowMs, St1);
        true ->
            try store_log(Event, St1)
            catch _:_ -> ok
            end,
            St1
    end.

%% Lowers the level the handler lets through until the second is over.
rate_limit(MaxSev, Now, NowMs, #{ref := Ref} = St) ->
    case atomics:get(Ref, ?A_MAXSEV) > MaxSev of
        true ->
            atomics:put(Ref, ?A_MAXSEV, MaxSev),
            erlang:send_after(1000 - (NowMs - Now * 1000), self(), {rate_reset, Now}),
            St#{limited_sec := Now};
        false ->
            St
    end.

floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

store_log({lager, {lager_msg, _Dest, Meta, Level, _DateTime, {Mega, Sec, Micro}, Message}},
          #{tabs := Tabs}) ->
    Get = fun(Key) ->
                  case lists:keyfind(Key, 1, Meta) of
                      {_, V} -> V;
                      false -> undefined
                  end
          end,
    store_line(#{t => (Mega * 1000000 + Sec) * 1000000 + Micro,
                 level => Level,
                 module => case Get(module) of
                               M when is_atom(M), M =/= undefined -> M;
                               _ -> null
                           end,
                 pid => case Get(pid) of
                            P when is_pid(P) -> ref_bin(P);
                            P when is_list(P) -> limited_chars(P, 100);
                            _ -> null
                        end,
                 source => lager,
                 text => lager_text(Message)}, Tabs);
store_log(#{level := Level, msg := Msg, meta := Meta} = Event, #{tabs := Tabs} = St) ->
    Time = case Meta of
               #{time := T} when is_integer(T) -> T;
               _ -> erlang:system_time(microsecond)
           end,
    %% A copy of this one comes from lager.
    case maps:get(redirected, St) andalso is_map_key(error_logger, Meta) of
        false ->
            store_line(#{t => Time,
                         level => Level,
                         module => case Meta of
                                       #{mfa := {M, _, _}} when is_atom(M) -> M;
                                       _ -> null
                                   end,
                         pid => case Meta of
                                    #{pid := P} when is_pid(P) -> ref_bin(P);
                                    _ -> null
                                end,
                         source => logger,
                         text => log_text(Event)}, Tabs);
        true ->
            ok
    end,
    case crash_info(Msg, Meta) of
        none -> ok;
        {crash, Who, Pid, Class, Reason, Stack} ->
            store_crash(Who, Pid, Class, Reason, Stack, Time, Tabs, maps:get(crash_re, St));
        {restart, Ctx, Sup, Child, Reason} -> store_restart(Ctx, Sup, Child, Reason, Time, Tabs)
    end.

store_line(Line, Tabs) ->
    Logs = maps:get(logs, Tabs),
    Seq = ets:update_counter(Logs, seq, 1),
    ets:insert(Logs, {Seq, Line#{seq => Seq}}),
    case Seq > ?LOG_RING of
        true -> ets:delete(Logs, Seq - ?LOG_RING);
        false -> ok
    end.

%% lager hands over the message already formatted (chardata). A message
%% formatted with ~s from UTF-8 bytes arrives as one char per byte; it is
%% shown decoded when the bytes are valid UTF-8.
lager_text(Message0) ->
    Message = pre_slice_bin(Message0, ?LOG_TEXT_CHARS * 16),
    Chars = try unicode:characters_to_list(Message) of
                L when is_list(L) -> L;
                _ -> lager_text_fallback(Message)
            catch _:_ ->
                lager_text_fallback(Message)
            end,
    Head = lists:sublist(Chars, ?LOG_TEXT_CHARS * 4),
    Text = case lists:all(fun(C) -> C < 256 end, Head)
               andalso lists:any(fun(C) -> C > 127 end, Head) of
               true ->
                   case unicode:characters_to_list(list_to_binary(Head), utf8) of
                       Decoded when is_list(Decoded) -> Decoded;
                       _ -> Head
                   end;
               false ->
                   Head
           end,
    clip(string:trim(Text, trailing), ?LOG_TEXT_CHARS).

pre_slice_bin(Bin, MaxBytes) when is_binary(Bin), byte_size(Bin) > MaxBytes ->
    binary:part(Bin, 0, MaxBytes);
pre_slice_bin(Other, _) ->
    Other.

lager_text_fallback(Message) ->
    unicode:characters_to_list(limited(Message, ?LOG_TEXT_CHARS)).

limited_chars(Chars, Max) ->
    case io_lib:printable_unicode_list(Chars) of
        true -> clip(Chars, Max);
        false -> limited(Chars, Max)
    end.

%% The message as the node's own logger would print it, within limits.
log_text(Event) ->
    Config = #{template => [msg], single_line => false, legacy_header => false,
               chars_limit => ?LOG_TEXT_CHARS, depth => ?LOG_DEPTH},
    try logger_formatter:format(Event, Config) of
        Chars -> clip(string:trim(unicode:characters_to_list(Chars), trailing), ?LOG_TEXT_CHARS)
    catch _:_ ->
        limited(maps:get(msg, Event, undefined), ?LOG_TEXT_CHARS)
    end.

clip(Chars, Max) ->
    case length(Chars) > Max of
        true -> unicode:characters_to_binary(lists:sublist(Chars, Max) ++ " ...");
        false -> unicode:characters_to_binary(Chars)
    end.

%% Crashes and supervisor reports among the events:
%%   - proc_lib crash reports (gen_server, gen_statem, proc_lib processes),
%%   - "Error in process" errors of plain processes, from the emulator,
%%   - supervisor reports on children that terminated or failed to start.
crash_info({report, #{label := {proc_lib, crash}, report := [Crasher | _]}}, _Meta)
  when is_list(Crasher) ->
    {Class, Reason, Stack} = case proplists:get_value(error_info, Crasher) of
                                 {C, R, S} -> {C, R, S};
                                 Other -> {exit, Other, []}
                             end,
    Who = case proplists:get_value(registered_name, Crasher, []) of
              Name when is_atom(Name), Name =/= [] -> atom_to_binary(Name, utf8);
              _ -> case proplists:get_value(initial_call, Crasher) of
                       {M, F, Args} when is_list(Args) -> bin(mfa({M, F, length(Args)}));
                       {M, F, A} -> bin(mfa({M, F, A}));
                       _ -> null
                   end
          end,
    {crash, Who, proplists:get_value(pid, Crasher), Class, Reason, Stack};
crash_info({report, #{label := {supervisor, Ctx}, report := Report}}, _Meta)
  when Ctx =:= child_terminated; Ctx =:= start_error; Ctx =:= shutdown;
       Ctx =:= shutdown_error ->
    Offender = case proplists:get_value(offender, Report) of
                   O when is_list(O) -> O;
                   _ -> []
               end,
    {restart, Ctx, proplists:get_value(supervisor, Report), Offender,
     proplists:get_value(reason, Report)};
crash_info({Format, [Pid | Rest]}, #{error_logger := #{emulator := true}})
  when is_list(Format), is_pid(Pid) ->
    %% [Pid, Reason], or [Pid, Node, Reason] on a distributed node
    case {lists:prefix("Error in process", Format), Rest} of
        {true, [_Node, Reason]} -> {crash, null, Pid, error, Reason, []};
        {true, [Reason]} -> {crash, null, Pid, error, Reason, []};
        _ -> none
    end;
crash_info(_Msg, _Meta) ->
    none.

%% Crashes with the same process (name or initial call) and the same
%% reason, pids and refs aside, are one group with a count.
store_crash(Who, Pid, Class, Reason0, Stack0, Time, #{crashes := Store}, CrashRe) ->
    {Reason, Stack} = split_stack(Reason0, Stack0),
    Line = one_line(limited(Reason, 600), 300),
    Key = {Who, re:replace(Line, CrashRe, "_", [global, {return, binary}])},
    group_put(Store, Key, fun(Old) ->
        Base = case Old of
                   undefined -> #{id => erlang:unique_integer([positive]), who => Who, count => 0,
                                  first => Time};
                   _ -> Old
               end,
        Base#{count := maps:get(count, Base) + 1,
              last => Time,
              pid => case is_pid(Pid) of true -> ref_bin(Pid); false -> null end,
              class => Class,
              reason => Line,
              text => limited(Reason, ?LOG_REASON_CHARS),
              stack => [format_frame(F) || F <- lists:sublist(Stack, ?LOG_STACK), is_frame(F)]}
    end).

%% gen_server and friends exit with {Reason, Stacktrace}; plain processes
%% that call erlang:error/1 directly have an empty one.
split_stack({Reason, []}, []) ->
    {Reason, []};
split_stack({Reason, [F | _] = Stack}, Stack0) when is_list(Stack) ->
    case is_frame(F) of
        true -> {Reason, Stack};
        false when is_list(Stack0) -> {{Reason, Stack}, Stack0};
        false -> {{Reason, Stack}, []}
    end;
split_stack(Reason, Stack) when is_list(Stack) ->
    {Reason, Stack};
split_stack(Reason, _) ->
    {Reason, []}.

is_frame({M, F, A, L}) -> is_atom(M) andalso is_atom(F) andalso (is_integer(A) orelse is_list(A))
                              andalso is_list(L);
is_frame(_) -> false.

%% Per supervisor and child id: terminations (each one a restart unless
%% the child is temporary), failed starts, and whether the supervisor gave
%% up (reached its restart intensity).
store_restart(Ctx, Sup, Offender, Reason0, Time, #{restarts := Store}) ->
    {Reason, _} = split_stack(Reason0, []),
    Child = proplists:get_value(id, Offender),
    Key = {Sup, Child},
    group_put(Store, Key, fun(Old) ->
        Base = case Old of
                   undefined -> #{id => erlang:unique_integer([positive]),
                                  supervisor => sup_name(Sup), child => fmt(Child),
                                  count => 0, failed_starts => 0, gave_up => false, times => []};
                   _ -> Old
               end,
        #{count := Count, failed_starts := Failed, times := Times} = Base,
        Counted = Ctx =:= child_terminated orelse Ctx =:= start_error,
        Base#{count := Count + case Ctx of child_terminated -> 1; _ -> 0 end,
              failed_starts := Failed + case Ctx of start_error -> 1; _ -> 0 end,
              gave_up := maps:get(gave_up, Base) orelse Ctx =:= shutdown,
              times := case Counted of
                           true -> lists:sublist([Time | Times], ?LOG_TIMES);
                           false -> Times
                       end,
              last => Time,
              context => Ctx,
              restart_type => case proplists:get_value(restart_type, Offender) of
                                  undefined -> null;
                                  RT -> RT
                              end,
              pid => case proplists:get_value(pid, Offender) of
                         P when is_pid(P) -> ref_bin(P);
                         _ -> null
                     end,
              reason => one_line(limited(Reason, 600), 300)}
    end).

sup_name({local, Name}) -> atom_to_binary(Name, utf8);
sup_name({global, Name}) -> fmt(Name);
sup_name({via, _, Name}) -> fmt(Name);
sup_name({Pid, Mod}) when is_pid(Pid), is_atom(Mod) -> bin(io_lib:format("~s ~s", [Mod, pid_to_list(Pid)]));
sup_name(Other) -> fmt(Other).

%% Inserts or updates the group under Key with Fun(Old | undefined); when
%% the store is full the group changed longest ago makes room. Evaluates
%% Fun(Old) before mutating ETS so an exception or heap-kill cannot leave
%% Tab and Idx out of sync, and never evicts the `seq` counter entry.
group_put(#{tab := Tab, idx := Idx}, Key, Fun) ->
    {Old, OldSeq} = case ets:lookup(Tab, Key) of
                        [{_, S, G}] -> {G, S};
                        [] -> {undefined, undefined}
                    end,
    New = Fun(Old),
    Seq = ets:update_counter(Idx, seq, 1),
    case OldSeq of
        undefined ->
            case ets:info(Tab, size) >= ?LOG_GROUPS of
                true ->
                    case ets:first(Idx) of
                        First when is_integer(First) ->
                            case ets:lookup(Idx, First) of
                                [{_, K}] ->
                                    ets:delete(Idx, First),
                                    ets:delete(Tab, K);
                                [] ->
                                    ok
                            end;
                        _ ->
                            ok
                    end;
                false ->
                    ok
            end;
        _ ->
            ets:delete(Idx, OldSeq)
    end,
    ets:insert(Tab, {Key, Seq, New}),
    ets:insert(Idx, {Seq, Key}).

now_ms() ->
    erlang:monotonic_time(millisecond).

%%--------------------------------------------------------------------
%% Log files
%%
%% The node's own log files, read only: the files lager's file backends
%% and crash log write, and those of logger's file handlers, each with
%% the rotated copies next to it (File.0, File.1, ... and .gz). Built so
%% that it cannot take the node down:
%%   - only files in that list can be read; every call builds the list
%%     again and refuses any other path;
%%   - nothing is kept between calls; each call runs in its own process
%%     with a heap limit, low priority and a time limit, opens the file
%%     raw and read only, and reads at most a page (LF_PAGE), a search
%%     at most LF_SCAN bytes, a download chunk at most LF_CHUNK;
%%   - at most LF_JOBS calls run at a time, others are refused as busy;
%%   - a .gz file can only be read from its start, up to LF_GZ_MAX bytes
%%     of uncompressed data.
%%--------------------------------------------------------------------

-define(LF_PAGE, 262144).
-define(LF_CHUNK, 1048576).
-define(LF_SCAN, 67108864).
-define(LF_SCAN_MS, 3000).
-define(LF_HITS, 500).
-define(LF_GZ_MAX, 67108864).
-define(LF_JOBS, [eobs_agent_file_1, eobs_agent_file_2]).
-define(LF_HEAP_WORDS, 8000000).
-define(LF_TIMEOUT, 10000).
-define(LF_ENTRY_CHARS, 16000).
%% Bytes read around a probe while seeking a time.
-define(LF_PROBE, 65536).

%% The log files of the node, newest first within each file's group.
logfile_list() ->
    lf_job(fun() -> {ok, [lf_info(F) || F <- lf_files()]} end).

%% A page of entries. Dir back: the page ending at Pos (eof: the end of
%% the file); fwd: the page starting at Pos. Pages start and end on line
%% boundaries; `start`/`stop` are where the next page goes on from.
logfile_read(Path, Pos, Dir, Bytes) ->
    lf_with(Path, fun(File) -> lf_read(File, Pos, Dir, min(max(Bytes, 4096), ?LF_PAGE)) end).

%% The position of the first entry at or after Time (a binary such as
%% <<"2026-10-27 11:32">>, compared with the entries' own timestamps).
logfile_seek(Path, Time) ->
    lf_with(Path, fun(#{gz := true}) -> {error, gz_not_seekable};
                     (File) -> lf_seek(File, Time)
                  end).

%% Lines containing Text, scanning from Pos in Dir for at most LF_SCAN
%% bytes or LF_SCAN_MS; `next` is where to go on, null when done.
logfile_search(Path, Pos, Dir, Text, MinLevel) when is_binary(Text), Text =/= <<>> ->
    lf_with(Path, fun(File) -> lf_search(File, Pos, Dir, Text, MinLevel) end).

%% Raw bytes of the file (compressed ones as they are), for downloads.
logfile_chunk(Path, Pos, Len) ->
    lf_with(Path, fun(#{path := P}) ->
                          lf_pread(P, Pos, min(Len, ?LF_CHUNK))
                  end).

lf_with(Path, Fun) ->
    lf_job(fun() ->
                   Wanted = unicode:characters_to_list(Path),
                   case [F || #{path := P} = F <- lf_files(), P =:= Wanted] of
                       [File | _] -> Fun(File);
                       [] -> {error, not_a_log_file}
                   end
           end).

%% Runs Fun in a process of its own, holding one of the LF_JOBS names.
lf_job(Fun) ->
    {Pid, Ref} = spawn_opt(fun() -> lf_job_init(Fun) end,
                           [monitor, {priority, low},
                            {max_heap_size, #{size => ?LF_HEAP_WORDS, kill => true,
                                              error_logger => false}}]),
    receive
        {'DOWN', Ref, process, Pid, {lf_done, Result}} -> Result;
        {'DOWN', Ref, process, Pid, lf_busy} -> {error, files_busy};
        {'DOWN', Ref, process, Pid, killed} -> {error, too_big};
        {'DOWN', Ref, process, Pid, Reason} -> {error, {failed, fmt(Reason)}}
    after ?LF_TIMEOUT ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        {error, timeout}
    end.

lf_job_init(Fun) ->
    case lists:any(fun(Name) -> try register(Name, self()) catch error:badarg -> false end end,
                   ?LF_JOBS) of
        true -> exit({lf_done, Fun()});
        false -> exit(lf_busy)
    end.

%% #{path, base, source, level, index, gz} per file; index is null for
%% the file being written, N for File.N.
lf_files() ->
    Lager = lists:append([lf_lager_files(Sink) || Sink <- lager_sinks()]),
    Crash = case is_pid(whereis(lager_crash_log)) of
                true ->
                    case application:get_env(lager, crash_log) of
                        {ok, F} when is_list(F), F =/= [] -> [{lf_lager_path(F), crash_log, null}];
                        _ -> []
                    end;
                false ->
                    []
            end,
    Logger = [{F, logger, L} || #{module := M, config := #{file := F}} = H <- lf_logger_handlers(),
                               M =:= logger_std_h orelse M =:= logger_disk_log_h,
                               is_list(F),
                               L <- [maps:get(level, H, all)]],
    Seen = lists:reverse(
             lists:foldl(fun({F, S, L}, Acc) ->
                                 case lists:keymember(F, 1, Acc) of
                                     true -> Acc;
                                     false -> [{F, S, L} | Acc]
                                 end
                         end, [], Lager ++ Crash ++ Logger)),
    lists:append([lf_rotations(F, S, L) || {F, S, L} <- Seen]).

%% Files of lager's file backends in Sink. The path a backend writes to
%% is in its state (lager_file_backend keeps the expanded name there, and
%% so do the renamed copies many projects use); the handler id
%% {lager_file_backend, File} is the fallback when the state can't be read.
lf_lager_files(Sink) ->
    Handlers = case bounded(fun() -> gen_event:which_handlers(Sink) end, ?LAGER_CALL_MS) of
                   Hs when is_list(Hs) -> [H || H <- Hs, H =/= ?LAGER_ID];
                   _ -> []
               end,
    FromState = [{P, Id} || {Id, State} <- lf_handler_states(Sink),
                            lists:member(Id, Handlers),
                            P <- lf_state_paths(State)],
    FromId = [{lf_lager_path(F), Id} || {_, F0} = Id <- Handlers,
                                        F <- [lf_name(F0)], F =/= none,
                                        not lists:keymember(Id, 2, FromState)],
    [{P, lager, lf_lager_level(Sink, Id)} || {P, Id} <- FromState ++ FromId].

%% [{HandlerId, State}] of the sink's handlers, through sys:get_state in a
%% process of its own with a capped heap; [] when that fails.
lf_handler_states(Sink) ->
    {Pid, Ref} = spawn_opt(fun() -> exit({done, sys:get_state(Sink, ?LAGER_CALL_MS)}) end,
                           [monitor, {max_heap_size, #{size => 1000000, kill => true,
                                                       error_logger => false}}]),
    receive
        {'DOWN', Ref, process, Pid, {done, L}} when is_list(L) ->
            [{case Id of false -> Mod; _ -> {Mod, Id} end, State} || {Mod, Id, State} <- L];
        {'DOWN', Ref, process, Pid, _} ->
            []
    after ?LAGER_CALL_MS + 500 ->
        exit(Pid, kill),
        erlang:demonitor(Ref, [flush]),
        []
    end.

%% Only inspect the file-name slot (element 2) of `#state{name = File, ...}`
%% records (matching lager_file_backend and its renamed copies), never
%% arbitrary fields of unrelated handlers (TLS keys, credentials, configs).
lf_state_paths(State) when is_tuple(State), tuple_size(State) >= 2, element(1, State) =:= state ->
    case lf_name(element(2, State)) of
        none ->
            [];
        F ->
            P = lf_lager_path(F),
            case lf_allowed_state_file(P) of
                true -> [P];
                false -> []
            end
    end;
lf_state_paths(_) ->
    [].

lf_allowed_state_file(Path) ->
    not lf_blocked_ext(Path)
        andalso lf_regular_no_symlink(Path)
        andalso lf_in_log_root_or_log_ext(Path).

lf_regular_no_symlink(Path) ->
    case file:read_link_info(Path) of
        {ok, Info} -> element(3, Info) =:= regular;
        _ -> false
    end.

lf_blocked_ext(Path) ->
    Ext = string:lowercase(filename:extension(Path)),
    lists:member(Ext, [".key", ".pem", ".crt", ".cer", ".p12", ".pfx", ".der",
                       ".jks", ".config", ".args", ".cookie", ".eterm", ".beam",
                       ".erl", ".hrl"]).

lf_in_log_root_or_log_ext(Path) ->
    case application:get_env(lager, log_root) of
        {ok, Root} when is_list(Root), Root =/= "" ->
            AbsRoot = filename:absname(Root),
            lists:prefix(AbsRoot ++ "/", Path) orelse lists:prefix(AbsRoot ++ "\\", Path)
                orelse string:lowercase(filename:extension(Path)) =:= ".log";
        _ ->
            true
    end.

lf_name(B) when is_binary(B), byte_size(B) > 0, byte_size(B) < 4096 ->
    case unicode:characters_to_list(B) of
        L when is_list(L) -> lf_name(L);
        _ -> none
    end;
lf_name([C | _] = L) when is_integer(C) ->
    case catch length(L) < 4096 andalso io_lib:printable_unicode_list(L) of
        true -> L;
        _ -> none
    end;
lf_name(_) ->
    none.

%% As lager's own expand_path: relative to log_root, then absolute.
lf_lager_path(File) ->
    Path = case {filename:pathtype(File), application:get_env(lager, log_root)} of
               {relative, {ok, Root}} when is_list(Root) -> filename:join(Root, File);
               _ -> File
           end,
    filename:absname(Path).

lf_lager_level(Sink, Id) ->
    case bounded(fun() -> gen_event:call(Sink, Id, get_loglevel, ?LAGER_CALL_MS) end,
                 ?LAGER_CALL_MS + 500) of
        {mask, Mask} when is_integer(Mask) -> lager_mask_level(Mask);
        N when is_integer(N) -> lager_mask_level(lf_num_mask(N));
        _ -> null
    end.

%% lager 2 numbers: debug 7 ... emergency 0; everything at or above.
lf_num_mask(N) -> (1 bsl (N + 1)) - 1.

lf_logger_handlers() ->
    case catch logger:get_handler_config() of
        L when is_list(L) -> [H || H <- L, is_map(H)];
        _ -> []
    end.

%% The file and its rotated copies File.N and File.N.gz, in that order.
lf_rotations(File, Source, Level) ->
    Dir = filename:dirname(File),
    Base = filename:basename(File),
    Names = case file:list_dir(Dir) of
                {ok, Ns} -> Ns;
                _ -> []
            end,
    Rotated = lists:sort([{N, Gz, Name} || Name <- Names,
                                           {N, Gz} <- [lf_rotation(Base, Name)]]),
    Entry = fun(Path, Index, Gz) ->
                    #{path => Path, base => File, source => Source, level => Level,
                      index => Index, gz => Gz}
            end,
    Current = case filelib:is_regular(File) of
                  true -> [Entry(File, null, false)];
                  false -> []
              end,
    Current ++ [Entry(filename:join(Dir, Name), N, Gz) || {N, Gz, Name} <- Rotated].

lf_rotation(Base, Name) ->
    case lists:prefix(Base ++ ".", Name) of
        true ->
            Rest = lists:nthtail(length(Base) + 1, Name),
            {Digits, Gz} = case lists:suffix(".gz", Rest) of
                               true -> {lists:sublist(Rest, length(Rest) - 3), true};
                               false -> {Rest, false}
                           end,
            case Digits =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Digits) of
                true -> {list_to_integer(Digits), Gz};
                false -> none
            end;
        false ->
            none
    end.

lf_info(#{path := Path, base := Base} = F) ->
    {Size, Mtime} = case file:read_file_info(Path, [{time, posix}]) of
                        {ok, Info} -> {element(2, Info), element(6, Info) * 1000};
                        _ -> {null, null}
                    end,
    F#{path := lf_bin(Path), base := lf_bin(Base), size => Size, mtime => Mtime}.

lf_bin(Name) ->
    case unicode:characters_to_binary(Name) of
        B when is_binary(B) -> B;
        _ -> list_to_binary(io_lib:format("~w", [Name]))
    end.

lf_pread(Path, Pos, Len) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                case file:pread(Fd, Pos, Len) of
                    {ok, Bin} -> {ok, Bin};
                    eof -> {ok, <<>>};
                    {error, _} = E -> E
                end
            after
                file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

lf_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        _ -> 0
    end.

%% Bytes [From, From + Len) of the uncompressed data of a .gz file, and
%% whether that reached its end.
lf_gz_range(_Path, From, Len) when From < 0; Len < 0 ->
    {error, badarg};
lf_gz_range(Path, From, Len) when From + Len > ?LF_GZ_MAX ->
    case From >= ?LF_GZ_MAX of
        true -> {error, gz_too_far};
        false -> lf_gz_range(Path, From, ?LF_GZ_MAX - From)
    end;
lf_gz_range(Path, From, Len) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            Z = zlib:open(),
            try
                ok = zlib:inflateInit(Z, 31),
                lf_gz_loop(Fd, Z, 0, From, From + Len, [])
            catch _:_ ->
                {error, bad_gz}
            after
                catch zlib:close(Z),
                file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

lf_gz_loop(Fd, Z, At, From, To, Acc) ->
    case file:read(Fd, 65536) of
        {ok, In} ->
            Out = iolist_to_binary(zlib:inflate(Z, In)),
            Next = At + byte_size(Out),
            Keep = case Next =< From orelse At >= To of
                       true -> <<>>;
                       false ->
                           S = max(From - At, 0),
                           binary:part(Out, S, min(byte_size(Out), To - At) - S)
                   end,
            case Next >= To of
                true -> {ok, iolist_to_binary(lists:reverse([Keep | Acc])), false};
                false -> lf_gz_loop(Fd, Z, Next, From, To, [Keep | Acc])
            end;
        eof ->
            {ok, iolist_to_binary(lists:reverse(Acc)), true};
        {error, _} = E ->
            E
    end.

%% Pages

lf_read(#{gz := true, path := P}, Pos, _Dir, Bytes) ->
    Start = case Pos of
                N when is_integer(N), N >= 0 -> N;
                _ -> 0
            end,
    case lf_gz_range(P, Start, Bytes) of
        {ok, Bin, Eof} ->
            Body = case Eof of
                       true -> Bin;
                       false -> lf_upto_last_nl(Bin)
                   end,
            Stop = Start + byte_size(Body),
            {ok, #{size => case Eof of true -> Stop; false -> null end,
                   start => Start, stop => Stop, gz => true,
                   entries => lf_entries(Body, Start)}};
        {error, _} = E ->
            E
    end;
lf_read(#{path := P}, Pos, Dir, Bytes) ->
    Size = lf_size(P),
    case Dir of
        back ->
            End = case Pos of
                      N when is_integer(N), N >= 0 -> min(N, Size);
                      _ -> Size
                  end,
            Start0 = max(0, End - Bytes),
            case lf_pread(P, Start0, End - Start0) of
                {ok, Bin} ->
                    {Start, Body} = case Start0 of
                                        0 -> {0, Bin};
                                        _ -> lf_from_first_nl(Start0, Bin)
                                    end,
                    {ok, #{size => Size, start => Start, stop => End, gz => false,
                           entries => lf_entries(Body, Start)}};
                {error, _} = E ->
                    E
            end;
        fwd ->
            Start = case Pos of
                        N when is_integer(N), N >= 0 -> lf_entry_start(P, min(N, Size));
                        _ -> 0
                    end,
            case lf_pread(P, Start, min(Bytes, Size - Start)) of
                {ok, Bin} ->
                    Body = case Start + byte_size(Bin) >= Size of
                               true -> Bin;
                               false -> lf_upto_last_nl(Bin)
                           end,
                    {ok, #{size => Size, start => Start, stop => Start + byte_size(Body), gz => false,
                           entries => lf_entries(Body, Start)}};
                {error, _} = E ->
                    E
            end
    end.

%% A page that would start inside a multi-line entry (a stack trace
%% printed by lager, a report) starts at that entry's first line instead,
%% looking back at most LF_PROBE bytes.
lf_entry_start(_P, 0) ->
    0;
lf_entry_start(P, Pos) ->
    {ok, Re} = lf_header_re(),
    case lf_pread(P, Pos, 512) of
        {ok, Line} ->
            case lf_header(Line, Re) of
                {ok, _} ->
                    Pos;
                none ->
                    From = max(0, Pos - ?LF_PROBE),
                    case lf_pread(P, From, Pos - From) of
                        {ok, Bin} ->
                            {Start, Body} = case From of
                                                0 -> {0, Bin};
                                                _ -> lf_from_first_nl(From, Bin)
                                            end,
                            case [At || {At, L} <- lf_lines(Body, Start), lf_header(L, Re) =/= none] of
                                [] -> Pos;
                                Heads -> lists:last(Heads)
                            end;
                        _ ->
                            Pos
                    end
            end;
        _ ->
            Pos
    end.

%% Drops a partial first line (unless the chunk is one long line).
lf_from_first_nl(Start, Bin) ->
    case binary:match(Bin, <<"\n">>) of
        {I, 1} when I + 1 < byte_size(Bin) ->
            {Start + I + 1, binary:part(Bin, I + 1, byte_size(Bin) - I - 1)};
        _ ->
            {Start, Bin}
    end.

%% O(last_line_len) backward scan with zero heap allocation.
lf_upto_last_nl(Bin) ->
    case lf_last_nl(Bin, byte_size(Bin) - 1) of
        nomatch -> Bin;
        I -> binary:part(Bin, 0, I + 1)
    end.

lf_last_nl(_Bin, I) when I < 0 -> nomatch;
lf_last_nl(Bin, I) ->
    case binary:at(Bin, I) of
        $\n -> I;
        _ -> lf_last_nl(Bin, I - 1)
    end.

%% Lines with their positions; a line that does not start with a
%% timestamp belongs to the entry above it (reports, stack traces).
lf_lines(Bin, Base) ->
    lf_lines(binary:split(Bin, <<"\n">>, [global]), Base, []).

lf_lines([], _Pos, Acc) -> lists:reverse(Acc);
lf_lines([<<>>], _Pos, Acc) -> lists:reverse(Acc);
lf_lines([L | Rest], Pos, Acc) -> lf_lines(Rest, Pos + byte_size(L) + 1, [{Pos, L} | Acc]).

lf_entries(Bin, Base) ->
    {ok, Re} = lf_header_re(),
    Groups = lists:foldl(fun({Pos, Line}, Acc) ->
                                 case lf_header(Line, Re) of
                                     {ok, H} -> [{Pos, H, [Line]} | Acc];
                                     none ->
                                         case Acc of
                                             [{P, H, Ls} | Rest] -> [{P, H, [Line | Ls]} | Rest];
                                             [] -> [{Pos, none, [Line]}]
                                         end
                                 end
                         end, [], lf_lines(Bin, Base)),
    [lf_entry(Pos, H, lists:reverse(Ls)) || {Pos, H, Ls} <- lists:reverse(Groups)].

lf_entry(Pos, Header, Lines) ->
    Text = lf_text(iolist_to_binary(lists:join(<<"\n">>, Lines))),
    case Header of
        none ->
            #{pos => Pos, t => null, level => null, pid => null, module => null, cont => true,
              skip => 0, text => Text};
        #{t := T, level := L, pid := P, module := M, skip := Skip} ->
            #{pos => Pos, t => T, level => L, pid => P, module => M, cont => false,
              skip => Skip, text => Text}
    end.

%% lager: 2026-10-27 11:32:06.771 [info] <0.89.0>@mod:fun:12 message
%%        2026-10-27 11:32:06.771 [info] <0.89.0>[@mod:fun:12] message
%%        2026-10-27 11:32:06.771 [info] Undefined[@Undefined:Undefined:Undefined] message
%% logger: 2026-10-27T11:32:06.771397+08:00 info: message
lf_header_re() ->
    re:compile("^(\\d{4}-\\d\\d-\\d\\d[ T]\\d\\d:\\d\\d:\\d\\d(?:[.,]\\d+)?)\\S*\\s+"
               "\\[?(debug|info|notice|warning|error|critical|alert|emergency)\\]?:?"
               "(?:\\s+(<[0-9.]+>|[Uu]ndefined)(?:\\[?@([a-zA-Z0-9_]+)[^\\s\\]]*\\]?)?)?\\s*",
               []).

lf_header(Line, Re) ->
    case re:run(Line, Re, [{capture, all, binary}]) of
        {match, [All, T, L | More]} ->
            {Pid, Mod} = case More of
                             [P, M] -> {lf_null(P), lf_null(M)};
                             [P] -> {lf_null(P), null};
                             [] -> {null, null}
                         end,
            %% The message starts after the header; it is ASCII, so its
            %% length in bytes is its length in characters.
            {ok, #{t => binary:replace(T, <<"T">>, <<" ">>), level => binary_to_atom(L, latin1),
                   pid => Pid, module => Mod, skip => byte_size(All)}};
        _ ->
            none
    end.

lf_null(<<>>) -> null;
lf_null(<<"Undefined">>) -> null;
lf_null(<<"undefined">>) -> null;
lf_null(B) -> B.

%% Text as shown: UTF-8, also when it was written as UTF-8 bytes taken
%% for latin1 characters (one char per byte, then encoded again).
lf_text(Bin0) ->
    Bin = pre_slice_bin(Bin0, ?LF_ENTRY_CHARS * 8),
    Chars = case unicode:characters_to_list(Bin, utf8) of
                L when is_list(L) -> lf_undouble(L);
                {incomplete, L, _} -> lf_undouble(L);
                _ -> binary_to_list(Bin)
            end,
    clip(Chars, ?LF_ENTRY_CHARS).

lf_undouble(Chars) ->
    case lists:all(fun(C) -> C < 256 end, Chars) andalso lists:any(fun(C) -> C > 127 end, Chars) of
        true ->
            case unicode:characters_to_list(list_to_binary(Chars), utf8) of
                L when is_list(L) -> L;
                _ -> Chars
            end;
        false ->
            Chars
    end.

%% Seeking a time: halves [Lo, Hi) while it is longer than a probe, then
%% looks for the first entry at or after Time from Lo.
lf_seek(#{path := P}, Time) ->
    {ok, Re} = lf_header_re(),
    Size = lf_size(P),
    Pos = lf_seek(P, Re, Time, 0, Size),
    {ok, #{pos => Pos, size => Size}}.

lf_seek(P, Re, Time, Lo, Hi) when Hi - Lo > ?LF_PROBE ->
    Mid = (Lo + Hi) div 2,
    case lf_first_time(P, Re, Mid) of
        {T, _At} when T < Time -> lf_seek(P, Re, Time, Mid, Hi);
        {_T, _At} -> lf_seek(P, Re, Time, Lo, Mid);
        none -> lf_seek(P, Re, Time, Mid, Hi)
    end;
lf_seek(P, Re, Time, Lo, Hi) ->
    case lf_pread(P, Lo, Hi - Lo + ?LF_PROBE) of
        {ok, Bin} ->
            {Start, Body} = case Lo of
                                0 -> {0, Bin};
                                _ -> lf_from_first_nl(Lo, Bin)
                            end,
            Found = [Pos || {Pos, Line} <- lf_lines(Body, Start),
                            {ok, #{t := T}} <- [lf_header(Line, Re)], T >= Time],
            case Found of
                [Pos | _] -> Pos;
                [] -> min(Hi, lf_size(P))
            end;
        _ ->
            min(Hi, lf_size(P))
    end.

lf_first_time(P, Re, At) ->
    case lf_pread(P, At, ?LF_PROBE) of
        {ok, Bin} ->
            {Start, Body} = lf_from_first_nl(At, Bin),
            case [{T, Pos} || {Pos, Line} <- lf_lines(Body, Start),
                              {ok, #{t := T}} <- [lf_header(Line, Re)]] of
                [First | _] -> First;
                [] -> none
            end;
        _ ->
            none
    end.

%% Search

lf_search(File, Pos, Dir, Text, MinLevel) ->
    {ok, Re} = lf_header_re(),
    %% Also finds the text in files that hold it encoded twice.
    Twice = unicode:characters_to_binary(binary_to_list(Text)),
    Pattern = binary:compile_pattern(lists:usort([Text, Twice])),
    MaxSev = case MinLevel of
                 null -> ?SEV_ALL;
                 L -> severity(L)
             end,
    Deadline = now_ms() + ?LF_SCAN_MS,
    case File of
        #{gz := true, path := P} ->
            Start = case Pos of
                        N when is_integer(N), N >= 0 -> N;
                        _ -> 0
                    end,
            lf_gz_search(P, Start, Pattern, Re, MaxSev, Deadline);
        #{path := P} ->
            Size = lf_size(P),
            Start = case {Pos, Dir} of
                        {N, _} when is_integer(N), N >= 0 -> min(N, Size);
                        {_, back} -> Size;
                        {_, fwd} -> 0
                    end,
            lf_scan(P, Size, Start, Dir, Pattern, Re, MaxSev, Deadline, 0, 0, [])
    end.

%% Streams a .gz log file chunk by chunk instead of decompressing up to
%% 64 MB at once, enforcing both the hit limit and scan deadline.
lf_gz_search(_P, Start, _Pat, _Re, _Sev, _Deadline) when Start >= ?LF_GZ_MAX ->
    {error, gz_too_far};
lf_gz_search(P, Start, Pat, Re, Sev, Deadline) ->
    LimitEnd = min(?LF_GZ_MAX, Start + ?LF_SCAN),
    case file:open(P, [read, raw, binary]) of
        {ok, Fd} ->
            Z = zlib:open(),
            try
                ok = zlib:inflateInit(Z, 31),
                lf_gz_search_loop(Fd, Z, 0, Start, LimitEnd, <<>>, Pat, Re, Sev, Deadline, 0, 0, [])
            catch _:_ ->
                {error, bad_gz}
            after
                catch zlib:close(Z),
                file:close(Fd)
            end;
        {error, _} = E ->
            E
    end.

lf_gz_search_loop(Fd, Z, At, Start, LimitEnd, Carry, Pat, Re, Sev, Deadline, Scanned, Count, HitsRev) ->
    case Count >= ?LF_HITS orelse At >= LimitEnd orelse now_ms() > Deadline of
        true ->
            Next = case At >= ?LF_GZ_MAX of
                       true -> null;
                       false -> At - byte_size(Carry)
                   end,
            {ok, #{hits => lists:reverse(HitsRev), next => Next, scanned => Scanned}};
        false ->
            case file:read(Fd, 65536) of
                {ok, In} ->
                    Out = iolist_to_binary(zlib:inflate(Z, In)),
                    NextAt = At + byte_size(Out),
                    case NextAt =< Start of
                        true ->
                            lf_gz_search_loop(Fd, Z, NextAt, Start, LimitEnd, <<>>, Pat, Re, Sev,
                                              Deadline, Scanned, Count, HitsRev);
                        false ->
                            Skip = max(Start - At, 0),
                            Take = min(byte_size(Out), LimitEnd - At) - Skip,
                            Slice = binary:part(Out, Skip, max(0, Take)),
                            Buf = <<Carry/binary, Slice/binary>>,
                            BufFrom = At + Skip - byte_size(Carry),
                            {Complete, Carry1} = lf_split_tail(Buf),
                            Left = ?LF_HITS - Count,
                            {Found, ResumeOff} = lf_hits(Complete, BufFrom, fwd, Pat, Re, Sev, Left),
                            Count1 = Count + length(Found),
                            HitsRev1 = lists:reverse(Found, HitsRev),
                            Scanned1 = Scanned + byte_size(Complete),
                            case ResumeOff of
                                {more, NextPos} ->
                                    {ok, #{hits => lists:reverse(HitsRev1), next => NextPos,
                                           scanned => Scanned1}};
                                done ->
                                    lf_gz_search_loop(Fd, Z, NextAt, Start, LimitEnd, Carry1,
                                                      Pat, Re, Sev, Deadline, Scanned1, Count1, HitsRev1)
                            end
                    end;
                eof ->
                    {Found, _} = lf_hits(Carry, At - byte_size(Carry), fwd, Pat, Re, Sev, ?LF_HITS - Count),
                    HitsRev1 = lists:reverse(Found, HitsRev),
                    {ok, #{hits => lists:reverse(HitsRev1), next => null,
                           scanned => Scanned + byte_size(Carry)}};
                {error, _} = E ->
                    E
            end
    end.

lf_split_tail(Buf) ->
    case lf_last_nl(Buf, byte_size(Buf) - 1) of
        nomatch when byte_size(Buf) > ?LF_ENTRY_CHARS * 8 ->
            {Buf, <<>>};
        nomatch ->
            {<<>>, Buf};
        I ->
            {binary:part(Buf, 0, I + 1), binary:part(Buf, I + 1, byte_size(Buf) - I - 1)}
    end.

lf_scan(_P, _Size, At, _Dir, _Pat, _Re, _Sev, _Deadline, Scanned, Count, HitsRev)
  when Count >= ?LF_HITS ->
    {ok, #{hits => lists:reverse(HitsRev), next => At, scanned => Scanned}};
lf_scan(P, Size, At, Dir, Pat, Re, Sev, Deadline, Scanned, Count, HitsRev) ->
    Done = case Dir of
               fwd -> At >= Size;
               back -> At =< 0
           end,
    case Done of
        true ->
            {ok, #{hits => lists:reverse(HitsRev), next => null, scanned => Scanned}};
        false ->
            case Scanned + ?LF_CHUNK > ?LF_SCAN orelse now_ms() > Deadline of
                true ->
                    {ok, #{hits => lists:reverse(HitsRev), next => At, scanned => Scanned}};
                false ->
                    ReadRes = case Dir of
                                  fwd ->
                                      case lf_pread(P, At, min(?LF_CHUNK, Size - At)) of
                                          {ok, <<>>} -> eof;
                                          {ok, B} ->
                                              B1 = case At + byte_size(B) >= Size of
                                                       true -> B;
                                                       false -> lf_upto_last_nl(B)
                                                   end,
                                              {ok, At, B1, At + byte_size(B1)};
                                          {error, _} = Err -> Err
                                      end;
                                  back ->
                                      S0 = max(0, At - ?LF_CHUNK),
                                      case lf_pread(P, S0, At - S0) of
                                          {ok, <<>>} -> eof;
                                          {ok, B} ->
                                              {S, B1} = case S0 of
                                                            0 -> {0, B};
                                                            _ -> lf_from_first_nl(S0, B)
                                                        end,
                                              {ok, S, B1, S};
                                          {error, _} = Err -> Err
                                      end
                              end,
                    case ReadRes of
                        eof ->
                            {ok, #{hits => lists:reverse(HitsRev), next => null, scanned => Scanned}};
                        {error, _} = E ->
                            E;
                        {ok, From, Body, ChunkNext} ->
                            Left = ?LF_HITS - Count,
                            {Found, Resume} = lf_hits(Body, From, Dir, Pat, Re, Sev, Left),
                            Count1 = Count + length(Found),
                            HitsRev1 = lists:reverse(Found, HitsRev),
                            Scanned1 = Scanned + byte_size(Body),
                            case Resume of
                                {more, ResumeAt} ->
                                    {ok, #{hits => lists:reverse(HitsRev1), next => ResumeAt,
                                           scanned => Scanned1}};
                                done ->
                                    lf_scan(P, Size, ChunkNext, Dir, Pat, Re, Sev, Deadline,
                                            Scanned1, Count1, HitsRev1)
                            end
                    end
            end
    end.

%% Finds up to Max matching lines in Body without splitting non-matching lines.
%% Returns {HitsInDirOrder, done | {more, ResumePos}}.
lf_hits(_Body, _From, _Dir, _Pat, _Re, _MaxSev, Max) when Max =< 0 ->
    {[], done};
lf_hits(Body, From, Dir, Pat, Re, MaxSev, Max) ->
    RangesRev = lf_match_lines(Body, Pat, 0, byte_size(Body), []),
    Ordered = case Dir of
                  back -> RangesRev;
                  fwd -> lists:reverse(RangesRev)
              end,
    lf_take_hits(Ordered, Body, From, Dir, Re, MaxSev, Max, []).

lf_match_lines(_Body, _Pat, Cursor, Size, Acc) when Cursor >= Size ->
    Acc;
lf_match_lines(Body, Pat, Cursor, Size, Acc) ->
    case binary:match(Body, Pat, [{scope, {Cursor, Size - Cursor}}]) of
        nomatch ->
            Acc;
        {P, _Len} ->
            Start = case lf_last_nl(Body, P - 1) of
                        nomatch -> 0;
                        I -> I + 1
                    end,
            {End, NextCursor} =
                case binary:match(Body, <<"\n">>, [{scope, {P, Size - P}}]) of
                    {Q, 1} -> {Q, Q + 1};
                    nomatch -> {Size, Size}
                end,
            lf_match_lines(Body, Pat, NextCursor, Size, [{Start, End} | Acc])
    end.

lf_take_hits([], _Body, _From, _Dir, _Re, _MaxSev, _Left, Acc) ->
    {lists:reverse(Acc), done};
lf_take_hits([{Start, End} | Rest], Body, From, Dir, Re, MaxSev, Left, Acc) ->
    Line = binary:part(Body, Start, End - Start),
    Hdr = case lf_header(Line, Re) of
              {ok, H} -> H;
              none -> none
          end,
    Entry = lf_entry(From + Start, Hdr, [Line]),
    case lf_level_ok(Entry, MaxSev) of
        true when Left =:= 1 ->
            case Rest of
                [] ->
                    {lists:reverse([Entry | Acc]), done};
                _ ->
                    Resume = case Dir of
                                 fwd -> From + min(byte_size(Body), End + 1);
                                 back -> From + Start
                             end,
                    {lists:reverse([Entry | Acc]), {more, Resume}}
            end;
        true ->
            lf_take_hits(Rest, Body, From, Dir, Re, MaxSev, Left - 1, [Entry | Acc]);
        false ->
            lf_take_hits(Rest, Body, From, Dir, Re, MaxSev, Left, Acc)
    end.

lf_level_ok(_E, ?SEV_ALL) -> true;
lf_level_ok(#{level := null}, _MaxSev) -> false;
lf_level_ok(#{level := L}, MaxSev) -> severity(L) =< MaxSev.

%%--------------------------------------------------------------------
%% Memory allocators
%%--------------------------------------------------------------------

%% Block (used) and carrier (reserved) sizes per alloc_util allocator,
%% summed over its instances. Handles both the OTP 22 format
%% ({blocks_size, Cur, Max, MaxEver}) and the typed blocks of OTP 23+.
alloc_info() ->
    Allocs = try erlang:system_info(alloc_util_allocators) catch _:_ -> [] end,
    #{allocators => [A || A <- [alloc_row(T) || T <- Allocs], A =/= undefined],
      memory_total => erlang:memory(total)}.

alloc_row(Type) ->
    case catch erlang:system_info({allocator_sizes, Type}) of
        Instances when is_list(Instances), Instances =/= [] ->
            Zero = #{mbcs_blocks => 0, mbcs_carriers => 0, sbcs_blocks => 0,
                     sbcs_carriers => 0, carriers_max => 0},
            Sums = lists:foldl(fun alloc_instance/2, Zero, Instances),
            #{mbcs_blocks := MB, mbcs_carriers := MC, sbcs_blocks := SB, sbcs_carriers := SC} = Sums,
            Sums#{type => Type,
                  instances => length(Instances),
                  blocks => MB + SB,
                  carriers => MC + SC};
        _ ->
            undefined
    end.

alloc_instance({instance, _, Sections}, Acc) when is_list(Sections) ->
    lists:foldl(fun alloc_section/2, Acc, Sections);
alloc_instance(_, Acc) ->
    Acc.

alloc_section({Kind, Data}, Acc) when is_list(Data) ->
    Prefix = case Kind of
                 sbcs -> sbcs;
                 mbcs -> mbcs;
                 mbcs_pool -> mbcs;
                 _ -> skip
             end,
    case Prefix of
        skip ->
            Acc;
        _ ->
            BS = blocks_size(Data),
            {CS, CMax} = case lists:keyfind(carriers_size, 1, Data) of
                             {carriers_size, C, _, Max} -> {C, Max};
                             {carriers_size, C} -> {C, C};
                             _ -> {0, 0}
                         end,
            {BK, CK} = case Prefix of
                           sbcs -> {sbcs_blocks, sbcs_carriers};
                           mbcs -> {mbcs_blocks, mbcs_carriers}
                       end,
            Acc#{BK := maps:get(BK, Acc) + BS,
                 CK := maps:get(CK, Acc) + CS,
                 carriers_max := maps:get(carriers_max, Acc) + CMax}
    end;
alloc_section(_, Acc) ->
    Acc.

blocks_size(Data) ->
    case lists:keyfind(blocks_size, 1, Data) of
        {blocks_size, BS, _, _} -> BS;
        {blocks_size, BS} -> BS;
        false ->
            case lists:keyfind(blocks, 1, Data) of
                {blocks, Typed} when is_list(Typed) ->
                    lists:sum([typed_size(Info) || {_, Info} <- Typed]);
                _ -> 0
            end
    end.

typed_size(Info) when is_list(Info) ->
    case lists:keyfind(size, 1, Info) of
        {size, S, _, _} -> S;
        {size, S} -> S;
        _ -> 0
    end;
typed_size(_) ->
    0.

%%--------------------------------------------------------------------
%% Diagnosis: health check and window Top N
%%
%% Both run only when the user asks, one at a time per node, in a
%% low-priority worker with a heap cap. A guard process kills the worker
%% when it takes too long, when the caller goes away (the tool timed out)
%% or when the tool node disconnects, so the worst outcome is a failed
%% check. Only bounded results are kept, and the per-binary `binary` list
%% is read in a separate capped helper.
%%--------------------------------------------------------------------

-define(DIAG, eobs_agent_diag).
-define(DIAG_CHECK_HEAP_WORDS, 4000000).
-define(DIAG_CHECK_MS, 30000).
%% The window keeps every process's start values; refuse beyond this.
-define(DIAG_MAX_PROCS, 500000).
-define(DIAG_WINDOW_HEAP_WORDS, 16000000).
-define(DIAG_TOP, 20).
-define(DIAG_LIST, 10).
%% How long the health check watches the run queue and stuck processes.
-define(DIAG_SAMPLES, 5).
-define(DIAG_SAMPLE_MS, 400).
-define(DIAG_STUCK_CANDIDATES, 5000).
-define(DIAG_STUCK_REDS, 100).
%% Fewer waiting messages than this is not reported as stuck.
-define(DIAG_STUCK_QUEUE, 10).
-define(DIAG_BIN_WARN, (50 * ?MB)).
-define(DIAG_BIN_CRIT, (200 * ?MB)).
%% Heap cap of the binary scan helper (one list entry per binary read),
%% and how many over-the-cap processes it skips before giving up.
-define(DIAG_BIN_HEAP_WORDS, 2000000).
-define(DIAG_BIN_RESTARTS, 3).
-define(MB, (1024 * 1024)).

%% Health check: a list of findings, each with a level (ok | warn | crit |
%% skip), the thresholds used and the processes or tables involved. The
%% tool turns ids and numbers into readable text.
diag_check(Owner) ->
    diag_run(Owner, max(?DIAG_CHECK_HEAP_WORDS, recon_heap_words()), ?DIAG_CHECK_MS, fun check/0).

%% Top N of processes by growth of reductions, memory and message queue
%% over a window of Seconds (1..60).
diag_window(Owner, Seconds) ->
    S = clamp(Seconds, 1, 60),
    diag_run(Owner, ?DIAG_WINDOW_HEAP_WORDS, S * 1000 + 30000, fun() -> window(S) end).

diag_run(Owner, HeapWords, Timeout, Fun) ->
    Caller = self(),
    {Guard, Ref} = spawn_monitor(fun() -> diag_guard(Caller, Owner, HeapWords, Timeout, Fun) end),
    receive
        {'DOWN', Ref, process, Guard, {shutdown, Reply}} -> Reply;
        {'DOWN', Ref, process, Guard, Reason} -> {error, {failed, fmt(Reason)}}
    end.

diag_guard(Caller, Owner, HeapWords, Timeout, Fun) ->
    try register(?DIAG, self())
    catch error:badarg -> exit({shutdown, {error, busy}})
    end,
    CRef = erlang:monitor(process, Caller),
    case monitor_owner(Owner) of
        true -> ok;
        false -> exit({shutdown, {error, owner_down}})
    end,
    {Worker, WRef} = spawn_opt(fun() -> exit({shutdown, Fun()}) end,
                               [monitor, {priority, low},
                                {max_heap_size, #{size => HeapWords, kill => true,
                                                  error_logger => false}}]),
    receive
        {'DOWN', WRef, process, Worker, {shutdown, Result}} -> exit({shutdown, Result});
        {'DOWN', WRef, process, Worker, killed} -> exit({shutdown, {error, too_big}});
        {'DOWN', WRef, process, Worker, Reason} -> exit({shutdown, {error, {failed, fmt(Reason)}}});
        {'DOWN', CRef, process, Caller, _} -> exit(Worker, kill), exit(normal);
        {nodedown, Owner} -> exit(Worker, kill), exit(normal)
    after Timeout ->
        exit(Worker, kill),
        exit({shutdown, {error, timeout}})
    end.

check() ->
    Started = erlang:monotonic_time(millisecond),
    Total = erlang:memory(total),
    WordSize = erlang:system_info(wordsize),
    Scheds = erlang:system_info(schedulers_online),
    MemWarn = min(Total div 20, 100 * ?MB),
    MemCrit = Total div 5,
    Dist0 = dist_queues(),
    {Queues, Mems, Candidates, Backlogged} = scan_processes(MemWarn),
    BinHolders = bin_scan(),
    RunQueues = sample_run_queue(?DIAG_SAMPLES, []),
    Stuck = stuck(Candidates),
    Dist1 = dist_queues(),
    Checks =
        [limit_check(process_count, erlang:system_info(process_count),
                     erlang:system_info(process_limit)),
         limit_check(port_count, erlang:system_info(port_count), erlang:system_info(port_limit)),
         limit_check(atom_count, safe(fun() -> erlang:system_info(atom_count) end),
                     safe(fun() -> erlang:system_info(atom_limit) end)),
         limit_check(ets_count, length(ets:all()), safe(fun() -> erlang:system_info(ets_limit) end)),
         queue_check(Queues, Backlogged),
         memory_check(Mems, Total, MemWarn, MemCrit),
         ets_check(Total, WordSize),
         binary_check(Total),
         run_queue_check(RunQueues, Scheds),
         stuck_check(Stuck),
         bin_holder_check(BinHolders),
         dist_check(Dist0, Dist1)],
    {ok, #{checks => Checks,
           memory_total => Total,
           process_count => erlang:system_info(process_count),
           took_ms => erlang:monotonic_time(millisecond) - Started}}.

finding(Id, Level, Fields) ->
    maps:merge(#{id => Id, level => Level, value => null, warn => null, crit => null,
                 items => []}, Fields).

level(V, _W, C) when V >= C -> crit;
level(V, W, _C) when V >= W -> warn;
level(_, _, _) -> ok.

%% Count against limit; thresholds are percentages.
limit_check(Id, Count, Limit) when is_integer(Count), is_integer(Limit), Limit > 0 ->
    finding(Id, level(Count * 100 div Limit, 70, 90),
            #{value => Count, limit => Limit, warn => 70, crit => 90});
limit_check(Id, _, _) ->
    finding(Id, skip, #{}).

%% One pass over all processes reading only cheap items. Keeps the longest
%% queues, the biggest processes over the warn threshold and the
%% processes with a backlog (stuck candidates), all bounded.
scan_processes(MemWarn) ->
    lists:foldl(
      fun(Pid, {Qs, Ms, Cand, Backlogged} = Acc) ->
              case erlang:process_info(Pid, [memory, message_queue_len, reductions]) of
                  [{memory, M}, {message_queue_len, Q}, {reductions, R}] ->
                      Qs1 = case Q >= 1000 of
                                true -> top_add(Q, Pid, Q, Qs);
                                false -> Qs
                            end,
                      Ms1 = case M >= MemWarn of
                                true -> top_add(M, Pid, M, Ms);
                                false -> Ms
                            end,
                      Cand1 = case Q >= ?DIAG_STUCK_QUEUE of
                                  true -> top_add(Q, Pid, {R, Q}, Cand);
                                  false -> Cand
                              end,
                      {Qs1, Ms1, Cand1, Backlogged + (if Q >= 1000 -> 1; true -> 0 end)};
                  _ ->
                      Acc
              end
      end,
      {top_new(?DIAG_LIST), top_new(?DIAG_LIST), top_new(?DIAG_STUCK_CANDIDATES), 0},
      erlang:processes()).

%% Refc binary bytes referenced by each process. Reading `binary` copies
%% one list entry per binary into the reader, so the scan runs in a helper
%% with a heap cap that notes where it is in a table. A process holding so
%% many binaries that the helper hits the cap is itself a finding: it is
%% recorded as such and a new helper carries on after it.
bin_scan() ->
    bin_scan(?DIAG_LIST, ?DIAG_BIN_WARN, []).

%% The K processes referencing the most refc binary bytes, at least Min,
%% leaving out the Own processes. Too-many-binaries entries come first,
%% with the value too_many.
bin_scan(K, Min, Own) ->
    Tab = ets:new(eobs_diag_bin, [public]),
    Pids = [P || P <- lists:sort(erlang:processes()), P =/= self(), not lists:member(P, Own)],
    Top = bin_scan(Pids, Tab, {Min, top_new(K)}, 0),
    ets:delete(Tab),
    Top.

bin_scan(Pids, Tab, {Min, Top}, Restarts) ->
    process_flag(trap_exit, true),
    ets:insert(Tab, [{top, Top}, {at, none}]),
    {H, Ref} = spawn_opt(fun() -> exit({shutdown, bin_scan_loop(Pids, Tab, Min, Top)}) end,
                         [monitor, {priority, low},
                          {max_heap_size, #{size => bin_heap_words(Pids), kill => true,
                                            error_logger => false}}]),
    try link(H) catch error:noproc -> ok end,
    receive
        {'DOWN', Ref, process, H, {shutdown, Done}} ->
            flush_exit(H),
            Done;
        {'DOWN', Ref, process, H, killed} when Restarts < ?DIAG_BIN_RESTARTS ->
            flush_exit(H),
            [{top, Top1}] = ets:lookup(Tab, top),
            case ets:lookup(Tab, at) of
                [{at, P}] when is_pid(P) ->
                    Rest = lists:dropwhile(fun(X) -> X =< P end, Pids),
                    bin_scan(Rest, Tab, {Min, top_add(1 bsl 60, P, too_many, Top1)}, Restarts + 1);
                _ ->
                    Top1
            end;
        {'DOWN', Ref, process, H, _} ->
            flush_exit(H),
            [{top, Top1}] = ets:lookup(Tab, top),
            Top1
    end.

flush_exit(Pid) ->
    receive {'EXIT', Pid, _} -> ok after 0 -> ok end.

%% The helper also holds its copy of the pid list (a cons cell per pid),
%% which must not count against the binaries it reads.
bin_heap_words(Pids) ->
    ?DIAG_BIN_HEAP_WORDS + 4 * length(Pids).

bin_scan_loop([], _Tab, _Min, Top) ->
    Top;
bin_scan_loop([P | Rest], Tab, Min, Top) ->
    ets:insert(Tab, {at, P}),
    {Held, _} = bin_held(P),
    case Held >= Min of
        true ->
            Top1 = top_add(Held, P, Held, Top),
            ets:insert(Tab, {top, Top1}),
            bin_scan_loop(Rest, Tab, Min, Top1);
        false ->
            bin_scan_loop(Rest, Tab, Min, Top)
    end.

%% {Bytes, Count} of the refc binaries a process references.
bin_held(P) ->
    case erlang:process_info(P, binary) of
        {binary, L} -> lists:foldl(fun({_, Size, _}, {B, N}) -> {B + Size, N + 1} end, {0, 0}, L);
        _ -> {0, 0}
    end.

%% Bounded best-K collection keyed on {Score, Pid}.
top_new(K) -> {K, gb_trees:empty()}.

top_add(Score, Pid, Val, {K, T} = Top) ->
    Key = {Score, Pid},
    case gb_trees:size(T) < K of
        true -> {K, gb_trees:insert(Key, Val, T)};
        false ->
            {Worst, _} = gb_trees:smallest(T),
            case Key > Worst of
                true -> {_, _, T1} = gb_trees:take_smallest(T), {K, gb_trees:insert(Key, Val, T1)};
                false -> Top
            end
    end.

%% [{Pid, Val}], best first.
top_list({_, T}) -> [{Pid, Val} || {{_, Pid}, Val} <- lists:reverse(gb_trees:to_list(T))].

%% Waits between samples, so this is also the window stuck() looks at.
sample_run_queue(0, Acc) ->
    Acc;
sample_run_queue(N, Acc) ->
    timer:sleep(?DIAG_SAMPLE_MS),
    sample_run_queue(N - 1, [erlang:statistics(run_queue) | Acc]).

%% Processes that had messages waiting at the scan and did not get to
%% handle any since then. Reading some process_info items costs the target
%% a reduction or so (and other viewers may be reading too), hence the
%% small allowance.
stuck(Candidates) ->
    lists:filtermap(
      fun({Pid, {R0, Q0}}) ->
              case erlang:process_info(Pid, [reductions, message_queue_len]) of
                  [{reductions, R}, {message_queue_len, Q}] when R - R0 < ?DIAG_STUCK_REDS, Q >= Q0 ->
                      {true, {Pid, Q}};
                  _ -> false
              end
      end, top_list(Candidates)).

proc_item(Pid, Value) ->
    CF = case erlang:process_info(Pid, current_function) of
             {current_function, C} -> bin(mfa(C));
             _ -> null
         end,
    #{pid => ref_bin(Pid), name => registered_name(Pid),
      initial_call => bin(initial_call(Pid)), current_function => CF, value => Value}.

queue_check(Queues, Backlogged) ->
    Items = [proc_item(P, Q) || {P, Q} <- top_list(Queues)],
    Max = lists:max([0 | [Q || {_, Q} <- top_list(Queues)]]),
    finding(message_queue, level(Max, 1000, 10000),
            #{value => Backlogged, warn => 1000, crit => 10000, items => Items}).

memory_check(Mems, Total, Warn, Crit) ->
    List = top_list(Mems),
    Max = lists:max([0 | [M || {_, M} <- List]]),
    finding(process_memory, level(Max, Warn, Crit),
            #{value => Max, total => Total, warn => Warn, crit => Crit,
              items => [proc_item(P, M) || {P, M} <- List]}).

ets_check(Total, WordSize) ->
    Warn = Total div 10,
    Crit = Total * 3 div 10,
    Sizes = lists:filtermap(
              fun(T) ->
                      case ets:info(T, memory) of
                          W when is_integer(W), W * WordSize >= Warn -> {true, {W * WordSize, T}};
                          _ -> false
                      end
              end, ets:all()),
    Big = lists:sublist(lists:reverse(lists:sort(Sizes)), ?DIAG_LIST),
    Max = lists:max([0 | [B || {B, _} <- Big]]),
    finding(ets_memory, level(Max, Warn, Crit),
            #{value => Max, total => Total, warn => Warn, crit => Crit,
              items => [#{table => table_id(T), name => ets:info(T, name),
                          owner => ref_bin(ets:info(T, owner)), value => B}
                        || {B, T} <- Big]}).

binary_check(Total) ->
    Binary = erlang:memory(binary),
    Pct = Binary * 100 div max(1, Total),
    finding(binary_memory, level(Pct, 40, 60),
            #{value => Pct, bytes => Binary, total => Total, warn => 40, crit => 60}).

run_queue_check(Samples, Scheds) ->
    Min = lists:min(Samples),
    finding(run_queue, level(Min, Scheds + 1, Scheds * 4 + 1),
            #{value => Min, max => lists:max(Samples), schedulers => Scheds,
              warn => Scheds + 1, crit => Scheds * 4 + 1}).

stuck_check(Stuck) ->
    Sorted = lists:reverse(lists:keysort(2, Stuck)),
    Max = lists:max([0 | [Q || {_, Q} <- Sorted]]),
    Level = case Sorted of
                [] -> ok;
                _ when Max >= 1000 -> crit;
                _ -> warn
            end,
    finding(stuck, Level,
            #{value => length(Sorted), seconds => ?DIAG_SAMPLES * ?DIAG_SAMPLE_MS / 1000,
              items => [proc_item(P, Q) || {P, Q} <- lists:sublist(Sorted, ?DIAG_LIST)]}).

%% Processes referencing a lot of refc binary data: typical of a binary
%% leak, where a long-lived process keeps slices of big binaries alive.
bin_holder_check(Holders) ->
    List = top_list(Holders),
    Level = case [B || {_, B} <- List] of
                [too_many | _] -> crit;
                [B | _] -> level(B, ?DIAG_BIN_WARN, ?DIAG_BIN_CRIT);
                [] -> ok
            end,
    finding(binary_holders, Level,
            #{value => length(List), warn => ?DIAG_BIN_WARN, crit => ?DIAG_BIN_CRIT,
              items => [proc_item(P, case B of too_many -> null; _ -> B end) || {P, B} <- List]}).

%% Bytes waiting in each distribution port's output queue.
dist_queues() ->
    Ctrl = try erlang:system_info(dist_ctrl) catch _:_ -> [] end,
    [{N, Q} || {N, P} <- Ctrl, is_port(P), {queue_size, Q} <- [erlang:port_info(P, queue_size)]].

%% A connection counts when its queue was over the threshold at both ends
%% of the check.
dist_check(Before, After) ->
    Warn = ?MB,
    Crit = 64 * ?MB,
    Busy = [{N, Q} || {N, Q} <- After, Q >= Warn,
                      case lists:keyfind(N, 1, Before) of
                          {_, Q0} -> Q0 >= Warn;
                          false -> false
                      end],
    Max = lists:max([0 | [Q || {_, Q} <- Busy]]),
    finding(dist_queue, level(Max, Warn, Crit),
            #{value => length(Busy), warn => Warn, crit => Crit,
              items => [#{node => N, value => Q} || {N, Q} <- lists:reverse(lists:keysort(2, Busy))]}).

window(Seconds) ->
    case erlang:system_info(process_count) > ?DIAG_MAX_PROCS of
        true ->
            {error, too_many_processes};
        false ->
            T0 = erlang:monotonic_time(millisecond),
            Start = lists:sort(snapshot()),
            timer:sleep(Seconds * 1000),
            End = lists:sort(snapshot()),
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            Tops0 = {top_new(?DIAG_TOP), top_new(?DIAG_TOP), top_new(?DIAG_TOP)},
            {{Reds, Mem, Queue}, New, Gone} = window_merge(Start, End, Tops0, 0, 0),
            Items = fun(Top) -> [window_item(P, D) || {P, D} <- top_list(Top)] end,
            {ok, #{seconds => Elapsed / 1000,
                   process_count => length(End),
                   created => New,
                   exited => Gone,
                   reductions => Items(Reds),
                   memory => Items(Mem),
                   message_queue_len => Items(Queue)}}
    end.

%% Our own diagnosis processes are left out.
snapshot() ->
    Own = [self(), whereis(?DIAG)],
    lists:foldl(
      fun(Pid, Acc) ->
              case lists:member(Pid, Own) of
                  true -> Acc;
                  false ->
                      case erlang:process_info(Pid, [reductions, memory, message_queue_len]) of
                          [{reductions, R}, {memory, M}, {message_queue_len, Q}] -> [{Pid, R, M, Q} | Acc];
                          _ -> Acc
                      end
              end
      end, [], erlang:processes()).

%% Walks both pid-sorted snapshots together. A process created during the
%% window grows from zero.
window_merge([{P, R0, M0, Q0} | S], [{P, R1, M1, Q1} | E], Tops, New, Gone) ->
    window_merge(S, E, window_add(P, R1 - R0, M1 - M0, Q1 - Q0, {R1, M1, Q1}, false, Tops), New, Gone);
window_merge([{P0, _, _, _} | S], [{P1, _, _, _} | _] = E, Tops, New, Gone) when P0 < P1 ->
    window_merge(S, E, Tops, New, Gone + 1);
window_merge(S, [{P, R1, M1, Q1} | E], Tops, New, Gone) ->
    window_merge(S, E, window_add(P, R1, M1, Q1, {R1, M1, Q1}, true, Tops), New + 1, Gone);
window_merge(S, [], Tops, New, Gone) ->
    {Tops, New, Gone + length(S)}.

%% Reading process_info costs a process a reduction or so, which is not
%% growth worth showing.
window_add(P, DR, DM, DQ, Now, New, {Reds, Mem, Queue}) ->
    Add = fun(D, Min, Top) when D >= Min -> top_add(D, P, {D, Now, New}, Top);
             (_, _, Top) -> Top
          end,
    {Add(DR, ?DIAG_STUCK_REDS, Reds), Add(DM, 1, Mem), Add(DQ, 1, Queue)}.

window_item(Pid, {Delta, {R, M, Q}, New}) ->
    (proc_item(Pid, Delta))#{reductions => R, memory => M, message_queue_len => Q,
                             new => New, alive => is_process_alive(Pid)}.

%%--------------------------------------------------------------------
%% Recon toolbox
%%
%% Counterparts of recon's proc_count/2, bin_leak/1, inet_count/2 and
%% inet_window/3, port_types/0, the recon_alloc fragmentation views and
%% scheduler_usage/1, built into the agent so the target needs no recon.
%% Everything that walks processes or sockets, or waits, goes through
%% diag_run/4: one run per node (shared with the diagnosis), a low-priority
%% worker with a heap cap, a timeout, and killed when the tool goes away.
%% Only the best N (at most 50) are kept while walking.
%%--------------------------------------------------------------------

-define(RECON_MAX_N, 50).
-define(RECON_SCAN_MS, 30000).
%% bin_leak: refused above this many processes; the guard's timeout, and
%% the earlier point where the run stops and reports what it has.
-define(RECON_LEAK_MAX_PROCS, 200000).
-define(RECON_LEAK_MS, 120000).
-define(RECON_LEAK_DEADLINE_MS, 100000).
%% Processes not garbage collected: a long queue (the collection would
%% wait behind it) or a huge heap (one collection blocks a scheduler).
-define(RECON_LEAK_QUEUE, 10000).
-define(RECON_LEAK_MEMORY, (1024 * ?MB)).
%% Pause after this many processes, and how long one collection may take.
-define(RECON_LEAK_BATCH, 100).
-define(RECON_LEAK_GC_MS, 5000).
-define(RECON_LEAK_RESTARTS, 50).
-define(RECON_SKIPPED, 20).
-define(RECON_MAX_SOCKETS, 100000).
-define(RECON_SOCKET_HEAP_WORDS, 16000000).
-define(RECON_PORT_TYPES, 100).

%% Top N processes by Attribute: memory | reductions | message_queue_len |
%% total_heap_size (bytes) | binary_memory (refc binary bytes referenced;
%% a process with too many binaries to read comes first, without a value).
recon_proc_count(Owner, Attribute, N) ->
    Attr = case lists:member(Attribute, [memory, reductions, message_queue_len,
                                         total_heap_size, binary_memory]) of
               true -> Attribute;
               false -> memory
           end,
    K = clamp(N, 1, ?RECON_MAX_N),
    diag_run(Owner, recon_heap_words(), ?RECON_SCAN_MS, fun() -> proc_count(Attr, K) end).

%% Room for a few copies of the process list (two words per pid), on top
%% of a fixed allowance.
recon_heap_words() ->
    ?DIAG_CHECK_HEAP_WORDS + 8 * erlang:system_info(process_count).

proc_count(Attr, K) ->
    case erlang:system_info(process_count) > ?DIAG_MAX_PROCS of
        true ->
            {error, too_many_processes};
        false ->
            T0 = erlang:monotonic_time(millisecond),
            Own = [self(), whereis(?DIAG)],
            Top = case Attr of
                      binary_memory -> bin_scan(K, 1, Own);
                      _ -> proc_scan(Attr, K, Own)
                  end,
            Word = erlang:system_info(wordsize),
            {ok, #{attribute => Attr,
                   n => K,
                   process_count => erlang:system_info(process_count),
                   took_ms => erlang:monotonic_time(millisecond) - T0,
                   items => [proc_count_item(Attr, P, V, Word) || {P, V} <- top_list(Top)]}}
    end.

proc_scan(Attr, K, Own) ->
    lists:foldl(
      fun(Pid, Top) ->
              case erlang:process_info(Pid, Attr) of
                  {Attr, V} ->
                      case lists:member(Pid, Own) of
                          true -> Top;
                          false -> top_add(V, Pid, V, Top)
                      end;
                  _ ->
                      Top
              end
      end, top_new(K), erlang:processes()).

proc_count_item(Attr, Pid, V, Word) ->
    Value = case V of
                too_many -> null;
                _ when Attr =:= total_heap_size -> V * Word;
                _ -> V
            end,
    Info = case erlang:process_info(Pid, [memory, reductions, message_queue_len, total_heap_size]) of
               [{memory, M}, {reductions, R}, {message_queue_len, Q}, {total_heap_size, H}] ->
                   #{memory => M, reductions => R, message_queue_len => Q, total_heap_size => H * Word};
               undefined ->
                   #{memory => null, reductions => null, message_queue_len => null,
                     total_heap_size => null}
           end,
    maps:merge(proc_item(Pid, Value), Info#{too_many => V =:= too_many}).

%% Garbage-collects the processes one at a time and reports the N whose
%% collection freed the most refc binary bytes: a process keeping
%% binaries alive only because it has not collected for a long time is
%% the typical binary leak. Only processes referencing refc binaries are
%% collected (others cannot free any); processes with a long queue or a
%% huge heap are skipped and listed.
recon_bin_leak(Owner, N) ->
    K = clamp(N, 1, ?RECON_MAX_N),
    diag_run(Owner, recon_heap_words(), ?RECON_LEAK_MS, fun() -> bin_leak(K) end).

bin_leak(K) ->
    case erlang:system_info(process_count) > ?RECON_LEAK_MAX_PROCS of
        true ->
            {error, too_many_processes};
        false ->
            T0 = erlang:monotonic_time(millisecond),
            Before = erlang:memory(binary),
            Own = [self() | [whereis(R) || R <- [?DIAG, ?HOLDER, ?TRACER, ?LOGS]]],
            Pids = [P || P <- lists:sort(erlang:processes()), not lists:member(P, Own)],
            Tab = ets:new(eobs_recon_leak, [public]),
            ets:insert(Tab, [{top, top_new(K)}, {skipped, [], 0}, {gc, 0}]),
            Complete = leak_run(Pids, Tab, T0 + ?RECON_LEAK_DEADLINE_MS, 0),
            [{top, Top}] = ets:lookup(Tab, top),
            [{skipped, Skipped, SkippedCount}] = ets:lookup(Tab, skipped),
            [{gc, Gc}] = ets:lookup(Tab, gc),
            ets:delete(Tab),
            {ok, #{n => K,
                   process_count => length(Pids),
                   gc_count => Gc,
                   skipped => SkippedCount,
                   complete => Complete,
                   took_ms => erlang:monotonic_time(millisecond) - T0,
                   binary_before => Before,
                   binary_after => erlang:memory(binary),
                   items => [leak_item(P, V) || {P, V} <- top_list(Top)],
                   skipped_items => [(proc_item(P, V))#{reason => R}
                                     || {P, R, V} <- lists:reverse(Skipped)]}}
    end.

%% Like bin_scan/4: the reading runs in a capped helper that notes where
%% it is, and a process with too many binaries to read is skipped. Returns
%% whether every process was visited.
leak_run(Pids, Tab, Deadline, Restarts) ->
    process_flag(trap_exit, true),
    ets:insert(Tab, {at, none}),
    Parent = self(),
    {H, Ref} = spawn_opt(fun() -> exit({shutdown, leak_loop(Pids, Tab, Parent, Deadline, 1)}) end,
                         [monitor, {priority, low},
                          {max_heap_size, #{size => bin_heap_words(Pids), kill => true,
                                            error_logger => false}}]),
    try link(H) catch error:noproc -> ok end,
    receive
        {'DOWN', Ref, process, H, {shutdown, Done}} ->
            flush_exit(H),
            Done;
        {'DOWN', Ref, process, H, killed} when Restarts < ?RECON_LEAK_RESTARTS ->
            flush_exit(H),
            case ets:lookup(Tab, at) of
                [{at, P}] when is_pid(P) ->
                    leak_skip(Tab, P, too_many_binaries, null),
                    Rest = lists:dropwhile(fun(X) -> X =< P end, Pids),
                    leak_run(Rest, Tab, Deadline, Restarts + 1);
                _ ->
                    false
            end;
        {'DOWN', Ref, process, H, _} ->
            flush_exit(H),
            false
    end.

leak_loop([], _Tab, _Parent, _Deadline, _I) ->
    true;
leak_loop([P | Rest], Tab, Parent, Deadline, I) ->
    case I rem ?RECON_LEAK_BATCH of
        0 -> timer:sleep(1);
        _ -> ok
    end,
    case erlang:monotonic_time(millisecond) < Deadline andalso is_process_alive(Parent) of
        false ->
            false;
        true ->
            ets:insert(Tab, {at, P}),
            leak_one(P, Tab),
            leak_loop(Rest, Tab, Parent, Deadline, I + 1)
    end.

leak_one(P, Tab) ->
    case erlang:process_info(P, [memory, message_queue_len]) of
        [{memory, _}, {message_queue_len, Q}] when Q > ?RECON_LEAK_QUEUE ->
            leak_skip(Tab, P, long_queue, Q);
        [{memory, M}, _] when M > ?RECON_LEAK_MEMORY ->
            leak_skip(Tab, P, big_heap, M);
        [_, _] ->
            case bin_held(P) of
                {_, 0} ->
                    ok;
                {BB, BC} ->
                    case leak_gc(P) of
                        ok ->
                            {AB, AC} = bin_held(P),
                            ets:update_counter(Tab, gc, 1),
                            case BB - AB of
                                Freed when Freed > 0 ->
                                    [{top, Top}] = ets:lookup(Tab, top),
                                    ets:insert(Tab, {top, top_add(Freed, P, {BB, AB, BC, AC}, Top)});
                                _ ->
                                    ok
                            end;
                        timeout ->
                            leak_skip(Tab, P, gc_timeout, null);
                        gone ->
                            ok
                    end
            end;
        undefined ->
            ok
    end.

%% A collection is a request the process serves when it gets to run, so
%% one that is suspended or stuck in a long call must not hold up the run.
leak_gc(P) ->
    Ref = make_ref(),
    case catch erlang:garbage_collect(P, [{async, Ref}]) of
        async ->
            receive
                {garbage_collect, Ref, true} -> ok;
                {garbage_collect, Ref, false} -> gone
            after ?RECON_LEAK_GC_MS ->
                timeout
            end;
        _ ->
            gone
    end.

leak_skip(Tab, P, Reason, Value) ->
    [{skipped, List, N}] = ets:lookup(Tab, skipped),
    List1 = case N < ?RECON_SKIPPED of
                true -> [{P, Reason, Value} | List];
                false -> List
            end,
    ets:insert(Tab, {skipped, List1, N + 1}).

leak_item(Pid, {BB, AB, BC, AC}) ->
    (proc_item(Pid, BB - AB))#{before_bytes => BB, after_bytes => AB,
                               before_count => BC, after_count => AC, freed => BB - AB}.

%% Top N inet sockets by Attribute (recv_oct | send_oct | recv_cnt |
%% send_cnt | oct | cnt): totals since each socket was opened, or with
%% Seconds > 0 the growth during a window of that length.
recon_inet_count(Owner, Attribute, N, Seconds) ->
    Attr = case lists:member(Attribute, [recv_oct, send_oct, recv_cnt, send_cnt, oct, cnt]) of
               true -> Attribute;
               false -> oct
           end,
    K = clamp(N, 1, ?RECON_MAX_N),
    S = clamp(Seconds, 0, 60),
    diag_run(Owner, ?RECON_SOCKET_HEAP_WORDS, S * 1000 + ?RECON_SCAN_MS,
             fun() -> inet_count(Attr, K, S) end).

inet_count(Attr, K, Seconds) ->
    T0 = erlang:monotonic_time(millisecond),
    case inet_snapshot() of
        {error, _} = Error ->
            Error;
        {ok, Start} when Seconds =:= 0 ->
            Top = lists:foldl(fun({P, St}, T) -> inet_add(Attr, P, St, St, false, T) end,
                              top_new(K), Start),
            inet_result(Attr, K, 0.0, length(Start), Top);
        {ok, Start} ->
            timer:sleep(Seconds * 1000),
            case inet_snapshot() of
                {error, _} = Error ->
                    Error;
                {ok, End} ->
                    Elapsed = (erlang:monotonic_time(millisecond) - T0) / 1000,
                    Prev = maps:from_list(Start),
                    Top = lists:foldl(
                            fun({P, St}, T) ->
                                    case Prev of
                                        #{P := St0} -> inet_add(Attr, P, inet_delta(St, St0), St, false, T);
                                        _ -> inet_add(Attr, P, St, St, true, T)
                                    end
                            end, top_new(K), End),
                    inet_result(Attr, K, Elapsed, length(End), Top)
            end
    end.

inet_result(Attr, K, Elapsed, Count, Top) ->
    {ok, #{attribute => Attr, n => K, seconds => Elapsed, socket_count => Count,
           items => [inet_item(P, V) || {P, V} <- top_list(Top)]}}.

%% [{Port, {RecvOct, SendOct, RecvCnt, SendCnt}}] of every inet socket.
inet_snapshot() ->
    Ports = [P || P <- erlang:ports(), inet_port(P)],
    case length(Ports) > ?RECON_MAX_SOCKETS of
        true -> {error, too_many_sockets};
        false -> {ok, [{P, St} || P <- Ports, {ok, St} <- [inet_stats(P)]]}
    end.

inet_port(Port) ->
    case erlang:port_info(Port, name) of
        {name, Name} -> inet_port_name(Name);
        undefined -> false
    end.

inet_stats(Port) ->
    case catch inet:getstat(Port, [recv_oct, send_oct, recv_cnt, send_cnt]) of
        {ok, L} ->
            Get = fun(K) -> proplists:get_value(K, L, 0) end,
            {ok, {Get(recv_oct), Get(send_oct), Get(recv_cnt), Get(send_cnt)}};
        _ ->
            error
    end.

%% Counters are unsigned and may wrap on 32-bit platforms.
inet_delta({A1, B1, C1, D1}, {A0, B0, C0, D0}) ->
    {max(0, A1 - A0), max(0, B1 - B0), max(0, C1 - C0), max(0, D1 - D0)}.

inet_add(Attr, Port, Delta, Now, New, Top) ->
    top_add(inet_value(Attr, Delta), Port, {inet_value(Attr, Delta), Now, New}, Top).

inet_value(recv_oct, {RO, _, _, _}) -> RO;
inet_value(send_oct, {_, SO, _, _}) -> SO;
inet_value(recv_cnt, {_, _, RC, _}) -> RC;
inet_value(send_cnt, {_, _, _, SC}) -> SC;
inet_value(oct, {RO, SO, _, _}) -> RO + SO;
inet_value(cnt, {_, _, RC, SC}) -> RC + SC.

%% The four counters are the socket's current totals; value is the
%% attribute's total or growth.
inet_item(Port, {Value, {RO, SO, RC, SC}, New}) ->
    Owner = case erlang:port_info(Port, connected) of
                {connected, O} -> O;
                undefined -> undefined
            end,
    #{port => ref_bin(Port),
      type => case erlang:port_info(Port, name) of
                  {name, "tcp_inet"} -> tcp;
                  {name, "udp_inet"} -> udp;
                  {name, "sctp_inet"} -> sctp;
                  _ -> null
              end,
      owner => ref_bin(Owner),
      owner_name => case is_pid(Owner) of
                        true -> registered_name(Owner);
                        false -> null
                    end,
      local => addr(catch inet:sockname(Port)),
      remote => addr(catch inet:peername(Port)),
      recv_oct => RO, send_oct => SO, recv_cnt => RC, send_cnt => SC,
      value => Value,
      new => New}.

%% Number of ports per driver name. One cheap port_info per port.
recon_port_types() ->
    Counts = lists:foldl(
               fun(P, Acc) ->
                       case erlang:port_info(P, name) of
                           {name, Name} -> maps:update_with(Name, fun(C) -> C + 1 end, 1, Acc);
                           undefined -> Acc
                       end
               end, #{}, erlang:ports()),
    Sorted = lists:reverse(lists:keysort(2, maps:to_list(Counts))),
    {Shown, Rest} = case length(Sorted) > ?RECON_PORT_TYPES of
                        true -> lists:split(?RECON_PORT_TYPES, Sorted);
                        false -> {Sorted, []}
                    end,
    Other = case Rest of
                [] -> [];
                _ -> [#{name => <<"other">>, count => lists:sum([C || {_, C} <- Rest])}]
            end,
    #{total => lists:sum([C || {_, C} <- Sorted]),
      types => [#{name => port_type_name(N), count => C} || {N, C} <- Shown] ++ Other}.

%% Spawned ports are named after their command, which need not be valid
%% Unicode.
port_type_name(Name) ->
    case catch unicode:characters_to_binary(Name) of
        B when is_binary(B) -> B;
        _ -> fmt(Name)
    end.

%% Per allocator instance: block (used) and carrier (reserved) bytes and
%% counts of the multiblock and singleblock carriers, usage (blocks /
%% carriers), average block size and the sbcs/mbcs carrier ratio; plus
%% the segment cache hit rate of each mseg_alloc instance. Current values.
recon_alloc() ->
    Allocs = try erlang:system_info(alloc_util_allocators) catch _:_ -> [] end,
    #{allocators => lists:append([alloc_instances(T) || T <- Allocs]),
      cache_hit_rates => cache_hit_rates(),
      memory_total => erlang:memory(total)}.

alloc_instances(Type) ->
    case catch erlang:system_info({allocator, Type}) of
        Instances when is_list(Instances) ->
            [alloc_frag(Type, N, Sections) || {instance, N, Sections} <- Instances, is_list(Sections)];
        _ ->
            []
    end.

alloc_frag(Type, N, Sections) ->
    %% The carrier pool's carriers are multiblock carriers, as in alloc_info/0.
    {MB, MBC, MC, MCC} = carrier_stats([mbcs, mbcs_pool], Sections),
    {SB, SBC, SC, SCC} = carrier_stats([sbcs], Sections),
    #{type => Type, instance => N,
      mbcs_blocks => MB, mbcs_carriers => MC, sbcs_blocks => SB, sbcs_carriers => SC,
      mbcs_block_count => MBC, sbcs_block_count => SBC,
      mbcs_carrier_count => MCC, sbcs_carrier_count => SCC,
      mbcs_usage => ratio(MB, MC), sbcs_usage => ratio(SB, SC),
      mbcs_avg_block => ratio(MB, MBC), sbcs_avg_block => ratio(SB, SBC),
      sbcs_to_mbcs => ratio(SCC, MCC)}.

%% {BlocksSize, BlockCount, CarriersSize, CarrierCount} summed over the
%% given sections.
carrier_stats(Kinds, Sections) ->
    lists:foldl(
      fun({Kind, Data}, {BS, BC, CS, CC} = Acc) when is_list(Data) ->
              case lists:member(Kind, Kinds) of
                  true -> {BS + blocks_size(Data), BC + blocks_count(Data),
                           CS + current(carriers_size, Data), CC + current(carriers, Data)};
                  false -> Acc
              end;
         (_, Acc) ->
              Acc
      end, {0, 0, 0, 0}, Sections).

%% OTP 22: {blocks, Cur, LastMax, Max}; OTP 23+: {blocks, [{Type, [{count, ...}, ...]}]}.
blocks_count(Data) ->
    case lists:keyfind(blocks, 1, Data) of
        {blocks, Typed} when is_list(Typed) ->
            lists:sum([typed_count(Info) || {_, Info} <- Typed]);
        {blocks, C} when is_integer(C) -> C;
        {blocks, C, _, _} when is_integer(C) -> C;
        _ -> 0
    end.

typed_count(Info) when is_list(Info) ->
    current(count, Info);
typed_count(_) ->
    0.

current(Key, Data) ->
    case lists:keyfind(Key, 1, Data) of
        {Key, V, _, _} when is_integer(V) -> V;
        {Key, V} when is_integer(V) -> V;
        _ -> 0
    end.

ratio(_, 0) -> null;
ratio(A, B) -> A / B.

%% A segment allocation not served by creating a new segment came from
%% the cache (recon_alloc:cache_hit_rates/0).
cache_hit_rates() ->
    case catch erlang:system_info({allocator, mseg_alloc}) of
        Instances when is_list(Instances) ->
            [cache_hit_rate(N, Props) || {instance, N, Props} <- Instances, is_list(Props)];
        _ ->
            []
    end.

cache_hit_rate(N, Props) ->
    Calls = case lists:keyfind(calls, 1, Props) of
                {calls, C} -> C;
                false ->
                    case lists:keyfind(memkind, 1, Props) of
                        {memkind, MK} when is_list(MK) ->
                            case lists:keyfind(calls, 1, MK) of
                                {calls, C} -> C;
                                false -> []
                            end;
                        _ -> []
                    end
            end,
    Alloc = call_count(mseg_alloc, Calls),
    Hits = max(0, Alloc - call_count(mseg_create, Calls)),
    #{instance => N, hits => Hits, calls => Alloc, ratio => ratio(Hits, Alloc)}.

call_count(Name, Calls) ->
    case lists:keyfind(Name, 1, Calls) of
        {Name, Giga, Count} -> Giga * 1000000000 + Count;
        _ -> 0
    end.

%% Utilisation of each scheduler over Seconds (1..30). The holder keeps
%% scheduler_wall_time enabled, and turns it off with the tool's leaving.
recon_scheduler_usage(Owner, Seconds) ->
    S = clamp(Seconds, 1, 30),
    ensure_holder(Owner),
    diag_run(Owner, ?DIAG_CHECK_HEAP_WORDS, S * 1000 + 10000, fun() -> scheduler_usage(S) end).

scheduler_usage(Seconds) ->
    %% Enable scheduler_wall_time on this worker too so another tool
    %% disconnecting mid-measurement cannot disable it underneath us.
    _ = erlang:system_flag(scheduler_wall_time, true),
    T0 = erlang:monotonic_time(millisecond),
    W0 = swt(),
    timer:sleep(Seconds * 1000),
    W1 = swt(),
    Elapsed = (erlang:monotonic_time(millisecond) - T0) / 1000,
    case is_list(W0) andalso is_list(W1) of
        false ->
            {error, {failed, <<"scheduler_wall_time is not available">>}};
        true ->
            Normal = erlang:system_info(schedulers),
            DirtyCpu = erlang:system_info(dirty_cpu_schedulers),
            Type = fun(Id) when Id =< Normal -> normal;
                      (Id) when Id =< Normal + DirtyCpu -> dirty_cpu;
                      (_) -> dirty_io
                   end,
            {ok, #{seconds => Elapsed,
                   schedulers => [#{id => Id, type => Type(Id),
                                    usage => case T1 - T00 of
                                                 DT when DT =< 0 -> 0.0;
                                                 DT -> min(1.0, max(0.0, (A1 - A0) / DT))
                                             end}
                                  || {Id, A1, T1} <- W1,
                                     {_, A0, T00} <- [lists:keyfind(Id, 1, W0)]]}}
    end.

%%--------------------------------------------------------------------
%% Distribution
%%--------------------------------------------------------------------

%% The node's distribution connections, for the cluster view.
dist_info() ->
    Ctrl = try erlang:system_info(dist_ctrl) catch _:_ -> [] end,
    Hidden = nodes(hidden),
    #{node => node(),
      alive => is_alive(),
      connections => [dist_conn(N, C, lists:member(N, Hidden)) || {N, C} <- Ctrl]}.

dist_conn(Node, Ctrl, Hidden) ->
    {In, Out} = case Ctrl of
                    P when is_port(P) ->
                        {stat(erlang:port_info(P, input)), stat(erlang:port_info(P, output))};
                    _ -> {null, null}
                end,
    #{node => Node, hidden => Hidden, input => In, output => Out}.

stat({_, N}) -> N;
stat(_) -> null.

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
