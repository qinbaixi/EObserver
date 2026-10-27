%% @doc Crash dump views: overview with diagnosis, generic tables
%% (query/3), process detail, details of other objects, search.
%%
%% Everything is computed from the reader API in eobs_dump; derived data
%% (tables, sort orders, parsed sections) is memoised with
%% eobs_dump:cache/3, which only keeps results once the scan is done.
%% Kinds, parts and keys arrive as binaries and are never turned into
%% atoms. Results are JSON-encodable maps.
-module(eobs_dump_view).

-export([overview/1, query/3, process/2, process_part/5, detail/3, expand/2, search/2]).
-export([classify/2]).

-define(MAX_SECTION, (4 bsl 20)).    % bytes read for one small section
-define(MAX_PROC, (1 bsl 20)).       % bytes read for one =proc section
-define(TOP, 10).
-define(MAX_SEARCH, 50).
-define(MB, (1024 * 1024)).
-define(SCAN_TABLE_MAX, 100000). % processes tabulated while the scan runs

-define(KINDS, [<<"processes">>, <<"ports">>, <<"ets">>, <<"timers">>, <<"schedulers">>,
                <<"nodes">>, <<"modules">>, <<"funs">>, <<"atoms">>, <<"persistent_terms">>,
                <<"allocators">>, <<"memory">>, <<"allocated_areas">>, <<"hash_tables">>,
                <<"index_tables">>, <<"internal_tables">>]).

%% =====================================================================
%% Overview

overview(H) ->
    try do_overview(H)
    catch C:R:St ->
        logger:warning("crash dump overview failed: ~p:~p ~p", [C, R, St]),
        {error, parse_failed}
    end.

do_overview(H) ->
    Info = eobs_dump:info(H),
    G = general(H),
    Mem = memory_map(H),
    NProcs = eobs_dump:count(H, <<"proc">>),
    %% Whole-table work waits for the scan on very large dumps (it would
    %% be redone on every poll while scanning).
    Full = not big_scan(H),
    Top = case Full of
              true -> #{memory => top_procs(H, <<"memory">>, ?TOP),
                        mql => [R || R = #{mq := Q} <- top_procs(H, <<"mq">>, ?TOP), Q > 0]};
              false -> #{memory => [], mql => []}
          end,
    Reason = classify(maps:get(slogan, G, <<>>), H),
    Counts = #{processes => NProcs,
               ports => eobs_dump:count(H, <<"port">>),
               ets => eobs_dump:count(H, <<"ets">>),
               timers => eobs_dump:count(H, <<"timer">>),
               funs => eobs_dump:count(H, <<"fun">>),
               modules => eobs_dump:count(H, <<"mod">>),
               atoms => case maps:get(atoms, G, null) of
                            null -> null;
                            A -> A
                        end,
               nodes => eobs_dump:count(H, <<"visible_node">>)
                        + eobs_dump:count(H, <<"hidden_node">>)
                        + eobs_dump:count(H, <<"not_connected">>)},
    Limits = limits(H),
    Findings = findings(H, #{info => Info, general => G, memory => Mem, reason => Reason,
                             counts => Counts, limits => Limits, top => Top, full => Full}),
    #{file => Info,
      general => general_out(G),
      reason => Reason,
      counts => Counts,
      limits => maps:with([processes, ports, atoms, ets], Limits),
      memory => Mem,
      findings => Findings,
      top => Top}.

