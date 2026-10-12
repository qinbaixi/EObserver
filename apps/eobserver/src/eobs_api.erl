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
request(Method, _Params) ->
    {error, {unknown_method, Method}}.

-spec collect(binary(), map(), term()) -> {ok, term(), term()} | {error, term()}.
collect(<<"node.load">>, #{<<"node">> := Node}, Prev) ->
    case eobs_node:call(to_node(Node), load_sample, [node()], ?TIMEOUT) of
        {ok, Sample} -> {ok, eobs_load:rates(Prev, Sample), Sample};
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

%% Only names of nodes we already observe are accepted, so the browser
%% cannot make the tool create arbitrary atoms.
to_node(Bin) ->
    try binary_to_existing_atom(Bin, utf8)
    catch error:badarg -> throw({error, not_observed})
    end.
