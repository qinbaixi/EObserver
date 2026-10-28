%% @doc Starts distribution on the tool node on demand.
%%
%% The tool boots without a node name. The first time a target is added we
%% start distribution as a hidden node, picking short or long names to match
%% the target, so the tool never shows up in the target's nodes().
%%
%% A running node cannot talk to both kinds of names. When a target needs
%% the other kind and no target is connected, distribution is restarted in
%% that mode. Starting distribution and connecting run in this process, one
%% target at a time, so that a switch never drops a connection that is
%% being set up.
-module(eobs_dist).
-behaviour(gen_server).

-export([start_link/0, connect/3, name_domain/1, discover/1, host_candidates/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Starts distribution if needed and connects to Target. MaySwitch says
%% whether distribution may be restarted in the other name mode; automatic
%% retries pass false, so a node that is down cannot take the mode away
%% from one the user has just added.
-spec connect(node(), atom() | undefined, boolean()) -> ok | {error, term()}.
connect(Target, Cookie, MaySwitch) ->
    gen_server:call(?MODULE, {connect, Target, Cookie, MaySwitch}, infinity).

init([]) ->
    {ok, #{}}.

handle_call({connect, Target, Cookie, MaySwitch}, _From, State) ->
    Reply = case ensure_started(Target, MaySwitch) of
                ok ->
                    set_cookie(Target, Cookie),
                    case net_kernel:connect_node(Target) of
                        true -> ok;
                        _ -> {error, unreachable}
                    end;
                {error, _} = Error ->
                    Error
            end,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

ensure_started(Target, MaySwitch) ->
    Domain = name_domain(Target),
    case node() of
        nonode@nohost ->
            start(Domain, Target);
        _ ->
            case net_kernel:get_state() of
                #{name_domain := Domain} -> ok;
                #{name_domain := Other} -> switch(Other, Domain, Target, MaySwitch)
            end
    end.

switch(Have, Want, Target, MaySwitch) ->
    case {MaySwitch, nodes(connected) -- [Target]} of
        {true, []} ->
            case net_kernel:stop() of
                ok -> start(Want, Target);
                {error, Reason} -> {error, {dist_stop_failed, Reason}}
            end;
        {true, Busy} ->
            {error, {name_domain_mismatch, Have, Want, Busy}};
        {false, _} ->
            {error, {name_domain_mismatch, Have, Want, []}}
    end.

set_cookie(_Node, undefined) -> ok;
set_cookie(Node, Cookie) -> erlang:set_cookie(Node, Cookie).

start(Domain, Target) ->
    start_epmd(),
    Name = "eobs_" ++ integer_to_list(erlang:unique_integer([positive])) ++ "_" ++ os:getpid(),
    %% Long names need a host name with a dot. Without one (common on
    %% Windows) the plain name fails, so name the tool after the local
    %% address that reaches the target.
    Plain = case Domain =:= longnames andalso not lists:member($., net_adm:localhost()) of
                true -> {error, no_fqdn};
                false -> start_net(list_to_atom(Name), Domain)
            end,
    case Plain of
        {error, _} when Domain =:= longnames ->
            Full = list_to_atom(Name ++ "@" ++ local_address(Target)),
            case start_net(Full, Domain) of
                ok -> ok;
                {error, Reason} -> {error, {dist_start_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {dist_start_failed, Reason}};
        ok ->
            ok
    end.

start_net(Name, Domain) ->
    case net_kernel:start(Name, #{name_domain => Domain, hidden => true}) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% The address of this machine that a connection to Target leaves from,
%% or 127.0.0.1 for a local target or one that cannot be resolved.
local_address(Target) ->
    [_, Host] = string:split(atom_to_list(Target), "@"),
    case inet:getaddr(Host, inet) of
        {ok, {127, _, _, _}} -> "127.0.0.1";
        {ok, Ip} -> route_address(Ip);
        {error, _} -> "127.0.0.1"
    end.

route_address(Ip) ->
    case gen_udp:open(0, [inet]) of
        {ok, Sock} ->
            Addr = case gen_udp:connect(Sock, Ip, 4369) of
                       ok ->
                           case inet:sockname(Sock) of
                               {ok, {{0, 0, 0, 0}, _}} -> "127.0.0.1";
                               {ok, {Local, _}} -> inet:ntoa(Local);
                               _ -> "127.0.0.1"
                           end;
                       _ ->
                           "127.0.0.1"
                   end,
            gen_udp:close(Sock),
            Addr;
        _ ->
            "127.0.0.1"
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
