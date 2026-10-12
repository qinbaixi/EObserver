%% @doc Cowboy middleware that asks for a password (HTTP Basic auth) when
%% one is configured. Needed whenever the UI listens beyond localhost,
%% since anyone who can open it can inspect and change observed nodes.
-module(eobs_auth).
-behaviour(cowboy_middleware).

-export([execute/2, check/2]).

execute(Req, Env) ->
    case application:get_env(eobserver, password) of
        {ok, Password} when is_binary(Password), Password =/= <<>> ->
            case check(cowboy_req:header(<<"authorization">>, Req), Password) of
                true ->
                    {ok, Req, Env};
                false ->
                    Req1 = cowboy_req:reply(401, #{<<"www-authenticate">> => <<"Basic realm=\"EObserver\", charset=\"UTF-8\"">>,
                                                   <<"content-type">> => <<"text/plain; charset=utf-8">>},
                                            <<"EObserver: password required\n">>, Req),
                    {stop, Req1}
            end;
        _ ->
            {ok, Req, Env}
    end.

%% Any user name is accepted; only the password is checked.
-spec check(binary() | undefined, binary()) -> boolean().
check(<<"Basic ", Encoded/binary>>, Password) ->
    try base64:decode(string:trim(Encoded)) of
        Decoded ->
            case binary:split(Decoded, <<":">>) of
                [_User, Given] -> equal(Given, Password);
                _ -> false
            end
    catch _:_ -> false
    end;
check(_, _) ->
    false.

%% Compares without short-circuiting on the first differing byte.
equal(A, B) when byte_size(A) =/= byte_size(B) ->
    false;
equal(A, B) ->
    lists:foldl(fun({X, Y}, Acc) -> Acc bor (X bxor Y) end, 0,
                lists:zip(binary_to_list(A), binary_to_list(B))) =:= 0.
