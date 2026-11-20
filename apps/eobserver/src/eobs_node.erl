%% @doc One process per observed node: connects, loads the agent, watches
%% for nodedown and reconnects with backoff.
%%
%% Connection attempts and agent injection run in a monitored worker
%% process so the gen_server always responds promptly to info/1,
%% reconnect/2 and stop/1 even when a target is unreachable or stalled.
-module(eobs_node).
-behaviour(gen_server).

-export([start_link/2, info/1, reconnect/2, stop/1, call/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-define(CALL_TIMEOUT, 10000).
-define(STOP_TIMEOUT, 4500).
-define(MIN_RETRY, 1000).
-define(MAX_RETRY, 15000).

start_link(Node, Cookie) ->
    gen_server:start_link(?MODULE, {Node, Cookie}, []).

info(Pid) ->
    gen_server:call(Pid, info).

reconnect(Pid, Cookie) ->
    gen_server:cast(Pid, {reconnect, Cookie}).

stop(Pid) ->
    gen_server:stop(Pid, normal, ?STOP_TIMEOUT).

%% Calls a function of the agent on Node. Runs in the caller's process so
%% that slow collections never block the node's state process.
-spec call(node(), atom(), [term()], timeout()) -> {ok, term()} | {error, term()}.
call(Node, Fun, Args, Timeout) ->
    case eobs_nodes:is_observed(Node) of
        true -> call_direct(Node, Fun, Args, Timeout);
        false -> {error, not_observed}
    end.

call_direct(Node, Fun, Args, Timeout) ->
    try
        {ok, erpc:call(Node, eobs_agent, Fun, Args, Timeout)}
    catch
        error:{erpc, Reason} -> {error, Reason};
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Redact cookie from crash reports / sys:get_status.
format_status(#{state := State} = Status) when is_map(State) ->
    Status#{state := State#{cookie => redacted}};
format_status(Status) ->
    Status.

%% gen_server

init({Node, Cookie}) ->
    process_flag(trap_exit, true),
    State = #{node => Node,
              cookie => Cookie,
              status => connecting,
              error => undefined,
              summary => undefined,
              agent => undefined,
              retry => ?MIN_RETRY,
              timer => undefined,
              timer_ref => undefined,
              worker => undefined,
              monitored => false,
              ours => false},
    self() ! connect,
    {ok, State}.

handle_call(info, _From, State) ->
    {reply, public(State), State}.

%% No cookie given (the UI's retry button): keep the one it was added with.
handle_cast({reconnect, undefined}, #{cookie := Cookie} = State) when Cookie =/= undefined ->
    handle_cast({reconnect, Cookie}, State);
handle_cast({reconnect, Cookie}, #{node := Node, cookie := OldCookie, status := Status} = State) ->
    State0 = stop_worker(cancel_timer(State#{cookie := Cookie, retry := ?MIN_RETRY})),
    State1 = case Status =:= connected andalso Cookie =/= OldCookie of
                 true ->
                     State0a = clear_monitor(State0),
                     _ = erlang:disconnect_node(Node),
                     State0a#{status := connecting, agent := undefined};
                 false ->
                     State0
             end,
    {noreply, start_connect(true, State1)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, State) ->
    {noreply, start_connect(true, cancel_timer(State))};
handle_info({retry, Ref}, #{timer_ref := Ref} = State) ->
    {noreply, start_connect(false, State#{timer := undefined, timer_ref := undefined})};
handle_info({retry, _Stale}, State) ->
    {noreply, State};
handle_info({'DOWN', WRef, process, WPid, Reason}, #{worker := {WPid, WRef}} = State) ->
    {noreply, handle_connect_result(Reason, State#{worker := undefined})};
handle_info({nodedown, Node}, #{node := Node, monitored := true} = State) ->
    State1 = set_status(disconnected, nodedown,
                        stop_worker(State#{agent := undefined, monitored := false})),
    {noreply, schedule_retry(State1)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{node := Node} = State) ->
    _ = stop_worker(cancel_timer(State)),
    case State of
        #{status := connected, agent := #{loaded := true}} -> eobs_inject:unload(Node);
        _ -> ok
    end,
    %% Drop the hidden connection too, so the node really is no longer
    %% observed (and stops showing EObserver in its connections).
    %% Distribution may be down while the tool switches name modes.
    catch erlang:monitor_node(Node, false),
    _ = erlang:disconnect_node(Node),
    ok.

%% internal

start_connect(MaySwitch, #{node := Node, cookie := Cookie, ours := Ours} = State) ->
    State0 = stop_worker(cancel_timer(State)),
    {Pid, Ref} = spawn_monitor(fun() -> connect_worker(Node, Cookie, MaySwitch, Ours) end),
    State0#{worker := {Pid, Ref}}.

connect_worker(Node, Cookie, MaySwitch, Ours) ->
    case eobs_dist:connect(Node, Cookie, MaySwitch) of
        ok ->
            case eobs_inject:ensure_loaded(Node) of
                {ok, Agent0} ->
                    Agent = case {Agent0, Ours} of
                                {#{method := already_loaded}, true} -> Agent0#{loaded := true};
                                _ -> Agent0
                            end,
                    Summary = case call_direct(Node, node_summary, [], ?CALL_TIMEOUT) of
                                  {ok, S} -> S;
                                  {error, _} -> undefined
                              end,
                    exit({connect_ok, Agent, Summary});
                {error, {transport, _}} ->
                    exit({connect_retry, unreachable});
                {error, Reason} ->
                    exit({connect_failed, {agent_load_failed, Reason}})
            end;
        {error, unreachable} ->
            exit({connect_retry, unreachable});
        {error, Reason} ->
            exit({connect_failed, Reason})
    end.

handle_connect_result({connect_ok, Agent, Summary}, #{node := Node, monitored := Mon} = State) ->
    case Mon of
        false -> erlang:monitor_node(Node, true);
        true -> ok
    end,
    set_status(connected, undefined,
               State#{agent := Agent, summary := Summary, retry := ?MIN_RETRY,
                      monitored := true, ours := maps:get(loaded, Agent)});
handle_connect_result({connect_retry, Reason}, State) ->
    State1 = clear_monitor(State),
    schedule_retry(set_status(disconnected, Reason, State1));
handle_connect_result({connect_failed, Reason}, State) ->
    State1 = clear_monitor(State),
    set_status(failed, Reason, State1);
handle_connect_result(Reason, State) ->
    State1 = clear_monitor(State),
    schedule_retry(set_status(disconnected, Reason, State1)).

clear_monitor(#{node := Node, monitored := true} = State) ->
    catch erlang:monitor_node(Node, false),
    State#{monitored := false};
clear_monitor(State) ->
    State.

stop_worker(#{worker := {Pid, Ref}} = State) ->
    erlang:demonitor(Ref, [flush]),
    exit(Pid, kill),
    State#{worker := undefined};
stop_worker(State) ->
    State.

set_status(Status, Error, #{node := Node} = State) ->
    State1 = State#{status := Status, error := Error},
    Pub = public(State1),
    eobs_nodes:update_info(Node, Pub),
    eobs_events:publish(node_status, Pub),
    State1.

schedule_retry(#{retry := Retry} = State) ->
    State0 = cancel_timer(State),
    TRef = make_ref(),
    Timer = erlang:send_after(Retry, self(), {retry, TRef}),
    State0#{timer := Timer, timer_ref := TRef, retry := min(Retry * 2, ?MAX_RETRY)}.

cancel_timer(#{timer := undefined} = State) ->
    State#{timer_ref := undefined};
cancel_timer(#{timer := Timer} = State) ->
    _ = erlang:cancel_timer(Timer),
    State#{timer := undefined, timer_ref := undefined}.

public(#{node := Node, status := Status, error := Error,
         summary := Summary, agent := Agent}) ->
    #{node => Node,
      status => Status,
      error => format_error(Error),
      summary => Summary,
      agent => Agent}.

format_error(undefined) -> null;
format_error(unreachable) -> <<"Node is unreachable (check the node name, cookie and network)">>;
format_error(nodedown) -> <<"Connection lost">>;
format_error({name_domain_mismatch, Have, Want, []}) ->
    iolist_to_binary(io_lib:format("EObserver already runs with ~p, but this node needs ~p",
                                   [Have, Want]));
format_error({name_domain_mismatch, Have, Want, Busy}) ->
    iolist_to_binary(io_lib:format("EObserver already runs with ~p for ~ts, but this node needs ~p",
                                   [Have, lists:join(", ", [atom_to_list(N) || N <- Busy]),
                                    Want]));
format_error(Other) ->
    iolist_to_binary(io_lib:format("~0p", [Other])).
