%% @doc Registry of observed nodes. Starts one eobs_node process per
%% target and answers lookups from the API layer.
-module(eobs_nodes).
-behaviour(gen_server).

-export([start_link/0, connect/2, disconnect/1, list/0, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec connect(node(), atom() | undefined) -> {ok, pid()} | {error, term()}.
connect(Node, Cookie) when is_atom(Node) ->
    gen_server:call(?MODULE, {connect, Node, Cookie}).

disconnect(Node) ->
    gen_server:call(?MODULE, {disconnect, Node}).

%% Returns the current state of every observed node.
list() ->
    Pids = gen_server:call(?MODULE, pids),
    [Info || Pid <- Pids, {ok, Info} <- [safe_info(Pid)]].

lookup(Node) ->
    gen_server:call(?MODULE, {lookup, Node}).

safe_info(Pid) ->
    try {ok, eobs_node:info(Pid)}
    catch exit:_ -> error
    end.

%% gen_server

init([]) ->
    {ok, #{}}.

handle_call({connect, Node, Cookie}, _From, Nodes) ->
    case Nodes of
        #{Node := Pid} ->
            eobs_node:reconnect(Pid, Cookie),
            {reply, {ok, Pid}, Nodes};
        _ ->
            case eobs_node_sup:start_child(Node, Cookie) of
                {ok, Pid} ->
                    monitor(process, Pid),
                    {reply, {ok, Pid}, Nodes#{Node => Pid}};
                {error, _} = Error ->
                    {reply, Error, Nodes}
            end
    end;
handle_call({disconnect, Node}, _From, Nodes) ->
    case maps:take(Node, Nodes) of
        {Pid, Rest} ->
            eobs_node:stop(Pid),
            {reply, ok, Rest};
        error ->
            {reply, {error, not_found}, Nodes}
    end;
handle_call(pids, _From, Nodes) ->
    {reply, maps:values(Nodes), Nodes};
handle_call({lookup, Node}, _From, Nodes) ->
    case Nodes of
        #{Node := Pid} -> {reply, {ok, Pid}, Nodes};
        _ -> {reply, {error, not_found}, Nodes}
    end.

handle_cast(_Msg, Nodes) ->
    {noreply, Nodes}.

handle_info({'DOWN', _, process, Pid, _}, Nodes) ->
    case [N || {N, P} <- maps:to_list(Nodes), P =:= Pid] of
        [Node] ->
            eobs_events:publish(node_removed, #{node => Node}),
            {noreply, maps:remove(Node, Nodes)};
        [] ->
            {noreply, Nodes}
    end;
handle_info(_Msg, Nodes) ->
    {noreply, Nodes}.
