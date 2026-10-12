%% @doc Starts distribution on the tool node on demand.
%%
%% The tool boots without a node name. The first time a target is added we
%% start distribution as a hidden node, picking short or long names to match
%% the target, so the tool never shows up in the target's nodes().
-module(eobs_dist).

-export([ensure_started/1, name_domain/1]).

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
    _ = os:cmd("epmd -daemon"),
    Name = list_to_atom("eobs_" ++ integer_to_list(erlang:unique_integer([positive]))
                        ++ "_" ++ os:getpid()),
    case net_kernel:start(Name, #{name_domain => Domain, hidden => true}) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, Reason} -> {error, {dist_start_failed, Reason}}
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
