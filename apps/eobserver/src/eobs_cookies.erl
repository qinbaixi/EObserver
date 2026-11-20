%% @doc Cookies the user has connected with, kept in a file under the
%% user's config directory so they only have to be typed once.
%%
%% The UI never gets a stored cookie back: it lists entries by id with a
%% short hint and connects by id.
-module(eobs_cookies).
-behaviour(gen_server).

-export([start_link/0, list/0, save/2, rename/2, delete/1, lookup/1, hint/1, file/0]).
-export([init/1, handle_call/3, handle_cast/2, format_status/1]).

-define(MAX_ENTRIES, 50).
-define(MAX_COOKIE_BYTES, 255).
-define(MAX_LABEL_BYTES, 256).
-define(LOOKUP_FLUSH_S, 60).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Entries without the cookie itself, most recently used first.
-spec list() -> [map()].
list() ->
    gen_server:call(?MODULE, list).

%% Stores a cookie (or refreshes it if already stored) and returns its id.
-spec save(binary(), binary()) -> {ok, binary()} | {error, term()}.
save(Cookie, _Label) when is_binary(Cookie), byte_size(Cookie) > ?MAX_COOKIE_BYTES ->
    {error, cookie_too_long};
save(Cookie, Label) when is_binary(Cookie), Cookie =/= <<>>, is_binary(Label) ->
    gen_server:call(?MODULE, {save, Cookie, clip_label(Label)});
save(_, _) ->
    {error, empty_cookie}.

%% Changes the label shown for a stored cookie.
-spec rename(binary(), binary()) -> ok | {error, term()}.
rename(Id, Label) when is_binary(Id), is_binary(Label) ->
    gen_server:call(?MODULE, {rename, Id, clip_label(Label)});
rename(_, _) ->
    {error, badarg}.

delete(Id) when is_binary(Id) ->
    gen_server:call(?MODULE, {delete, Id});
delete(_) ->
    {error, badarg}.

%% Returns the cookie for an id and marks it as just used.
-spec lookup(binary()) -> {ok, binary()} | {error, not_found}.
lookup(Id) when is_binary(Id) ->
    gen_server:call(?MODULE, {lookup, Id});
lookup(_) ->
    {error, not_found}.

file() ->
    Dir = case application:get_env(eobserver, config_dir) of
              {ok, D} -> D;
              undefined -> filename:basedir(user_config, "eobserver")
          end,
    filename:join(Dir, "cookies.eterm").

%% First and last two graphemes, enough to tell cookies apart without
%% slicing multi-byte UTF-8 characters mid-codepoint.
hint(Cookie) when is_binary(Cookie) ->
    case unicode:characters_to_binary(Cookie) of
        Bin when is_binary(Bin) ->
            Len = string:length(Bin),
            case Len > 8 of
                true ->
                    <<(string:slice(Bin, 0, 2))/binary, "…"/utf8,
                      (string:slice(Bin, Len - 2, 2))/binary>>;
                false ->
                    <<"••••"/utf8>>
            end;
        _ ->
            <<"••••"/utf8>>
    end;
hint(_) ->
    <<"••••"/utf8>>.

clip_label(Label) when byte_size(Label) > ?MAX_LABEL_BYTES ->
    case unicode:characters_to_binary(binary:part(Label, 0, ?MAX_LABEL_BYTES)) of
        Valid when is_binary(Valid) -> Valid;
        {incomplete, Valid, _} -> Valid;
        {error, Valid, _} -> Valid
    end;
clip_label(Label) ->
    Label.

