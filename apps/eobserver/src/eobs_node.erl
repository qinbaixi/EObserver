%% @doc One process per observed node: connects, loads the agent, watches
%% for nodedown and reconnects with backoff.
-module(eobs_node).
-behaviour(gen_server).

-export([start_link/2, info/1, reconnect/2, stop/1, call/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CALL_TIMEOUT, 10000).
-define(MIN_RETRY, 1000).
-define(MAX_RETRY, 15000).

start_link(Node, Cookie) ->
    gen_server:start_link(?MODULE, {Node, Cookie}, []).

info(Pid) ->
    gen_server:call(Pid, info).

reconnect(Pid, Cookie) ->
    gen_server:cast(Pid, {reconnect, Cookie}).

stop(Pid) ->
    gen_server:stop(Pid).

%% Calls a function of the agent on Node. Runs in the caller's process so
%% that slow collections never block the node's state process.
-spec call(node(), atom(), [term()], timeout()) -> {ok, term()} | {error, term()}.
call(Node, Fun, Args, Timeout) ->
    try
        {ok, erpc:call(Node, eobs_agent, Fun, Args, Timeout)}
    catch
        error:{erpc, Reason} -> {error, Reason};
        Class:Reason -> {error, {Class, Reason}}
    end.

%% gen_server

init({Node, Cookie}) ->
    process_flag(trap_exit, true),
    self() ! connect,
    {ok, #{node => Node,
           cookie => Cookie,
           status => connecting,
           error => undefined,
           summary => undefined,
           agent => undefined,
           retry => ?MIN_RETRY,
           timer => undefined}}.

handle_call(info, _From, State) ->
    {reply, public(State), State}.

%% No cookie given (the UI's retry button): keep the one it was added with.
handle_cast({reconnect, undefined}, #{cookie := Cookie} = State) when Cookie =/= undefined ->
    handle_cast({reconnect, Cookie}, State);
handle_cast({reconnect, Cookie}, State) ->
    State1 = cancel_timer(State#{cookie := Cookie, retry := ?MIN_RETRY}),
    self() ! connect,
    {noreply, State1}.

handle_info(connect, State) ->
    {noreply, do_connect(State#{timer := undefined})};
handle_info({nodedown, Node}, #{node := Node} = State) ->
    State1 = set_status(disconnected, nodedown, State#{agent := undefined}),
    {noreply, schedule_retry(State1)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{node := Node, status := connected, agent := #{loaded := true}}) ->
    eobs_inject:unload(Node);
terminate(_Reason, _State) ->
    ok.

%% internal

do_connect(#{node := Node, cookie := Cookie} = State) ->
    case eobs_dist:ensure_started(Node) of
        ok ->
            set_cookie(Node, Cookie),
            case net_kernel:connect_node(Node) of
                true ->
                    erlang:monitor_node(Node, true),
                    after_connect(State);
                _ ->
                    schedule_retry(set_status(disconnected, unreachable, State))
            end;
        {error, Reason} ->
            %% Not retryable: the tool node itself cannot reach this target.
            set_status(failed, Reason, State)
    end.

after_connect(#{node := Node} = State) ->
    case eobs_inject:ensure_loaded(Node) of
        {ok, Agent} ->
            Summary = case call(Node, node_summary, [], ?CALL_TIMEOUT) of
                          {ok, S} -> S;
                          {error, _} -> undefined
                      end,
            set_status(connected, undefined,
                       State#{agent := Agent, summary := Summary, retry := ?MIN_RETRY});
        {error, Reason} ->
            set_status(failed, {agent_load_failed, Reason}, State)
    end.

set_cookie(_Node, undefined) -> ok;
set_cookie(Node, Cookie) -> erlang:set_cookie(Node, Cookie).

set_status(Status, Error, State) ->
    State1 = State#{status := Status, error := Error},
    eobs_events:publish(node_status, public(State1)),
    State1.

schedule_retry(#{retry := Retry} = State) ->
    Ref = erlang:send_after(Retry, self(), connect),
    State#{timer := Ref, retry := min(Retry * 2, ?MAX_RETRY)}.

cancel_timer(#{timer := undefined} = State) ->
    State;
cancel_timer(#{timer := Ref} = State) ->
    _ = erlang:cancel_timer(Ref),
    State#{timer := undefined}.

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
format_error({name_domain_mismatch, Have, Want}) ->
    iolist_to_binary(io_lib:format("EObserver already runs with ~p, but this node needs ~p",
                                   [Have, Want]));
format_error(Other) ->
    iolist_to_binary(io_lib:format("~0p", [Other])).
