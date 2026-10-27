%% @doc Supervisor of the open crash dumps (one eobs_dump each). It also
%% owns the registry table that maps dump ids and paths to dumps.
-module(eobs_dump_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(eobs_dump_reg, [named_table, public, set, {read_concurrency, true}]),
    Child = #{id => eobs_dump, start => {eobs_dump, start_link, []},
              restart => temporary, shutdown => 5000},
    {ok, {#{strategy => simple_one_for_one, intensity => 5, period => 10}, [Child]}}.
