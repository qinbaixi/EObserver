%% @doc Collector code that EObserver loads into the observed node.
%%
%% This module is shipped to the target with code:load_binary/3, so it
%% must only depend on kernel/stdlib APIs available in OTP 22 and must not
%% reference any other EObserver module. Everything returned is plain
%% Erlang terms; the tool node is responsible for turning them into JSON.
-module(eobs_agent).

-export([version/0, node_summary/0, load_sample/1]).
-export([process_list/3, process_detail/1, process_state/2, process_kill/1,
         process_send/2]).
-export([app_list/0, app_tree/1]).
-export([port_list/0, port_detail/1, port_close/1, inet_list/0, socket_list/0]).
-export([ets_list/0, ets_rows/2, mnesia_list/0, mnesia_rows/2]).
-export([alloc_info/0, dist_info/0]).

%% Bump whenever the exported API or return shapes change, so the tool
%% replaces an older copy that is still loaded on the target.
-define(VERSION, 7).

%% Long-lived helper process on the observed node. It keeps
%% scheduler_wall_time enabled, builds process lists while holding the
%% per-viewer reduction snapshots in its own heap (no copying), and exits
%% when the observing tool node goes away.
-define(HOLDER, eobs_agent_srv).
%% Snapshots of sessions not seen for this long are dropped.
-define(SNAP_TTL_MS, 120000).
%% Caps on what we ship back for a single term.
-define(TERM_DEPTH, 30).
-define(TERM_CHARS, 8000).
-define(MAX_MESSAGES, 100).
%% Supervision tree limits: children listed per supervisor, total nodes,
%% and how long a busy supervisor may take to answer.
-define(TREE_MAX_CHILDREN, 200).
-define(TREE_MAX_NODES, 3000).
-define(SUP_TIMEOUT, 3000).
%% Table viewer: chars per cell, and how many objects a search may scan.
-define(CELL_CHARS, 300).
-define(SEARCH_SCAN, 200000).

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
            {Pid, Ref} = spawn_monitor(fun() -> holder(Parent, Owner) end),
            receive
                {Pid, ready} -> erlang:demonitor(Ref, [flush]), ok;
                {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok
            end;
        _ ->
            ok
    end.

holder(Parent, Owner) ->
    try register(?HOLDER, self()) of
        true ->
            erlang:system_flag(scheduler_wall_time, true),
            erlang:monitor_node(Owner, true),
            Parent ! {self(), ready},
            holder_loop(Owner, #{})
    catch
        error:badarg -> Parent ! {self(), ready}
    end.

holder_loop(Owner, Snaps) ->
    receive
        {nodedown, Owner} ->
            ok;
        stop ->
            ok;
        {From, Ref, {process_list, Session, Opts}} ->
            {Reply, Snaps1} = try do_process_list(Session, Opts, Snaps)
                              catch C:R -> {{error, {C, R}}, Snaps}
                              end,
            From ! {Ref, Reply},
            holder_loop(Owner, Snaps1)
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
    Filter = string:lowercase(unicode:characters_to_list(maps:get(filter, Opts, <<>>))),
    Sort = maps:get(sort, Opts, reds),
    NeedName = Filter =/= "" orelse Sort =:= name,
    Items = collect_processes(Prev, NeedName, Sort =:= memory),
    Snap = maps:from_list([{Pid, R} || {Pid, R, _, _, _, _} <- Items]),
    Matching = case Filter of
                   "" -> Items;
                   _ -> [I || I <- Items, matches(I, Filter)]
               end,
    Offset = maps:get(offset, Opts, 0),
    Limit = min(maps:get(limit, Opts, 50), 500),
    Page = page(sort_key(Sort), maps:get(order, Opts, desc), Offset, Limit, Matching),
    Reply = #{total => length(Matching),
              process_count => length(Items),
              has_delta => Prev =/= undefined,
              rows => [row(I) || I <- Page]},
    {Reply, Snaps#{Session => {Now, Snap}}}.

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
page(Key, Order, Offset, Limit, Items) ->
    K = Offset + Limit,
    Keyed = [{Key(I), I} || I <- Items],
    Ordered = case K =< 2000 andalso length(Keyed) > 4 * K of
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
    Has = fun(Text) -> string:str(string:to_lower(Text), Filter) > 0 end,
    HasAtom = fun(A) -> is_atom(A) andalso Has(atom_to_list(A)) end,
    HasMfa = fun({M, F, _}) -> HasAtom(M) orelse HasAtom(F);
                (_) -> false
             end,
    (Name =/= undefined andalso HasAtom(Name))
        orelse HasMfa(info(Pid, initial_call, undefined))
        orelse HasMfa(info(Pid, current_function, undefined))
        orelse (looks_like_pid(Filter) andalso Has(pid_to_list(Pid))).

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
%% with depth and length caps, so pids print as local pids and a huge
%% state never crosses the network.
process_detail(PidBin) ->
    Pid = to_pid(PidBin),
    Keys = [registered_name, status, initial_call, current_function, current_stacktrace,
            message_queue_len, links, monitors, monitored_by, trap_exit, priority,
            group_leader, reductions, memory, total_heap_size, heap_size, stack_size,
            garbage_collection, dictionary, error_handler],
    case erlang:process_info(Pid, Keys) of
        undefined ->
            {error, not_found};
        Info0 ->
            Info = maps:from_list(Info0),
            #{dictionary := Dict, message_queue_len := QLen} = Info,
            Name = case maps:get(registered_name, Info) of [] -> undefined; N -> N end,
            {ok, #{pid => PidBin,
                   name => Name,
                   status => maps:get(status, Info),
                   initial_call => bin(initial_call(Pid)),
                   current_function => bin(mfa(maps:get(current_function, Info))),
                   stacktrace => [format_frame(F) || F <- maps:get(current_stacktrace, Info)],
                   message_queue_len => QLen,
                   messages => messages(Pid, QLen),
                   links => [ref_bin(L) || L <- maps:get(links, Info)],
                   monitors => [monitor_bin(M) || M <- maps:get(monitors, Info)],
                   monitored_by => [ref_bin(M) || M <- maps:get(monitored_by, Info)],
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
                   dictionary => [#{key => fmt(K), value => fmt(V)} || {K, V} <- Dict],
                   word_size => erlang:system_info(wordsize)}}
    end.

%% Reading the whole queue copies it, so only short queues are shown.
messages(Pid, QLen) when QLen =< ?MAX_MESSAGES ->
    case erlang:process_info(Pid, messages) of
        {messages, Msgs} -> [fmt(M) || M <- Msgs];
        undefined -> []
    end;
messages(_Pid, _QLen) ->
    truncated.

process_state(PidBin, Timeout) ->
    Pid = to_pid(PidBin),
    try sys:get_state(Pid, Timeout) of
        State -> {ok, fmt(State)}
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, not_found};
        _:Reason -> {error, fmt(Reason)}
    end.

process_kill(PidBin) ->
    exit(to_pid(PidBin), kill),
    ok.

process_send(PidBin, Msg) ->
    to_pid(PidBin) ! Msg,
    ok.

%%--------------------------------------------------------------------
%% Applications
%%--------------------------------------------------------------------

app_list() ->
    Running = application:which_applications(),
    RunningNames = [A || {A, _, _} <- Running],
    Loaded = [{A, D, V} || {A, D, V} <- application:loaded_applications(),
                           not lists:member(A, RunningNames)],
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
                    {Tree, _} = sup_node(Root, App, supervisor, Mod, ?TREE_MAX_NODES),
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

sup_node(Pid, Id, Type, Mod, Budget) ->
    Base = #{pid => ref_bin(Pid),
             id => fmt(Id),
             name => registered_name(Pid),
             type => Type,
             module => Mod},
    case Type of
        supervisor when Budget > 0 ->
            case sup_call(Pid, which_children) of
                {ok, Children} ->
                    Total = length(Children),
                    Shown = lists:sublist(Children, ?TREE_MAX_CHILDREN),
                    {Nodes, Left} = lists:foldl(
                                      fun(Child, {Acc, B}) -> child_node(Child, Acc, B) end,
                                      {[], Budget - 1}, Shown),
                    {Base#{children => lists:reverse(Nodes),
                           hidden => Total - length(Nodes)}, Left};
                {error, Reason} ->
                    {Base#{children => [], hidden => 0, error => fmt(Reason)}, Budget - 1}
            end;
        _ ->
            {Base#{children => [], hidden => 0}, Budget - 1}
    end.

child_node({_Id, _Child, _Type, _Mods}, Acc, Budget) when Budget =< 0 ->
    {Acc, Budget};
child_node({Id, Child, Type, Mods}, Acc, Budget) when is_pid(Child) ->
    Mod = case Mods of [M | _] -> M; _ -> Mods end,
    {Node, Left} = sup_node(Child, Id, Type, Mod, Budget),
    {[Node | Acc], Left};
child_node({Id, Child, Type, _Mods}, Acc, Budget) ->
    %% restarting or undefined (not running) children
    {[#{pid => null, id => fmt(Id), name => null, type => Type, module => null,
        status => Child, children => [], hidden => 0} | Acc], Budget - 1}.

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
            #{id => ref_bin(Port),
              name => bin(Name),
              registered_name => port_item(Port, registered_name, null),
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

port_detail(PortBin) ->
    Port = to_port(PortBin),
    case port_row(Port) of
        undefined ->
            {error, not_found};
        Row ->
            Links = [ref_bin(L) || L <- port_item(Port, links, [])],
            Monitors = [monitor_bin(M) || M <- port_item(Port, monitors, [])],
            Extra = case maps:get(inet, Row) of
                        true -> inet_info(Port);
                        false -> #{}
                    end,
            {ok, maps:merge(Row#{links => Links, monitors => Monitors,
                                 parallelism => port_item(Port, parallelism, false),
                                 locking => port_item(Port, locking, null)}, Extra)}
    end.

