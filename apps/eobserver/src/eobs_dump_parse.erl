%% @doc Crash dump section parsers. Section bodies (the text after the
%% `=tag:id' header line, up to the next header) become maps with binary
%% values. summary/3 runs during the scan for every section whose tag is in
%% summary_tags/0, so it only looks at the few lines the list views need.
-module(eobs_dump_parse).

-export([summary_tags/0, summary/3]).
-export([lines/1, kv/1, general/1, proc/1, links/1, port/1, ets/1, timer/1,
         dist_node/1, mod/1, fun_info/1, memory/1, hash_table/1, index_table/1,
         allocated_areas/1, allocator/1, scheduler/1, word_size/1, version/1,
         int/1, int/2, num/1, mfa_of_pc/1, split_pids/1, unquote_atom/1]).

summary_tags() ->
    [<<"proc">>, <<"port">>, <<"ets">>, <<"timer">>, <<"mod">>, <<"fun">>,
     <<"visible_node">>, <<"hidden_node">>, <<"not_connected">>].

%% Compact maps: missing fields are left out to keep the index small.
%% Pure (runs in parallel scan workers). Binaries are copied so that the
%% stored summaries never keep the scanner's read chunks alive.
summary(Tag, _Id, Body) ->
    try do_summary(Tag, Body) of
        M when is_map(M) -> maps:map(fun(_, V) -> own(V) end, M);
        Other -> Other
    catch _:_ -> skip
    end.

own(V) when is_binary(V) -> binary:copy(V);
own(L) when is_list(L) -> [own(X) || X <- L];
own(M) when is_map(M) -> maps:map(fun(_, X) -> own(X) end, M);
own(V) -> V.

do_summary(<<"proc">>, Body) -> proc_summary(lines(Body), #{});
do_summary(<<"port">>, Body) -> port(Body);
do_summary(<<"ets">>, Body) -> ets_summary(ets(Body));
do_summary(<<"timer">>, Body) -> timer(Body);
do_summary(<<"mod">>, Body) -> maps:with([cur, old], mod(Body));
do_summary(<<"fun">>, Body) -> fun_info(Body);
do_summary(<<"visible_node">>, Body) -> node_summary(dist_node(Body));
do_summary(<<"hidden_node">>, Body) -> node_summary(dist_node(Body));
do_summary(<<"not_connected">>, Body) -> node_summary(dist_node(Body));
do_summary(_, _) -> skip.

proc_summary([], Acc) -> Acc;
proc_summary([L | Ls], Acc) ->
    proc_summary(Ls, proc_line(L, Acc)).

proc_line(<<"State: ", V/binary>>, Acc) -> Acc#{state => V};
proc_line(<<"Name: ", V/binary>>, Acc) -> Acc#{name => V};
proc_line(<<"Spawned as: ", V/binary>>, Acc) -> Acc#{init => V};
proc_line(<<"Current call: ", V/binary>>, Acc) -> Acc#{cur => V};
proc_line(<<"Last scheduled in for: ", V/binary>>, Acc) -> Acc#{cur => V};
proc_line(<<"Message queue length: ", V/binary>>, Acc) -> put_int(mq, V, Acc);
proc_line(<<"Reductions: ", V/binary>>, Acc) -> put_int(reds, V, Acc);
proc_line(<<"Stack+heap: ", V/binary>>, Acc) -> put_int(sh, V, Acc);
proc_line(<<"OldHeap: ", V/binary>>, Acc) -> put_int(oh, V, Acc);
proc_line(<<"Memory: ", V/binary>>, Acc) -> put_int(mem, V, Acc);
proc_line(<<"BinVHeap: ", V/binary>>, Acc) -> add_int(bin, V, Acc);
proc_line(<<"OldBinVHeap: ", V/binary>>, Acc) -> add_int(bin, V, Acc);
proc_line(<<"Program counter: ", V/binary>>, Acc) ->
    case Acc of
        #{cur := _} -> Acc;
        _ -> Acc#{pc => mfa_of_pc(V)}
    end;
proc_line(_, Acc) -> Acc.

put_int(K, V, Acc) ->
    case int(V) of
        null -> Acc;
        I -> Acc#{K => I}
    end.

add_int(K, V, Acc) ->
    case int(V) of
        null -> Acc;
        I -> Acc#{K => I + maps:get(K, Acc, 0)}
    end.

ets_summary(M) ->
    maps:with([table, name, type, objects, words, protection], M).

node_summary(M) ->
    S = maps:with([name, controller, creation, error], M),
    S#{links => length(maps:get(links, M, [])),
       monitors => length(maps:get(monitors, M, [])),
       monitored_by => length(maps:get(monitored_by, M, []))}.

%% ---------------------------------------------------------------------
%% Generic helpers

%% Body lines without trailing \r; the empty last line is dropped.
lines(Body) ->
    [strip_cr(L) || L <- binary:split(Body, <<"\n">>, [global]), L =/= <<>>].

strip_cr(L) ->
    case byte_size(L) of
        0 -> L;
        N ->
            case binary:last(L) of
                $\r -> binary:part(L, 0, N - 1);
                _ -> L
            end
    end.

%% "Key: Value" lines -> [{Key, Value}]; lines without ": " give {Line, <<>>}.
kv(Body) ->
    [split_kv(L) || L <- lines(Body)].

split_kv(L) ->
    case binary:split(L, <<": ">>) of
        [K, V] -> {K, V};
        [K] ->
            case byte_size(K) > 0 andalso binary:last(K) of
                $: -> {binary:part(K, 0, byte_size(K) - 1), <<>>};
                _ -> {K, <<>>}
            end
    end.

int(V) -> int(V, null).

int(V, Default) when is_binary(V) ->
    case string:to_integer(string:trim(V)) of
        {I, _} when is_integer(I) -> I;
        _ -> Default
    end;
int(_, Default) -> Default.

num(V) when is_binary(V) ->
    case string:to_float(string:trim(V)) of
        {F, _} when is_float(F) -> F;
        _ -> int(V)
    end;
num(_) -> null.

%% "0x00007fa80a198470 (gen_server:loop/7 + 544)" -> <<"gen_server:loop/7 + 544">>
mfa_of_pc(V) ->
    case binary:match(V, <<"(">>) of
        {P, 1} ->
            R = binary:part(V, P + 1, byte_size(V) - P - 1),
            case byte_size(R) > 0 andalso binary:last(R) of
                $) -> binary:part(R, 0, byte_size(R) - 1);
                _ -> R
            end;
        nomatch -> V
    end.

%% "<0.1.0><0.2.0>" or "<0.1.0> <0.2.0>" -> [<<"<0.1.0>">>, <<"<0.2.0>">>]
split_pids(V) ->
    [<<P/binary, ">">> || P0 <- binary:split(V, <<">">>, [global]),
                          P <- [string:trim(P0)], P =/= <<>>].

unquote_atom(<<$', Rest/binary>> = A) ->
    case byte_size(Rest) > 0 andalso binary:last(Rest) of
        $' -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> A
    end;
unquote_atom(A) -> A.

%% ---------------------------------------------------------------------
%% =erl_crash_dump:Vsn

version(Vsn) when is_binary(Vsn) ->
    [int(P, 0) || P <- binary:split(Vsn, <<".">>, [global])];
version(_) -> [0, 0].

general(Body) ->
    case lines(Body) of
        [] -> #{};
        [Time | Rest] -> general(Rest, #{time => Time}, none)
    end.

general([], Acc, _) -> Acc;
general([<<"Slogan: ", S/binary>> | Ls], Acc, _) ->
    general(Ls, Acc#{slogan => S}, slogan);
general([<<"System version: ", V/binary>> | Ls], Acc, _) ->
    general(Ls, Acc#{system_version => V}, none);
general([<<"Compiled: ", V/binary>> | Ls], Acc, _) ->
    general(Ls, Acc#{compiled => V}, none);
general([<<"Taints: ", V/binary>> | Ls], Acc, _) ->
    general(Ls, Acc#{taints => V}, none);
general([<<"Taints:">> | Ls], Acc, _) ->
    general(Ls, Acc#{taints => <<>>}, none);
general([<<"Atoms: ", V/binary>> | Ls], Acc, _) ->
    general(Ls, Acc#{atoms => int(V)}, none);
general([<<"Calling Thread: ", V/binary>> | Ls], Acc, _) ->
    general(Ls, Acc#{calling_thread => V}, none);
general([L | Ls], #{slogan := S} = Acc, slogan) ->
    %% Multi-line slogans continue until "System version:".
    general(Ls, Acc#{slogan => <<S/binary, "\n", L/binary>>}, slogan);
general([L | Ls], Acc, St) ->
    {K, V} = split_kv(L),
    Extra = maps:get(extra, Acc, []),
    general(Ls, Acc#{extra => Extra ++ [{K, V}]}, St).

%% "[64-bit]" in the system version means 8 byte words.
word_size(SysVsn) when is_binary(SysVsn) ->
    case binary:match(SysVsn, <<"[64-bit]">>) of
        nomatch -> 4;
        _ -> 8
    end;
word_size(_) -> 8.

%% ---------------------------------------------------------------------
%% =proc:Pid (full)

proc(Body) ->
    proc_full(lines(Body), #{}).

proc_full([], Acc) -> Acc;
proc_full([<<"Last calls:", First/binary>> | Ls], Acc) ->
    %% Each call is on its own line indented by one space; an empty line ends it.
    {Calls, Rest} = lists:splitwith(fun(<<" ", _/binary>>) -> true; (_) -> false end, Ls),
    First1 = [string:trim(First) || string:trim(First) =/= <<>>],
    proc_full(Rest, Acc#{last_calls => First1 ++ [string:trim(C) || C <- Calls]});
proc_full([<<"Link list: ", V/binary>> | Ls], Acc) ->
    proc_full(Ls, maps:merge(Acc, links(V)));
proc_full([<<"arity = ", V/binary>> | Ls], Acc) ->
    proc_full(Ls, Acc#{arity => int(V)});
proc_full([L | Ls], Acc) ->
    {K, V} = split_kv(L),
    proc_full(Ls, proc_field(K, V, Acc)).

proc_field(<<"State">>, V, A) -> A#{state => V};
proc_field(<<"Name">>, V, A) -> A#{name => V};
proc_field(<<"Spawned as">>, V, A) -> A#{init => V};
proc_field(<<"Spawned by">>, <<"[]">>, A) -> A;
proc_field(<<"Spawned by">>, V, A) -> A#{parent => V};
proc_field(<<"Started">>, V, A) -> A#{started => V};
proc_field(<<"Current call">>, V, A) -> A#{cur => V};
proc_field(<<"Last scheduled in for">>, V, A) -> A#{cur => V, running => true};
proc_field(<<"Message queue length">>, V, A) -> A#{mq => int(V)};
proc_field(<<"Number of heap fragments">>, V, A) -> A#{heap_frags => int(V)};
proc_field(<<"Heap fragment data">>, V, A) -> A#{heap_frag_data => int(V)};
proc_field(<<"Reductions">>, V, A) -> A#{reds => int(V)};
proc_field(<<"Stack+heap">>, V, A) -> A#{sh => int(V)};
proc_field(<<"OldHeap">>, V, A) -> A#{oh => int(V)};
proc_field(<<"Heap unused">>, V, A) -> A#{heap_unused => int(V)};
proc_field(<<"OldHeap unused">>, V, A) -> A#{oh_unused => int(V)};
proc_field(<<"BinVHeap">>, V, A) -> A#{bin_vheap => int(V)};
proc_field(<<"OldBinVHeap">>, V, A) -> A#{old_bin_vheap => int(V)};
proc_field(<<"BinVHeap unused">>, V, A) -> A#{bin_vheap_unused => int(V)};
proc_field(<<"OldBinVHeap unused">>, V, A) -> A#{old_bin_vheap_unused => int(V)};
proc_field(<<"Memory">>, V, A) -> A#{mem => int(V)};
proc_field(<<"Program counter">>, V, A) -> A#{pc => V};
proc_field(<<"CP">>, V, A) -> A#{cp => V};
proc_field(<<"Internal State">>, V, A) -> A#{internal_state => V};
proc_field(<<"Run queue">>, V, A) -> A#{run_queue => V};
proc_field(<<"New heap start">>, V, A) -> A#{new_heap_start => V};
proc_field(<<"New heap top">>, V, A) -> A#{new_heap_top => V};
proc_field(<<"Stack top">>, V, A) -> A#{stack_top => V};
proc_field(<<"Stack end">>, V, A) -> A#{stack_end => V};
proc_field(<<"Old heap start">>, V, A) -> A#{old_heap_start => V};
proc_field(<<"Old heap top">>, V, A) -> A#{old_heap_top => V};
proc_field(<<"Old heap end">>, V, A) -> A#{old_heap_end => V};
proc_field(K, V, A) ->
    A#{extra => maps:get(extra, A, []) ++ [{K, V}]}.

%% "[<0.85.0>, #Port<0.4>, {from,<0.78.0>,#Ref<...>}, {to,{name,node},#Ref<...>}]"
links(V0) ->
    V1 = string:trim(V0),
    V2 = case V1 of
             <<"[", R/binary>> -> R;
             _ -> V1
         end,
    V = case byte_size(V2) > 0 andalso binary:last(V2) of
            $] -> binary:part(V2, 0, byte_size(V2) - 1);
            _ -> V2
        end,
    lists:foldr(fun link/2, #{links => [], monitors => [], monitored_by => []},
                split_top(V)).

link(<<"{to,", R/binary>>, #{monitors := Ms} = A) ->
    A#{monitors => [monitor_target(R) | Ms]};
link(<<"{from,", R/binary>>, #{monitored_by := Ms} = A) ->
    A#{monitored_by => [monitor_target(R) | Ms]};
link(<<>>, A) -> A;
link(L, #{links := Ls} = A) ->
    A#{links => [L | Ls]}.

%% "<0.1.0>,#Ref<..>}" or "{name,node},#Ref<..>}" or "node@host,[]}"
monitor_target(<<"{", _/binary>> = R) ->
    case binary:split(R, <<"}">>) of
        [Inner, _] -> <<Inner/binary, "}">>;
        _ -> R
    end;
monitor_target(R) ->
    hd(binary:split(R, <<",">>)).

%% Split on ", " / "," at bracket depth 0.
split_top(Bin) -> split_top(Bin, 0, <<>>, []).

split_top(<<>>, _, Cur, Acc) -> lists:reverse([string:trim(Cur) | Acc]);
split_top(<<C, R/binary>>, D, Cur, Acc) when C =:= ${; C =:= $[; C =:= $< ->
    split_top(R, D + 1, <<Cur/binary, C>>, Acc);
split_top(<<C, R/binary>>, D, Cur, Acc) when C =:= $}; C =:= $]; C =:= $> ->
    split_top(R, max(0, D - 1), <<Cur/binary, C>>, Acc);
split_top(<<$,, R/binary>>, 0, Cur, Acc) ->
    split_top(R, 0, <<>>, [string:trim(Cur) | Acc]);
split_top(<<C, R/binary>>, D, Cur, Acc) ->
    split_top(R, D, <<Cur/binary, C>>, Acc).

%% ---------------------------------------------------------------------
%% =port:Id

port(Body) ->
    lists:foldl(fun port_field/2, #{}, kv(Body)).

port_field({<<"State">>, V}, A) -> A#{state => V};
port_field({<<"Task Flags">>, V}, A) -> A#{task_flags => V};
port_field({<<"Slot">>, V}, A) -> A#{slot => int(V)};
port_field({<<"Connected">>, V}, A) -> A#{connected => V};
port_field({<<"Links">>, V}, A) -> A#{links => split_pids(V)};
port_field({<<"Registered as">>, V}, A) -> A#{name => V};
port_field({<<"Monitors">>, V}, A) -> A#{monitors => paren_items(V)};
port_field({<<"Suspended">>, V}, A) -> A#{suspended => split_pids(V)};
port_field({<<"Port controls linked-in driver">>, V}, A) -> A#{type => <<"driver">>, controls => V};
port_field({<<"Port controls forker process">>, V}, A) -> A#{type => <<"forker">>, controls => V};
port_field({<<"Port controls external process">>, V}, A) -> A#{type => <<"spawn">>, controls => V};
port_field({<<"Port is a file">>, V}, A) -> A#{type => <<"file">>, controls => V};
port_field({<<"Port is UNIX fd not opened by emulator">>, V}, A) -> A#{type => <<"fd">>, controls => V};
port_field({<<"Input">>, V}, A) -> A#{input => int(V)};
port_field({<<"Output">>, V}, A) -> A#{output => int(V)};
port_field({<<"Queue">>, V}, A) -> A#{queue => int(V)};
port_field({<<"Port Data">>, V}, A) -> A#{data => V};
port_field({K, V}, A) -> A#{extra => maps:get(extra, A, []) ++ [{K, V}]}.

%% "(<0.66.0>,#Ref<...>)(<0.67.0>,#Ref<...>)" -> [<<"<0.66.0>">>, ...]
paren_items(V) ->
    [hd(binary:split(I, <<",">>)) || I <- binary:split(V, [<<"(">>, <<")">>], [global, trim_all])].

%% ---------------------------------------------------------------------
%% =ets:Owner, =internal_ets:Descr

ets(Body) ->
    lists:foldl(fun ets_field/2, #{}, kv(Body)).

ets_field({<<"Slot">>, V}, A) -> A#{slot => int(V)};
ets_field({<<"Table">>, V}, A) -> A#{table => V};
ets_field({<<"Name">>, V}, A) -> A#{name => V};
ets_field({<<"Ordered set (AVL tree), Elements">>, V}, A) ->
    A#{type => <<"ordered_set">>, objects => int(V)};
ets_field({<<"Buckets">>, V}, A) -> A#{buckets => int(V)};
ets_field({<<"Objects">>, V}, A) -> A#{objects => int(V)};
ets_field({<<"Words">>, V}, A) -> A#{words => int(V)};
ets_field({<<"Type">>, V}, A) -> A#{type => V};
ets_field({<<"Protection">>, V}, A) -> A#{protection => V};
ets_field({<<"Compressed">>, V}, A) -> A#{compressed => V};
ets_field({<<"Fixed">>, V}, A) -> A#{fixed => V};
ets_field({<<"Write Concurrency">>, V}, A) -> A#{write_concurrency => V};
ets_field({<<"Read Concurrency">>, V}, A) -> A#{read_concurrency => V};
ets_field({<<"Chain Length Min">>, V}, A) -> A#{chain_min => num(V)};
ets_field({<<"Chain Length Max">>, V}, A) -> A#{chain_max => num(V)};
ets_field({<<"Chain Length Avg">>, V}, A) -> A#{chain_avg => num(V)};
ets_field({<<"Chain Length Std Dev">>, V}, A) -> A#{chain_stddev => num(V)};
ets_field({<<"Chain Length Expected Std Dev">>, V}, A) -> A#{chain_exp_stddev => num(V)};
ets_field({K, V}, A) -> A#{extra => maps:get(extra, A, []) ++ [{K, V}]}.

%% ---------------------------------------------------------------------
%% =timer:Owner

timer(Body) ->
    lists:foldl(fun({<<"Message">>, V}, A) -> A#{msg => V};
                   ({<<"Time left">>, V}, A) -> A#{left => int(V)};
                   (_, A) -> A
                end, #{}, kv(Body)).

%% ---------------------------------------------------------------------
%% =visible_node:Ch, =hidden_node:Ch, =not_connected:Ch

dist_node(Body) ->
    lists:foldl(fun node_field/2, #{links => [], monitors => [], monitored_by => []},
                lists:reverse(kv(Body))).

node_field({<<"Name">>, V}, A) -> A#{name => V};
node_field({<<"Controller">>, V}, A) -> A#{controller => V};
node_field({<<"Creation">>, V}, A) ->
    A#{creation => [I || C <- binary:split(V, <<" ">>, [global, trim_all]),
                         I <- [int(C)], is_integer(I)]};
node_field({<<"Remote link">>, V}, #{links := L} = A) -> A#{links => [pair(V) | L]};
node_field({<<"Remote monitoring">>, V}, #{monitors := L} = A) -> A#{monitors => [pair(V) | L]};
node_field({<<"Remotely monitored by">>, V}, #{monitored_by := L} = A) ->
    A#{monitored_by => [pair(V) | L]};
node_field({<<"Error">>, V}, A) -> A#{error => V};
node_field(_, A) -> A.

pair(V) ->
    case binary:split(string:trim(V), <<" ">>) of
        [L, R] -> #{local => L, remote => string:trim(R)};
        [L] -> #{local => L, remote => null}
    end.

%% ---------------------------------------------------------------------
%% =mod:Name, =fun

mod(Body) ->
    lists:foldl(fun({<<"Current size">>, V}, A) -> A#{cur => int(V)};
                   ({<<"Old size">>, V}, A) -> A#{old => int(V)};
                   ({<<"Current attributes">>, V}, A) -> A#{cur_attrib => V};
                   ({<<"Current compilation info">>, V}, A) -> A#{cur_comp => V};
                   ({<<"Old attributes">>, V}, A) -> A#{old_attrib => V};
                   ({<<"Old compilation info">>, V}, A) -> A#{old_comp => V};
                   (_, A) -> A
                end, #{}, kv(Body)).

fun_info(Body) ->
    lists:foldl(fun({<<"Module">>, V}, A) -> A#{module => V};
                   ({<<"Uniq">>, V}, A) -> A#{uniq => int(V)};
                   ({<<"Index">>, V}, A) -> A#{index => int(V)};
                   ({<<"Address">>, V}, A) -> A#{address => V};
                   ({<<"Native_address">>, V}, A) -> A#{native_address => V};
                   ({<<"Refc">>, V}, A) -> A#{refc => int(V)};
                   (_, A) -> A
                end, #{}, kv(Body)).

%% ---------------------------------------------------------------------
%% =memory, =hash_table:Name, =index_table:Name, =allocated_areas

memory(Body) ->
    maps:from_list([{K, int(V)} || {K, V} <- kv(Body), int(V) =/= null]).

hash_table(Body) ->
    maps:from_list([{K, int(V)} || {K, V} <- kv(Body),
                                   lists:member(K, [<<"size">>, <<"used">>, <<"objs">>, <<"depth">>])]).

index_table(Body) ->
    maps:from_list([{K, int(V)} || {K, V} <- kv(Body),
                                   lists:member(K, [<<"size">>, <<"used">>, <<"limit">>,
                                                    <<"rate">>, <<"entries">>])]).

%% "atom_space: 131104 114462" -> [{<<"atom_space">>, 131104, 114462}]
allocated_areas(Body) ->
    [case [int(X) || X <- binary:split(V, <<" ">>, [global, trim_all])] of
         [A, U | _] -> {K, A, U};
         [A] -> {K, A, null};
         [] -> {K, null, null}
     end || {K, V} <- kv(Body)].

%% =allocator:Name -> [{Key, [Value]}], values split on spaces.
allocator(Body) ->
    [{K, binary:split(V, <<" ">>, [global, trim_all])} || {K, V} <- kv(Body)].

%% ---------------------------------------------------------------------
%% =scheduler:N, =dirty_*_scheduler:N, =dirty_*_run_queue

scheduler(Body) ->
    sched(lines(Body), #{}).

sched([], A) -> A;
sched([<<"Current Process Limited Stack Trace:", _/binary>> | Ls], A) ->
    A#{stack => Ls};
sched([L | Ls], A) ->
    {K, V} = split_kv(L),
    sched(Ls, sched_field(K, V, A)).

sched_field(<<"Current Process">>, V, A) -> A#{process => V};
sched_field(<<"Current Port">>, V, A) -> A#{port => V};
sched_field(<<"Scheduler Sleep Info Flags">>, V, A) -> A#{sleep_flags => V};
sched_field(<<"Scheduler Sleep Info Aux Work">>, V, A) -> A#{sleep_aux => V};
sched_field(<<"Run Queue Max Length">>, V, A) -> A#{rq_max => int(V)};
sched_field(<<"Run Queue High Length">>, V, A) -> A#{rq_high => int(V)};
sched_field(<<"Run Queue Normal Length">>, V, A) -> A#{rq_normal => int(V)};
sched_field(<<"Run Queue Low Length">>, V, A) -> A#{rq_low => int(V)};
sched_field(<<"Run Queue Port Length">>, V, A) -> A#{rq_port => int(V)};
sched_field(<<"Run Queue Flags">>, V, A) -> A#{rq_flags => V};
sched_field(<<"Current Process State">>, V, A) -> A#{process_state => V};
sched_field(<<"Current Process Internal State">>, V, A) -> A#{process_internal_state => V};
sched_field(<<"Current Process Program counter">>, V, A) -> A#{process_pc => V};
sched_field(<<"Current Process CP">>, V, A) -> A#{process_cp => V};
sched_field(K, V, A) -> A#{extra => maps:get(extra, A, []) ++ [{K, V}]}.
