%% @doc Cowboy middleware that enforces:
%%   1. Host header validation against DNS rebinding when listening on loopback.
%%   2. HTTP Basic authentication when a password is configured.
-module(eobs_auth).
-behaviour(cowboy_middleware).

-export([execute/2, check/2, configured_password/0, host_allowed/2]).

execute(Req, Env) ->
    Ip = application:get_env(eobserver, http_ip, {127, 0, 0, 1}),
    case host_allowed(cowboy_req:header(<<"host">>, Req), Ip) of
        false ->
            Req1 = cowboy_req:reply(403, #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                                    <<"EObserver: forbidden Host header\n">>, Req),
            {stop, Req1};
        true ->
            check_auth(Req, Env)
    end.

check_auth(Req, Env) ->
    case configured_password() of
        {ok, Password} ->
            case check(cowboy_req:header(<<"authorization">>, Req), Password) of
                true ->
                    {ok, Req, Env};
                false ->
                    Req1 = cowboy_req:reply(401, #{<<"www-authenticate">> => <<"Basic realm=\"EObserver\", charset=\"UTF-8\"">>,
                                                   <<"content-type">> => <<"text/plain; charset=utf-8">>},
                                            <<"EObserver: password required\n">>, Req),
                    {stop, Req1}
            end;
        none ->
            {ok, Req, Env}
    end.

%% Normalises the configured password; returns {ok, Binary} or none.
%% Shared with eobs_app:warn_if_exposed/0 so auth and warning never disagree.
-spec configured_password() -> {ok, binary()} | none.
configured_password() ->
    case application:get_env(eobserver, password) of
        {ok, P} when is_binary(P), P =/= <<>> ->
            {ok, P};
        {ok, P} when is_list(P), P =/= [] ->
            case unicode:characters_to_binary(P) of
                Bin when is_binary(Bin), Bin =/= <<>> -> {ok, Bin};
                _ -> erlang:error(invalid_password_config)
            end;
        undefined -> none;
        {ok, <<>>} -> none;
        {ok, ""} -> none;
        {ok, undefined} -> none;
        {ok, Other} -> erlang:error({invalid_password_config, Other})
    end.

%% Blocks DNS rebinding when bound to a loopback interface without a
%% password: only loopback hostnames/IPs are accepted.
-spec host_allowed(binary() | undefined, inet:ip_address()) -> boolean().
host_allowed(undefined, _) ->
    true;
host_allowed(Host, Ip) when is_binary(Host) ->
    case is_loopback(Ip) of
        false ->
            true;
        true ->
            Name = host_name(Host),
            Name =:= <<"localhost">>
                orelse Name =:= <<"127.0.0.1">>
                orelse Name =:= <<"::1">>
                orelse Name =:= list_to_binary(inet:ntoa(Ip))
    end;
host_allowed(_, _) ->
    false.

is_loopback({127, _, _, _}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback(_) -> false.

host_name(<<"[", Rest/binary>>) ->
    case binary:split(Rest, <<"]">>) of
        [H, _] -> string:lowercase(H);
        _ -> <<>>
    end;
host_name(Host) ->
    case binary:split(Host, <<":">>) of
        [H, _] -> string:lowercase(H);
        [H] -> string:lowercase(H)
    end.

%% Any user name is accepted; only the password is checked.
%% RFC 7617 specifies case-insensitive auth scheme ("Basic").
-spec check(binary() | undefined, binary()) -> boolean().
check(<<Scheme:5/binary, " ", Encoded/binary>>, Password) when is_binary(Password) ->
    case string:lowercase(Scheme) of
        <<"basic">> ->
            try base64:decode(string:trim(Encoded)) of
                Decoded ->
                    case binary:split(Decoded, <<":">>) of
                        [_User, Given] -> equal(Given, Password);
                        _ -> false
                    end
            catch _:_ -> false
            end;
        _ ->
            false
    end;
check(_, _) ->
    false.

%% Constant-time comparison via fixed-length SHA-256 digests so neither
%% content nor byte length leaks via timing.
equal(A, B) when is_binary(A), is_binary(B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B)).
