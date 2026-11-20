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
    case catch list_to_integer(Port) of
        P when is_integer(P), P >= 0, P =< 65535 ->
            parse(Rest, Acc#{http_port => P});
        _ ->
            io:format(standard_error, "eobs: invalid --port ~ts~n~ts", [Port, usage()]),
            halt(1)
    end;
parse(["--listen", Ip | Rest], Acc) ->
    case inet:parse_address(Ip) of
        {ok, Addr} ->
            parse(Rest, Acc#{http_ip => Addr});
        {error, _} ->
            io:format(standard_error, "eobs: invalid --listen address ~ts~n~ts", [Ip, usage()]),
            halt(1)
    end;
parse(["--password", Password | Rest], Acc) ->
    case unicode:characters_to_binary(Password) of
        Bin when is_binary(Bin) ->
            parse(Rest, Acc#{password => Bin});
        _ ->
            io:format(standard_error, "eobs: invalid UTF-8 in --password~n", []),
            halt(1)
    end;
parse(["--dump-dir", Dir | Rest], Acc) ->
    Existing = maps:get(dump_dirs, Acc, []),
    parse(Rest, Acc#{dump_dirs => Existing ++ [Dir]});
parse(["--read-only" | Rest], Acc) ->
    parse(Rest, Acc#{read_only => true});
parse(["--no-browser" | Rest], Acc) ->
    parse(Rest, Acc#{browser => false});
parse([Unknown | Rest], Acc) ->
    io:format(standard_error, "eobs: ignoring unknown argument ~ts~n~ts", [Unknown, usage()]),
    parse(Rest, Acc).

usage() ->
    "usage: eobs [--node NAME@HOST] [--cookie COOKIE] [--port 8090]\n"
    "            [--listen 127.0.0.1] [--password PASS] [--dump-dir DIR]\n"
    "            [--read-only] [--no-browser]\n"
    "Password and cookie can also be given in EOBS_PASSWORD and EOBS_COOKIE.\n".

open_browser(Url) ->
    spawn(fun() ->
        case os:type() of
            {unix, darwin} ->
                run_exec("open", [Url]);
            {win32, _} ->
                case os:find_executable("cmd") of
                    false -> ok;
                    Cmd ->
                        Port = open_port({spawn_executable, Cmd},
                                         [{args, ["/c", "start", "", Url]}, hide]),
                        catch port_close(Port)
                end;
            {unix, _} ->
                run_exec("xdg-open", [Url])
        end
    end),
    ok.

run_exec(Bin, Args) ->
    case os:find_executable(Bin) of
        false -> ok;
        Exe ->
            Port = open_port({spawn_executable, Exe}, [{args, Args}, stderr_to_stdout]),
            receive {Port, _} -> ok after 1000 -> ok end,
            catch port_close(Port)
    end.
