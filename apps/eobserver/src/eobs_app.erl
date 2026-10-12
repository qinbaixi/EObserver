-module(eobs_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Opts = cli_opts(),
    apply_opts(Opts),
    {ok, Sup} = eobs_sup:start_link(),
    {ok, _} = eobs_http:start(),
    after_start(Opts),
    {ok, Sup}.

stop(_State) ->
    eobs_http:stop().

%% Command line options are only honoured when started through bin/eobs,
%% which passes -eobs_cli; under `rebar3 shell` or tests the plain
%% arguments belong to rebar3.
cli_opts() ->
    case init:get_argument(eobs_cli) of
        {ok, _} -> eobs_cli:parse(init:get_plain_arguments());
        error -> #{browser => false}
    end.

apply_opts(Opts) ->
    maps:foreach(fun(Key, Value) when Key =:= http_ip; Key =:= http_port ->
                         application:set_env(eobserver, Key, Value);
                    (_, _) ->
                         ok
                 end, Opts).

after_start(Opts) ->
    case Opts of
        #{node := Node} ->
            eobs_nodes:connect(Node, maps:get(cookie, Opts, undefined));
        _ ->
            ok
    end,
    Url = eobs_http:url(),
    io:format("EObserver is running at ~ts~n", [Url]),
    case maps:get(browser, Opts, false) of
        true -> eobs_cli:open_browser(Url);
        false -> ok
    end.
