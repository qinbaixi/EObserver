-module(eobs_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Opts = apply_opts(cli_opts()),
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

apply_opts(Opts0) ->
    Opts1 = case {maps:is_key(password, Opts0), os:getenv("EOBS_PASSWORD")} of
                {false, Env} when is_list(Env), Env =/= "" ->
                    case unicode:characters_to_binary(Env) of
                        Bin when is_binary(Bin) -> Opts0#{password => Bin};
                        _ -> erlang:error(invalid_eobs_password_env)
                    end;
                _ ->
                    Opts0
            end,
    Opts = case {maps:is_key(cookie, Opts1), os:getenv("EOBS_COOKIE")} of
               {false, CEnv} when is_list(CEnv), CEnv =/= "" ->
                   Opts1#{cookie => list_to_atom(CEnv)};
               _ ->
                   Opts1
           end,
    maps:foreach(fun(Key, Value) when Key =:= http_ip; Key =:= http_port; Key =:= read_only;
                                      Key =:= password; Key =:= dump_dirs ->
                         application:set_env(eobserver, Key, Value);
                    (_, _) ->
                         ok
                 end, Opts),
    Opts.

after_start(Opts) ->
    case Opts of
        #{node := Node} ->
            eobs_nodes:connect(Node, maps:get(cookie, Opts, undefined));
        _ ->
            ok
    end,
    Url = eobs_http:url(),
    io:format("EObserver is running at ~ts~n", [Url]),
    warn_if_exposed(),
    case maps:get(browser, Opts, false) of
        true -> eobs_cli:open_browser(Url);
        false -> ok
    end.

warn_if_exposed() ->
    {ok, Ip} = application:get_env(eobserver, http_ip),
    Loopback = case Ip of
                   {127, _, _, _} -> true;
                   {0, 0, 0, 0, 0, 0, 0, 1} -> true;
                   _ -> false
               end,
    case Loopback orelse eobs_auth:configured_password() =/= none of
        true -> ok;
        false -> io:format(standard_error,
                           "eobs: warning: listening on ~ts without --password; anyone who can "
                           "reach this port can inspect and change the observed nodes~n",
                           [inet:ntoa(Ip)])
    end,
    case Loopback orelse application:get_env(eobserver, dump_dirs, []) =/= [] of
        true -> ok;
        false -> io:format(standard_error,
                           "eobs: warning: listening on ~ts without --dump-dir; crash dump "
                           "file browsing is unrestricted on this host~n",
                           [inet:ntoa(Ip)])
    end.
