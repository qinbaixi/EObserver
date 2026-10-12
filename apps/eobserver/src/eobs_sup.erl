-module(eobs_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => pg, start => {pg, start_link, [eobs]}},
        #{id => eobs_node_sup, start => {eobs_node_sup, start_link, []},
          type => supervisor},
        #{id => eobs_nodes, start => {eobs_nodes, start_link, []}},
        #{id => eobs_cookies, start => {eobs_cookies, start_link, []}}
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}}.
