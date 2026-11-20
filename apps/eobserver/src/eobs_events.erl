%% @doc Fan-out of tool events (node status changes, dump progress) to
%% connected browsers. Encodes the JSON frame once per broadcast so
%% large payloads are shared as a single refc binary across all sockets.
-module(eobs_events).

-export([subscribe/0, publish/2]).

-define(GROUP, node_events).

subscribe() ->
    pg:join(eobs, ?GROUP, self()).

publish(Event, Data) ->
    case pg:get_members(eobs, ?GROUP) of
        [] ->
            ok;
        Members ->
            Frame = eobs_json:encode(#{type => event, event => Event, data => Data}),
            [Pid ! {eobs_frame, Frame} || Pid <- Members],
            ok
    end.
