%% @doc Downloads of an observed node's log files: streamed chunk by chunk
%% from the agent, which only reads files of the node's own log setup.
-module(eobs_download).

-export([init/2]).

%% A chunk is at most 1 MB; the agent gives up on one after 10 s.
-define(CHUNK, 1048576).
-define(TIMEOUT, 15000).

init(Req, State) ->
    case cowboy_req:header(<<"sec-fetch-site">>, Req) of
        <<"cross-site">> ->
            {ok, error_reply(403, <<"cross-site download refused\n">>, Req), State};
        _ ->
            try cowboy_req:match_qs([{node, nonempty}, {path, nonempty}], Req) of
                #{node := NodeBin, path := Path} ->
                    Reply = case node_atom(NodeBin) of
                                {ok, Node} -> first_chunk(Node, Path, Req);
                                error -> error_reply(404, <<"not_observed">>, Req)
                            end,
                    {ok, Reply, State}
            catch _:_ ->
                {ok, error_reply(400, <<"bad_request">>, Req), State}
            end
    end.

node_atom(Bin) ->
    try binary_to_existing_atom(Bin, utf8) of
        Node ->
            case eobs_nodes:is_observed(Node) of
                true -> {ok, Node};
                false -> error
            end
    catch error:badarg -> error
    end.

%% The first chunk decides between an error and a download.
first_chunk(Node, Path, Req) ->
    case chunk(Node, Path, 0) of
        {ok, Bin} ->
            Name = filename:basename(Path),
            Req1 = cowboy_req:stream_reply(200, #{
                       <<"content-type">> => <<"application/octet-stream">>,
                       <<"x-content-type-options">> => <<"nosniff">>,
                       <<"content-disposition">> =>
                           iolist_to_binary(["attachment; filename*=UTF-8''", uri_string:quote(Name)])},
                       Req),
            stream(Node, Path, Bin, 0, Req1),
            Req1;
        {error, Reason} ->
            cowboy_req:reply(400, #{<<"content-type">> => <<"application/json; charset=utf-8">>},
                             eobs_json:encode(#{error => iolist_to_binary(io_lib:format("~p", [Reason]))}),
                             Req)
    end.

stream(_Node, _Path, Bin, _Pos, Req) when byte_size(Bin) < ?CHUNK ->
    cowboy_req:stream_body(Bin, fin, Req);
stream(Node, Path, Bin, Pos, Req) ->
    cowboy_req:stream_body(Bin, nofin, Req),
    Next = Pos + byte_size(Bin),
    case chunk_retry(Node, Path, Next, 2) of
        {ok, More} -> stream(Node, Path, More, Next, Req);
        %% Abort without sending a chunked `fin` terminator so the client
        %% detects an incomplete download instead of saving a truncated file.
        {error, Reason} -> exit({download_aborted, Reason})
    end.

chunk_retry(Node, Path, Pos, Tries) ->
    case chunk(Node, Path, Pos) of
        {error, files_busy} when Tries > 0 ->
            timer:sleep(250),
            chunk_retry(Node, Path, Pos, Tries - 1);
        Other ->
            Other
    end.

chunk(Node, Path, Pos) ->
    case eobs_node:call(Node, logfile_chunk, [Path, Pos, ?CHUNK], ?TIMEOUT) of
        {ok, {ok, Bin}} when is_binary(Bin) -> {ok, Bin};
        {ok, {error, _} = E} -> E;
        {error, _} = E -> E;
        Other -> {error, {bad_return, Other}}
    end.

error_reply(Code, Body, Req) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"text/plain; charset=utf-8">>}, Body, Req).
