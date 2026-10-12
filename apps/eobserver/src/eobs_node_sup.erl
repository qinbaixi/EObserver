-module(eobs_node_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/2, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child(Node, Cookie) ->
    supervisor:start_child(?MODULE, [Node, Cookie]).

init([]) ->
    Child = #{id => eobs_node, start => {eobs_node, start_link, []},
              restart => temporary},
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [Child]}}.
