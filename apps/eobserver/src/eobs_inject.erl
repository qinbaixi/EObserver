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

-spec ensure_loaded(node()) -> {ok, map()} | {error, term()}.
ensure_loaded(Node) ->
    Wanted = ?MOD:version(),
    case remote_version(Node) of
        Wanted ->
            {ok, #{loaded => false, version => Wanted, method => already_loaded}};
        _ ->
            Release = rpc(Node, erlang, system_info, [otp_release]),
            try_methods(Node, Release, [precompiled, local, remote_compile], [])
    end.

unload(Node) ->
    _ = rpc(Node, code, purge, [?MOD]),
    _ = rpc(Node, code, delete, [?MOD]),
    _ = rpc(Node, code, purge, [?MOD]),
    ok.

remote_version(Node) ->
    case rpc(Node, ?MOD, version, []) of
        V when is_integer(V) -> V;
        _ -> undefined
    end.

try_methods(_Node, _Release, [], Errors) ->
    {error, lists:reverse(Errors)};
try_methods(Node, Release, [Method | Rest], Errors) ->
    case load(Method, Node, Release) of
        ok ->
            {ok, #{loaded => true, version => ?MOD:version(), method => Method}};
        {error, Reason} ->
            try_methods(Node, Release, Rest, [{Method, Reason} | Errors])
    end.

load(precompiled, Node, Release) when is_list(Release) ->
    Path = filename:join([code:priv_dir(eobserver), "agent", Release, "eobs_agent.beam"]),
    case file:read_file(Path) of
        {ok, Bin} -> load_binary(Node, Bin);
        {error, enoent} -> {error, not_bundled};
        {error, _} = Error -> Error
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
        Other -> {error, Other}
    end.

rpc(Node, M, F, A) ->
    try erpc:call(Node, M, F, A, ?TIMEOUT)
    catch Class:Reason -> {rpc_error, {Class, Reason}}
    end.