port_close(PortBin) ->
    try erlang:port_close(to_port(PortBin)) of
        true -> ok
    catch
        error:badarg -> {error, not_found}
    end.

%% gen_tcp / gen_udp / gen_sctp sockets (inet driver ports).
inet_list() ->
    [maps:merge(Row, inet_info(Port))
     || Port <- erlang:ports(),
        Row <- [port_row(Port)],
        Row =/= undefined, maps:get(inet, Row)].

inet_info(Port) ->
    Stats = case catch inet:getstat(Port, [recv_oct, send_oct, recv_cnt, send_cnt]) of
                {ok, S} -> maps:from_list(S);
                _ -> #{}
            end,
    #{local => addr(catch inet:sockname(Port)),
      remote => addr(catch inet:peername(Port)),
      protocol => case erlang:port_info(Port, name) of
                      {name, "tcp_inet"} -> tcp;
                      {name, "udp_inet"} -> udp;
                      {name, "sctp_inet"} -> sctp;
                      _ -> unknown
                  end,
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

addr({ok, {Ip, Port}}) when is_tuple(Ip) ->
    bin(inet:ntoa(Ip) ++ ":" ++ integer_to_list(Port));
addr({ok, #{addr := Ip, port := Port}}) when is_tuple(Ip) ->
    bin(inet:ntoa(Ip) ++ ":" ++ integer_to_list(Port));
addr({ok, #{path := Path}}) ->
    bin(io_lib:format("~ts", [Path]));
addr({ok, Other}) ->
    fmt(Other);
addr(_) ->
    null.

%%--------------------------------------------------------------------
%% ETS and Mnesia tables
%%--------------------------------------------------------------------

ets_list() ->
    Word = erlang:system_info(wordsize),
    [T || T <- [ets_row(Tab, Word) || Tab <- ets:all()], T =/= undefined].

ets_row(Tab, Word) ->
    case catch ets:info(Tab) of
        Info when is_list(Info) ->
            Owner = proplists:get_value(owner, Info),
            Name = proplists:get_value(name, Info),
            #{id => table_id(Tab),
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
              system => system_owner(Owner)};
        _ ->
            undefined
    end.

%% Tables owned by kernel/stdlib processes are hidden by default, as in
%% OTP's observer.
system_owner(Pid) when is_pid(Pid) ->
    case catch application:get_application(Pid) of
        {ok, App} -> lists:member(App, [kernel, stdlib]);
        _ -> false
    end;
system_owner(_) ->
    false.

table_id(Tab) when is_atom(Tab) -> atom_to_binary(Tab, utf8);
table_id(Tab) -> fmt(Tab).

%% Opts: id (from ets_list), offset, limit, search (binary).
ets_rows(IdBin, Opts) ->
    case find_ets(IdBin) of
        undefined ->
            {error, not_found};
        Tab ->
            case ets:info(Tab, protection) of
                private -> {error, private};
                _ -> {ok, read_rows(fun(Spec, N) -> ets:select(Tab, Spec, N) end,
                                    ets:info(Tab, size), ets:info(Tab, keypos), Opts)}
            end
    end.

find_ets(IdBin) ->
    Match = [T || T <- ets:all(), table_id(T) =:= IdBin],
    case Match of
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
                    Select = fun(Spec, N) -> mnesia_select(Tab, Spec, N) end,
                    Size = mnesia:table_info(Tab, size),
                    {ok, (read_rows(Select, Size, 2, Opts))#{attributes =>
                         [fmt(A) || A <- mnesia:table_info(Tab, attributes)]}};
                _ ->
                    {error, not_found}
            end
    end.

%% Paged read inside an activity, so it works for every storage type.
mnesia_select(Tab, Spec, N) ->
    case mnesia:activity(async_dirty,
                         fun() -> mnesia:select(Tab, Spec, N, read) end) of
        '$end_of_table' -> '$end_of_table';
        {Objs, Cont} -> {Objs, {mnesia_cont, Cont}}
    end.

mnesia_running() ->
    lists:keymember(mnesia, 1, application:which_applications())
        andalso (catch mnesia:system_info(is_running)) =:= yes.

%% Reads one page of objects via Select(MatchSpec, ChunkSize), which must
%% behave like ets:select/3. Without a search the page is reached by
%% skipping Offset objects; with a search every object is formatted and
%% matched, scanning at most SEARCH_SCAN objects.
read_rows(Select, Size, KeyPos, Opts) ->
    Offset = maps:get(offset, Opts, 0),
    Limit = min(maps:get(limit, Opts, 50), 500),
    Search = string:to_lower(unicode:characters_to_list(maps:get(search, Opts, <<>>))),
    Spec = [{'_', [], ['$_']}],
    {Objects, Matched, Scanned, Complete} =
        case Search of
            "" ->
                Objs = take(Select(Spec, 500), Offset, Limit),
                {Objs, Size, Offset + length(Objs), true};
            _ ->
                search(Select(Spec, 500), Search, Offset, Limit)
        end,
    Rows = [row_cells(O) || O <- Objects],
    #{rows => Rows,
      keypos => KeyPos,
      columns => lists:max([0 | [length(R) || R <- Rows]]),
      total => Matched,
      scanned => Scanned,
      complete => Complete}.

take(Chunk, Offset, Limit) ->
    take(Chunk, Offset, Limit, []).

take(_, _, 0, Acc) ->
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

search(Chunk, Search, Offset, Limit) ->
    search(Chunk, Search, Offset, Limit, [], 0, 0).

search('$end_of_table', _, _, _, Acc, Matched, Scanned) ->
    {lists:reverse(Acc), Matched, Scanned, true};
search(_, _, _, _, Acc, Matched, Scanned) when Scanned >= ?SEARCH_SCAN ->
    {lists:reverse(Acc), Matched, Scanned, false};
search({Objs, Cont}, Search, Offset, Limit, Acc0, Matched0, Scanned0) ->
    {Acc, Matched} =
        lists:foldl(
          fun(O, {A, M}) ->
                  Text = string:to_lower(lists:flatten(io_lib:format("~tP", [O, ?TERM_DEPTH]))),
                  case string:str(Text, Search) > 0 of
                      true when M >= Offset, M < Offset + Limit -> {[O | A], M + 1};
                      true -> {A, M + 1};
                      false -> {A, M}
                  end
          end, {Acc0, Matched0}, Objs),
    search(next(Cont), Search, Offset, Limit, Acc, Matched, Scanned0 + length(Objs)).

next('$end_of_table') -> '$end_of_table';
next({mnesia_cont, Cont}) ->
    case mnesia:activity(async_dirty, fun() -> mnesia:select(Cont) end) of
        '$end_of_table' -> '$end_of_table';
        {Objs, Cont1} -> {Objs, {mnesia_cont, Cont1}}
    end;
next(Cont) ->
    ets:select(Cont).

row_cells(Obj) when is_tuple(Obj) ->
    [cell(E) || E <- tuple_to_list(Obj)];
row_cells(Obj) ->
    [cell(Obj)].

cell(Term) ->
    Chars = lists:flatten(io_lib:format("~tP", [Term, ?TERM_DEPTH])),
    case length(Chars) > ?CELL_CHARS of
        true -> unicode:characters_to_binary(lists:sublist(Chars, ?CELL_CHARS) ++ " ...");
        false -> unicode:characters_to_binary(Chars)
    end.

to_port(Bin) when is_binary(Bin) ->
    list_to_port(binary_to_list(Bin)).

to_pid(Bin) when is_binary(Bin) ->
    list_to_pid(binary_to_list(Bin)).

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
mfa(Other) -> lists:flatten(io_lib:format("~p", [Other])).

fmt(Term) ->
    Chars = lists:flatten(io_lib:format("~tP", [Term, ?TERM_DEPTH])),
    case length(Chars) > ?TERM_CHARS of
        true -> unicode:characters_to_binary(lists:sublist(Chars, ?TERM_CHARS) ++ " ...");
        false -> unicode:characters_to_binary(Chars)
    end.

bin(Chars) -> unicode:characters_to_binary(Chars).

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
            BK = list_to_atom(atom_to_list(Prefix) ++ "_blocks"),
            CK = list_to_atom(atom_to_list(Prefix) ++ "_carriers"),
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
