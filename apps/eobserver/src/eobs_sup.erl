-module(eobs_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => pg, start => {pg, start_link, [eobs]}},
        %% Starts distribution and connects; eobs_node processes call it.
        #{id => eobs_dist, start => {eobs_dist, start_link, []}},
        #{id => eobs_node_sup, start => {eobs_node_sup, start_link, []},
          type => supervisor},
        %% Before eobs_nodes: restoring saved nodes looks up their cookies.
        #{id => eobs_cookies, start => {eobs_cookies, start_link, []}},
        #{id => eobs_nodes, start => {eobs_nodes, start_link, []}},
        %% Crash dump viewer; isolated via one_for_one so node/cookie
        %% restarts never destroy open crash dumps.
        #{id => eobs_dump_files, start => {eobs_dump_files, start_link, []}},
        #{id => eobs_dump_sup, start => {eobs_dump_sup, start_link, []},
          type => supervisor}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