general_out(G) ->
    Extra = [#{key => K, value => V} || {K, V} <- maps:get(extra, G, [])],
    maps:merge(#{slogan => null, node => null, time => null, system_version => null,
                 compiled => null, taints => null, calling_thread => null},
               (maps:remove(extra, G))#{raw => Extra}).

%% =erl_crash_dump section plus node name, word size and dump version.
general(H) ->
    eobs_dump:cache(H, {eobs_view, general}, fun() -> do_general(H) end).

do_general(H) ->
    {Vsn, G0} = case eobs_dump:sections(H, <<"erl_crash_dump">>) of
                    [{V, Off, Len} | _] ->
                        case eobs_dump:read(H, Off, min(Len, ?MAX_SECTION)) of
                            {ok, Body} -> {V, eobs_dump_parse:general(Body)};
                            _ -> {V, #{}}
                        end;
                    [] -> {null, #{}}
                end,
    Node = case eobs_dump:sections(H, <<"node">>) of
               [{N, _, _} | _] when is_binary(N) -> eobs_dump_parse:unquote_atom(N);
               _ ->
                   case eobs_dump:count(H, <<"no_distribution">>) of
                       0 -> null;
                       _ -> <<"nonode@nohost">>
                   end
           end,
    SysVsn = maps:get(system_version, G0, null),
    Slogan = maps:get(slogan, G0, null),
    G0#{node => Node,
        dump_version => Vsn,
        word_size => eobs_dump_parse:word_size(SysVsn),
        otp_release => otp_release(SysVsn),
        slogan => case is_binary(Slogan) andalso byte_size(Slogan) > 65536 of
                      true -> <<(binary:part(Slogan, 0, 65536))/binary, "...">>;
                      false -> Slogan
                  end}.

otp_release(V) when is_binary(V) ->
    case re:run(V, "Erlang/OTP (\\d+)", [{capture, all_but_first, binary}]) of
        {match, [R]} -> R;
        _ -> null
    end;
otp_release(_) -> null.

word_size(H) -> maps:get(word_size, general(H), 8).

memory_map(H) ->
    case section_body(H, <<"memory">>, null) of
        {ok, Body} -> eobs_dump_parse:memory(Body);
        _ -> #{}
    end.

limits(H) ->
    Idx = maps:from_list([{Id, eobs_dump_parse:index_table(B)}
                          || {Id, B} <- section_bodies(H, <<"index_table">>)]),
    Lim = fun(Name) ->
                  case maps:get(Name, Idx, #{}) of
                      #{<<"limit">> := L} -> L;
                      _ -> null
                  end
          end,
    Used = fun(Name) ->
                   case maps:get(Name, Idx, #{}) of
                       #{<<"entries">> := E} -> E;
                       _ -> null
                   end
           end,
    #{processes => null, ports => null, ets => null,
      atoms => Lim(<<"atom_tab">>), atoms_used => Used(<<"atom_tab">>),
      modules => Lim(<<"module_code">>), modules_used => Used(<<"module_code">>),
      exports => Lim(<<"export_list">>), exports_used => Used(<<"export_list">>)}.

%% ---------------------------------------------------------------------
%% Reason: the slogan classified into a code + params.

classify(Slogan0, H) ->
    Slogan = string:trim(to_bin(Slogan0)),
    Short = clip(Slogan, 4096),
    case classify_text(Slogan) of
        {unknown, _} ->
            case halted(H) of
                true -> #{code => halt, params => #{text => Short}};
                false -> #{code => unknown, params => #{text => Short}}
            end;
        {Code, Params} ->
            #{code => Code, params => Params}
    end.

classify_text(S) ->
    Rules = [
        {"^(\\w+): Cannot (allocate|reallocate) (\\d+) bytes of memory \\(of type \"([^\"]*)\"\\)",
         fun([Alloc, Op, Size, Type]) ->
                 Code = case lists:member(Type, [<<"heap">>, <<"old_heap">>, <<"heap_frag">>]) of
                            true -> out_of_memory_heap;
                            false -> oom
                        end,
                 {Code, #{allocator => Alloc, op => Op, size => binary_to_integer(Size),
                          type => Type}}
         end},
        {"^Out of virtual memory in (\\w+)",
         fun([Fn]) -> {oom, #{allocator => Fn, op => null, size => null, type => null}} end},
        {"^Kernel pid terminated \\(([^)]*)\\) \\((.*)\\)$",
         fun([Name, Reason]) ->
                 {kernel_pid_terminated, #{process => Name, app => app_of(Reason),
                                           reason => clip(Reason, 4096)}}
         end},
        {"^Could not start kernel pid \\(([^)]*)\\) \\((.*)\\)$",
         fun([Name, Reason]) ->
                 {kernel_start_failed, #{process => Name, reason => clip(Reason, 4096)}}
         end},
        {"^(?:Runtime terminating during boot|init terminating in do_boot) \\((.*)\\)$",
         fun([Reason]) -> {init_terminating, #{reason => clip(Reason, 4096), phase => <<"boot">>}} end},
        {"^no more index entries in (\\w+) \\(max=(\\d+)\\)",
         fun([Tab, Max]) ->
                 What = case Tab of
                            <<"atom_tab">> -> <<"atoms">>;
                            <<"module_code">> -> <<"modules">>;
                            <<"export_list">> -> <<"exports">>;
                            Other -> Other
                        end,
                 {system_limit, #{what => What, max => binary_to_integer(Max)}}
         end},
        {"^System process (\\S+) terminated: (.*)$",
         fun([P, R]) -> {system_process_terminated, #{process => P, reason => clip(R, 4096)}} end},
        {"^Received SIGUSR1", fun(_) -> {sigusr1, #{}} end},
        {"^Crash dump requested by user", fun(_) -> {user_requested, #{}} end}
    ],
    classify_rules(S, Rules).

classify_rules(S, []) -> {unknown, S};
classify_rules(S, [{Re, Fun} | Rules]) ->
    case re:run(S, Re, [{capture, all_but_first, binary}, dotall, unicode]) of
        {match, Groups} ->
            try Fun(Groups)
            catch _:_ -> classify_rules(S, Rules)
            end;
        _ -> classify_rules(S, Rules)
    end.

app_of(Reason) ->
    case re:run(Reason, "application_start_failure,'?([A-Za-z0-9_@]+)'?",
                [{capture, all_but_first, binary}]) of
        {match, [App]} -> App;
        _ ->
            case re:run(Reason, "^\\{?'?([a-z][A-Za-z0-9_@]*)'?,", [{capture, all_but_first, binary}]) of
                {match, [_]} -> null;
                _ -> null
            end
    end.

%% erlang:halt/1,2 on the calling scheduler's stack means a deliberate halt.
halted(H) ->
    try halted1(H) catch _:_ -> false end.

halted1(H) ->
    case calling_scheduler(H) of
        #{} = S ->
            Stack = maps:get(stack, S, []),
            PC = maps:get(process_pc, S, <<>>),
            lists:any(fun(L) -> binary:match(L, <<"erlang:halt/">>) =/= nomatch end, [PC | Stack]);
        _ -> false
    end.

calling_scheduler(H) ->
    case maps:get(calling_thread, general(H), null) of
        <<"scheduler:", N/binary>> ->
            Tags = [<<"scheduler">>, <<"dirty_cpu_scheduler">>, <<"dirty_io_scheduler">>],
            case [B || T <- Tags, {ok, B} <- [section_body(H, T, N)]] of
                [Body | _] -> eobs_dump_parse:scheduler(Body);
                [] -> none
            end;
        _ -> none
    end.

%% ---------------------------------------------------------------------
%% Findings

findings(H, Ctx) ->
    Rules = [fun f_truncated/2, fun f_aborted/2, fun f_skipped/2, fun f_calling/2,
             fun f_oom_culprit/2, fun f_top_memory/2, fun f_mql/2, fun f_limits/2,
             fun f_big_ets/2, fun f_binary/2, fun f_states/2, fun f_many_procs/2,
             fun f_run_queue/2, fun f_port_queue/2],
    Fs0 = lists:append([try R(H, Ctx) catch _:_ -> [] end || R <- Rules]),
    %% The top process already reported as the OOM culprit is not repeated.
    Culprits = [P || #{code := garbage_collecting, params := #{pid := P}} <- Fs0],
    Fs = [F || F <- Fs0, not (maps:get(code, F) =:= top_memory_process
                              andalso lists:member(maps:get(pid, maps:get(params, F)), Culprits))],
    Order = #{critical => 0, warning => 1, info => 2},
    lists:sort(fun(#{level := A}, #{level := B}) -> maps:get(A, Order) =< maps:get(B, Order) end, Fs).

finding(Level, Code, Params, Target) ->
    #{level => Level, code => Code, params => Params, target => Target}.

proc_target(Pid) -> #{kind => process, key => Pid}.

f_truncated(_H, #{info := #{truncated := true} = I}) ->
    [finding(warning, truncated, #{at => maps:get(size, I, null),
                                   last_tag => maps:get(last_tag, I, null),
                                   last_id => maps:get(last_id, I, null)}, null)];
f_truncated(_, _) -> [].

f_aborted(H, _) ->
    [finding(warning, dump_aborted, #{reason => Id}, null)
     || {Id, _, _} <- lists:sublist(eobs_dump:sections(H, <<"abort">>), 1)].

f_skipped(_H, #{info := #{skipped := N}}) when is_integer(N), N > 0 ->
    [finding(info, skipped_sections, #{count => N}, null)];
f_skipped(_, _) -> [].

f_calling(H, _) ->
    case calling_scheduler(H) of
        #{process := P} = S when P =/= <<>> ->
            Fn = case maps:get(process_pc, S, null) of
                     null -> null;
                     PC -> eobs_dump_parse:mfa_of_pc(PC)
                 end,
            [finding(info, calling_process,
                     #{pid => P, scheduler => maps:get(calling_thread, general(H)),
                       state => maps:get(process_state, S, null), function => Fn},
                     proc_target(P))];
        _ -> []
    end.

%% Out of memory: processes caught garbage collecting are the usual culprits.
f_oom_culprit(H, #{reason := #{code := Code}, full := true})
  when Code =:= oom; Code =:= out_of_memory_heap ->
    T = proc_table(H),
    Garbing = [tab_id(T, I) || I <- first_bits(match_bits(T, <<"\tgarbing\t">>), maps:get(n, T), 5)],
    [begin
         Row = proc_row_by_id(H, Pid),
         finding(critical, garbage_collecting,
                 #{pid => Pid, name => maps:get(name, Row, null), memory => maps:get(memory, Row, null)},
                 proc_target(Pid))
     end || Pid <- lists:sublist(Garbing, 5)];
f_oom_culprit(_, _) -> [].

f_top_memory(_H, #{top := #{memory := [Top | _]}, memory := Mem, reason := #{code := Code}}) ->
    #{pid := Pid, memory := M} = Top,
    Total = maps:get(<<"total">>, Mem, 0),
    Share = case Total > 0 of
                true -> round(M * 1000 / Total) / 10;
                false -> null
            end,
    Oom = Code =:= oom orelse Code =:= out_of_memory_heap,
    Level = if
                is_number(Share), Share >= 30, Oom -> critical;
                is_number(Share), Share >= 10 -> warning;
                true -> info
            end,
    [finding(Level, top_memory_process,
             #{pid => Pid, name => maps:get(name, Top), memory => M, share => Share},
             proc_target(Pid))];
f_top_memory(_, _) -> [].

f_mql(_H, #{top := #{mql := Rows}}) ->
    [finding(case Q >= 100000 of true -> critical; false -> warning end,
             long_message_queue, #{pid => Pid, name => N, len => Q}, proc_target(Pid))
     || #{pid := Pid, name := N, mq := Q} <- lists:sublist(Rows, 5), Q >= 1000].

f_limits(_H, #{limits := L, counts := C}) ->
    AtomsUsed = case maps:get(atoms, C) of
                    null -> maps:get(atoms_used, L);
                    A -> A
                end,
    [F || {What, Used, Lim} <- [{atoms, AtomsUsed, maps:get(atoms, L)},
                                {modules, maps:get(modules_used, L), maps:get(modules, L)},
                                {exports, maps:get(exports_used, L), maps:get(exports, L)}],
          is_integer(Used), is_integer(Lim), Lim > 0, Used >= Lim * 0.8,
          F <- [finding(case Used >= Lim * 0.95 of true -> critical; false -> warning end,
                        limit_near, #{what => What, used => Used, limit => Lim}, null)]].

f_big_ets(H, #{memory := Mem, full := true}) ->
    Total = maps:get(<<"total">>, Mem, 0),
    Min = max(100 * ?MB, Total div 5),
    Rows = lists:sort(fun(#{memory := A}, #{memory := B}) -> A >= B end,
                      [R || R = #{memory := M} <- rows(H, <<"ets">>), is_integer(M), M >= Min]),
    [finding(warning, big_ets, #{table => T, name => N, owner => O, bytes => M, objects => Ob},
             #{kind => ets, key => T})
     || #{table := T, name := N, owner := O, memory := M, objects := Ob} <- lists:sublist(Rows, 3)];
f_big_ets(_, _) -> [].

f_binary(H, #{memory := #{<<"total">> := T, <<"binary">> := B}, full := Full})
  when T > 0, B * 10 >= T * 3 ->
    {Pid, Bin} = case Full of
                     true ->
                         case top_procs(H, <<"bin">>, 1) of
                             [#{pid := P, bin := PB}] -> {P, PB};
                             _ -> {null, null}
                         end;
                     false -> {null, null}
                 end,
    Target = case Pid of null -> null; _ -> proc_target(Pid) end,
    [finding(warning, binary_heavy, #{binary => B, total => T, share => round(B * 1000 / T) / 10,
                                      pid => Pid, pid_binary => Bin}, Target)];
f_binary(_, _) -> [].

f_states(H, #{counts := #{processes := N}, full := true}) when N > 0 ->
    Counts = state_counts(H),
    [finding(warning, many_processes_in_state, #{state => S, count => C, total => N}, null)
     || {S, C} <- maps:to_list(Counts),
        (S =:= <<"Scheduled">> andalso C >= max(50, N div 20))
            orelse (S =:= <<"Suspended">> andalso C >= 100)
            orelse (S =:= <<"Exiting">> andalso C >= 100)
            orelse (S =:= <<"Garbing">> andalso C >= 10)];
f_states(_, _) -> [].

f_many_procs(_H, #{counts := #{processes := N}}) when N >= 100000 ->
    [finding(info, many_processes, #{count => N}, null)];
f_many_procs(_, _) -> [].

f_run_queue(H, _) ->
    Rows = rows(H, <<"schedulers">>),
    [finding(warning, run_queue_long, #{scheduler => Id, type => T, length => L}, null)
     || #{id := Id, type := T, run_queue := L} <- Rows, is_integer(L), L >= 100].

f_port_queue(H, #{full := true}) ->
    [finding(warning, port_queue, #{port => P, name => N, bytes => Q}, #{kind => port, key => P})
     || #{id := P, name := N, queue := Q} <- rows(H, <<"ports">>), is_integer(Q), Q >= 10 * ?MB];
f_port_queue(_, _) -> [].

state_counts(H) ->
    maps:get(states, proc_table(H)).

%% =====================================================================
%% Generic tables

query(H, Kind, Opts) when is_binary(Kind) ->
    case lists:member(Kind, ?KINDS) of
        false -> {error, unknown_kind};
        true ->
            try do_query(H, Kind, norm_opts(Opts))
            catch C:R:St ->
                logger:warning("crash dump query ~ts failed: ~p:~p ~p", [Kind, C, R, St]),
                {error, parse_failed}
            end
    end;
query(_, _, _) ->
    {error, unknown_kind}.

norm_opts(Opts) when is_map(Opts) ->
    Get = fun(K, D) -> maps:get(K, Opts, maps:get(atom_to_binary(K), Opts, D)) end,
    Order = case Get(order, desc) of
                asc -> asc;
                <<"asc">> -> asc;
                _ -> desc
            end,
    Sort = case Get(sort, null) of
               S when is_binary(S), S =/= <<>> -> S;
               _ -> null
           end,
    Filter = case Get(filter, <<>>) of
                 F when is_binary(F) -> string:lowercase(string:trim(F));
                 _ -> <<>>
             end,
    #{offset => clamp(Get(offset, 0), 0, 1 bsl 40),
      limit => clamp(Get(limit, 50), 0, 1000),
      sort => Sort, order => Order, filter => Filter};
norm_opts(_) ->
    norm_opts(#{}).

clamp(V, Lo, Hi) when is_integer(V) -> max(Lo, min(Hi, V));
clamp(_, Lo, _) -> Lo.

do_query(H, <<"processes">>, Opts) -> proc_query(H, Opts);
do_query(H, <<"atoms">>, Opts) -> atom_query(H, Opts);
do_query(H, <<"persistent_terms">>, Opts) -> pt_query(H, Opts);
do_query(H, Kind, Opts) ->
    Cols = columns(Kind),
    page(Cols, rows(H, Kind), Opts, default_sort(Kind)).

%% Sort, filter and page a list of row maps.
page(Cols, Rows, #{offset := Off, limit := Lim, sort := Sort0, order := Order, filter := F},
     DefaultSort) ->
    Sortable = [K || #{key := K, sortable := true} <- Cols],
    Sort = case Sort0 =/= null andalso [K || K <- Sortable, atom_to_binary(K) =:= Sort0] of
               [K | _] -> K;
               _ -> DefaultSort
           end,
    TextKeys = [K || #{key := K, type := T} <- Cols, lists:member(T, [text, pid, port, term])],
    Filtered = case F of
                   <<>> -> Rows;
                   _ -> [R || R <- Rows, row_matches(R, TextKeys, F)]
               end,
    Sorted = case Sort of
                 null -> Filtered;
                 _ ->
                     Asc = lists:sort(fun(A, B) -> cmp(sort_val(A, Sort), sort_val(B, Sort)) end,
                                      Filtered),
                     case Order of
                         asc -> Asc;
                         desc -> lists:reverse(Asc)
                     end
             end,
    #{total => length(Sorted), columns => Cols, rows => slice(Sorted, Off, Lim)}.

slice(L, Off, _) when Off >= length(L) -> [];
slice(L, Off, Lim) -> lists:sublist(L, Off + 1, Lim).

row_matches(Row, Keys, F) ->
    lists:any(fun(K) ->
                      case maps:get(K, Row, null) of
                          V when is_binary(V) -> contains(V, F);
                          #{text := T} -> contains(T, F);
                          _ -> false
                      end
              end, Keys).

contains(V, F) ->
    binary:match(string:lowercase(V), F) =/= nomatch.

sort_val(Row, K) ->
    case maps:get(K, Row, null) of
        #{text := T} -> T;
        V when is_binary(V) ->
            case id_key(V) of
                none -> string:lowercase(V);
                Key -> Key
            end;
        V -> V
    end.

%% null sorts first in asc; numbers before binaries.
cmp(null, _) -> true;
cmp(_, null) -> false;
cmp(A, B) -> A =< B.

%% Pids/ports/refs sort numerically: "<0.10.0>" -> {id, [0,10,0]}.
id_key(<<"<", _/binary>> = V) -> id_nums(V);
id_key(<<"#Port<", _/binary>> = V) -> id_nums(V);
id_key(_) -> none.

id_nums(V) ->
    case re:run(V, "^(?:#Port)?<(\\d+)\\.(\\d+)(?:\\.(\\d+))?>$", [{capture, all_but_first, binary}]) of
        {match, Ns} -> {id, [binary_to_integer(N) || N <- Ns, N =/= <<>>]};
        _ -> none
    end.

default_sort(<<"ports">>) -> id;
default_sort(<<"ets">>) -> memory;
default_sort(<<"timers">>) -> time_left;
default_sort(<<"modules">>) -> current_size;
default_sort(<<"funs">>) -> refc;
default_sort(<<"allocators">>) -> carriers_size;
default_sort(<<"hash_tables">>) -> null;
default_sort(<<"index_tables">>) -> null;
default_sort(<<"memory">>) -> null;
default_sort(<<"allocated_areas">>) -> null;
default_sort(_) -> null.

col(Key, Type) -> #{key => Key, type => Type, sortable => true}.
col(Key, Type, Sortable) -> #{key => Key, type => Type, sortable => Sortable}.

columns(<<"processes">>) ->
    [col(pid, pid), col(name, text), col(state, text), col(init, text), col(current, text),
     col(reds, int), col(memory, bytes), col(mq, int), col(heap, bytes), col(bin, bytes)];
columns(<<"ports">>) ->
    [col(id, port), col(name, text), col(state, text), col(type, text), col(controls, text),
     col(connected, pid), col(slot, int), col(input, bytes), col(output, bytes), col(queue, bytes)];
columns(<<"ets">>) ->
    [col(table, text), col(name, text), col(owner, pid), col(type, text), col(protection, text),
     col(objects, int), col(memory, bytes)];
columns(<<"timers">>) ->
    [col(owner, pid), col(message, text), col(time_left, ms)];
columns(<<"schedulers">>) ->
    [col(id, int), col(type, text), col(process, pid), col(port, port), col(run_queue, int),
     col(port_queue, int), col(sleep, text)];
columns(<<"nodes">>) ->
    [col(channel, int), col(name, text), col(type, text), col(controller, text),
     col(creation, text), col(links, int), col(monitors, int), col(monitored_by, int),
     col(error, text)];
columns(<<"modules">>) ->
    [col(name, text), col(current_size, bytes), col(old_size, bytes)];
columns(<<"funs">>) ->
    [col(module, text), col(uniq, int), col(index, int), col(address, text), col(refc, int)];
columns(<<"atoms">>) ->
    [col(index, int), col(name, text, false)];
columns(<<"persistent_terms">>) ->
    [col(key, term), col(value, term, false)];
columns(<<"allocators">>) ->
    [col(name, text), col(instances, int), col(blocks_size, bytes), col(carriers_size, bytes),
     col(usage, int)];
columns(<<"memory">>) ->
    [col(key, text), col(value, bytes)];
columns(<<"allocated_areas">>) ->
    [col(key, text), col(allocated, bytes), col(used, bytes)];
columns(<<"hash_tables">>) ->
    [col(name, text), col(size, int), col(used, int), col(objs, int), col(depth, int)];
columns(<<"index_tables">>) ->
    [col(name, text), col(size, int), col(limit, int), col(entries, int)];
columns(<<"internal_tables">>) ->
    [col(name, text), col(type, text), col(objects, int), col(memory, bytes)].

%% All rows of a small kind, memoised.
rows(H, Kind) ->
    eobs_dump:cache(H, {eobs_view, rows, Kind}, fun() -> build_rows(H, Kind) end).

build_rows(H, <<"ports">>) ->
    [port_row(Id, S) || {Id, S} <- summaries_all(H, <<"port">>)];
build_rows(H, <<"ets">>) ->
    WS = word_size(H),
    [ets_row(Id, S, WS) || {Id, S} <- summaries_all(H, <<"ets">>)];
build_rows(H, <<"timers">>) ->
    [#{owner => Id, message => maps:get(msg, S, null), time_left => maps:get(left, S, null)}
     || {Id, S} <- summaries_all(H, <<"timer">>)];
build_rows(H, <<"nodes">>) ->
    [node_row(T, Id, S) || T <- [<<"visible_node">>, <<"hidden_node">>, <<"not_connected">>],
                           {Id, S} <- summaries_all(H, T)];
build_rows(H, <<"modules">>) ->
    [#{name => eobs_dump_parse:unquote_atom(Id), current_size => maps:get(cur, S, null),
       old_size => maps:get(old, S, null)} || {Id, S} <- summaries_all(H, <<"mod">>)];
build_rows(H, <<"funs">>) ->
    [#{module => maps:get(module, S, null), uniq => maps:get(uniq, S, null),
       index => maps:get(index, S, null), address => maps:get(address, S, null),
       refc => maps:get(refc, S, null)} || {_, S} <- summaries_all(H, <<"fun">>)];
build_rows(H, <<"schedulers">>) ->
    sched_rows(H);
build_rows(H, <<"allocators">>) ->
    alloc_rows(H);
build_rows(H, <<"memory">>) ->
    case section_body(H, <<"memory">>, null) of
        {ok, Body} ->
            [#{key => K, value => eobs_dump_parse:int(V)} || {K, V} <- eobs_dump_parse:kv(Body)];
        _ -> []
    end;
build_rows(H, <<"allocated_areas">>) ->
    case section_body(H, <<"allocated_areas">>, null) of
        {ok, Body} ->
            [#{key => K, allocated => A, used => U}
             || {K, A, U} <- eobs_dump_parse:allocated_areas(Body)];
        _ -> []
    end;
build_rows(H, <<"hash_tables">>) ->
    [maps:merge(#{name => Id, size => null, used => null, objs => null, depth => null},
                atom_keys(eobs_dump_parse:hash_table(B)))
     || {Id, B} <- section_bodies(H, <<"hash_table">>)];
build_rows(H, <<"index_tables">>) ->
    [maps:merge(#{name => Id, size => null, limit => null, entries => null},
                atom_keys(eobs_dump_parse:index_table(B)))
     || {Id, B} <- section_bodies(H, <<"index_table">>)];
build_rows(H, <<"internal_tables">>) ->
    WS = word_size(H),
    [begin
         E = eobs_dump_parse:ets(B),
         #{name => Id, type => maps:get(type, E, null), objects => maps:get(objects, E, null),
           memory => words(maps:get(words, E, null), WS)}
     end || {Id, B} <- section_bodies(H, <<"internal_ets">>)];
build_rows(_, _) ->
    [].

atom_keys(M) ->
    maps:from_list([{K1, V} || {K, V} <- maps:to_list(M),
                               K1 <- [known_key(K)], K1 =/= none]).

known_key(<<"size">>) -> size;
known_key(<<"used">>) -> used;
known_key(<<"objs">>) -> objs;
known_key(<<"depth">>) -> depth;
known_key(<<"limit">>) -> limit;
known_key(<<"entries">>) -> entries;
known_key(_) -> none.

words(null, _) -> null;
words(W, _) when W < 0 -> null;
words(W, WS) -> W * WS.

port_row(Id, S) ->
    #{id => Id, name => maps:get(name, S, null), state => maps:get(state, S, null),
      type => maps:get(type, S, null), controls => maps:get(controls, S, null),
      connected => maps:get(connected, S, null), slot => maps:get(slot, S, null),
      input => maps:get(input, S, null), output => maps:get(output, S, null),
      queue => maps:get(queue, S, null)}.

ets_row(Owner, S, WS) ->
    #{table => maps:get(table, S, null), name => maps:get(name, S, null), owner => Owner,
      type => maps:get(type, S, null), protection => maps:get(protection, S, null),
      objects => maps:get(objects, S, null), memory => words(maps:get(words, S, null), WS)}.

node_row(Tag, Ch, S) ->
    Type = case Tag of
               <<"visible_node">> -> <<"visible">>;
               <<"hidden_node">> -> <<"hidden">>;
               _ -> <<"not_connected">>
           end,
    #{channel => eobs_dump_parse:int(Ch), name => unquote(maps:get(name, S, null)), type => Type,
      controller => maps:get(controller, S, null),
      creation => case maps:get(creation, S, []) of
                      [] -> null;
                      Cs -> iolist_to_binary(lists:join(<<" ">>, [integer_to_binary(C) || C <- Cs]))
                  end,
      links => maps:get(links, S, 0), monitors => maps:get(monitors, S, 0),
      monitored_by => maps:get(monitored_by, S, 0), error => maps:get(error, S, null)}.

%% Summaries for every section of Tag, in file order, from one consistent
%% pass over the index (a section without one gets #{}).
summaries_all(H, Tag) ->
    [{Id, case S of none -> #{}; _ -> S end} || {Id, _, _, S} <- eobs_dump:entries(H, Tag)].

sched_rows(H) ->
    Types = [{<<"scheduler">>, <<"normal">>}, {<<"dirty_cpu_scheduler">>, <<"dirty_cpu">>},
             {<<"dirty_io_scheduler">>, <<"dirty_io">>}],
    DirtyRq = fun(T) ->
                      case section_body(H, T, null) of
                          {ok, B} -> eobs_dump_parse:scheduler(B);
                          _ -> #{}
                      end
              end,
    Rqs = #{<<"dirty_cpu">> => DirtyRq(<<"dirty_cpu_run_queue">>),
            <<"dirty_io">> => DirtyRq(<<"dirty_io_run_queue">>)},
    [begin
         S0 = eobs_dump_parse:scheduler(B),
         S = maps:merge(maps:get(Type, Rqs, #{}), S0),
         RQ = lists:sum([V || K <- [rq_max, rq_high, rq_normal, rq_low],
                              V <- [maps:get(K, S, 0)], is_integer(V)]),
         #{id => eobs_dump_parse:int(Id), type => Type,
           process => nonempty(maps:get(process, S, null)),
           port => nonempty(maps:get(port, S, null)),
           run_queue => RQ, port_queue => maps:get(rq_port, S, null),
           sleep => nonempty(maps:get(sleep_flags, S, null))}
     end || {Tag, Type} <- Types, {Id, B} <- section_bodies(H, Tag)].

unquote(null) -> null;
unquote(N) -> eobs_dump_parse:unquote_atom(N).

nonempty(<<>>) -> null;
nonempty(V) -> V.

%% Allocators aggregated per type ("binary_alloc[3]" -> "binary_alloc").
alloc_rows(H) ->
    Insts = [{alloc_type(Id), alloc_sums(eobs_dump_parse:allocator(B))}
             || {Id, B} <- section_bodies(H, <<"allocator">>)],
    Types = lists:usort([T || {T, _} <- Insts]),
    [begin
         Ss = [S || {T1, S} <- Insts, T1 =:= T],
         Blocks = lists:sum([B || {B, _} <- Ss]),
         Carriers = lists:sum([C || {_, C} <- Ss]),
         #{name => T, instances => length(Ss), blocks_size => Blocks, carriers_size => Carriers,
           usage => case Carriers > 0 of
                        true -> round(Blocks * 100 / Carriers);
                        false -> null
                    end}
     end || T <- Types].

alloc_type(Id) when is_binary(Id) -> hd(binary:split(Id, <<"[">>));
alloc_type(_) -> <<"?">>.

%% {BlocksSize, CarriersSize} of one instance (current values).
alloc_sums(KVs) ->
    lists:foldl(fun({K, [V | _]}, {B, C}) ->
                        case alloc_key(K) of
                            blocks -> {B + eobs_dump_parse:int(V, 0), C};
                            carriers -> {B, C + eobs_dump_parse:int(V, 0)};
                            none -> {B, C}
                        end;
                   (_, Acc) -> Acc
                end, {0, 0}, KVs).

alloc_key(K) ->
    case re:run(K, "^(mbcs|sbcs|mbcs_pool) (blocks|carriers)(\\[[^\\]]*\\])? size$",
                [{capture, [2], binary}]) of
        {match, [<<"blocks">>]} -> blocks;
        {match, [<<"carriers">>]} -> carriers;
        _ -> none
    end.

%% ---------------------------------------------------------------------
%% Processes: packed tables so a million rows sort and page quickly.

proc_query(H, Opts) ->
    case big_scan(H) of
        true ->
            %% Building the table for a huge dump on every poll would stall the
            %% scan; the list fills in once the scan is done.
            #{total => eobs_dump:count(H, <<"proc">>), columns => columns(<<"processes">>),
              rows => [], scanning => true};
        false ->
            proc_query1(H, Opts)
    end.

%% Still scanning a dump with too many processes to tabulate repeatedly.
big_scan(H) ->
    maps:get(status, eobs_dump:info(H), scanning) =:= scanning
        andalso eobs_dump:count(H, <<"proc">>) > ?SCAN_TABLE_MAX.

proc_query1(H, #{offset := Off, limit := Lim, sort := Sort0, order := Order, filter := F}) ->
    T = proc_table(H),
    Keys = [<<"pid">>, <<"name">>, <<"state">>, <<"init">>, <<"current">>, <<"reds">>,
            <<"memory">>, <<"mq">>, <<"heap">>, <<"bin">>],
    Sort = case lists:member(Sort0, Keys) of
               true -> Sort0;
               false -> <<"memory">>
           end,
    Perm = proc_perm(H, T, Sort),
    N = maps:get(n, T),
    {Total, Idxs} =
        case F of
            <<>> ->
                {N, perm_slice(Perm, N, Order, Off, Lim)};
            _ ->
                Bits = match_bits(T, F),
                perm_filter(Perm, N, Order, Bits, Off, Lim)
        end,
    #{total => Total, columns => columns(<<"processes">>),
      rows => [proc_row_by_id(H, tab_id(T, I)) || I <- Idxs]}.

top_procs(H, Sort, N) ->
    T = proc_table(H),
    Perm = proc_perm(H, T, Sort),
    [proc_row_by_id(H, tab_id(T, I)) || I <- perm_slice(Perm, maps:get(n, T), desc, 0, N)].

proc_table(H) ->
    eobs_dump:cache(H, {eobs_view, proc_table}, fun() -> build_proc_table(H) end).

%% #{n, ids => {Blob, Offs}, text => {Blob, Offs}, ints => #{Key => <<V:64>>...}}
build_proc_table(H) ->
    WS = word_size(H),
    Sums = summaries_all(H, <<"proc">>),
    {Ids, Texts, Ints, States} =
        lists:foldl(fun({Id, S}, {IA, TA, NA, SA}) ->
                            R = proc_row(Id, S, WS),
                            Line = iolist_to_binary(
                                     lists:join($\t, [lower(maps:get(K, R)) || K <- [pid, name, state, init, current]])),
                            St = maps:get(state, S, <<"?">>),
                            {[Id | IA], [Line | TA],
                             [[int64(maps:get(K, R)) || K <- [reds, memory, mq, heap, bin]] | NA],
                             SA#{St => maps:get(St, SA, 0) + 1}}
                    end, {[], [], [], #{}}, Sums),
    N = length(Ids),
    IntCols = transpose(lists:reverse(Ints), 5),
    #{n => N, states => States,
      ids => pack_strings(lists:reverse(Ids)),
      text => pack_strings(lists:reverse(Texts)),
      ints => maps:from_list(lists:zip([<<"reds">>, <<"memory">>, <<"mq">>, <<"heap">>, <<"bin">>],
                                       IntCols))}.

lower(null) -> <<>>;
lower(B) -> string:lowercase(B).

int64(null) -> 0;
int64(I) when is_integer(I) -> max(-(1 bsl 63), min(I, (1 bsl 63) - 1)).

transpose(Rows, Cols) ->
    [iolist_to_binary([<<(lists:nth(C, R)):64/signed>> || R <- Rows]) || C <- lists:seq(1, Cols)].

pack_strings(L) ->
    {Offs, _} = lists:mapfoldl(fun(B, O) -> {<<O:32>>, O + byte_size(B)} end, 0, L),
    Total = lists:sum([byte_size(B) || B <- L]),
    {iolist_to_binary(L), iolist_to_binary([Offs, <<Total:32>>])}.

packed_at({Blob, Offs}, I) ->
    <<_:(I * 4)/binary, O1:32, O2:32, _/binary>> = Offs,
    binary:part(Blob, O1, O2 - O1).

tab_id(T, I) -> packed_at(maps:get(ids, T), I).

%% Ascending permutation (<<Idx:32>>...) of the table for a sort key.
proc_perm(H, T, Key) ->
    eobs_dump:cache(H, {eobs_view, proc_perm, Key}, fun() -> build_perm(T, Key) end).

build_perm(#{n := N} = T, Key) ->
    Vals = case maps:find(Key, maps:get(ints, T)) of
               {ok, Col} -> [V || <<V:64/signed>> <= Col];
               error when Key =:= <<"pid">> ->
                   [pid_key(tab_id(T, I)) || I <- seq(N)];
               error ->
                   Field = text_field(Key),
                   [lists:nth(Field, binary:split(packed_at(maps:get(text, T), I), <<"\t">>, [global]))
                    || I <- seq(N)]
           end,
    Sorted = lists:sort(lists:zip(Vals, seq(N))),
    << <<I:32>> || {_, I} <- Sorted >>.

seq(0) -> [];
seq(N) -> lists:seq(0, N - 1).

text_field(<<"name">>) -> 2;
text_field(<<"state">>) -> 3;
text_field(<<"init">>) -> 4;
text_field(_) -> 5.

%% "<0.10.0>" -> [0, 10, 0] without regexps (millions of calls).
pid_key(<<"<", Rest/binary>> = Pid) ->
    try [binary_to_integer(P) || P <- binary:split(binary:part(Rest, 0, byte_size(Rest) - 1),
                                                    <<".">>, [global])]
    catch _:_ -> [Pid]
    end;
pid_key(Pid) -> [Pid].

perm_slice(_, N, _, Off, _) when Off >= N -> [];
perm_slice(Perm, N, Order, Off, Lim) ->
    [perm_at(Perm, N, Order, P) || P <- lists:seq(Off, min(N, Off + Lim) - 1)].

perm_at(Perm, _N, asc, P) -> <<_:(P * 4)/binary, I:32, _/binary>> = Perm, I;
perm_at(Perm, N, desc, P) -> perm_at(Perm, N, asc, N - 1 - P).

perm_filter(Perm, _N, Order, Bits, Off, Lim) ->
    Fold = fun(I, {Count, Acc}) ->
                   case bit(Bits, I) of
                       true when Count >= Off, Count < Off + Lim -> {Count + 1, [I | Acc]};
                       true -> {Count + 1, Acc};
                       false -> {Count, Acc}
                   end
           end,
    Is = [I || <<I:32>> <= Perm],
    {Total, Acc} = lists:foldl(Fold, {0, []}, case Order of asc -> Is; desc -> lists:reverse(Is) end),
    {Total, lists:reverse(Acc)}.

bit(Bits, I) ->
    <<_:I, B:1, _/bits>> = Bits,
    B =:= 1.

%% Bitmap of rows whose text columns contain F.
match_bits(#{n := N, text := {Blob, Offs}}, F) ->
    Positions = [P || {P, _} <- binary:matches(Blob, F)],
    Rows = rows_of(Positions, Offs, 0, N, []),
    to_bits(lists:usort(Rows), 0, N, []).

rows_of([], _, _, _, Acc) -> Acc;
rows_of(_, _, I, N, Acc) when I >= N -> Acc;
rows_of([P | Ps] = All, Offs, I, N, Acc) ->
    <<_:(I * 4)/binary, _:32, End:32, _/binary>> = Offs,
    case P < End of
        true -> rows_of(Ps, Offs, I, N, [I | Acc]);
        false -> rows_of(All, Offs, I + 1, N, Acc)
    end.

to_bits([], Pos, N, Acc) ->
    list_to_bitstring(lists:reverse([<<0:(N - Pos)>> | Acc]));
to_bits([I | Is], Pos, N, Acc) ->
    to_bits(Is, I + 1, N, [<<1:1>>, <<0:(I - Pos)>> | Acc]).

proc_row(Pid, S, WS) ->
    Mem = case maps:get(mem, S, null) of
              null -> mul(maps:get(sh, S, null), WS);
              M -> M
          end,
    Heap = case maps:get(sh, S, null) of
               null -> null;
               SH -> (SH + maps:get(oh, S, 0)) * WS
           end,
    #{pid => Pid, name => maps:get(name, S, null), state => maps:get(state, S, null),
      init => maps:get(init, S, null),
      current => maps:get(cur, S, maps:get(pc, S, null)),
      reds => maps:get(reds, S, null), memory => Mem, mq => maps:get(mq, S, null),
      heap => Heap, bin => mul(maps:get(bin, S, null), WS)}.

mul(null, _) -> null;
mul(V, WS) -> V * WS.

proc_row_by_id(H, Pid) ->
    WS = word_size(H),
    S = case eobs_dump:summary(H, <<"proc">>, Pid) of
            {ok, M} -> M;
            not_found ->
                case section_body(H, <<"proc">>, Pid, ?MAX_PROC) of
                    {ok, Body} ->
                        case eobs_dump_parse:summary(<<"proc">>, Pid, Body) of
                            M when is_map(M) -> M;
                            _ -> #{}
                        end;
                    _ -> #{}
                end
        end,
    proc_row(Pid, S, WS).

%% ---------------------------------------------------------------------
%% Atoms: one big section, paged through the line index.

atom_query(H, #{offset := Off, limit := Lim, order := Order0, sort := Sort, filter := F}) ->
    Cols = columns(<<"atoms">>),
    %% Lines run newest first; index 1 is the oldest atom.
    Order = case Sort of
                <<"index">> -> Order0;
                _ -> asc
            end,
    N = eobs_dump_term:line_count(H, <<"atoms">>, null),
    Row = fun(Line, Name) -> #{index => N - Line, name => Name} end,
    case F of
        <<>> ->
            {Lines, First} = case Order of
                                 desc -> {lists:seq(Off, min(N, Off + Lim) - 1), Off};
                                 asc -> {lists:seq(max(0, N - Off - Lim), N - Off - 1),
                                         max(0, N - Off - Lim)}
                             end,
            case Lines of
                [] -> #{total => N, columns => Cols, rows => []};
                _ ->
                    {_, Names} = eobs_dump_term:lines(H, <<"atoms">>, null, First, length(Lines)),
                    Rows = [Row(L, Nm) || {L, Nm} <- lists:zip(Lines, Names)],
                    #{total => N, columns => Cols,
                      rows => case Order of asc -> lists:reverse(Rows); desc -> Rows end}
            end;
        _ ->
            Matches = atom_matches(H, F),
            Ordered = case Order of
                          desc -> Matches;
                          asc -> lists:reverse(Matches)
                      end,
            #{total => length(Ordered), columns => Cols,
              rows => [Row(L, Nm) || {L, Nm} <- slice(Ordered, Off, Lim)]}
    end.

%% [{LineNo, Name}] of atoms containing F, in file order; capped.
atom_matches(H, F) ->
    case section_of(H, <<"atoms">>, null) of
        {Off, Len} -> scan_atoms(H, Off, Len, 0, <<>>, 0, F, []);
        none -> []
    end.

scan_atoms(_, _, Len, Pos, Carry, LineNo, F, Acc) when Pos >= Len ->
    lists:reverse(match_atom_lines([Carry || Carry =/= <<>>], LineNo, F, Acc));
scan_atoms(H, Off, Len, Pos, Carry, LineNo, F, Acc) ->
    case eobs_dump:read(H, Off + Pos, min(?MB, Len - Pos)) of
        {ok, Chunk} when Chunk =/= <<>> ->
            Parts = binary:split(<<Carry/binary, Chunk/binary>>, <<"\n">>, [global]),
            {Complete, [Last]} = lists:split(length(Parts) - 1, Parts),
            Acc1 = match_atom_lines(Complete, LineNo, F, Acc),
            case length(Acc1) > 100000 of
                true -> lists:reverse(Acc1);
                false -> scan_atoms(H, Off, Len, Pos + byte_size(Chunk), Last,
                                    LineNo + length(Complete), F, Acc1)
            end;
        _ ->
            lists:reverse(Acc)
    end.

match_atom_lines([], _, _, Acc) -> Acc;
match_atom_lines([L | Ls], N, F, Acc) ->
    Acc1 = case binary:match(string:lowercase(L), F) of
               nomatch -> Acc;
               _ -> [{N, strip_cr(L)} | Acc]
           end,
    match_atom_lines(Ls, N + 1, F, Acc1).

strip_cr(L) -> string:trim(L, trailing, "\r").

%% ---------------------------------------------------------------------
%% Persistent terms

pt_query(H, #{offset := Off, limit := Lim, order := Order, sort := Sort, filter := F}) ->
    Cols = columns(<<"persistent_terms">>),
    N = eobs_dump_term:line_count(H, <<"persistent_terms">>, null),
    case F =:= <<>> andalso Sort =/= <<"key">> of
        true ->
            {Total, Items} = eobs_dump_term:persistent_terms(H, Off, Lim, 0),
            #{total => Total, columns => Cols, rows => Items};
        false ->
            %% Keys rendered once (short), then filtered/sorted by text.
            Keys = eobs_dump:cache(H, {eobs_view, pt_keys}, fun() ->
                       {_, Items} = eobs_dump_term:persistent_terms(H, 0, min(N, 100000), 0),
                       [{I, maps:get(text, K)} || {I, #{key := K}} <- lists:zip(seq(length(Items)), Items)]
                   end),
            Matching = [{T, I} || {I, T} <- Keys, F =:= <<>> orelse contains(T, F)],
            Sorted = case Sort of
                         <<"key">> ->
                             Asc = lists:sort(Matching),
                             case Order of asc -> Asc; desc -> lists:reverse(Asc) end;
                         _ -> lists:keysort(2, Matching)
                     end,
            Rows = [hd(element(2, eobs_dump_term:persistent_terms(H, I, 1, 0)))
                    || {_, I} <- slice(Sorted, Off, Lim)],
            #{total => length(Sorted), columns => Cols, rows => Rows}
    end.

%% =====================================================================
%% Process detail

process(H, Pid) when is_binary(Pid) ->
    case section_body(H, <<"proc">>, Pid, ?MAX_PROC) of
        {ok, Body} ->
            try do_process(H, Pid, Body)
            catch C:R:St ->
                logger:warning("crash dump process ~ts failed: ~p:~p ~p", [Pid, C, R, St]),
                {error, parse_failed}
            end;
        _ ->
            {error, not_found}
    end;
process(_, _) ->
    {error, not_found}.

do_process(H, Pid, Body) ->
    WS = word_size(H),
    P = eobs_dump_parse:proc(Body),
    Row = proc_row_by_id(H, Pid),
    W = fun(K) -> mul(maps:get(K, P, null), WS) end,
    Info0 = [{state, maps:get(state, P, null), text},
             {name, maps:get(name, P, null), text},
             {init, maps:get(init, P, null), text},
             {current, maps:get(cur, P, null), text},
             {parent, maps:get(parent, P, null), pid},
             {started, maps:get(started, P, null), text},
             {reds, maps:get(reds, P, null), int},
             {mq, maps:get(mq, P, null), int},
             {memory, maps:get(mem, P, null), bytes},
             {stack_heap, W(sh), bytes},
             {old_heap, W(oh), bytes},
             {heap_unused, W(heap_unused), bytes},
             {old_heap_unused, W(oh_unused), bytes},
             {bin_vheap, W(bin_vheap), bytes},
             {old_bin_vheap, W(old_bin_vheap), bytes},
             {bin_vheap_unused, W(bin_vheap_unused), bytes},
             {old_bin_vheap_unused, W(old_bin_vheap_unused), bytes},
             {heap_frags, maps:get(heap_frags, P, null), int},
             {heap_frag_data, W(heap_frag_data), bytes},
             {program_counter, maps:get(pc, P, null), text},
             {cp, maps:get(cp, P, null), text},
             {arity, maps:get(arity, P, null), int},
             {internal_state, maps:get(internal_state, P, null), text},
             {run_queue, maps:get(run_queue, P, null), text},
             {last_calls, case maps:get(last_calls, P, []) of
                              [] -> null;
                              Cs -> iolist_to_binary(lists:join($\n, Cs))
                          end, text},
             {new_heap_start, maps:get(new_heap_start, P, null), text},
             {new_heap_top, maps:get(new_heap_top, P, null), text},
             {stack_top, maps:get(stack_top, P, null), text},
             {stack_end, maps:get(stack_end, P, null), text},
             {old_heap_start, maps:get(old_heap_start, P, null), text},
             {old_heap_top, maps:get(old_heap_top, P, null), text},
             {old_heap_end, maps:get(old_heap_end, P, null), text}]
            ++ [{K, V, text} || {K, V} <- maps:get(extra, P, [])],
    Info = [#{key => K, value => V, type => T} || {K, V, T} <- Info0, V =/= null],
    Count = fun(Tag) -> eobs_dump_term:line_count(H, Tag, Pid) end,
    HasHeap = eobs_dump_term:has_heap(H, Pid),
    Notes = [<<"garbing">> || maps:get(state, P, null) =:= <<"Garbing">>]
            ++ [<<"no_heap">> || not HasHeap]
            ++ [<<"truncated">> || proc_truncated(H, Pid)],
    #{summary => Row,
      info => Info,
      parent => maps:get(parent, P, null),
      links => maps:get(links, P, []),
      monitors => [resolve_name(H, M) || M <- maps:get(monitors, P, [])],
      monitored_by => maps:get(monitored_by, P, []),
      parts => #{messages => Count(<<"proc_messages">>),
                 dictionary => Count(<<"proc_dictionary">>),
                 stack => Count(<<"proc_stack">>),
                 heap => HasHeap},
      notes => Notes}.

%% The last section of a truncated dump belongs to this process.
proc_truncated(H, Pid) ->
    case eobs_dump:info(H) of
        #{truncated := true, last_id := Pid} -> true;
        _ -> false
    end.

%% "{name,node}" monitors point at a registered process on this node.
resolve_name(H, <<"{", _/binary>> = M) ->
    case re:run(M, "^\\{([^,]+),([^}]+)\\}$", [{capture, all_but_first, binary}]) of
        {match, [Name, Node]} ->
            Local = maps:get(node, general(H), null),
            case eobs_dump_parse:unquote_atom(Node) =:= Local of
                true -> case registered(H, Name) of
                            null -> M;
                            Pid -> Pid
                        end;
                false -> M
            end;
        _ -> M
    end;
resolve_name(_, M) -> M.

registered(H, Name) ->
    Map = eobs_dump:cache(H, {eobs_view, registered}, fun() ->
              maps:from_list([{N, Id} || {Id, #{name := N}} <- summaries_all(H, <<"proc">>)])
          end),
    maps:get(Name, Map, null).

process_part(H, Pid, Part, Offset, Limit) when is_binary(Pid), is_binary(Part) ->
    Off = clamp(Offset, 0, 1 bsl 40),
    Lim = clamp(Limit, 0, 1000),
    try
        case Part of
            <<"messages">> -> items(eobs_dump_term:messages(H, Pid, Off, Lim));
            <<"dictionary">> -> items(eobs_dump_term:dictionary(H, Pid, Off, Lim));
            <<"stack">> -> items(eobs_dump_term:stack(H, Pid, Off, Lim));
            _ -> {error, unknown_part}
        end
    catch C:R:St ->
        logger:warning("crash dump ~ts of ~ts failed: ~p:~p ~p", [Part, Pid, C, R, St]),
        {error, parse_failed}
    end;
process_part(_, _, _, _, _) ->
    {error, unknown_part}.

items({Total, Items}) -> #{total => Total, items => Items}.

expand(H, Token) ->
    eobs_dump_term:expand(H, Token).

%% =====================================================================
%% Detail of other objects: {title, fields: [{key, value}], terms?}

detail(H, Kind, Key) when is_binary(Kind), is_binary(Key) ->
    try do_detail(H, Kind, Key)
    catch C:R:St ->
        logger:warning("crash dump detail ~ts failed: ~p:~p ~p", [Kind, C, R, St]),
        {error, parse_failed}
    end;
detail(_, _, _) ->
    {error, not_found}.

do_detail(H, <<"port">>, Key) ->
    case section_body(H, <<"port">>, Key) of
        {ok, Body} ->
            P = eobs_dump_parse:port(Body),
            #{title => Key, fields => fields(P, [name, state, task_flags, type, controls, connected,
                                                  links, monitors, suspended, slot, input,
                                                  output, queue, data])};
        _ -> {error, not_found}
    end;
do_detail(H, <<"ets">>, Key) ->
    case find_ets(H, Key) of
        {Owner, Body} ->
            E = eobs_dump_parse:ets(Body),
            WS = word_size(H),
            E1 = E#{owner => Owner, memory => words(maps:get(words, E, null), WS)},
            #{title => Key,
              fields => fields(E1, [table, name, owner, type, protection, objects, memory,
                                    buckets, compressed, fixed, write_concurrency,
                                    read_concurrency, chain_min, chain_max, chain_avg,
                                    chain_stddev, chain_exp_stddev, slot])};
        none -> {error, not_found}
    end;
do_detail(H, <<"node">>, Key) ->
    Found = [{T, B} || T <- [<<"visible_node">>, <<"hidden_node">>, <<"not_connected">>],
                       {ok, B} <- [section_body(H, T, Key)]],
    case Found of
        [{T, Body} | _] ->
            N = eobs_dump_parse:dist_node(Body),
            Pairs = fun(K) -> [#{local => L, remote => R} || #{local := L, remote := R} <- maps:get(K, N, [])] end,
            #{title => maps:get(name, N, Key),
              fields => fields(N#{type => T, channel => Key,
                                  creation => creation_text(maps:get(creation, N, []))},
                               [name, channel, type, controller, creation, error]),
              links => Pairs(links), monitors => Pairs(monitors),
              monitored_by => Pairs(monitored_by)};
        [] -> {error, not_found}
    end;
do_detail(H, <<"module">>, Key) ->
    Name = mod_id(H, Key),
    case section_body(H, <<"mod">>, Name) of
        {ok, Body} ->
            M = eobs_dump_parse:mod(Body),
            Terms = [#{key => F, value => T}
                     || F <- [<<"cur_attrib">>, <<"cur_comp">>, <<"old_attrib">>, <<"old_comp">>],
                        {ok, T} <- [eobs_dump_term:mod_attr(H, Name, F, 0)]],
            #{title => eobs_dump_parse:unquote_atom(Name),
              fields => fields(#{current_size => maps:get(cur, M, null),
                                 old_size => maps:get(old, M, null)},
                               [current_size, old_size]),
              terms => Terms};
        _ -> {error, not_found}
    end;
do_detail(H, <<"allocator">>, Key) ->
    Insts = [{Id, eobs_dump_parse:allocator(B)} || {Id, B} <- section_bodies(H, <<"allocator">>),
                                                   Id =:= Key orelse alloc_type(Id) =:= Key],
    case Insts of
        [] -> {error, not_found};
        _ ->
            #{title => Key,
              fields => [#{key => Id, value => null} || {Id, _} <- Insts],
              instances => [#{name => Id,
                              fields => [#{key => K, value => iolist_to_binary(lists:join($\s, Vs))}
                                         || {K, Vs} <- KVs]}
                            || {Id, KVs} <- Insts]}
    end;
do_detail(H, <<"scheduler">>, Key) ->
    Found = [B || T <- [<<"scheduler">>, <<"dirty_cpu_scheduler">>, <<"dirty_io_scheduler">>],
                  {ok, B} <- [section_body(H, T, Key)]],
    case Found of
        [Body | _] ->
            S = eobs_dump_parse:scheduler(Body),
            #{title => Key,
              fields => fields(S, [process, process_state, process_internal_state, process_pc,
                                   process_cp, port, sleep_flags, sleep_aux, rq_max, rq_high,
                                   rq_normal, rq_low, rq_port, rq_flags]),
              stack => maps:get(stack, S, [])};
        [] -> {error, not_found}
    end;
do_detail(H, <<"timer">>, Key) ->
    case [R || R = #{owner := O} <- rows(H, <<"timers">>), O =:= Key] of
        [] -> {error, not_found};
        Rs ->
            #{title => Key,
              fields => [#{key => message, value => M} || #{message := M} <- Rs]
                        ++ [#{key => time_left, value => T} || #{time_left := T} <- Rs]}
    end;
do_detail(_, _, _) ->
    {error, not_found}.

creation_text([]) -> null;
creation_text(Cs) -> iolist_to_binary(lists:join($\s, [integer_to_binary(C) || C <- Cs])).

fields(M, Keys) ->
    [#{key => K, value => field_value(V)} || K <- Keys, V <- [maps:get(K, M, null)], V =/= null, V =/= <<>>].

field_value(L) when is_list(L) -> iolist_to_binary(lists:join(<<", ">>, [field_value(X) || X <- L]));
field_value(V) when is_binary(V); is_number(V); is_boolean(V) -> V;
field_value(V) -> iolist_to_binary(io_lib:format("~0p", [V])).

%% Module ids in the dump may be quoted atoms.
mod_id(H, Key) ->
    case eobs_dump:lookup(H, <<"mod">>, Key) of
        [_ | _] -> Key;
        [] ->
            Quoted = <<"'", Key/binary, "'">>,
            case eobs_dump:lookup(H, <<"mod">>, Quoted) of
                [_ | _] -> Quoted;
                [] -> Key
            end
    end.

%% ETS tables are keyed by their "Table:" value; sections by owner pid.
find_ets(H, Key) ->
    case [{Owner, Off, Len} || {Owner, Off, Len, #{table := T}} <- eobs_dump:entries(H, <<"ets">>),
                               T =:= Key] of
        [{Owner, Off, Len} | _] ->
            case eobs_dump:read(H, Off, min(Len, ?MAX_SECTION)) of
                {ok, Body} -> {Owner, Body};
                _ -> none
            end;
        [] -> none
    end.

%% =====================================================================
%% Search: [{kind, key, label}], at most 50

search(H, Q0) when is_binary(Q0) ->
    Q = string:lowercase(string:trim(Q0)),
    case byte_size(Q) of
        0 -> [];
        N when N > 256 -> [];
        _ ->
            try lists:sublist(do_search(H, Q), ?MAX_SEARCH)
            catch _:_ -> []
            end
    end;
search(_, _) -> [].

do_search(H, Q) ->
    Exact = exact_pid(H, Q),
    Procs = case big_scan(H) of
                true -> [];
                false -> search_procs(H, Q)
            end,
    Others =
        [#{kind => port, key => Id, label => label(Id, N)}
         || #{id := Id, name := N} = R <- rows(H, <<"ports">>), match_any(R, [id, name, controls], Q)]
        ++ [#{kind => ets, key => T1, label => label(T1, O)}
            || #{table := T1, owner := O} = R <- rows(H, <<"ets">>), match_any(R, [table, name], Q)]
        ++ [#{kind => module, key => N, label => N}
            || #{name := N} <- rows(H, <<"modules">>), contains(N, Q)]
        ++ [#{kind => node, key => integer_to_binary(C), label => N}
            || #{channel := C, name := N} <- rows(H, <<"nodes">>), is_binary(N), contains(N, Q),
               is_integer(C)],
    ExactKeys = [K || #{key := K} <- Exact],
    Exact ++ [P || #{key := K} = P <- Procs, not lists:member(K, ExactKeys)]
        ++ lists:sublist(Others, ?MAX_SEARCH).

search_procs(H, Q) ->
    T = proc_table(H),
    Bits = match_bits(T, Q),
    [begin
                 Id = tab_id(T, I),
                 Fields = binary:split(packed_at(maps:get(text, T), I), <<"\t">>, [global]),
                 Label = case lists:nth(2, Fields) of
                             <<>> -> iolist_to_binary([Id, " ", lists:nth(4, Fields)]);
                             _ -> iolist_to_binary([Id, " ", name_of(H, Id)])
                         end,
                 #{kind => process, key => Id, label => Label}
             end || I <- first_bits(Bits, maps:get(n, T), 20)].

exact_pid(H, Q) ->
    Pid = case Q of
              <<"<", _/binary>> -> Q;
              _ -> <<"<", Q/binary, ">">>
          end,
    case id_nums(Pid) of
        {id, [_, _, _]} ->
            case eobs_dump:lookup(H, <<"proc">>, Pid) of
                [_ | _] -> [#{kind => process, key => Pid, label => label(Pid, name_of(H, Pid))}];
                [] -> []
            end;
        _ -> []
    end.

name_of(H, Pid) ->
    case eobs_dump:summary(H, <<"proc">>, Pid) of
        {ok, #{name := N}} -> N;
        _ -> <<>>
    end.

label(A, null) -> A;
label(A, <<>>) -> A;
label(A, B) -> iolist_to_binary([A, " ", B]).

match_any(Row, Keys, Q) ->
    lists:any(fun(K) ->
                      case maps:get(K, Row, null) of
                          V when is_binary(V) -> contains(V, Q);
                          _ -> false
                      end
              end, Keys).

first_bits(Bits, N, Max) -> first_bits(Bits, 0, N, Max, []).

first_bits(_, _, _, 0, Acc) -> lists:reverse(Acc);
first_bits(_, I, N, _, Acc) when I >= N -> lists:reverse(Acc);
first_bits(Bits, I, N, Max, Acc) ->
    case bit(Bits, I) of
        true -> first_bits(Bits, I + 1, N, Max - 1, [I | Acc]);
        false -> first_bits(Bits, I + 1, N, Max, Acc)
    end.

%% =====================================================================
%% Helpers

section_of(H, Tag, null) ->
    case eobs_dump:sections(H, Tag) of
        [{_, Off, Len} | _] -> {Off, Len};
        [] -> none
    end;
section_of(H, Tag, Id) ->
    case eobs_dump:lookup(H, Tag, Id) of
        [{Off, Len} | _] -> {Off, Len};
        [] -> none
    end.

section_body(H, Tag, Id) ->
    section_body(H, Tag, Id, ?MAX_SECTION).

section_body(H, Tag, Id, Max) ->
    case section_of(H, Tag, Id) of
        {Off, Len} -> eobs_dump:read(H, Off, min(Len, Max));
        none -> {error, not_found}
    end.

%% [{Id, Body}] for every section of Tag (small sections only).
section_bodies(H, Tag) ->
    Secs = eobs_dump:sections(H, Tag),
    Locs = [{Off, min(Len, ?MAX_SECTION)} || {_, Off, Len} <- Secs],
    Results = case Locs of
                  [] -> [];
                  _ -> read_many(H, Locs)
              end,
    [{Id, B} || {{Id, _, _}, {ok, B}} <- lists:zip(Secs, Results)].

%% One fd for many reads when the reader offers it.
read_many(H, Locs) ->
    case erlang:function_exported(eobs_dump, reads, 2) of
        true ->
            case eobs_dump:reads(H, Locs) of
                L when is_list(L) -> L;
                _ -> [eobs_dump:read(H, O, L) || {O, L} <- Locs]
            end;
        false ->
            [eobs_dump:read(H, O, L) || {O, L} <- Locs]
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<>>.

clip(B, N) when byte_size(B) > N -> <<(binary:part(B, 0, N))/binary, "...">>;
clip(B, _) -> B.
