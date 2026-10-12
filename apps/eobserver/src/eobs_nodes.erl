%% @doc Registry of observed nodes. Starts one eobs_node process per
%% target and answers lookups from the API layer.
%%
%% Nodes added with a saved cookie (or the default one) are written to
%% nodes.eterm next to cookies.eterm and reconnected on the next start.
%% Nodes added with a cookie that was not saved are not remembered, as
%% there is nothing to reconnect them with.
-module(eobs_nodes).
-behaviour(gen_server).

-export([start_link/0, connect/2, connect/3, disconnect/1, list/0, lookup/1, file/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec connect(node(), atom() | undefined) -> {ok, pid()} | {error, term()}.
connect(Node, undefined) ->
    connect(Node, undefined, default);
connect(Node, Cookie) ->
    connect(Node, Cookie, forget).

%% Remember: {cookie_id, Id} or default to reconnect after a restart,
%% forget to observe for this run only.
-spec connect(node(), atom() | undefined, {cookie_id, binary()} | default | forget) ->
          {ok, pid()} | {error, term()}.
connect(Node, Cookie, Remember) when is_atom(Node) ->
    gen_server:call(?MODULE, {connect, Node, Cookie, Remember}).

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

file() ->
    filename:join(filename:dirname(eobs_cookies:file()), "nodes.eterm").

%% State: #{nodes => #{node() => pid()}, saved => #{node() => Remember}}.
init([]) ->
    self() ! restore,
    {ok, #{nodes => #{}, saved => read()}}.

handle_call({connect, Node, Cookie, Remember}, _From, #{nodes := Nodes} = State) ->
    State1 = case {Nodes, Cookie} of
                 %% A retry without a cookie keeps the cookie (and the saved
                 %% entry) the node was added with.
                 {#{Node := _}, undefined} -> State;
                 _ -> remember(Node, Remember, State)
             end,
    case Nodes of
        #{Node := Pid} ->
            eobs_node:reconnect(Pid, Cookie),
            {reply, {ok, Pid}, State1};
        _ ->
            case start(Node, Cookie) of
                {ok, Pid} -> {reply, {ok, Pid}, State1#{nodes := Nodes#{Node => Pid}}};
                {error, _} = Error -> {reply, Error, State}
            end
    end;
handle_call({disconnect, Node}, _From, #{nodes := Nodes, saved := Saved} = State) ->
    State1 = case maps:is_key(Node, Saved) of
                 true -> save(State#{saved := maps:remove(Node, Saved)});
                 false -> State
             end,
    case maps:take(Node, Nodes) of
        {Pid, Rest} ->
            eobs_node:stop(Pid),
            {reply, ok, State1#{nodes := Rest}};
        error ->
            {reply, {error, not_found}, State1}
    end;
handle_call(pids, _From, #{nodes := Nodes} = State) ->
    {reply, maps:values(Nodes), State};
handle_call({lookup, Node}, _From, #{nodes := Nodes} = State) ->
    case Nodes of
        #{Node := Pid} -> {reply, {ok, Pid}, State};
        _ -> {reply, {error, not_found}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(restore, #{nodes := Nodes, saved := Saved} = State) ->
    Started = maps:fold(fun(Node, Remember, Acc) ->
                                case Acc of
                                    #{Node := _} -> Acc;
                                    _ -> restore(Node, Remember, Acc)
                                end
                        end, Nodes, Saved),
    {noreply, State#{nodes := Started}};
handle_info({'DOWN', _, process, Pid, _}, #{nodes := Nodes} = State) ->
    case [N || {N, P} <- maps:to_list(Nodes), P =:= Pid] of
        [Node] ->
            eobs_events:publish(node_removed, #{node => Node}),
            {noreply, State#{nodes := maps:remove(Node, Nodes)}};
        [] ->
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

%% internal

start(Node, Cookie) ->
    case eobs_node_sup:start_child(Node, Cookie) of
        {ok, Pid} ->
            monitor(process, Pid),
            {ok, Pid};
        Error ->
            Error
    end.

restore(Node, Remember, Nodes) ->
    Cookie = case Remember of
                 {cookie_id, Id} ->
                     case eobs_cookies:lookup(Id) of
                         {ok, C} -> binary_to_atom(C, utf8);
                         {error, _} -> undefined
                     end;
                 default ->
                     undefined
             end,
    case start(Node, Cookie) of
        {ok, Pid} -> Nodes#{Node => Pid};
        {error, _} -> Nodes
    end.

remember(Node, forget, #{saved := Saved} = State) ->
    %% Now observed with a cookie that is not saved: the old entry would
    %% reconnect with the wrong one.
    case maps:is_key(Node, Saved) of
        true -> save(State#{saved := maps:remove(Node, Saved)});
        false -> State
    end;
remember(Node, Remember, #{saved := Saved} = State) ->
    case Saved of
        #{Node := Remember} -> State;
        _ -> save(State#{saved := Saved#{Node => Remember}})
    end.

save(#{saved := Saved} = State) ->
    File = file(),
    Data = [io_lib:format("~tp.~n", [{Node, R}]) || {Node, R} <- lists:sort(maps:to_list(Saved))],
    _ = filelib:ensure_dir(File),
    case file:write_file(File ++ ".tmp", unicode:characters_to_binary(Data)) of
        ok -> _ = file:rename(File ++ ".tmp", File);
        _ -> ok
    end,
    State.

read() ->
    case file:consult(file()) of
        {ok, Terms} ->
            maps:from_list([{N, R} || {N, R} <- Terms, is_atom(N), valid(R)]);
        {error, _} ->
            #{}
    end.

valid({cookie_id, Id}) -> is_binary(Id);
valid(default) -> true;
valid(_) -> false.
