%% @doc Downloads of an observed node's log files: streamed chunk by chunk
%% from the agent, which only reads files of the node's own log setup.
-module(eobs_download).

-export([init/2]).

%% A chunk is at most 1 MB; the agent gives up on one after 10 s.
-define(CHUNK, 1048576).
-define(TIMEOUT, 15000).

init(Req, State) ->
    #{node := NodeBin, path := Path} =
        cowboy_req:match_qs([{node, nonempty}, {path, nonempty}], Req),
    Reply = case node_atom(NodeBin) of
                {ok, Node} -> first_chunk(Node, Path, Req);
                error -> error_reply(404, <<"not_observed">>, Req)
            end,
    {ok, Reply, State}.

node_atom(Bin) ->
    try {ok, binary_to_existing_atom(Bin, utf8)}
    catch error:badarg -> error
    end.

%% The first chunk decides between an error and a download.
first_chunk(Node, Path, Req) ->
    case chunk(Node, Path, 0) of
        {ok, Bin} ->
            Name = filename:basename(Path),
            Req1 = cowboy_req:stream_reply(200, #{
                       <<"content-type">> => <<"application/octet-stream">>,
                       <<"content-disposition">> =>
                           iolist_to_binary(["attachment; filename*=UTF-8''", uri_string:quote(Name)])},
                       Req),
            stream(Node, Path, Bin, 0, Req1),
            Req1;
        {error, Reason} ->
            error_reply(400, eobs_json:encode(#{error => iolist_to_binary(io_lib:format("~p", [Reason]))}), Req)
    end.

stream(_Node, _Path, Bin, _Pos, Req) when byte_size(Bin) < ?CHUNK ->
    cowboy_req:stream_body(Bin, fin, Req);
stream(Node, Path, Bin, Pos, Req) ->
    cowboy_req:stream_body(Bin, nofin, Req),
    Next = Pos + byte_size(Bin),
    case chunk(Node, Path, Next) of
        {ok, More} -> stream(Node, Path, More, Next, Req);
        %% The file went away or the node is gone: end what was sent.
        {error, _} -> cowboy_req:stream_body(<<>>, fin, Req)
    end.

chunk(Node, Path, Pos) ->
    case eobs_node:call(Node, logfile_chunk, [Path, Pos, ?CHUNK], ?TIMEOUT) of
        {ok, {ok, Bin}} when is_binary(Bin) -> {ok, Bin};
        {ok, {error, _} = E} -> E;
        {error, _} = E -> E
    end.

error_reply(Code, Body, Req) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"text/plain; charset=utf-8">>}, Body, Req).
