%% @doc Turns two consecutive raw load samples from eobs_agent into rates
%% for the load charts.
-module(eobs_load).

-export([rates/2]).

%% Returns the chart point for Cur, using Prev (or undefined for the
%% first sample, in which case rates are null).
-spec rates(map() | undefined, map()) -> map().
rates(Prev, #{time := T1} = Cur) ->
    Base = #{time => erlang:system_time(millisecond),
             run_queue => maps:get(run_queue, Cur),
             process_count => maps:get(process_count, Cur),
             memory => maps:get(memory, Cur)},
    case Prev of
        #{time := T0} when T1 > T0 ->
            Secs = (T1 - T0) / 1000000,
            Base#{schedulers => scheduler_util(Prev, Cur),
                  io_input => rate(io_input, Prev, Cur, Secs),
                  io_output => rate(io_output, Prev, Cur, Secs),
                  reductions => rate(reductions, Prev, Cur, Secs)};
        _ ->
            Base#{schedulers => null, io_input => null, io_output => null,
                  reductions => null}
    end.

rate(Key, Prev, Cur, Secs) ->
    max(0, maps:get(Key, Cur) - maps:get(Key, Prev)) / Secs.

%% Per scheduler utilisation in [0, 1], tagged with the scheduler type.
scheduler_util(#{scheduler_wall_time := Swt0},
               #{scheduler_wall_time := Swt1, schedulers := Normal,
                 dirty_cpu_schedulers := DirtyCpu})
  when is_list(Swt0), is_list(Swt1) ->
    Zipped = lists:zip(Swt0, Swt1),
    [#{id => Id,
       type => scheduler_type(Id, Normal, DirtyCpu),
       util => util(A1 - A0, T1 - T0)}
     || {{Id, A0, T0}, {Id, A1, T1}} <- Zipped];
scheduler_util(_, _) ->
    null.

util(_Active, Total) when Total =< 0 -> 0.0;
util(Active, Total) -> min(1.0, max(0.0, Active / Total)).

scheduler_type(Id, Normal, _) when Id =< Normal -> normal;
scheduler_type(Id, Normal, DirtyCpu) when Id =< Normal + DirtyCpu -> dirty_cpu;
scheduler_type(_, _, _) -> dirty_io.
