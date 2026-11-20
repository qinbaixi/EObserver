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

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-export([same_origin/2]).

-define(MIN_INTERVAL, 500).
-define(MAX_INTERVAL, 3600000).
-define(DEFAULT_INTERVAL, 2000).
-define(MAX_SUBS, 64).
-define(MAX_REQS, 64).

init(Req, Opts) ->
    case same_origin(cowboy_req:header(<<"origin">>, Req), cowboy_req:header(<<"host">>, Req)) of
        true ->
            {cowboy_websocket, Req, #{subs => #{}, reqs => #{}},
             #{idle_timeout => 120000, max_frame_size => 1048576}};
        false ->
            {ok, cowboy_req:reply(403, #{}, <<"cross-origin WebSocket refused\n">>, Req), Opts}
    end.

%% Browsers do not apply CORS to WebSockets, so without this check any web
%% page the user visits could drive the UI's socket on localhost.
same_origin(undefined, _Host) ->
    true;
same_origin(Origin, Host) when is_binary(Origin), is_binary(Host) ->
    case uri_string:parse(Origin) of
        #{scheme := Scheme, host := OHost} = U
          when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
            OPort = maps:get(port, U, default_port(Scheme)),
            case split_host(Host, Scheme) of
                {HHost, HPort} ->
                    string:lowercase(OHost) =:= string:lowercase(HHost) andalso OPort =:= HPort;
                error ->
                    false
            end;
        _ ->
            false
    end;
same_origin(_, _) ->
    false.

split_host(<<"[", Rest/binary>>, Scheme) ->
    case binary:split(Rest, <<"]">>) of
        [H, <<>>] -> {H, default_port(Scheme)};
        [H, <<":", P/binary>>] ->
            try {H, binary_to_integer(P)}
            catch _:_ -> error
            end;
        _ -> error
    end;
split_host(Host, Scheme) ->
    case string:split(Host, <<":">>, trailing) of
        [H, P] when H =/= <<>> ->
            try {H, binary_to_integer(P)}
            catch _:_ -> error
            end;
        [H] when H =/= <<>> -> {H, default_port(Scheme)};
        _ -> error
    end.

default_port(<<"https">>) -> 443;
default_port(_) -> 80.

websocket_init(State) ->
    eobs_events:subscribe(),
    {[], State}.

websocket_handle({text, Data}, State) ->
    try
        Msg = eobs_json:decode(Data),
        handle_msg(Msg, State)
    catch _:_ ->
        {[], State}
    end;
websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info({eobs_frame, Bin}, State) ->
    {[{text, Bin}], State};
websocket_info({eobs_event, Event, Data}, State) ->
    {[safe_frame(#{type => event, event => Event, data => Data})], State};
websocket_info({resp_frame, Pid, Bin}, #{reqs := Reqs} = State) ->
    Reqs1 = drop_req(Pid, Reqs),
    {[{text, Bin}], State#{reqs := Reqs1}};
websocket_info({tick, Id, TickRef}, State) ->
    {[], start_tick(Id, TickRef, State)};
websocket_info({push_frame, Id, Worker, Bin, TopicState}, #{subs := Subs} = State) ->
    case Subs of
        #{Id := #{worker := {Worker, MonRef}} = Sub} ->
            erlang:demonitor(MonRef, [flush]),
            Sub1 = Sub#{worker := undefined, state := TopicState},
            {[{text, Bin}], State#{subs := Subs#{Id := Sub1}}};
        _ ->
            {[], State}
    end;
websocket_info({'DOWN', MonRef, process, Pid, _Reason}, #{subs := Subs, reqs := Reqs} = State) ->
    case maps:take(Pid, Reqs) of
        {MonRef, Reqs1} ->
            {[], State#{reqs := Reqs1}};
        _ ->
            Subs1 = clear_worker(Pid, MonRef, Subs),
            {[], State#{subs := Subs1}}
    end;
websocket_info(_Info, State) ->
    {[], State}.

terminate(_Reason, _Req, #{subs := Subs, reqs := Reqs}) ->
    maps:foreach(fun(_, #{timer := Timer, worker := W}) ->
                         _ = Timer =/= undefined andalso erlang:cancel_timer(Timer),
                         kill_worker(W)
                 end, Subs),
    maps:foreach(fun(Pid, _) -> exit(Pid, kill) end, Reqs),
    ok;
terminate(_Reason, _Req, _State) ->
    ok.

%% internal

handle_msg(#{<<"type">> := <<"req">>, <<"id">> := Id, <<"method">> := Method} = Msg,
           #{reqs := Reqs} = State) when is_binary(Method) ->
    case map_size(Reqs) >= ?MAX_REQS of
        true ->
            {[safe_frame(result(#{type => resp, id => Id}, result, {error, busy}))], State};
        false ->
            Params = valid_params(maps:get(<<"params">>, Msg, #{})),
            Self = self(),
            {Pid, MonRef} = spawn_monitor(fun() ->
                Res = run(fun() -> eobs_api:request(Method, Params) end),
                Bin = encode_safe(result(#{type => resp, id => Id}, result, Res)),
                Self ! {resp_frame, self(), Bin}
            end),
            {[], State#{reqs := Reqs#{Pid => MonRef}}}
    end;
handle_msg(#{<<"type">> := <<"sub">>, <<"id">> := Id, <<"topic">> := Topic} = Msg,
           #{subs := Subs} = State) when is_binary(Topic) ->
    Subs0 = cancel(Id, Subs),
    case map_size(Subs0) >= ?MAX_SUBS of
        true ->
            {[safe_frame(result(#{type => push, id => Id}, data, {error, too_many_subscriptions}))],
             State#{subs := Subs0}};
        false ->
            Interval = valid_interval(maps:get(<<"interval">>, Msg, ?DEFAULT_INTERVAL)),
            TickRef = make_ref(),
            Sub = #{topic => Topic,
                    params => valid_params(maps:get(<<"params">>, Msg, #{})),
                    interval => Interval,
                    tick_ref => TickRef,
                    worker => undefined,
                    timer => undefined,
                    state => undefined},
            State1 = State#{subs := maps:put(Id, Sub, Subs0)},
            {[], start_tick(Id, TickRef, State1)}
    end;
handle_msg(#{<<"type">> := <<"unsub">>, <<"id">> := Id}, #{subs := Subs} = State) ->
    {[], State#{subs := cancel(Id, Subs)}};
handle_msg(_Msg, State) ->
    {[], State}.

valid_interval(I) when is_integer(I), I >= ?MIN_INTERVAL, I =< ?MAX_INTERVAL -> I;
valid_interval(I) when is_integer(I), I < ?MIN_INTERVAL -> ?MIN_INTERVAL;
valid_interval(I) when is_integer(I), I > ?MAX_INTERVAL -> ?MAX_INTERVAL;
valid_interval(_) -> ?DEFAULT_INTERVAL.

valid_params(P) when is_map(P) -> P;
valid_params(_) -> #{}.

start_tick(Id, TickRef, #{subs := Subs} = State) ->
    case Subs of
        #{Id := #{tick_ref := TickRef, interval := Interval, topic := Topic,
                  params := Params, state := TopicState} = Sub} ->
            Worker = case Sub of
                         #{worker := undefined} ->
                             spawn_collect(Id, Topic, Params, TopicState);
                         #{worker := Busy} -> Busy
                     end,
            NextRef = make_ref(),
            Timer = erlang:send_after(Interval, self(), {tick, Id, NextRef}),
            State#{subs := Subs#{Id := Sub#{worker := Worker, timer := Timer, tick_ref := NextRef}}};
        _ ->
            State
    end.

spawn_collect(Id, Topic, Params, TopicState) ->
    Self = self(),
    spawn_monitor(fun() ->
                      {Result, TopicState1} =
                          case run(fun() -> eobs_api:collect(Topic, Params, TopicState) end) of
                              {ok, {Data, NewState}} -> {{ok, Data}, NewState};
                              Error -> {Error, TopicState}
                          end,
                      Bin = encode_safe(result(#{type => push, id => Id}, data, Result)),
                      Self ! {push_frame, Id, self(), Bin, TopicState1}
                  end).

cancel(Id, Subs) ->
    case maps:take(Id, Subs) of
        {#{timer := Timer, worker := W}, Rest} ->
            _ = Timer =/= undefined andalso erlang:cancel_timer(Timer),
            kill_worker(W),
            Rest;
        error ->
            Subs
    end.

kill_worker({Pid, MonRef}) ->
    erlang:demonitor(MonRef, [flush]),
    exit(Pid, kill),
    ok;
kill_worker(_) ->
    ok.

drop_req(Pid, Reqs) ->
    case maps:take(Pid, Reqs) of
        {MonRef, Rest} ->
            erlang:demonitor(MonRef, [flush]),
            Rest;
        error ->
            Reqs
    end.

clear_worker(Pid, MonRef, Subs) ->
    maps:map(fun(_, #{worker := {P, M}} = Sub) when P =:= Pid, M =:= MonRef ->
                     Sub#{worker := undefined};
                (_, Sub) ->
                     Sub
             end, Subs).

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

encode_safe(Map) ->
    try eobs_json:encode(Map)
    catch Class:Reason ->
        logger:warning("eobs json encode failed: ~p:~p", [Class, Reason]),
        eobs_json:encode(maps:merge(maps:with([type, id, event], Map),
                                    #{ok => false, error => <<"encode_failed">>}))
    end.

safe_frame(Map) ->
    {text, encode_safe(Map)}.
