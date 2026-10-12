%% @doc Fan-out of tool events (node status changes) to connected browsers.
-module(eobs_events).

-export([subscribe/0, publish/2]).

-define(GROUP, node_events).

subscribe() ->
    pg:join(eobs, ?GROUP, self()).

publish(Event, Data) ->
    [Pid ! {eobs_event, Event, Data} || Pid <- pg:get_members(eobs, ?GROUP)],
    ok.
