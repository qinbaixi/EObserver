%% @doc Command line options and browser launching.
-module(eobs_cli).

-export([parse/1, open_browser/1, usage/0]).

%% Parses plain arguments into an option map. Unknown arguments are
%% reported and ignored so a typo never prevents the UI from starting.
-spec parse([string()]) -> map().
parse(Args) ->
    parse(Args, #{browser => true}).

parse([], Acc) ->
    Acc;
parse(["--node", Node | Rest], Acc) ->
    parse(Rest, Acc#{node => list_to_atom(Node)});
parse(["--cookie", Cookie | Rest], Acc) ->
    parse(Rest, Acc#{cookie => list_to_atom(Cookie)});
parse(["--port", Port | Rest], Acc) ->
    parse(Rest, Acc#{http_port => list_to_integer(Port)});
parse(["--listen", Ip | Rest], Acc) ->
    {ok, Addr} = inet:parse_address(Ip),
    parse(Rest, Acc#{http_ip => Addr});
parse(["--no-browser" | Rest], Acc) ->
    parse(Rest, Acc#{browser => false});
parse([Unknown | Rest], Acc) ->
    io:format(standard_error, "eobs: ignoring unknown argument ~ts~n~ts", [Unknown, usage()]),
    parse(Rest, Acc).

usage() ->
    "usage: eobs [--node NAME@HOST] [--cookie COOKIE] [--port 8090]\n"
    "            [--listen 127.0.0.1] [--no-browser]\n".

open_browser(Url) ->
    Cmd = case os:type() of
              {unix, darwin} -> "open '" ++ Url ++ "'";
              {win32, _} -> "cmd /c start \"\" \"" ++ Url ++ "\"";
              {unix, _} -> "xdg-open '" ++ Url ++ "' >/dev/null 2>&1"
          end,
    spawn(fun() -> os:cmd(Cmd) end),
    ok.
