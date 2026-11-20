%% @doc Registry of observed nodes. Starts one eobs_node process per
%% target and answers lookups from the API layer.
%%
%% Nodes added with a saved cookie (or the default one) are written to
%% nodes.eterm next to cookies.eterm and reconnected on the next start.
%% Nodes added with a cookie that was not saved are not remembered, as
%% there is nothing to reconnect them with.
-module(eobs_nodes).
-behaviour(gen_server).

-export([start_link/0, connect/2, connect/3, disconnect/1, list/0, lookup/1,
         is_observed/1, update_info/2, file/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(REG, eobs_nodes_reg).
-define(MAX_NODES, 100).

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
connect(Node, _Cookie, _Remember) when Node =:= nonode@nohost ->
    {error, cannot_observe_self};
connect(Node, Cookie, Remember) when is_atom(Node) ->
    case Node =:= node() of
        true -> {error, cannot_observe_self};
        false -> gen_server:call(?MODULE, {connect, Node, Cookie, Remember})
    end.

%% Detaches Node from the registry first (never blocking eobs_nodes), then
%% stops the eobs_node process in the caller with a bounded timeout.
disconnect(Node) ->
    case gen_server:call(?MODULE, {detach, Node}) of
        {ok, Pid} ->
            try eobs_node:stop(Pid)
            catch exit:_ -> exit(Pid, kill)
            end,
            ok;
        Error ->
            Error
    end.

%% Returns the current state of every observed node without blocking on
%% individual eobs_node gen_servers.
list() ->
    case ets:whereis(?REG) of
        undefined -> [];
        _ -> [Info || {_Node, _Pid, Info} <- ets:tab2list(?REG)]
    end.

lookup(Node) ->
    case ets:whereis(?REG) of
        undefined -> {error, not_found};
        _ ->
            case ets:lookup(?REG, Node) of
                [{_, Pid, _}] -> {ok, Pid};
                [] -> {error, not_found}
            end
    end.

%% Lock-free O(1) check used by eobs_api, eobs_download and eobs_node:call/4
%% to guarantee the agent is never invoked on EObserver's own VM or on an
%% unobserved node.
-spec is_observed(node()) -> boolean().
is_observed(Node) when is_atom(Node), Node =/= nonode@nohost ->
    Node =/= node()
        andalso ets:whereis(?REG) =/= undefined
        andalso ets:member(?REG, Node);
is_observed(_) ->
    false.

update_info(Node, Info) ->
    case ets:whereis(?REG) of
        undefined -> ok;
        _ ->
            _ = ets:update_element(?REG, Node, {3, Info}),
            ok
    end.

%% gen_server

file() ->
    filename:join(filename:dirname(eobs_cookies:file()), "nodes.eterm").

%% State: #{nodes => #{node() => {pid(), reference()}}, saved => #{node() => Remember}}.
init([]) ->
    ets:new(?REG, [named_table, public, set, {read_concurrency, true}]),
    %% Clean up any orphaned eobs_node children left behind by a prior restart.
    case whereis(eobs_node_sup) of
        undefined -> ok;
        _ -> [supervisor:terminate_child(eobs_node_sup, P)
              || {_, P, _, _} <- supervisor:which_children(eobs_node_sup), is_pid(P)]
    end,
    self() ! restore,
    {ok, #{nodes => #{}, saved => read()}}.

handle_call({connect, Node, Cookie, Remember}, _From, #{nodes := Nodes} = State) ->
    case Nodes of
        #{Node := {Pid, _MonRef}} ->
            State1 = case Cookie of
                         undefined -> State;
                         _ -> remember(Node, Remember, State)
                     end,
            eobs_node:reconnect(Pid, Cookie),
            {reply, {ok, Pid}, State1};
        _ when map_size(Nodes) >= ?MAX_NODES ->
            {reply, {error, too_many_nodes}, State};
        _ ->
            case start(Node, Cookie) of
                {ok, Pid, MonRef} ->
                    State1 = remember(Node, Remember, State),
                    {reply, {ok, Pid}, State1#{nodes := Nodes#{Node => {Pid, MonRef}}}};
                {error, _} = Error ->
                    {reply, Error, State}
            end
    end;
handle_call({detach, Node}, _From, #{nodes := Nodes, saved := Saved} = State) ->
    State1 = case maps:is_key(Node, Saved) of
                 true -> save(State#{saved := maps:remove(Node, Saved)});
                 false -> State
             end,
    case maps:take(Node, Nodes) of
        {{Pid, MonRef}, Rest} ->
            erlang:demonitor(MonRef, [flush]),
            ets:delete(?REG, Node),
            eobs_events:publish(node_removed, #{node => Node}),
            {reply, {ok, Pid}, State1#{nodes := Rest}};
        error ->
            {reply, {error, not_found}, State1}
    end;
handle_call({lookup, Node}, _From, #{nodes := Nodes} = State) ->
    case Nodes of
        #{Node := {Pid, _}} -> {reply, {ok, Pid}, State};
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
    case [N || {N, {P, _}} <- maps:to_list(Nodes), P =:= Pid] of
        [Node] ->
            ets:delete(?REG, Node),
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
            MonRef = monitor(process, Pid),
            InitInfo = #{node => Node, status => connecting, error => null,
                         summary => undefined, agent => undefined},
            ets:insert(?REG, {Node, Pid, InitInfo}),
            {ok, Pid, MonRef};
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
        {ok, Pid, MonRef} -> Nodes#{Node => {Pid, MonRef}};
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
