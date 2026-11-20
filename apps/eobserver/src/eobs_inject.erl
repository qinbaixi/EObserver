%% @doc Loads the eobs_agent module into an observed node.
%%
%% The agent is compiled by the tool's OTP, which may emit instructions an
%% older target cannot load. We therefore try, in order:
%%   1. a beam precompiled for the target's OTP release
%%      (priv/agent/<release>/eobs_agent.beam, produced by CI),
%%   2. the beam the tool itself runs,
%%   3. compiling the agent's abstract code on the target.
-module(eobs_inject).

-export([ensure_loaded/1, unload/1]).

-define(MOD, eobs_agent).
-define(TIMEOUT, 15000).
-define(UNLOAD_TIMEOUT, 3000).

-spec ensure_loaded(node()) -> {ok, map()} | {error, term()}.
ensure_loaded(Node) ->
    Wanted = ?MOD:version(),
    case remote_version(Node) of
        Wanted ->
            {ok, #{loaded => false, version => Wanted, method => already_loaded}};
        {transport_error, Reason} ->
            {error, {transport, Reason}};
        Other ->
            %% When upgrading an older loaded agent, stop its helpers and
            %% soft-purge any previous old code so load_binary never fails
            %% with not_purged.
            case is_integer(Other) of
                true ->
                    _ = rpc(Node, ?MOD, prepare_unload, [], ?UNLOAD_TIMEOUT),
                    _ = rpc(Node, code, soft_purge, [?MOD], ?UNLOAD_TIMEOUT);
                false ->
                    ok
            end,
            case rpc(Node, erlang, system_info, [otp_release]) of
                {rpc_error, {error, {erpc, Reason}}} when Reason =:= noconnection; Reason =:= timeout ->
                    {error, {transport, Reason}};
                Release ->
                    try_methods(Node, Release, [precompiled, local, remote_compile], [])
            end
    end.

%% Gracefully unloads eobs_agent from Node without ever issuing a hard
%% code:purge/1 that could kill production processes executing logger or
%% lager callbacks.
unload(Node) ->
    Stopped = case rpc(Node, ?MOD, prepare_unload, [], ?UNLOAD_TIMEOUT) of
                  ok -> true;
                  _ -> rpc(Node, ?MOD, logs_stop, [], ?UNLOAD_TIMEOUT) =:= ok
              end,
    case Stopped of
        true ->
            _ = rpc(Node, code, soft_purge, [?MOD], ?UNLOAD_TIMEOUT),
            _ = rpc(Node, code, delete, [?MOD], ?UNLOAD_TIMEOUT),
            case rpc(Node, code, soft_purge, [?MOD], ?UNLOAD_TIMEOUT) of
                true -> ok;
                false ->
                    timer:sleep(50),
                    _ = rpc(Node, code, soft_purge, [?MOD], ?UNLOAD_TIMEOUT),
                    ok;
                _ -> ok
            end;
        false ->
            ok
    end.

remote_version(Node) ->
    case rpc(Node, ?MOD, version, []) of
        V when is_integer(V) -> V;
        {rpc_error, {error, {erpc, Reason}}} when Reason =:= noconnection; Reason =:= timeout ->
            {transport_error, Reason};
        _ -> undefined
    end.

try_methods(_Node, _Release, [], Errors) ->
    {error, lists:reverse(Errors)};
try_methods(Node, Release, [Method | Rest], Errors) ->
    case load(Method, Node, Release) of
        ok ->
            {ok, #{loaded => true, version => ?MOD:version(), method => Method}};
        {error, {transport, _} = T} ->
            {error, T};
        {error, Reason} ->
            try_methods(Node, Release, Rest, [{Method, Reason} | Errors])
    end.

load(precompiled, Node, Release) when is_list(Release), Release =/= "" ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Release) of
        false ->
            {error, invalid_release};
        true ->
            Path = filename:join([code:priv_dir(eobserver), "agent", Release, "eobs_agent.beam"]),
            case file:read_file(Path) of
                {ok, Bin} -> load_binary(Node, Bin);
                {error, enoent} -> {error, not_bundled};
                {error, _} = Error -> Error
            end
    end;
load(precompiled, _Node, _Release) ->
    {error, unknown_release};
load(local, Node, _Release) ->
    case code:get_object_code(?MOD) of
        {?MOD, Bin, _File} -> load_binary(Node, Bin);
        error -> {error, no_object_code}
    end;
load(remote_compile, Node, _Release) ->
    case code:get_object_code(?MOD) of
        {?MOD, Bin, _} ->
            case beam_lib:chunks(Bin, [abstract_code]) of
                {ok, {?MOD, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
                    case rpc(Node, compile, forms, [Forms, [binary, return_errors]]) of
                        {ok, ?MOD, Compiled} -> load_binary(Node, Compiled);
                        {ok, ?MOD, Compiled, _Warnings} -> load_binary(Node, Compiled);
                        {rpc_error, {error, {erpc, Reason}}} when Reason =:= noconnection; Reason =:= timeout ->
                            {error, {transport, Reason}};
                        Other -> {error, {compile_failed, Other}}
                    end;
                _ ->
                    {error, no_abstract_code}
            end;
        error ->
            {error, no_object_code}
    end.

load_binary(Node, Bin) ->
    case rpc(Node, code, load_binary, [?MOD, "eobs_agent.beam", Bin]) of
        {module, ?MOD} -> ok;
        {error, Reason} -> {error, Reason};
        {rpc_error, {error, {erpc, Reason}}} when Reason =:= noconnection; Reason =:= timeout ->
            {error, {transport, Reason}};
        Other -> {error, Other}
    end.

rpc(Node, M, F, A) ->
    rpc(Node, M, F, A, ?TIMEOUT).

rpc(Node, M, F, A, Timeout) ->
    try erpc:call(Node, M, F, A, Timeout)
    catch Class:Reason -> {rpc_error, {Class, Reason}}
    end.
