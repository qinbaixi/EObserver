%% @doc Request and subscription handlers behind the WebSocket protocol.
%%
%% request/2 serves one-shot requests; collect/3 produces the data for a
%% subscription topic and is called on every tick with the state the
%% previous tick returned (undefined on the first). Both run in a worker
%% process spawned by eobs_ws.
-module(eobs_api).

-export([request/2, collect/2, collect/3]).

-define(TIMEOUT, 10000).

request(<<"nodes.list">>, _Params) ->
    {ok, eobs_nodes:list()};
request(<<"nodes.connect">>, #{<<"node">> := Node} = Params) ->
    Cookie = case maps:get(<<"cookie">>, Params, <<>>) of
                 <<>> -> undefined;
                 null -> undefined;
                 C -> binary_to_atom(C, utf8)
             end,
    case eobs_nodes:connect(binary_to_atom(Node, utf8), Cookie) of
        {ok, _Pid} -> ok;
        Error -> Error
    end;
request(<<"nodes.disconnect">>, #{<<"node">> := Node}) ->
    eobs_nodes:disconnect(to_node(Node));
request(<<"node.summary">>, Params) ->
    collect(<<"node.summary">>, Params);
request(<<"process.info">>, #{<<"node">> := Node, <<"pid">> := Pid}) ->
    unwrap(eobs_node:call(to_node(Node), process_detail, [Pid], ?TIMEOUT));
request(<<"process.state">>, #{<<"node">> := Node, <<"pid">> := Pid}) ->
    unwrap(eobs_node:call(to_node(Node), process_state, [Pid, 5000], ?TIMEOUT));
request(<<"process.kill">>, #{<<"node">> := Node, <<"pid">> := Pid}) ->
    unwrap(eobs_node:call(to_node(Node), process_kill, [Pid], ?TIMEOUT));
request(<<"process.send">>, #{<<"node">> := Node, <<"pid">> := Pid, <<"message">> := Text}) ->
    case parse_term(Text) of
        {ok, Term} -> unwrap(eobs_node:call(to_node(Node), process_send, [Pid, Term], ?TIMEOUT));
        {error, _} = Error -> Error
    end;
request(<<"apps.list">>, #{<<"node">> := Node}) ->
    eobs_node:call(to_node(Node), app_list, [], ?TIMEOUT);
request(<<"apps.tree">>, #{<<"node">> := Node, <<"app">> := App}) ->
    %% Application names come from apps.list, so they already exist as atoms.
    case catch binary_to_existing_atom(App, utf8) of
        A when is_atom(A) -> unwrap(eobs_node:call(to_node(Node), app_tree, [A], 30000));
        _ -> {error, not_running}
    end;
request(Method, _Params) ->
    {error, {unknown_method, Method}}.

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
collect(Topic, _Params) ->
    {error, {unknown_topic, Topic}}.

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
