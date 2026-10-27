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
               _ -> inet:ntoa(Ip)
           end,
    lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])).

www_dir() ->
    filename:join(code:priv_dir(eobserver), "www").

%% cowboy handler for the SPA shell
init(Req, #{index := Index} = State) ->
    Reply = case file:read_file(Index) of
                {ok, Html} ->
                    cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                                            <<"cache-control">> => <<"no-cache">>},
                                     Html, Req);
                {error, _} ->
                    cowboy_req:reply(503, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                                     <<"EObserver frontend is not built. Run `make web`.\n">>, Req)
            end,
    {ok, Reply, State}.
