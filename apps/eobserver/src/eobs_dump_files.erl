%% @doc Crash dump files: the recently opened ones, kept in a file under
%% the user's config directory (like eobs_cookies), and a directory
%% browser for the browser UI, which cannot see local paths itself.
-module(eobs_dump_files).
-behaviour(gen_server).

-export([start_link/0, recent/0, add/3, file/0, browse/1, absolute/1, roots/0, is_dump_name/1]).
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
%% Path null or empty starts at the home directory.
-spec browse(binary() | string() | null) -> {ok, map()} | {error, atom()}.
browse(Path0) ->
    Path = case Path0 of
               P when P =:= null; P =:= undefined; P =:= <<>>; P =:= "" -> home();
               P when is_binary(P) -> unicode:characters_to_list(P);
               P -> P
           end,
    case is_list(Path) andalso absolute(Path) of
        false ->
            {error, badarg};
        Dir ->
            case file:read_file_info(Dir) of
                {ok, {file_info, _, directory, _, _, _, _, _, _, _, _, _, _, _}} ->
                    case file:list_dir(Dir) of
                        {ok, Names} -> {ok, listing(Dir, Names)};
                        {error, _} = Error -> Error
                    end;
                {ok, _} ->
                    {error, enotdir};
                {error, _} = Error ->
                    Error
            end
    end.

listing(Dir, Names0) ->
    Names = lists:sort([N || N <- Names0, not hidden(N)]),
    Shown = lists:sublist(Names, ?MAX_LIST),
    Entries = [entry(Dir, N) || N <- Shown],
    Sorted = lists:sort(fun(#{dir := DA, name := A}, #{dir := DB, name := B}) ->
                                {not DA, string:casefold(A)} =< {not DB, string:casefold(B)}
                        end, [E || E <- Entries, E =/= skip]),
    Parent = filename:dirname(Dir),
    #{path => bin(Dir),
      parent => case Parent =:= Dir of
                    true -> null;
                    false -> bin(Parent)
                end,
      sep => <<"/">>,
      roots => roots(),
      truncated => length(Names) > ?MAX_LIST,
      entries => Sorted}.

entry(Dir, Name) ->
    Full = filename:join(Dir, Name),
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
    end.

hidden([$. | _]) -> true;
hidden(<<".", _/binary>>) -> true;
hidden(_) -> false.

%% erl_crash.dump, erl_crash-2024.dump, node1.dump, ...
is_dump_name(Name) ->
    Lower = string:lowercase(unicode:characters_to_list(Name)),
    lists:suffix(".dump", Lower) orelse
        (lists:prefix("erl_crash", Lower) andalso string:find(Lower, ".dump") =/= nomatch).

%% Places to start browsing from: home, the tool's working directory, and
%% on Windows the drive letters.
-spec roots() -> [map()].
roots() ->
    Home = home(),
    {ok, Cwd} = file:get_cwd(),
    Drives = case os:type() of
                 {win32, _} ->
                     [#{name => bin([D, $:]), path => bin([D, $:, $/]), kind => drive}
                      || D <- lists:seq($A, $Z), filelib:is_dir([D, $:, $/])];
                 _ ->
                     [#{name => <<"/">>, path => <<"/">>, kind => root}]
             end,
    [#{name => bin(filename:basename(Home)), path => bin(Home), kind => home},
     #{name => bin(filename:basename(Cwd)), path => bin(Cwd), kind => cwd} | Drives].

%% Absolute, normalised path with a leading ~ expanded.
absolute("~") -> home();
absolute([$~, Sep | Rest]) when Sep =:= $/; Sep =:= $\\ -> absolute(filename:join(home(), Rest));
absolute(Path) -> normalise(filename:absname(Path)).

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
        _ -> element(2, file:get_cwd())
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
