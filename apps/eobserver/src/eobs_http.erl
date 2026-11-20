-module(eobs_http).

-export([start/0, stop/0, url/0]).
-export([init/2]).

-define(LISTENER, eobs_http_listener).

start() ->
    {ok, Ip} = application:get_env(eobserver, http_ip),
    {ok, Port} = application:get_env(eobserver, http_port),
    Www = www_dir(),
    Routes = [
        {"/ws", eobs_ws, #{}},
        {"/download/logfile", eobs_download, #{}},
        {"/assets/[...]", cowboy_static, {dir, filename:join(Www, "assets")}},
        {"/favicon.svg", cowboy_static, {file, filename:join(Www, "favicon.svg")}},
        %% Every other path is a client-side route: serve the SPA shell.
        {"/[...]", ?MODULE, #{index => filename:join(Www, "index.html")}}
    ],
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    cowboy:start_clear(?LISTENER, [{ip, Ip}, {port, Port}],
                       #{env => #{dispatch => Dispatch},
                         middlewares => [eobs_auth, cowboy_router, cowboy_handler]}).

stop() ->
    cowboy:stop_listener(?LISTENER).

url() ->
    {Ip, Port} = ranch:get_addr(?LISTENER),
    Host = case Ip of
               {0, 0, 0, 0} -> "localhost";
               {127, 0, 0, 1} -> "localhost";
               {0, 0, 0, 0, 0, 0, 0, 0} -> "localhost";
               {0, 0, 0, 0, 0, 0, 0, 1} -> "[::1]";
               T when tuple_size(T) =:= 8 -> "[" ++ inet:ntoa(Ip) ++ "]";
               _ -> inet:ntoa(Ip)
           end,
    lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])).

www_dir() ->
    filename:join(code:priv_dir(eobserver), "www").

%% cowboy handler for the SPA shell (cached by mtime+size to avoid disk reads per route)
init(Req, #{index := Index} = State) ->
    Reply = case read_index(Index) of
                {ok, Html} ->
                    cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                                            <<"cache-control">> => <<"no-cache">>,
                                            <<"x-frame-options">> => <<"DENY">>,
                                            <<"x-content-type-options">> => <<"nosniff">>},
                                     Html, Req);
                {error, _} ->
                    cowboy_req:reply(503, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                                     <<"EObserver frontend is not built. Run `make web`.\n">>, Req)
            end,
    {ok, Reply, State}.

read_index(Index) ->
    case file:read_file_info(Index, [{time, posix}]) of
        {ok, {file_info, Size, regular, _, _, Mtime, _, _, _, _, _, _, _, _}} ->
            Key = {eobs_http_index, Index},
            case persistent_term:get(Key, undefined) of
                {Size, Mtime, Html} ->
                    {ok, Html};
                _ ->
                    case file:read_file(Index) of
                        {ok, Html} ->
                            persistent_term:put(Key, {Size, Mtime, Html}),
                            {ok, Html};
                        Error ->
                            Error
                    end
            end;
        Error ->
            Error
    end.
