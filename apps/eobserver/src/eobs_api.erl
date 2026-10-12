%% @doc Request and subscription handlers behind the WebSocket protocol.
%%
%% request/2 serves one-shot requests; collect/3 produces the data for a
%% subscription topic and is called on every tick with the state the
%% previous tick returned (undefined on the first). Both run in a worker
%% process spawned by eobs_ws.
-module(eobs_api).

-export([request/2, collect/2, collect/3]).

-define(TIMEOUT, 10000).

%% Requests that change the observed node; refused in read-only mode.
-define(MUTATING, [<<"process.kill">>, <<"process.send">>, <<"port.close">>]).

request(Method, Params) ->
    case lists:member(Method, ?MUTATING) andalso read_only() of
        true -> {error, read_only};
        false -> handle(Method, Params)
    end.

handle(<<"settings.get">>, _Params) ->
    {ok, Vsn} = application:get_key(eobserver, vsn),
    {ok, #{read_only => read_only(), version => list_to_binary(Vsn)}};
handle(<<"nodes.list">>, _Params) ->
    {ok, eobs_nodes:list()};
handle(<<"nodes.connect">>, #{<<"node">> := Node} = Params) ->
    Cookie = case maps:get(<<"cookie">>, Params, <<>>) of
                 <<>> -> undefined;
                 null -> undefined;
                 C -> binary_to_atom(C, utf8)
             end,
    case eobs_nodes:connect(binary_to_atom(Node, utf8), Cookie) of
        {ok, _Pid} -> ok;
        Error -> Error
    end;
handle(<<"nodes.disconnect">>, #{<<"node">> := Node}) ->
    eobs_nodes:disconnect(to_node(Node));
handle(<<"node.summary">>, Params) ->
    collect(<<"node.summary">>, Params);
%% processes
handle(<<"process.info">>, #{<<"node">> := Node, <<"pid">> := Pid}) ->
    agent(Node, process_detail, [Pid]);
handle(<<"process.state">>, #{<<"node">> := Node, <<"pid">> := Pid}) ->
    agent(Node, process_state, [Pid, 5000]);
handle(<<"process.kill">>, #{<<"node">> := Node, <<"pid">> := Pid}) ->
    agent(Node, process_kill, [Pid]);
handle(<<"process.send">>, #{<<"node">> := Node, <<"pid">> := Pid, <<"message">> := Text}) ->
    case parse_term(Text) of
        {ok, Term} -> agent(Node, process_send, [Pid, Term]);
        {error, _} = Error -> Error
    end;
%% applications
handle(<<"apps.list">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), app_list, [], ?TIMEOUT);
handle(<<"apps.tree">>, #{<<"node">> := Node, <<"app">> := App}) ->
    %% Application names come from apps.list, so they already exist as atoms.
    case catch binary_to_existing_atom(App, utf8) of
        A when is_atom(A) -> unwrap(eobs_node:call(to_node(Node), app_tree, [A], 30000));
        _ -> {error, not_running}
    end;
%% ports
handle(<<"port.info">>, #{<<"node">> := Node, <<"port">> := Port}) ->
    agent(Node, port_detail, [Port]);
handle(<<"port.close">>, #{<<"node">> := Node, <<"port">> := Port}) ->
    agent(Node, port_close, [Port]);
%% tables
handle(<<"ets.rows">>, #{<<"node">> := Node, <<"table">> := Id} = Params) ->
    agent(Node, ets_rows, [Id, table_opts(Params)]);
handle(<<"mnesia.rows">>, #{<<"node">> := Node, <<"table">> := Id} = Params) ->
    agent(Node, mnesia_rows, [Id, table_opts(Params)]);
handle(Method, _Params) ->
    {error, {unknown_method, Method}}.

table_opts(Params) ->
    #{offset => int(maps:get(<<"offset">>, Params, 0), 0),
      limit => int(maps:get(<<"limit">>, Params, 50), 50),
      search => case maps:get(<<"search">>, Params, <<>>) of
                    B when is_binary(B) -> B;
                    _ -> <<>>
                end}.

agent(Node, Fun, Args) ->
    unwrap(eobs_node:call(to_node(Node), Fun, Args, ?TIMEOUT)).

read_only() ->
    application:get_env(eobserver, read_only, false) =:= true.

-spec collect(binary(), map(), term()) -> {ok, term(), term()} | {error, term()}.
collect(<<"node.load">>, #{<<"node">> := Node}, Prev) ->
    case eobs_node:call(to_node(Node), load_sample, [node()], ?TIMEOUT) of
        {ok, Sample} -> {ok, eobs_load:rates(Prev, Sample), Sample};
        Error -> Error
    end;
collect(<<"node.processes">>, #{<<"node">> := Node} = Params, Session0) ->
    Session = case Session0 of
                  undefined -> {node(), self(), erlang:unique_integer()};
                  _ -> Session0
              end,
    Opts = #{sort => enum(maps:get(<<"sort">>, Params, <<"reds">>),
                          [reds, reductions, memory, message_queue_len, name, pid], reds),
             order => enum(maps:get(<<"order">>, Params, <<"desc">>), [asc, desc], desc),
             filter => maps:get(<<"filter">>, Params, <<>>),
             offset => int(maps:get(<<"offset">>, Params, 0), 0),
             limit => int(maps:get(<<"limit">>, Params, 50), 50)},
    case eobs_node:call(to_node(Node), process_list, [node(), Session, Opts], ?TIMEOUT) of
        {ok, Page} -> {ok, Page, Session};
        Error -> Error
    end;
collect(Topic, Params, State) ->
    case collect(Topic, Params) of
        {ok, Data} -> {ok, Data, State};
        Error -> Error
    end.

%% Stateless topics.
collect(<<"node.summary">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), node_summary, [], ?TIMEOUT);
collect(<<"node.ports">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), port_list, [], ?TIMEOUT);
collect(<<"node.inet">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), inet_list, [], ?TIMEOUT);
collect(<<"node.sockets">>, #{<<"node">> := Node}) ->
    unwrap(eobs_node:call(to_node(Node), socket_list, [], ?TIMEOUT));
collect(<<"node.ets">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), ets_list, [], ?TIMEOUT);
collect(<<"node.mnesia">>, #{<<"node">> := Node}) ->
    unwrap(eobs_node:call(to_node(Node), mnesia_list, [], ?TIMEOUT));
collect(<<"node.allocators">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), alloc_info, [], ?TIMEOUT);
collect(<<"cluster">>, _Params) ->
    {ok, cluster()};
collect(Topic, _Params) ->
    {error, {unknown_topic, Topic}}.

%% Distribution links of every connected observed node, collected in
%% parallel so one slow node does not hold up the others.
cluster() ->
    Observed = [N || #{node := N, status := connected} <- eobs_nodes:list()],
    Refs = [{N, spawn_monitor(fun() -> exit({dist, eobs_node:call(N, dist_info, [], 5000)}) end)}
            || N <- Observed],
    Infos = [{N, receive {'DOWN', Ref, process, Pid, {dist, R}} -> R;
                         {'DOWN', Ref, process, Pid, _} -> {error, crashed}
                 end} || {N, {Pid, Ref}} <- Refs],
    #{tool => node(),
      nodes => [#{node => N,
                  connections => case R of
                                     {ok, #{connections := C}} -> C;
                                     _ -> []
                                 end,
                  error => case R of {ok, _} -> null; _ -> eobs_json:to_json(R) end}
                || {N, R} <- Infos]}.

unwrap({ok, ok}) -> ok;
unwrap({ok, {ok, _} = Ok}) -> Ok;
unwrap({ok, {error, _} = Error}) -> Error;
unwrap({error, _} = Error) -> Error.

%% Maps a browser-supplied binary onto one of a fixed set of atoms.
enum(Bin, Allowed, Default) when is_binary(Bin) ->
    case [A || A <- Allowed, atom_to_binary(A, utf8) =:= Bin] of
        [A] -> A;
        [] -> Default
    end;
enum(_, _, Default) ->
    Default.

int(N, _Default) when is_integer(N), N >= 0 -> N;
int(_, Default) -> Default.

parse_term(Text) ->
    case erl_scan:string(unicode:characters_to_list(Text) ++ " .") of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} -> {ok, Term};
                {error, {_, Mod, Reason}} -> {error, iolist_to_binary(Mod:format_error(Reason))}
            end;
        {error, {_, Mod, Reason}, _} ->
            {error, iolist_to_binary(Mod:format_error(Reason))}
    end.

%% Only names of nodes we already observe are accepted, so the browser
%% cannot make the tool create arbitrary atoms.
to_node(Bin) ->
    try binary_to_existing_atom(Bin, utf8)
    catch error:badarg -> throw({error, not_observed})
    end.