%% Redact plaintext cookies from OTP crash reports / sys:get_status.
format_status(#{state := Entries} = Status) when is_list(Entries) ->
    Status#{state := [public(E) || E <- Entries]};
format_status(Status) ->
    Status.

%% gen_server

init([]) ->
    {ok, read()}.

handle_call(list, _From, Entries) ->
    {reply, [public(E) || E <- Entries], Entries};
handle_call({save, Cookie, Label}, _From, Entries) ->
    {Entry, Rest} = case lists:partition(fun(#{cookie := C}) -> C =:= Cookie end, Entries) of
                        {[E | _], Others} -> {E, Others};
                        {[], Others} -> {#{id => new_id(Entries), cookie => Cookie, label => <<>>}, Others}
                    end,
    Entry1 = Entry#{last_used => now_s(),
                    label => case Label of
                                 <<>> -> maps:get(label, Entry);
                                 _ -> Label
                             end},
    store([Entry1 | Rest], Entry1, Entries);
handle_call({rename, Id, Label}, _From, Entries) ->
    case lists:partition(fun(#{id := I}) -> I =:= Id end, Entries) of
        {[E | _], _} ->
            New = [case I of Id -> E#{label => Label}; _ -> X end || #{id := I} = X <- Entries],
            case write(New) of
                ok -> {reply, ok, New};
                Error -> {reply, Error, Entries}
            end;
        {[], _} ->
            {reply, {error, not_found}, Entries}
    end;
handle_call({delete, Id}, _From, Entries) ->
    New = [E || #{id := I} = E <- Entries, I =/= Id],
    case write(New) of
        ok -> {reply, ok, New};
        Error -> {reply, Error, Entries}
    end;
handle_call({lookup, Id}, _From, Entries) ->
    case lists:partition(fun(#{id := I}) -> I =:= Id end, Entries) of
        {[E | _], Rest} ->
            Now = now_s(),
            Prev = maps:get(last_used, E, 0),
            E1 = E#{last_used => Now},
            New = [E1 | Rest],
            case Now - Prev >= ?LOOKUP_FLUSH_S of
                true -> _ = write(New);
                false -> ok
            end,
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
    maps:put(hint, hint(Cookie), maps:remove(cookie, E));
public(E) ->
    E.

%% Storage: one Erlang term per entry, readable with file:consult/1.

read() ->
    case file:consult(file()) of
        {ok, Terms} ->
            Valid = [maps:merge(#{label => <<>>, last_used => 0}, E)
                     || #{id := I, cookie := C} = E <- Terms, is_binary(I), is_binary(C), C =/= <<>>],
            Sorted = lists:sort(fun(#{last_used := A}, #{last_used := B}) -> A >= B end, Valid),
            dedup(Sorted, #{}, #{}, []);
        {error, _} ->
            []
    end.

dedup([], _, _, Acc) ->
    lists:reverse(Acc);
dedup([#{id := I, cookie := C} = E | Rest], Ids, Cookies, Acc) ->
    case is_map_key(I, Ids) orelse is_map_key(C, Cookies) of
        true -> dedup(Rest, Ids, Cookies, Acc);
        false -> dedup(Rest, Ids#{I => true}, Cookies#{C => true}, [E | Acc])
    end.

%% Creates the temp file empty and restricts permissions to 0600 BEFORE
%% writing plaintext cookies (eliminating the world-readable TOCTOU window).
write(Entries) ->
    File = file(),
    Dir = filename:dirname(File),
    Tmp = File ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    Data = unicode:characters_to_binary([io_lib:format("~tp.~n", [E]) || E <- Entries]),
    case filelib:ensure_dir(File) of
        ok ->
            _ = ignore_enotsup(file:change_mode(Dir, 8#700)),
            case file:open(Tmp, [write, raw, binary, exclusive]) of
                {ok, Fd} ->
                    Res = try
                              ok = ignore_enotsup(file:change_mode(Tmp, 8#600)),
                              ok = file:write(Fd, Data),
                              ok = file:sync(Fd)
                          catch _:_ ->
                              {error, write_failed}
                          after
                              _ = file:close(Fd)
                          end,
                    case Res of
                        ok ->
                            case file:rename(Tmp, File) of
                                ok -> ok;
                                Error -> _ = file:delete(Tmp), Error
                            end;
                        Error ->
                            _ = file:delete(Tmp),
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

ignore_enotsup({error, enotsup}) -> ok;
ignore_enotsup(Other) -> Other.

new_id(Entries) ->
    Id = binary:encode_hex(crypto_free_random(6), lowercase),
    case lists:any(fun(#{id := I}) -> I =:= Id end, Entries) of
        true -> new_id(Entries);
        false -> Id
    end.

%% A short random id without depending on the crypto application.
crypto_free_random(N) ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, N) >>.

now_s() ->
    erlang:system_time(second).
