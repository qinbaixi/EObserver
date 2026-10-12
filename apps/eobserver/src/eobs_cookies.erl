%% @doc Cookies the user has connected with, kept in a file under the
%% user's config directory so they only have to be typed once.
%%
%% The UI never gets a stored cookie back: it lists entries by id with a
%% short hint and connects by id.
-module(eobs_cookies).
-behaviour(gen_server).

-export([start_link/0, list/0, save/2, delete/1, lookup/1, hint/1, file/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(MAX_ENTRIES, 50).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Entries without the cookie itself, most recently used first.
-spec list() -> [map()].
list() ->
    gen_server:call(?MODULE, list).

%% Stores a cookie (or refreshes it if already stored) and returns its id.
-spec save(binary(), binary()) -> {ok, binary()} | {error, term()}.
save(Cookie, Label) when is_binary(Cookie), Cookie =/= <<>> ->
    gen_server:call(?MODULE, {save, Cookie, Label});
save(_, _) ->
    {error, empty_cookie}.

delete(Id) ->
    gen_server:call(?MODULE, {delete, Id}).

%% Returns the cookie for an id and marks it as just used.
-spec lookup(binary()) -> {ok, binary()} | {error, not_found}.
lookup(Id) ->
    gen_server:call(?MODULE, {lookup, Id}).

file() ->
    Dir = case application:get_env(eobserver, config_dir) of
              {ok, D} -> D;
              undefined -> filename:basedir(user_config, "eobserver")
          end,
    filename:join(Dir, "cookies.eterm").

%% First and last two characters, enough to tell cookies apart.
hint(Cookie) when byte_size(Cookie) > 8 ->
    <<(binary:part(Cookie, 0, 2))/binary, "…"/utf8,
      (binary:part(Cookie, byte_size(Cookie), -2))/binary>>;
hint(_) ->
    <<"••••"/utf8>>.

%% gen_server

init([]) ->
    {ok, read()}.

handle_call(list, _From, Entries) ->
    {reply, [public(E) || E <- Entries], Entries};
handle_call({save, Cookie, Label}, _From, Entries) ->
    {Entry, Rest} = case lists:partition(fun(#{cookie := C}) -> C =:= Cookie end, Entries) of
                        {[E], Others} -> {E, Others};
                        {[], Others} -> {#{id => new_id(), cookie => Cookie, label => <<>>}, Others}
                    end,
    Entry1 = Entry#{last_used => now_s(),
                    label => case Label of
                                 <<>> -> maps:get(label, Entry);
                                 _ -> Label
                             end},
    store([Entry1 | Rest], Entry1, Entries);
handle_call({delete, Id}, _From, Entries) ->
    New = [E || #{id := I} = E <- Entries, I =/= Id],
    case write(New) of
        ok -> {reply, ok, New};
        Error -> {reply, Error, Entries}
    end;
handle_call({lookup, Id}, _From, Entries) ->
    case lists:partition(fun(#{id := I}) -> I =:= Id end, Entries) of
        {[E], Rest} ->
            E1 = E#{last_used => now_s()},
            New = [E1 | Rest],
            _ = write(New),
            {reply, {ok, maps:get(cookie, E1)}, New};
        {[], _} ->
            {reply, {error, not_found}, Entries}
    end.

handle_cast(_Msg, Entries) ->
    {noreply, Entries}.

store(New0, #{id := Id}, Old) ->
    New = lists:sublist(New0, ?MAX_ENTRIES),
    case write(New) of
        ok -> {reply, {ok, Id}, New};
        Error -> {reply, Error, Old}
    end.

public(#{cookie := Cookie} = E) ->
    maps:put(hint, hint(Cookie), maps:remove(cookie, E)).

%% Storage: one Erlang term per entry, readable with file:consult/1.

read() ->
    case file:consult(file()) of
        {ok, Terms} ->
            Valid = [E || #{id := _, cookie := C} = E <- Terms, is_binary(C)],
            lists:sort(fun(#{last_used := A}, #{last_used := B}) -> A >= B end,
                       [maps:merge(#{label => <<>>, last_used => 0}, E) || E <- Valid]);
        {error, _} ->
            []
    end.

write(Entries) ->
    File = file(),
    Tmp = File ++ ".tmp",
    Data = unicode:characters_to_binary([io_lib:format("~tp.~n", [E]) || E <- Entries]),
    Steps = [fun() -> filelib:ensure_dir(File) end,
             fun() -> file:write_file(Tmp, Data) end,
             %% Like ~/.erlang.cookie: readable by the owner only.
             fun() -> ignore_enotsup(file:change_mode(Tmp, 8#600)) end,
             fun() -> file:rename(Tmp, File) end],
    run(Steps).

run([]) -> ok;
run([Step | Rest]) ->
    case Step() of
        ok -> run(Rest);
        Error -> Error
    end.

ignore_enotsup({error, enotsup}) -> ok;
ignore_enotsup(Other) -> Other.

new_id() ->
    binary:encode_hex(crypto_free_random(6), lowercase).

%% A short random id without depending on the crypto application.
crypto_free_random(N) ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, N) >>.

now_s() ->
    erlang:system_time(second).
