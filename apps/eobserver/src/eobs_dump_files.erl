%% @doc Crash dump files: the recently opened ones, kept in a file under
%% the user's config directory (like eobs_cookies), and a directory
%% browser for the browser UI, which cannot see local paths itself.
-module(eobs_dump_files).
-behaviour(gen_server).

-export([start_link/0, recent/0, add/3, file/0, browse/1, absolute/1, roots/0,
         is_dump_name/1, valid_path/1, allowed/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(MAX_ENTRIES, 20).
%% Directory listings stop here (`truncated` is set).
-define(MAX_LIST, 5000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Recently opened dumps that still exist, most recent first:
%% [#{path, size, mtime, opened}].
-spec recent() -> [map()].
recent() ->
    Entries = gen_server:call(?MODULE, list),
    [E#{size => Size, mtime => Mtime}
     || #{path := P} = E <- Entries,
        allowed(P),
        {ok, {file_info, Size, regular, _, _, Mtime, _, _, _, _, _, _, _, _}}
            <- [file:read_file_info(P, [{time, posix}])]].

%% Records an opened dump. Never fails the open.
add(Path, Size, Mtime) ->
    catch gen_server:call(?MODULE, {add, #{path => Path, size => Size, mtime => Mtime,
                                            opened => erlang:system_time(second)}}),
    ok.

file() ->
    Dir = case application:get_env(eobserver, config_dir) of
              {ok, D} -> D;
              undefined -> filename:basedir(user_config, "eobserver")
          end,
    filename:join(Dir, "dumps.eterm").

%% Lists a directory: dirs first, then files, hidden entries left out.
%% Path null or empty starts at the first allowed dump dir (if configured)
%% or the home directory.
-spec browse(binary() | string() | null) -> {ok, map()} | {error, atom()}.
browse(Path0) ->
    Allowed = allowed_dirs(),
    PathRes = case Path0 of
                  P when P =:= null; P =:= undefined; P =:= <<>>; P =:= "" ->
                      case Allowed of
                          [First | _] -> {ok, First};
                          [] -> {ok, home()}
                      end;
                  P ->
                      normalize_path(P)
              end,
    case PathRes of
        {error, _} = Err ->
            Err;
        {ok, Dir} ->
            case allowed_norm(Dir, Allowed) of
                false ->
                    {error, eacces};
                true ->
                    case file:read_file_info(Dir) of
                        {ok, {file_info, _, directory, _, _, _, _, _, _, _, _, _, _, _}} ->
                            case file:list_dir(Dir) of
                                {ok, Names} -> {ok, listing(Dir, Names, Allowed)};
                                {error, _} = Error -> Error
                            end;
                        {ok, _} ->
                            {error, enotdir};
                        {error, _} = Error ->
                            Error
                    end
            end
    end.

listing(Dir, Names0, Allowed) ->
    Names = lists:sort([N || N <- Names0, not hidden(N)]),
    Shown = lists:sublist(Names, ?MAX_LIST),
    Keyed = [{not maps:get(dir, E), string:casefold(maps:get(name, E)), E}
             || N <- Shown, E <- [entry(Dir, N, Allowed)], E =/= skip],
    Sorted = [E || {_, _, E} <- lists:sort(fun({DA, NA, _}, {DB, NB, _}) ->
                                                   {DA, NA} =< {DB, NB}
                                           end, Keyed)],
    Parent = filename:dirname(Dir),
    ParentOut = case Parent =:= Dir orelse not allowed_norm(Parent, Allowed) of
                    true -> null;
                    false -> bin(Parent)
                end,
    #{path => bin(Dir),
      parent => ParentOut,
      sep => <<"/">>,
      roots => roots(),
      truncated => length(Names) > ?MAX_LIST,
      entries => Sorted}.

entry(Dir, Name, Allowed) ->
    Full = filename:join(Dir, Name),
    case Allowed =:= [] orelse allowed_norm(Full, Allowed) of
        false ->
            skip;
        true ->
            case file:read_file_info(Full, [{time, posix}]) of
                {ok, {file_info, Size, Type, _, _, Mtime, _, _, _, _, _, _, _, _}} ->
                    IsDir = Type =:= directory,
                    #{name => bin(Name), path => bin(Full), dir => IsDir,
                      size => case IsDir of true -> null; false -> Size end,
                      mtime => Mtime,
                      dump => not IsDir andalso is_dump_name(Name)};
                {error, _} ->
                    %% A dangling link or an entry we may not stat.
                    skip
            end
    end.

hidden([$. | _]) -> true;
hidden(<<".", _/binary>>) -> true;
hidden(_) -> false.

%% erl_crash.dump, erl_crash-2024.dump, node1.dump, ...
is_dump_name(Name) ->
    Lower = string:lowercase(unicode:characters_to_list(Name)),
    lists:suffix(".dump", Lower) orelse
        (lists:prefix("erl_crash", Lower) andalso string:find(Lower, ".dump") =/= nomatch).

%% Places to start browsing from: configured dump_dirs (if set), otherwise
%% home, the tool's working directory, and on Windows the drive letters.
-spec roots() -> [map()].
roots() ->
    case allowed_dirs() of
        [_ | _] = Allowed ->
            [#{name => bin(root_label(D)), path => bin(D), kind => root} || D <- Allowed];
        [] ->
            Home = home(),
            CwdEntry = case file:get_cwd() of
                           {ok, Cwd} ->
                               [#{name => bin(root_label(Cwd)), path => bin(Cwd), kind => cwd}];
                           _ ->
                               []
                       end,
            Drives = case os:type() of
                         {win32, _} ->
                             [#{name => bin([D, $:]), path => bin([D, $:, $/]), kind => drive}
                              || D <- lists:seq($A, $Z), filelib:is_dir([D, $:, $/])];
                         _ ->
                             [#{name => <<"/">>, path => <<"/">>, kind => root}]
                     end,
            [#{name => bin(root_label(Home)), path => bin(Home), kind => home}] ++ CwdEntry ++ Drives
    end.

root_label(Dir) ->
    case filename:basename(Dir) of
        "" -> Dir;
        Base -> Base
    end.

%% Rejects NUL bytes and Windows UNC / device paths (\\server\share, \\?\..., //...).
-spec valid_path(binary() | string()) -> boolean().
valid_path(Bin) when is_binary(Bin), Bin =/= <<>> ->
    case binary:match(Bin, <<0>>) of
        nomatch ->
            case unicode:characters_to_list(Bin) of
                L when is_list(L) -> valid_path_list(L);
                _ -> false
            end;
        _ ->
            false
    end;
valid_path([_ | _] = L) ->
    valid_path_list(L);
valid_path(_) ->
    false.

valid_path_list(L) ->
    not lists:member(0, L) andalso not is_unc_or_device(L).

is_unc_or_device([A, B | _]) when (A =:= $/ orelse A =:= $\\),
                                  (B =:= $/ orelse B =:= $\\) ->
    true;
is_unc_or_device(_) ->
    false.

normalize_path(P) when is_binary(P) ->
    case valid_path(P) of
        true -> {ok, absolute(unicode:characters_to_list(P))};
        false -> {error, badarg}
    end;
normalize_path(P) when is_list(P) ->
    case valid_path_list(P) of
        true -> {ok, absolute(P)};
        false -> {error, badarg}
    end;
normalize_path(_) ->
    {error, badarg}.

%% Enforces --dump-dir allowlist when configured (resolving symlinks).
-spec allowed(binary() | string()) -> boolean().
allowed(Path) ->
    case allowed_dirs() of
        [] ->
            true;
        Allowed ->
            case normalize_path(Path) of
                {ok, Norm} -> allowed_norm(Norm, Allowed);
                _ -> false
            end
    end.

allowed_dirs() ->
    case application:get_env(eobserver, dump_dirs, []) of
        Dirs when is_list(Dirs) ->
            [realpath_norm(absolute(to_list(D))) || D <- Dirs, valid_path(D)];
        _ ->
            []
    end.

to_list(B) when is_binary(B) -> unicode:characters_to_list(B);
to_list(L) when is_list(L) -> L.

allowed_norm(_Dir, []) ->
    true;
allowed_norm(Dir, Allowed) ->
    Real = realpath_norm(Dir),
    lists:any(fun(Root) -> path_within(Real, Root) end, Allowed).

path_within(Path0, Root0) ->
    Path = cmp_path(Path0),
    Root = cmp_path(Root0),
    Path =:= Root orelse
        case lists:suffix("/", Root) of
            true -> lists:prefix(Root, Path);
            false -> lists:prefix(Root ++ "/", Path)
        end.

cmp_path(P) ->
    case os:type() of
        {win32, _} -> string:lowercase(P);
        _ -> P
    end.

%% Resolves symlinks along existing path components (up to 32 hops) and
%% returns a normalised absolute path using forward slashes.
realpath_norm(Path) ->
    realpath_norm(normalise(Path), 32).

realpath_norm(Path, 0) ->
    Path;
realpath_norm(Path, Hops) ->
    case resolve_links(filename:split(Path), "", Hops) of
        {resolved, Out} -> normalise(Out);
        {redirect, Target, Left} -> realpath_norm(Target, Left)
    end.

resolve_links([], Acc, _Hops) ->
    {resolved, Acc};
resolve_links([Part | Rest], "", Hops) ->
    resolve_links(Rest, Part, Hops);
resolve_links([Part | Rest], Acc, Hops) ->
    Cur = filename:join(Acc, Part),
    case file:read_link(Cur) of
        {ok, Target} when Hops > 0 ->
            AbsTarget = case filename:pathtype(Target) of
                            absolute -> Target;
                            _ -> filename:join(Acc, Target)
                        end,
            Next = case Rest of
                       [] -> AbsTarget;
                       _ -> filename:join([AbsTarget | Rest])
                   end,
            {redirect, Next, Hops - 1};
        _ ->
            resolve_links(Rest, Cur, Hops)
    end.

%% Absolute, normalised path with a leading ~ expanded.
absolute("~") ->
    normalise(home());
absolute([$~, Sep | Rest]) when Sep =:= $/; Sep =:= $\\ ->
    Clean = strip_leading_seps(Rest),
    normalise(filename:join(home(), Clean));
absolute(Path) ->
    normalise(filename:absname(Path)).

strip_leading_seps([C | Rest]) when C =:= $/; C =:= $\\ ->
    strip_leading_seps(Rest);
strip_leading_seps(Rest) ->
    Rest.

%% Resolves "." and ".." without touching the file system.
normalise(Path) ->
    [Root | Parts] = filename:split(Path),
    filename:join([Root | lists:reverse(lists:foldl(fun(".", Acc) -> Acc;
                                                       ("..", [_ | Acc]) -> Acc;
                                                       ("..", []) -> [];
                                                       (P, Acc) -> [P | Acc]
                                                    end, [], Parts))]).

home() ->
    case init:get_argument(home) of
        {ok, [[H | _]]} -> H;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> Cwd;
                _ -> "/"
            end
    end.

bin(S) ->
    case unicode:characters_to_binary(S) of
        B when is_binary(B) -> B;
        _ -> unicode:characters_to_binary(S, latin1)
    end.

%% gen_server

init([]) ->
    {ok, read()}.

handle_call(list, _From, Entries) ->
    {reply, Entries, Entries};
handle_call({add, #{path := Path} = Entry}, _From, Entries) ->
    New = lists:sublist([Entry | [E || #{path := P} = E <- Entries, P =/= Path]], ?MAX_ENTRIES),
    case write(New) of
        ok -> {reply, ok, New};
        Error -> {reply, Error, Entries}
    end.

handle_cast(_Msg, Entries) ->
    {noreply, Entries}.

%% Storage: one Erlang term per entry, readable with file:consult/1.

read() ->
    case file:consult(file()) of
        {ok, Terms} ->
            Valid = [E || #{path := P, opened := O} = E <- Terms, is_binary(P), is_integer(O)],
            lists:sublist(lists:sort(fun(#{opened := A}, #{opened := B}) -> A >= B end, Valid),
                          ?MAX_ENTRIES);
        {error, _} ->
            []
    end.

write(Entries) ->
    File = file(),
    Tmp = File ++ ".tmp",
    Data = unicode:characters_to_binary([io_lib:format("~tp.~n", [E]) || E <- Entries]),
    case filelib:ensure_dir(File) of
        ok ->
            case file:write_file(Tmp, Data) of
                ok -> file:rename(Tmp, File);
                Error -> Error
            end;
        Error ->
            Error
    end.
