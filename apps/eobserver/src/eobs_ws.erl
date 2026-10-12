%% @doc WebSocket endpoint. Protocol (JSON text frames):
%%
%%   -> {"type":"req","id":1,"method":"nodes.list","params":{}}
%%   <- {"type":"resp","id":1,"ok":true,"result":...}
%%   -> {"type":"sub","id":"s1","topic":"node.summary","params":{...},"interval":2000}
%%   <- {"type":"push","id":"s1","ok":true,"data":...}
%%   -> {"type":"unsub","id":"s1"}
%%   <- {"type":"event","event":"node_status","data":...}
%%
%% Each request and each subscription tick runs in its own worker process,
%% so a slow node never stalls the socket. A subscription skips a tick while
%% its previous collection is still running.
-module(eobs_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).
-export([same_origin/2]).

-define(MIN_INTERVAL, 500).
-define(DEFAULT_INTERVAL, 2000).

init(Req, Opts) ->
    case same_origin(cowboy_req:header(<<"origin">>, Req), cowboy_req:header(<<"host">>, Req)) of
        true ->
            {cowboy_websocket, Req, #{subs => #{}}, #{idle_timeout => 120000,
                                                       max_frame_size => 1048576}};
        false ->
            {ok, cowboy_req:reply(403, #{}, <<"cross-origin WebSocket refused\n">>, Req), Opts}
    end.

%% Browsers do not apply CORS to WebSockets, so without this check any web
%% page the user visits could drive the UI's socket on localhost.
same_origin(undefined, _Host) ->
    true;
same_origin(Origin, Host) when is_binary(Host) ->
    case uri_string:parse(Origin) of
        #{host := OHost} = U ->
            OPort = maps:get(port, U, default_port(maps:get(scheme, U, <<"http">>))),
            {HHost, HPort} = split_host(Host),
            string:lowercase(OHost) =:= string:lowercase(HHost) andalso OPort =:= HPort;
        _ ->
            false
    end;
same_origin(_, _) ->
    false.

split_host(Host) ->
    case string:split(Host, <<":">>, trailing) of
        [H, P] when H =/= <<>> ->
            try {string:trim(H, both, "[]"), binary_to_integer(P)}
            catch _:_ -> {Host, 80}
            end;
        _ -> {Host, 80}
    end.

default_port(<<"https">>) -> 443;
default_port(_) -> 80.

websocket_init(State) ->
    eobs_events:subscribe(),
    {[], State}.

websocket_handle({text, Data}, State) ->
    try eobs_json:decode(Data) of
        Msg -> handle_msg(Msg, State)
    catch _:_ ->
        {[], State}
    end;
websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info({eobs_event, Event, Data}, State) ->
    {[frame(#{type => event, event => Event, data => Data})], State};
websocket_info({resp, Id, Result}, State) ->
    {[frame(result(#{type => resp, id => Id}, result, Result))], State};
websocket_info({tick, Id}, State) ->
    {[], start_tick(Id, State)};
websocket_info({push, Id, Worker, Result, TopicState}, #{subs := Subs} = State) ->
    case Subs of
        #{Id := #{worker := Worker} = Sub} ->
            Sub1 = Sub#{worker := undefined, state := TopicState},
            {[frame(result(#{type => push, id => Id}, data, Result))],
             State#{subs := Subs#{Id := Sub1}}};
        _ ->
            {[], State}
    end;
websocket_info(_Info, State) ->
    {[], State}.

%% internal

handle_msg(#{<<"type">> := <<"req">>, <<"id">> := Id, <<"method">> := Method} = Msg, State) ->
    Params = maps:get(<<"params">>, Msg, #{}),
    Self = self(),
    spawn(fun() -> Self ! {resp, Id, run(fun() -> eobs_api:request(Method, Params) end)} end),
    {[], State};
handle_msg(#{<<"type">> := <<"sub">>, <<"id">> := Id, <<"topic">> := Topic} = Msg,
           #{subs := Subs} = State) ->
    Interval = max(?MIN_INTERVAL, maps:get(<<"interval">>, Msg, ?DEFAULT_INTERVAL)),
    Sub = #{topic => Topic,
            params => maps:get(<<"params">>, Msg, #{}),
            interval => Interval,
            worker => undefined,
            timer => undefined,
            state => undefined},
    State1 = State#{subs := maps:put(Id, Sub, cancel(Id, Subs))},
    {[], start_tick(Id, State1)};
handle_msg(#{<<"type">> := <<"unsub">>, <<"id">> := Id}, #{subs := Subs} = State) ->
    {[], State#{subs := cancel(Id, Subs)}};
handle_msg(_Msg, State) ->
    {[], State}.

start_tick(Id, #{subs := Subs} = State) ->
    case Subs of
        #{Id := #{interval := Interval, topic := Topic, params := Params,
                  state := TopicState} = Sub} ->
            Worker = case Sub of
                         #{worker := undefined} ->
                             spawn_collect(Id, Topic, Params, TopicState);
                         #{worker := Busy} -> Busy
                     end,
            Timer = erlang:send_after(Interval, self(), {tick, Id}),
            State#{subs := Subs#{Id := Sub#{worker := Worker, timer := Timer}}};
        _ ->
            State
    end.

spawn_collect(Id, Topic, Params, TopicState) ->
    Self = self(),
    spawn(fun() ->
                  {Result, TopicState1} =
                      case run(fun() -> eobs_api:collect(Topic, Params, TopicState) end) of
                          {ok, {Data, NewState}} -> {{ok, Data}, NewState};
                          Error -> {Error, TopicState}
                      end,
                  Self ! {push, Id, self(), Result, TopicState1}
          end).

cancel(Id, Subs) ->
    case maps:take(Id, Subs) of
        {#{timer := Timer}, Rest} ->
            _ = Timer =/= undefined andalso erlang:cancel_timer(Timer),
            Rest;
        error ->
            Subs
    end.

run(Fun) ->
    try Fun() of
        ok -> {ok, null};
        {ok, _} = Ok -> Ok;
        {ok, Data, NewState} -> {ok, {Data, NewState}};
        {error, _} = Error -> Error;
        Other -> {error, {bad_return, Other}}
    catch
        throw:{error, _} = Error -> Error;
        Class:Reason:Stack ->
            logger:warning("eobs request crashed: ~p:~p ~p", [Class, Reason, Stack]),
            {error, internal_error}
    end.

result(Base, Key, {ok, Value}) ->
    Base#{ok => true, Key => Value};
result(Base, _Key, {error, Reason}) ->
    Base#{ok => false, error => error_text(Reason)}.

error_text(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
error_text(Reason) when is_binary(Reason) -> Reason;
error_text(Reason) -> iolist_to_binary(io_lib:format("~0tp", [Reason])).

frame(Map) ->
    {text, eobs_json:encode(Map)}.
