%% @doc Starts distribution on the tool node on demand.
%%
%% The tool boots without a node name. The first time a target is added we
%% start distribution as a hidden node, picking short or long names to match
%% the target, so the tool never shows up in the target's nodes().
-module(eobs_dist).

-export([ensure_started/1, name_domain/1, discover/1, host_candidates/0]).

-spec ensure_started(node()) -> ok | {error, term()}.
ensure_started(Target) ->
    Domain = name_domain(Target),
    case node() of
        nonode@nohost ->
            start(Domain);
        _ ->
            case net_kernel:get_state() of
                #{name_domain := Domain} -> ok;
                #{name_domain := Other} -> {error, {name_domain_mismatch, Other, Domain}}
            end
    end.

start(Domain) ->
    start_epmd(),
    Name = list_to_atom("eobs_" ++ integer_to_list(erlang:unique_integer([positive]))
                        ++ "_" ++ os:getpid()),
    case net_kernel:start(Name, #{name_domain => Domain, hidden => true}) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason} -> {error, {dist_start_failed, Reason}}
    end.

%% Distribution needs a local epmd. A release does not put the bundled
%% ERTS on PATH, so prefer the epmd next to the running emulator.
start_epmd() ->
    BinDir = filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "bin"]),
    Epmd = case os:find_executable("epmd", BinDir) of
               false -> os:find_executable("epmd");
               Path -> Path
           end,
    case Epmd of
        false ->
            ok;
        _ ->
            Port = open_port({spawn_executable, Epmd},
                             [{args, ["-daemon"]}, exit_status, hide, stderr_to_stdout]),
            wait_exit(Port)
    end.

wait_exit(Port) ->
    receive
        {Port, {exit_status, _}} -> ok;
        {Port, {data, _}} -> wait_exit(Port)
    after 5000 ->
        catch port_close(Port),
        ok
    end.

%% A host part containing a dot means the target uses long names.
name_domain(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_, Host] ->
            case lists:member($., Host) of
                true -> longnames;
                false -> shortnames
            end;
        _ ->
            shortnames
    end.

%% Nodes registered with the epmd on this machine, as name@Host. epmd
%% does not know which host part a node was started with, so the caller
%% picks it (see host_candidates/0). EObserver's own instances are left out.
-spec discover(string() | undefined) -> map().
discover(Host0) ->
    #{default := Default} = Hosts = host_candidates(),
    Host = case Host0 of
               undefined -> binary_to_list(Default);
               _ -> Host0
           end,
    case erl_epmd:names({127, 0, 0, 1}) of
        {ok, Names} ->
            Nodes = [#{name => list_to_binary(N), port => P,
                       node => list_to_binary(N ++ "@" ++ Host)}
                     || {N, P} <- lists:sort(Names), not is_tool_name(N)],
            Hosts#{host => list_to_binary(Host), epmd => true, nodes => Nodes};
        {error, _} ->
            Hosts#{host => list_to_binary(Host), epmd => false, nodes => []}
    end.

%% Host parts a local node is likely to use. Once distribution is running
%% only hosts of the same name domain can be reached, so its own host
%% part becomes the default.
host_candidates() ->
    {ok, Short} = inet:gethostname(),
    Fqdn = net_adm:localhost(),
    All = lists:usort([Short, Fqdn, "localhost", "127.0.0.1"]),
    Default = case node() of
                  nonode@nohost -> Short;
                  Self -> lists:last(string:split(atom_to_list(Self), "@"))
              end,
    #{default => list_to_binary(Default),
      hosts => [list_to_binary(H) || H <- [Default | lists:delete(Default, All)]]}.

is_tool_name("eobs_" ++ Rest) ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse C =:= $_ end, Rest);
is_tool_name(_) ->
    false.
