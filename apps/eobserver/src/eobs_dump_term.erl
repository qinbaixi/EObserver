%% @doc Crash dump term decoding. Process heaps, message queues,
%% dictionaries, stacks and the literal area are stored in the dump as
%% one term per line, linked by `H<addr>' pointers. Terms are rendered
%% straight from those lines into bounded, pretty printed text; nothing
%% is decoded into real Erlang terms (no atoms are created).
%%
%% A Term is #{text, more} where more is an expand token (or null) that
%% renders the same term again with larger limits.
%%
%% Large sections are never read whole: line-oriented sections get a
%% sparse line index, heaps a sorted address index (both memoised with
%% eobs_dump:cache/3), and lines are read through a small block cache.
-module(eobs_dump_term).

-export([render/4, expand/2, term_at/6,
         messages/4, dictionary/4, stack/4, persistent_terms/4,
         lines/5, line_count/3, section_text/4, mod_attr/4,
         atom_text/1, has_heap/2]).

-ifdef(TEST).
-export([etf_text/2, parse_ref/1, layout/2]).
-endif.

-define(LINE_MARK, 128).           % line index granularity
-define(CHUNK, (1 bsl 20)).        % streaming read size
-define(BLOCK, 65536).             % block cache unit
-define(MAX_BLOCKS, 256).          % block cache size per request (16 MB)
-define(MAX_LINE, (2 bsl 20)).     % longest heap/section line read
-define(MAX_HEAP_INDEX, (256 bsl 20)). % heap bytes indexed per process
-define(SMALL_HEAP, (4 bsl 20)).    % heaps indexed whole right away
-define(INC_MAX, (16 bsl 20)).     % searched incrementally before indexing
-define(MAX_LEVEL, 3).
-define(WIDTH, 80).

-define(PARTS, [<<"line">>, <<"msg">>, <<"key">>, <<"value">>, <<"var">>,
                <<"cur_attrib">>, <<"cur_comp">>, <<"old_attrib">>, <<"old_comp">>]).
-define(TOKEN_TAGS, [<<"proc_messages">>, <<"proc_dictionary">>, <<"proc_stack">>,
                     <<"persistent_terms">>, <<"mod">>]).

limits(0) -> #{depth => 6, items => 20, bytes => 48, chars => 1500};
limits(1) -> #{depth => 12, items => 100, bytes => 256, chars => 12000};
limits(2) -> #{depth => 30, items => 1000, bytes => 4096, chars => 120000};
limits(_) -> #{depth => 100, items => 10000, bytes => 65536, chars => 1000000}.

%% ---------------------------------------------------------------------
%% Public API

%% Render one line part of a line-oriented section. Tag/Id name the
%% section, LineNo is 0-based, Part selects which term on the line.
term_at(H, Tag, Id, LineNo, Part, Level) ->
    session(fun() -> term_at_1(H, Tag, Id, LineNo, Part, Level) end).

term_at_1(H, Tag, Id, LineNo, Part, Level) ->
    case lines(H, Tag, Id, LineNo, 1) of
        {_, [Line]} ->
            Ctx = ctx_for(Tag, Id),
            Token = token(Tag, Id, LineNo, Part, Level),
            render_part(H, Ctx, Line, Part, Level, Token);
        _ ->
            {error, not_found}
    end.

expand(H, Token) when is_binary(Token) ->
    case decode_token(Token) of
        {ok, {Tag, Id, _, Part, Level}} when Tag =:= <<"mod">> ->
            mod_attr(H, Id, Part, Level + 1);
        {ok, {Tag, Id, LineNo, Part, Level}} ->
            case term_at(H, Tag, Id, LineNo, Part, Level + 1) of
                {error, _} = E -> E;
                T -> {ok, T}
            end;
        error ->
            {error, bad_token}
    end;
expand(_, _) ->
    {error, bad_token}.

%% Render raw term text (a dump line fragment) in the heap context of a
%% process (Pid binary) or of the literal area only (null). No token.
render(H, Pid, Text, Level) ->
    Ctx = case Pid of
              null -> literals;
              _ -> {proc, Pid}
          end,
    with_render(H, Ctx, Level, fun() ->
        {Ref, _} = parse_ref(Text),
        r(Ref, 0)
    end, null).

%% Message queue: items are Terms.
messages(H, Pid, Offset, Limit) ->
    session(fun() -> messages_1(H, Pid, Offset, Limit) end).

messages_1(H, Pid, Offset, Limit) ->
    Tag = <<"proc_messages">>,
    {Total, Lines} = lines(H, Tag, Pid, Offset, Limit),
    Items = [render_part(H, {proc, Pid}, L, <<"msg">>, 0, token(Tag, Pid, N, <<"msg">>, 0))
             || {N, L} <- number(Offset, Lines)],
    {Total, Items}.

%% Process dictionary: items are #{key, value}.
dictionary(H, Pid, Offset, Limit) ->
    session(fun() -> dictionary_1(H, Pid, Offset, Limit) end).

dictionary_1(H, Pid, Offset, Limit) ->
    Tag = <<"proc_dictionary">>,
    {Total, Lines} = lines(H, Tag, Pid, Offset, Limit),
    Items = [#{key => render_part(H, {proc, Pid}, L, <<"key">>, 0,
                                  token(Tag, Pid, N, <<"key">>, 0)),
               value => render_part(H, {proc, Pid}, L, <<"value">>, 0,
                                    token(Tag, Pid, N, <<"value">>, 0))}
             || {N, L} <- number(Offset, Lines)],
    {Total, Items}.

%% Stack: items are #{addr, kind, text} plus term for y registers.
stack(H, Pid, Offset, Limit) ->
    session(fun() -> stack_1(H, Pid, Offset, Limit) end).

stack_1(H, Pid, Offset, Limit) ->
    Tag = <<"proc_stack">>,
    {Total, Lines} = lines(H, Tag, Pid, Offset, Limit),
    Items = [stack_item(H, Pid, N, L) || {N, L} <- number(Offset, Lines)],
    {Total, Items}.

stack_item(H, Pid, N, Line) ->
    {Label, Rest} = case binary:split(Line, <<":">>) of
                        [A, B] -> {A, B};
                        [A] -> {<<>>, A}
                    end,
    case Rest of
        <<"SReturn addr ", T/binary>> ->
            #{addr => Label, kind => <<"return">>, text => code_text(T)};
        <<"SCatch ", T/binary>> ->
            #{addr => Label, kind => <<"catch">>, text => code_text(T)};
        <<"S", T/binary>> ->
            #{addr => Label, kind => <<"frame">>, text => T};
        _ ->
            Term = render_part(H, {proc, Pid}, Line, <<"var">>, 0,
                               token(<<"proc_stack">>, Pid, N, <<"var">>, 0)),
            #{addr => Label, kind => <<"var">>, text => maps:get(text, Term), term => Term}
    end.

%% "0xA001090 (gen_server:loop/7 + 544)" -> "gen_server:loop/7 + 544"
code_text(T) ->
    case binary:match(T, <<"(">>) of
        {P, 1} ->
            R = binary:part(T, P + 1, byte_size(T) - P - 1),
            case byte_size(R) > 0 andalso binary:last(R) of
                $) -> binary:part(R, 0, byte_size(R) - 1);
                _ -> R
            end;
        nomatch -> T
    end.

%% Persistent terms: items are #{key, value} Terms.
persistent_terms(H, Offset, Limit, Level) ->
    session(fun() -> persistent_terms_1(H, Offset, Limit, Level) end).

persistent_terms_1(H, Offset, Limit, Level) ->
    Tag = <<"persistent_terms">>,
    {Total, Lines} = lines(H, Tag, null, Offset, Limit),
    Items = [#{key => render_part(H, literals, L, <<"key">>, Level,
                                  token(Tag, null, N, <<"key">>, Level)),
               value => render_part(H, literals, L, <<"value">>, Level,
                                    token(Tag, null, N, <<"value">>, Level))}
             || {N, L} <- number(Offset, Lines)],
    {Total, Items}.

%% Module attributes / compile info (external format in the =mod section).
mod_attr(H, Mod, Field, Level0) ->
    Level = min(Level0, ?MAX_LEVEL),
    case eobs_dump:lookup(H, <<"mod">>, Mod) of
        [{Off, Len} | _] ->
            case eobs_dump:read(H, Off, min(Len, ?MAX_LINE)) of
                {ok, Body} ->
                    M = eobs_dump_parse:mod(Body),
                    case maps:get(field_key(Field), M, undefined) of
                        undefined ->
                            {error, not_found};
                        Data ->
                            Token = case Level < ?MAX_LEVEL of
                                        true -> token(<<"mod">>, Mod, 0, Field, Level);
                                        false -> null
                                    end,
                            {ok, with_render(H, literals, Level, fun() ->
                                     ext_doc(raw_binary(H, Data))
                                 end, Token)}
                    end;
                Error ->
                    Error
            end;
        [] ->
            {error, not_found}
    end.

field_key(<<"cur_attrib">>) -> cur_attrib;
field_key(<<"cur_comp">>) -> cur_comp;
field_key(<<"old_attrib">>) -> old_attrib;
field_key(<<"old_comp">>) -> old_comp;
field_key(_) -> none.

has_heap(H, Pid) ->
    eobs_dump:lookup(H, <<"proc_heap">>, Pid) =/= [].

number(Offset, Lines) ->
    lists:zip(lists:seq(Offset, Offset + length(Lines) - 1), Lines).

ctx_for(<<"persistent_terms">>, _) -> literals;
ctx_for(_, Id) -> {proc, Id}.

%% ---------------------------------------------------------------------
%% Tokens: base64url(term_to_binary({1, Tag, Id, LineNo, Part, Level})).
%% Only binaries and integers, decoded with [safe] and validated.

token(Tag, Id, LineNo, Part, Level) when Level < ?MAX_LEVEL ->
    base64url(term_to_binary({1, Tag, Id, LineNo, Part, Level}));
token(_, _, _, _, _) ->
    null.

decode_token(Token) when byte_size(Token) < 1024 ->
    try binary_to_term(unbase64url(Token), [safe]) of
        {1, Tag, Id, LineNo, Part, Level}
          when is_binary(Tag), (is_binary(Id) orelse Id =:= null),
               is_integer(LineNo), LineNo >= 0, is_binary(Part),
               is_integer(Level), Level >= 0, Level < ?MAX_LEVEL ->
            case lists:member(Tag, ?TOKEN_TAGS) andalso lists:member(Part, ?PARTS) of
                true -> {ok, {Tag, Id, LineNo, Part, Level}};
                false -> error
            end;
        _ -> error
    catch _:_ -> error
    end;
decode_token(_) -> error.

base64url(Bin) ->
    << <<(case C of $+ -> $-; $/ -> $_; _ -> C end)>> || <<C>> <= base64:encode(Bin), C =/= $= >>.

unbase64url(Bin) ->
    B = << <<(case C of $- -> $+; $_ -> $/; _ -> C end)>> || <<C>> <= Bin >>,
    Pad = case byte_size(B) rem 4 of 0 -> <<>>; 2 -> <<"==">>; 3 -> <<"=">>; _ -> <<>> end,
    base64:decode(<<B/binary, Pad/binary>>).

%% ---------------------------------------------------------------------
%% Rendering a line part

render_part(H, Ctx, Line, Part, Level0, Token) ->
    Level = min(Level0, ?MAX_LEVEL),
    with_render(H, Ctx, Level, fun() -> part_doc(Line, Part) end, Token).

part_doc(Line, <<"line">>) ->
    {Ref, _} = parse_ref(Line),
    r(Ref, 0);
part_doc(Line, <<"msg">>) ->
    %% "<msg>:<seq trace token>"
    {Ref, _} = parse_ref(Line),
    r(Ref, 0);
part_doc(Line, <<"var">>) ->
    case binary:split(Line, <<":">>) of
        [_, T] -> {Ref, _} = parse_ref(T), r(Ref, 0);
        _ -> leaf(Line)
    end;
part_doc(Line, Part) when Part =:= <<"key">>; Part =:= <<"value">> ->
    {Ref, Rest} = parse_ref(Line),
    case Rest of
        <<"|", VText/binary>> ->
            %% persistent term line "K|V"
            case Part of
                <<"key">> -> r(Ref, 0);
                <<"value">> -> {V, _} = parse_ref(VText), r(V, 0)
            end;
        _ ->
            %% dictionary line: pointer to a {Key, Value} tuple
            case deref(Ref) of
                {tuple, 2, Elems} ->
                    {[K, V], _} = parse_refs(Elems, 2),
                    case Part of
                        <<"key">> -> r(K, 0);
                        <<"value">> -> r(V, 0)
                    end;
                _ when Part =:= <<"key">> -> r(Ref, 0);
                _ -> leaf(<<"undefined">>)
            end
    end;
part_doc(Line, _) ->
    leaf(Line).

%% Run a render with limits, budget and block cache in the process
%% dictionary; always cleaned up. Never throws.
with_render(H, Ctx, Level, Fun, Token) ->
    Lim = limits(Level),
    put(eobs_term_st, #{h => H, ctx => Ctx, lim => Lim,
                        budget => maps:get(chars, Lim),
                        visits => maps:get(chars, Lim) * 4 + 1000,
                        trunc => false}),
    try
        Doc = Fun(),
        Text0 = iolist_to_binary(layout(Doc, 0)),
        MaxChars = maps:get(chars, Lim) * 2,
        {Text, Cut} = case byte_size(Text0) > MaxChars of
                          true -> {<<(utf8_prefix(Text0, MaxChars))/binary, "...">>, true};
                          false -> {Text0, false}
                      end,
        #{trunc := Trunc} = get(eobs_term_st),
        More = case Trunc orelse Cut of
                   true -> Token;
                   false -> null
               end,
        #{text => Text, more => More}
    catch
        _:_ ->
            #{text => <<"<unreadable term>">>, more => null}
    after
        erase(eobs_term_st),
        end_step()
    end.

st(K) -> maps:get(K, get(eobs_term_st)).

lim(K) -> maps:get(K, st(lim)).

truncated() ->
    S = get(eobs_term_st),
    put(eobs_term_st, S#{trunc => true}).

%% Charge N chars against the budget; false when exhausted.
charge(N) ->
    S = #{budget := B, visits := V} = get(eobs_term_st),
    put(eobs_term_st, S#{budget => B - N, visits => V - 1}),
    B > 0 andalso V > 0.

%% ---------------------------------------------------------------------
%% Documents: {t, Text} | {c, Open, Close, [Doc]} | {p, KeyDoc, ValDoc}

leaf(T) -> {t, T}.

ellipsis() -> truncated(), {t, <<"...">>}.

flat_size({t, T}) -> iolist_size(T);
flat_size({c, O, C, Ds}) ->
    iolist_size(O) + iolist_size(C) + max(0, length(Ds) - 1) + lists:sum([flat_size(D) || D <- Ds]);
flat_size({p, K, V}) -> flat_size(K) + 4 + flat_size(V).

flat({t, T}) -> T;
flat({c, O, C, Ds}) -> [O, lists:join($,, [flat(D) || D <- Ds]), C];
flat({p, K, V}) -> [flat(K), <<" => ">>, flat(V)].

layout(Doc, Indent) ->
    case Indent + flat_size(Doc) =< ?WIDTH of
        true -> flat(Doc);
        false -> break(Doc, Indent)
    end.

break({t, T}, _) -> T;
break({c, O, C, []}, _) -> [O, C];
break({c, O, C, Ds}, Indent) ->
    case lists:all(fun({t, _}) -> true; (_) -> false end, Ds) of
        true -> fill(O, C, Ds, Indent);
        false -> break_lines(O, C, Ds, Indent)
    end;
break({p, K, V}, Indent) ->
    break_pair(K, V, Indent).

%% Leaves only: pack as many per line as fit.
fill(O, C, Ds, Indent) ->
    In = Indent + 2,
    Pad = [$\n | lists:duplicate(In, $\s)],
    {Lines, Cur, _} =
        lists:foldl(fun({t, T}, {Ls, [], _}) ->
                            {Ls, [T], In + iolist_size(T)};
                       ({t, T}, {Ls, Cur, W}) ->
                            S = iolist_size(T) + 1,
                            case W + S + 1 > ?WIDTH of
                                true -> {[lists:reverse(Cur) | Ls], [T], In + S};
                                false -> {Ls, [T, $, | Cur], W + S}
                            end
                    end, {[], [], In}, Ds),
    All = lists:reverse([lists:reverse(Cur) | Lines]),
    [O, Pad, lists:join([$, | Pad], All), $\n, lists:duplicate(Indent, $\s), C].

break_lines(O, C, Ds, Indent) ->
    In = Indent + 2,
    Pad = [$\n | lists:duplicate(In, $\s)],
    [O, Pad, lists:join([$, | Pad], [layout(D, In) || D <- Ds]),
     $\n, lists:duplicate(Indent, $\s), C].

break_pair(K, V, Indent) ->
    KT = layout(K, Indent),
    KS = iolist_size(KT),
    case flat_size(V) + Indent + KS + 4 =< ?WIDTH orelse KS > 40 of
        true -> [KT, <<" => ">>, layout(V, Indent + 4)];
        false -> [KT, <<" =>">>, $\n, lists:duplicate(Indent + 4, $\s), layout(V, Indent + 4)]
    end.

%% ---------------------------------------------------------------------
%% Term text grammar

%% Refs as they appear inside lines:
%%   H<hex> pointer, N nil, I<int>, A<hexlen>:<name>, P<pid>, p<port>,
%%   S<info string>, E<hexlen>:<data> external format,
%%   D<n>:<atoms>E<len>:<data> distribution external.
parse_ref(<<"H", R/binary>>) ->
    {A, Rest} = hex(R),
    {{ptr, A}, Rest};
parse_ref(<<"N", R/binary>>) ->
    {nil, R};
parse_ref(<<"I", R/binary>>) ->
    {I, Rest} = int_text(R),
    {{int, I}, Rest};
parse_ref(<<"A", R/binary>>) ->
    {Len, <<":", R1/binary>>} = hex(R),
    <<Name:Len/binary, Rest/binary>> = R1,
    {{atom, Name}, Rest};
parse_ref(<<"P", R/binary>>) ->
    {Id, Rest} = upto_gt(R),
    {{pid, Id}, Rest};
parse_ref(<<"p", R/binary>>) ->
    {Id, Rest} = upto_gt(R),
    {{port, <<"#Port", Id/binary>>}, Rest};
parse_ref(<<"S", R/binary>>) ->
    {{str, string:trim(R, trailing)}, <<>>};
parse_ref(<<"E", R/binary>>) ->
    {Len, <<":", R1/binary>>} = hex(R),
    {Data, Rest} = take_data(Len, R1),
    {{ext, [], Data}, Rest};
parse_ref(<<"D", R/binary>>) ->
    try
        {N, <<":", R1/binary>>} = hex(R),
        {Atoms, <<"E", R2/binary>>} = attab(N, R1, []),
        {Len, <<":", R3/binary>>} = hex(R2),
        {Data, Rest} = take_data(Len, R3),
        {{ext, Atoms, Data}, Rest}
    catch _:_ ->
        {{bad, <<"<distribution message>">>}, <<>>}
    end;
parse_ref(Other) ->
    {{bad, Other}, <<>>}.

attab(0, R, Acc) -> {lists:reverse(Acc), R};
attab(N, R, Acc) ->
    {{atom, A}, Rest} = parse_ref(R),
    attab(N - 1, Rest, [A | Acc]).

%% Data of a given byte length, base64 (dump >= 0.5) or hex encoded.
take_data(Len, R) ->
    case st_or(b64, true) of
        true ->
            N = ((Len + 2) div 3) * 4,
            case R of
                <<D:N/binary, Rest/binary>> -> {{b64, Len, D}, Rest};
                _ -> {{b64, Len, R}, <<>>}
            end;
        false ->
            N = Len * 2,
            case R of
                <<D:N/binary, Rest/binary>> -> {{hex, Len, D}, Rest};
                _ -> {{hex, Len, R}, <<>>}
            end
    end.

st_or(K, Default) ->
    case get(eobs_term_st) of
        #{K := V} -> V;
        #{h := H} ->
            V = case K of
                    b64 -> eobs_dump:cache(H, {eobs_term, b64}, fun() -> dump_b64(H) end);
                    _ -> Default
                end,
            put(eobs_term_st, (get(eobs_term_st))#{K => V}),
            V;
        _ -> Default
    end.

dump_b64(H) ->
    case eobs_dump:sections(H, <<"erl_crash_dump">>) of
        [{Vsn, _, _} | _] -> eobs_dump_parse:version(Vsn) >= [0, 5];
        _ -> true
    end.

hex(B) -> hex(B, 0).

hex(<<C, R/binary>>, A) when C >= $0, C =< $9 -> hex(R, A * 16 + C - $0);
hex(<<C, R/binary>>, A) when C >= $A, C =< $F -> hex(R, A * 16 + C - $A + 10);
hex(<<C, R/binary>>, A) when C >= $a, C =< $f -> hex(R, A * 16 + C - $a + 10);
hex(R, A) -> {A, R}.

int_text(<<"-", R/binary>>) ->
    {D, Rest} = digits(R, <<>>),
    {<<"-", D/binary>>, Rest};
int_text(R) -> digits(R, <<>>).

digits(<<C, R/binary>>, Acc) when C >= $0, C =< $9 -> digits(R, <<Acc/binary, C>>);
digits(R, Acc) -> {Acc, R}.

upto_gt(R) ->
    case binary:match(R, <<">">>) of
        {P, 1} -> {binary:part(R, 0, P + 1), binary:part(R, P + 1, byte_size(R) - P - 1)};
        nomatch -> {R, <<>>}
    end.

%% Comma separated refs; at most Max of them.
parse_refs(Bin, Max) -> parse_refs(Bin, Max, []).

parse_refs(_, 0, Acc) -> {lists:reverse(Acc), true};
parse_refs(<<>>, _, Acc) -> {lists:reverse(Acc), false};
parse_refs(Bin, Max, Acc) ->
    {Ref, Rest} = parse_ref(Bin),
    case Rest of
        <<",", R/binary>> -> parse_refs(R, Max - 1, [Ref | Acc]);
        _ -> {lists:reverse([Ref | Acc]), false}
    end.

%% Heap line (after "Addr:") -> node.
node_of(<<"l", R/binary>>) ->
    {Hd, <<"|", R1/binary>>} = parse_ref(R),
    {Tl, _} = parse_ref(R1),
    {cons, Hd, Tl};
node_of(<<"t", R/binary>>) ->
    {N, <<":", R1/binary>>} = hex(R),
    {tuple, N, R1};
node_of(<<"F", R/binary>>) ->
    {Len, <<":", R1/binary>>} = hex(R),
    {float, binary:part(R1, 0, min(Len, byte_size(R1)))};
node_of(<<"B", R/binary>>) ->
    {big, R};
node_of(<<"Yh", R/binary>>) ->
    {Len, <<":", R1/binary>>} = hex(R),
    {Data, _} = take_data(Len, R1),
    {heapbin, Len, Data};
node_of(<<"Yc", R/binary>>) ->
    {Binp, <<":", R1/binary>>} = hex(R),
    {Off, <<":", R2/binary>>} = hex(R1),
    {Sz, _} = hex(R2),
    {refc, Binp, Off, Sz};
node_of(<<"Ys", R/binary>>) ->
    {Binp, <<":", R1/binary>>} = hex(R),
    {Off, <<":", R2/binary>>} = hex(R1),
    {Sz, _} = hex(R2),
    {sub, Binp, Off, Sz};
node_of(<<"Mf", R/binary>>) ->
    {Size, <<":", R1/binary>>} = hex(R),
    {Keys, <<":", R2/binary>>} = parse_ref(R1),
    {flatmap, Size, Keys, R2};
node_of(<<"Mh", R/binary>>) ->
    {Size, <<":", R1/binary>>} = hex(R),
    {_N, <<":", R2/binary>>} = hex(R1),
    {hashmap, Size, R2};
node_of(<<"Mn", R/binary>>) ->
    {_N, <<":", R1/binary>>} = hex(R),
    {mapnode, R1};
node_of(Other) ->
    {Ref, _} = parse_ref(Other),
    {ref, Ref}.

deref({ptr, Addr}) ->
    case heap_line(Addr) of
        {ok, Line} -> node_of(Line);
        none -> missing
    end;
deref(_) ->
    not_ptr.

%% ---------------------------------------------------------------------
%% Renderer

r(Ref, Depth) ->
    case charge(1) of
        false -> ellipsis();
        true when Depth > 0 ->
            case Depth > lim(depth) of
                true -> ellipsis();
                false -> r1(Ref, Depth)
            end;
        true -> r1(Ref, Depth)
    end.

r1(nil, _) -> leaf(<<"[]">>);
r1({int, I}, _) -> chg(leaf(I));
r1({atom, A}, _) -> chg(leaf(atom_text(A)));
r1({pid, P}, _) -> chg(leaf(P));
r1({port, P}, _) -> chg(leaf(P));
r1({str, S}, _) -> chg(leaf(S));
r1({bad, _}, _) -> leaf(<<"<bad term>">>);
r1({ext, Atoms, Data}, Depth) ->
    ext_doc(decode_data(Data), Atoms, Depth);
r1({ptr, _} = P, Depth) ->
    try deref(P) of
        missing -> leaf(<<"<incomplete heap>">>);
        Node -> rnode(Node, P, Depth)
    catch _:_ ->
        leaf(<<"<bad term>">>)
    end.

chg({t, T} = D) ->
    charge(iolist_size(T)),
    D.

rnode({cons, _, _}, P, Depth) ->
    list_doc(P, Depth);
rnode({tuple, N, Elems}, _, Depth) ->
    Max = lim(items),
    {Refs, _} = parse_refs(Elems, min(N, Max)),
    Docs = [r(E, Depth + 1) || E <- Refs],
    Docs1 = case N > length(Refs) of
                true -> Docs ++ [ellipsis()];
                false -> Docs
            end,
    {c, <<"{">>, <<"}">>, Docs1};
rnode({float, F}, _, _) -> chg(leaf(float_text(F)));
rnode({big, B}, _, _) -> chg(leaf(big_text(B)));
rnode({heapbin, Len, Data}, _, _) ->
    Show = min(Len, lim(bytes)),
    bin_doc(data_prefix(Data, 0, Show), Len);
rnode({refc, Binp, Off, Sz}, _, _) ->
    Show = min(Sz, lim(bytes)),
    case binary_bytes(Binp, Off, Show) of
        {ok, Bytes} -> bin_doc(Bytes, Sz);
        none -> leaf(<<"<binary not in dump>">>)
    end;
rnode({sub, Binp, Off, Sz}, _, _) ->
    Show = min(Sz, lim(bytes)),
    case sub_bytes(Binp, Off, Show, 4) of
        {ok, Bytes} -> bin_doc(Bytes, Sz);
        none -> leaf(<<"<binary not in dump>">>)
    end;
rnode({flatmap, Size, KeysRef, Vals}, _, Depth) ->
    Max = min(Size, lim(items)),
    Keys = case deref(KeysRef) of
               {tuple, _, KElems} -> element(1, parse_refs(KElems, Max));
               _ -> []
           end,
    {VRefs, _} = parse_refs(Vals, Max),
    Pairs = [{p, r(K, Depth + 1), r(V, Depth + 1)} || {K, V} <- zip(Keys, VRefs)],
    map_doc(Pairs, Size);
rnode({hashmap, Size, Children}, _, Depth) ->
    Max = lim(items),
    {Leaves, _} = hashmap_leaves(Children, Max, []),
    Pairs = [{p, r(K, Depth + 1), r(V, Depth + 1)} || {K, V} <- Leaves],
    map_doc(lists:sort(fun key_order/2, Pairs), Size);
rnode({mapnode, _} = N, P, Depth) ->
    %% A bare interior node should not be referenced; show what it holds.
    rnode({hashmap, 0, element(2, N)}, P, Depth);
rnode({ref, Ref}, _, Depth) ->
    r1(Ref, Depth).

%% Dump floats are "%.20e"; show the shortest round-trip form.
float_text(F) ->
    try float_to_binary(binary_to_float(string:trim(F)), [short])
    catch _:_ -> F
    end.

%% Hashmap leaves come in hash order; approximate Erlang term order on
%% the rendered keys (numbers numerically, then by type, then text).
key_order({p, K1, _}, {p, K2, _}) ->
    key_rank(flat_bin(K1)) =< key_rank(flat_bin(K2)).

flat_bin(D) -> iolist_to_binary(flat(D)).

key_rank(<<C, _/binary>> = T) when C >= $0, C =< $9; C =:= $- ->
    {0, try binary_to_integer(T) catch _:_ -> try binary_to_float(T) catch _:_ -> 0 end end, T};
key_rank(<<"#Ref", _/binary>> = T) -> {2, 0, T};
key_rank(<<"#Fun", _/binary>> = T) -> {3, 0, T};
key_rank(<<"fun ", _/binary>> = T) -> {3, 0, T};
key_rank(<<"#Port", _/binary>> = T) -> {4, 0, T};
key_rank(<<"<<", _/binary>> = T) -> {10, 0, T};
key_rank(<<"<", _/binary>> = T) -> {5, 0, T};
key_rank(<<"{", _/binary>> = T) -> {6, 0, T};
key_rank(<<"#{", _/binary>> = T) -> {7, 0, T};
key_rank(<<"[]">>) -> {8, 0, <<>>};
key_rank(<<"[", _/binary>> = T) -> {9, 0, T};
key_rank(<<"\"", _/binary>> = T) -> {9, 0, T};
key_rank(T) -> {1, 0, T}.

zip([A | As], [B | Bs]) -> [{A, B} | zip(As, Bs)];
zip(_, _) -> [].

map_doc(Pairs, Size) ->
    Pairs1 = case Size > length(Pairs) of
                 true -> Pairs ++ [ellipsis()];
                 false -> Pairs
             end,
    {c, <<"#{">>, <<"}">>, Pairs1}.

%% Collect up to Max {K, V} leaves of a hashmap; children are pointers to
%% interior nodes (Mn) or leaf cons cells [K|V].
hashmap_leaves(Children, Max, _) ->
    {N, Acc} = hm(Children, Max, {0, []}),
    {lists:reverse(Acc), N >= Max}.

hm(Children, Max, Acc) ->
    {Refs, _} = parse_refs(Children, 64),
    hm_refs(Refs, Max, Acc).

hm_refs([], _, Acc) -> Acc;
hm_refs(_, Max, {N, _} = Acc) when N >= Max -> Acc;
hm_refs([Ref | Refs], Max, {N, L} = Acc) ->
    case charge(0) of
        false -> {Max, L};
        true ->
            case deref(Ref) of
                {cons, K, V} -> hm_refs(Refs, Max, {N + 1, [{K, V} | L]});
                {mapnode, Sub} -> hm_refs(Refs, Max, hm(Sub, Max, Acc));
                _ -> hm_refs(Refs, Max, Acc)
            end
    end.

%% Lists: walk the cons cells; printable integer lists become strings.
list_doc(P, Depth) ->
    Max = lim(items),
    {Heads, Tail, More} = walk(P, Max, []),
    case is_string(Heads) andalso (Tail =:= nil orelse Tail =:= more) of
        false ->
            Docs = [r(E, Depth + 1) || E <- Heads],
            list_close(Docs, Tail, More, Depth);
        true when More ->
            %% Keep reading a string a bit further than the item limit.
            {Heads2, Tail2, More2} = walk(P, min(lim(chars), Max * 10), []),
            case is_string(Heads2) of
                true -> string_doc(Heads2, More2 orelse Tail2 =/= nil);
                false -> string_doc(Heads, true)
            end;
        true ->
            string_doc(Heads, false)
    end.

list_close(Docs, nil, false, _) -> {c, <<"[">>, <<"]">>, Docs};
list_close(Docs, _, true, _) -> {c, <<"[">>, <<"]">>, Docs ++ [ellipsis()]};
list_close(Docs, incomplete, _, _) ->
    {c, <<"[">>, <<"]">>, Docs ++ [leaf(<<"<incomplete heap>">>)]};
list_close(Docs, {improper, T}, _, Depth) ->
    {c, <<"[">>, [<<"|">>, flat(r(T, Depth + 1)), <<"]">>], Docs}.

%% -> {HeadRefs, nil | incomplete | {improper, Ref} | more, More}
walk(nil, _, Acc) -> {lists:reverse(Acc), nil, false};
walk({ptr, _} = P, N, Acc) ->
    case charge(0) of
        false -> {lists:reverse(Acc), more, true};
        true ->
            case deref(P) of
                {cons, H, T} when N > 0 -> walk(T, N - 1, [H | Acc]);
                {cons, _, _} -> {lists:reverse(Acc), more, true};
                missing -> {lists:reverse(Acc), incomplete, false};
                _ -> {lists:reverse(Acc), {improper, P}, false}
            end
    end;
walk(Other, _, Acc) ->
    {lists:reverse(Acc), {improper, Other}, false}.

is_string([]) -> false;
is_string(Heads) -> lists:all(fun is_char_ref/1, Heads).

is_char_ref({int, I}) ->
    case catch binary_to_integer(I) of
        C when is_integer(C) -> is_char(C);
        _ -> false
    end;
is_char_ref(_) -> false.

is_char(C) when C >= 32, C < 127 -> true;
is_char(C) when C >= 8, C =< 13 -> true;
is_char(27) -> true;
is_char(C) when C >= 160, C < 16#D800 -> true;
is_char(C) when C > 16#DFFF, C < 16#FFFE -> true;
is_char(C) when C > 16#FFFF, C =< 16#10FFFF -> true;
is_char(_) -> false.

string_doc(Heads, More) ->
    Chars = [binary_to_integer(I) || {int, I} <- Heads],
    T = [$", escape(Chars), $", [<<"...">> || More]],
    More andalso truncated(),
    chg(leaf(iolist_to_binary(T))).

escape(Chars) -> [esc(C) || C <- Chars].

esc($") -> <<"\\\"">>;
esc($\\) -> <<"\\\\">>;
esc($\n) -> <<"\\n">>;
esc($\t) -> <<"\\t">>;
esc($\r) -> <<"\\r">>;
esc(C) when C < 32 -> io_lib:format("\\~3.8.0b", [C]);
esc(C) when C < 127 -> C;
esc(C) -> unicode:characters_to_binary([C]).

%% Binaries
bin_doc(Bytes, Total) when is_binary(Bytes) ->
    Shown = byte_size(Bytes),
    Body = case Shown > 0 andalso printable_bin(Bytes) of
               true -> [$", escape(unicode:characters_to_list(Bytes)), $"];
               false -> lists:join($,, [integer_to_binary(B) || <<B>> <= Bytes])
           end,
    Tail = case Total > Shown of
               true -> truncated(), [<<"...">>, <<" ">>, integer_to_binary(Total), <<" bytes">>];
               false -> []
           end,
    chg(leaf(iolist_to_binary([<<"<<">>, Body, Tail, <<">>">>])));
bin_doc(_, _) ->
    leaf(<<"<binary not in dump>">>).

printable_bin(B) ->
    case unicode:characters_to_list(B) of
        L when is_list(L) -> lists:all(fun is_char/1, L);
        _ -> false
    end.

%% Decode Len data bytes starting at Off from a {b64|hex, Total, Text}.
data_prefix({b64, _, D}, Off, N) ->
    S = (Off div 3) * 4,
    E = min(byte_size(D), ((Off + N + 2) div 3) * 4),
    case E > S of
        true ->
            Dec = b64_decode(binary:part(D, S, E - S)),
            Skip = Off rem 3,
            Avail = max(0, byte_size(Dec) - Skip),
            binary:part(Dec, Skip, min(N, Avail));
        false -> <<>>
    end;
data_prefix({hex, _, D}, Off, N) ->
    S = Off * 2,
    E = min(byte_size(D), (Off + N) * 2),
    case E > S of
        true -> hex_decode(binary:part(D, S, E - S));
        false -> <<>>
    end.

decode_data({b64, _, D}) -> b64_decode(D);
decode_data({hex, _, D}) -> hex_decode(D).

%% Tolerant: a truncated dump may cut the base64 text anywhere.
b64_decode(D) ->
    N = byte_size(D) - byte_size(D) rem 4,
    try base64:decode(binary:part(D, 0, N))
    catch _:_ ->
        try base64:decode(binary:part(D, 0, max(0, N - 4)))
        catch _:_ -> <<>>
        end
    end.

hex_decode(D) ->
    << <<(hexval(A) * 16 + hexval(B))>> || <<A, B>> <= D >>.

hexval(C) when C >= $0, C =< $9 -> C - $0;
hexval(C) when C >= $A, C =< $F -> C - $A + 10;
hexval(C) when C >= $a, C =< $f -> C - $a + 10;
hexval(_) -> 0.

raw_binary(H, Data) ->
    put(eobs_term_st, (get(eobs_term_st))#{h => H}),
    case st_or(b64, true) of
        true -> b64_decode(Data);
        false -> hex_decode(Data)
    end.

%% Bytes of a refc binary from its =binary:<addr> section.
binary_bytes(Binp, Off, N) ->
    H = st(h),
    Ids = [integer_to_binary(Binp, 16), string:lowercase(integer_to_binary(Binp, 16))],
    case first_section(H, <<"binary">>, Ids) of
        {SOff, SLen} ->
            Need = case st_or(b64, true) of
                       true -> ((Off + N + 2) div 3) * 4;
                       false -> (Off + N) * 2
                   end,
            case eobs_dump:read(H, SOff, min(SLen, Need + 24)) of
                {ok, Body} ->
                    {Len, <<":", Data0/binary>>} = hex(Body),
                    Data = hd(binary:split(Data0, <<"\n">>)),
                    Enc = case st_or(b64, true) of true -> b64; false -> hex end,
                    {ok, data_prefix({Enc, Len, Data}, Off, min(N, max(0, Len - Off)))};
                _ -> none
            end;
        none -> none
    end.

first_section(_, _, []) -> none;
first_section(H, Tag, [Id | Ids]) ->
    case eobs_dump:lookup(H, Tag, Id) of
        [{O, L} | _] -> {O, L};
        [] -> first_section(H, Tag, Ids)
    end.

%% Sub binary: Binp is a heap binary / ProcBin on the heap, or a binary.
sub_bytes(_, _, _, 0) -> none;
sub_bytes(Binp, Off, N, Hops) ->
    case heap_line(Binp) of
        {ok, Line} ->
            case node_of(Line) of
                {heapbin, Len, Data} -> {ok, data_prefix(Data, Off, min(N, max(0, Len - Off)))};
                {refc, B2, O2, _} -> binary_bytes(B2, O2 + Off, N);
                {sub, B2, O2, _} -> sub_bytes(B2, O2 + Off, N, Hops - 1);
                _ -> none
            end;
        none ->
            binary_bytes(Binp, Off, N)
    end.

big_text(<<"16#", Hex/binary>>) when byte_size(Hex) < 4000 ->
    integer_to_binary(element(1, hex(Hex)));
big_text(<<"-16#", Hex/binary>>) when byte_size(Hex) < 4000 ->
    integer_to_binary(-element(1, hex(Hex)));
big_text(B) ->
    string:trim(B).

%% Atom names as Erlang source text, quoted when needed.
atom_text(Name) ->
    case needs_quote(Name) of
        false -> Name;
        true -> iolist_to_binary([$', [aesc(C) || C <- unicode_list(Name)], $'])
    end.

unicode_list(Name) ->
    case unicode:characters_to_list(Name) of
        L when is_list(L) -> L;
        _ -> binary_to_list(Name)
    end.

aesc($') -> <<"\\'">>;
aesc($\\) -> <<"\\\\">>;
aesc(C) when C < 32 -> io_lib:format("\\~3.8.0b", [C]);
aesc(C) -> unicode:characters_to_binary([C]).

needs_quote(<<C, Rest/binary>> = Name) when C >= $a, C =< $z ->
    not lists:all(fun atom_char/1, binary_to_list(Rest)) orelse reserved(Name);
needs_quote(_) -> true.

atom_char(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 -> true;
atom_char($_) -> true;
atom_char($@) -> true;
atom_char(_) -> false.

reserved(N) ->
    lists:member(N, [<<"after">>, <<"and">>, <<"andalso">>, <<"band">>, <<"begin">>,
                     <<"bnot">>, <<"bor">>, <<"bsl">>, <<"bsr">>, <<"bxor">>, <<"case">>,
                     <<"catch">>, <<"cond">>, <<"div">>, <<"else">>, <<"end">>, <<"fun">>,
                     <<"if">>, <<"let">>, <<"maybe">>, <<"not">>, <<"of">>, <<"or">>,
                     <<"orelse">>, <<"receive">>, <<"rem">>, <<"try">>, <<"when">>,
                     <<"xor">>]).

utf8_prefix(Bin, N) ->
    P = binary:part(Bin, 0, N),
    case unicode:characters_to_binary(P) of
        B when is_binary(B) -> B;
        {incomplete, B, _} -> B;
        {error, B, _} -> B
    end.

%% ---------------------------------------------------------------------
%% External term format, rendered without creating atoms.

ext_doc(Bin) -> ext_doc(Bin, [], 0).

ext_doc(Bin, Atoms, Depth) ->
    put(eobs_etf_atoms, list_to_tuple(Atoms)),
    try etf(Bin, Depth) of
        {Doc, _} -> Doc
    catch _:_ ->
        leaf(iolist_to_binary([<<"<external term, ">>, integer_to_binary(byte_size(Bin)),
                               <<" bytes>">>]))
    after
        erase(eobs_etf_atoms)
    end.

-ifdef(TEST).
etf_text(Bin, Level) ->
    with_render(none, literals, Level, fun() -> ext_doc(Bin) end, null).
-endif.

etf(<<131, 80, USize:32, Z/binary>>, Depth) when USize =< (16 bsl 20) ->
    etf(<<131, (zlib:uncompress(Z))/binary>>, Depth);
etf(<<131, 68, _/binary>>, _) ->
    %% Distribution header: not decoded.
    {leaf(<<"<distribution message>">>), <<>>};
etf(<<131, R/binary>>, Depth) ->
    e(R, Depth);
etf(R, Depth) ->
    e(R, Depth).

e(Bin, Depth) ->
    case charge(1) andalso Depth =< lim(depth) of
        false -> {ellipsis(), skip(Bin)};
        true -> e1(Bin, Depth)
    end.

e1(<<97, I, R/binary>>, _) -> {chg(leaf(integer_to_binary(I))), R};
e1(<<98, I:32/signed, R/binary>>, _) -> {chg(leaf(integer_to_binary(I))), R};
e1(<<70, F:64/float, R/binary>>, _) -> {chg(leaf(float_to_binary(F, [short]))), R};
e1(<<99, F:31/binary, R/binary>>, _) -> {chg(leaf(hd(binary:split(F, <<0>>)))), R};
e1(<<110, N, S, D:N/binary, R/binary>>, _) -> {chg(leaf(big(S, D))), R};
e1(<<111, N:32, S, D:N/binary, R/binary>>, _) when N =< 4096 -> {chg(leaf(big(S, D))), R};
e1(<<111, N:32, _, _:N/binary, R/binary>>, _) -> {leaf(<<"<bignum>">>), R};
e1(<<106, R/binary>>, _) -> {leaf(<<"[]">>), R};
e1(<<107, L:16, S:L/binary, R/binary>>, _) ->
    Chars = binary_to_list(S),
    Max = lim(chars),
    case lists:all(fun is_char/1, Chars) of
        true when L > Max ->
            truncated(),
            {chg(leaf(iolist_to_binary([$", escape(lists:sublist(Chars, Max)), $", <<"...">>]))), R};
        true -> {chg(leaf(iolist_to_binary([$", escape(Chars), $"]))), R};
        false ->
            Items = lim(items),
            Docs = [leaf(integer_to_binary(C)) || C <- lists:sublist(Chars, Items)],
            {list_close(Docs, nil, L > Items, 0), R}
    end;
e1(<<108, N:32, R0/binary>>, Depth) ->
    {Docs, R1} = elems(N, R0, Depth),
    case R1 of
        <<106, R/binary>> -> {{c, <<"[">>, <<"]">>, Docs}, R};
        _ ->
            {T, R} = e(R1, Depth + 1),
            {{c, <<"[">>, [<<"|">>, flat(T), <<"]">>], Docs}, R}
    end;
e1(<<104, N, R0/binary>>, Depth) ->
    {Docs, R} = elems(N, R0, Depth),
    {{c, <<"{">>, <<"}">>, Docs}, R};
e1(<<105, N:32, R0/binary>>, Depth) ->
    {Docs, R} = elems(N, R0, Depth),
    {{c, <<"{">>, <<"}">>, Docs}, R};
e1(<<116, N:32, R0/binary>>, Depth) ->
    {Pairs, R} = pairs(N, R0, Depth),
    {{c, <<"#{">>, <<"}">>, Pairs}, R};
e1(<<109, L:32, B:L/binary, R/binary>>, _) ->
    {bin_doc(binary:part(B, 0, min(L, lim(bytes))), L), R};
e1(<<77, L:32, _Bits, B:L/binary, R/binary>>, _) ->
    {bin_doc(binary:part(B, 0, min(L, lim(bytes))), L), R};
e1(<<88, R0/binary>>, _) ->
    {Node, <<Id:32, Ser:32, _:32, R/binary>>} = ename(R0),
    {chg(leaf(pid_text(Node, Id, Ser))), R};
e1(<<103, R0/binary>>, _) ->
    {Node, <<Id:32, Ser:32, _:8, R/binary>>} = ename(R0),
    {chg(leaf(pid_text(Node, Id, Ser))), R};
e1(<<89, R0/binary>>, _) ->
    {Node, <<Id:32, _:32, R/binary>>} = ename(R0),
    {chg(leaf(port_text(Node, Id))), R};
e1(<<120, R0/binary>>, _) ->
    {Node, <<Id:64, _:32, R/binary>>} = ename(R0),
    {chg(leaf(port_text(Node, Id))), R};
e1(<<102, R0/binary>>, _) ->
    {Node, <<Id:32, _:8, R/binary>>} = ename(R0),
    {chg(leaf(port_text(Node, Id))), R};
e1(<<90, Len:16, R0/binary>>, _) ->
    {Node, <<_:32, Ids:(Len * 4)/binary, R/binary>>} = ename(R0),
    {chg(leaf(ref_text(Node, Ids))), R};
e1(<<114, Len:16, R0/binary>>, _) ->
    {Node, <<_:8, Ids:(Len * 4)/binary, R/binary>>} = ename(R0),
    {chg(leaf(ref_text(Node, Ids))), R};
e1(<<101, R0/binary>>, _) ->
    {Node, <<Id:4/binary, _:8, R/binary>>} = ename(R0),
    {chg(leaf(ref_text(Node, Id))), R};
e1(<<113, R0/binary>>, _) ->
    {M, R1} = ename(R0),
    {F, R2} = ename(R1),
    {A, R} = small(R2),
    {chg(leaf(iolist_to_binary([<<"fun ">>, atom_text(M), $:, atom_text(F), $/,
                                integer_to_binary(A)]))), R};
e1(<<112, Size:32, R0/binary>>, _) ->
    Body = binary:part(R0, 0, Size - 4),
    R = binary:part(R0, Size - 4, byte_size(R0) - Size + 4),
    <<_Arity, _Uniq:16/binary, _Index:32, _NumFree:32, R1/binary>> = Body,
    {M, R2} = ename(R1),
    {OldIndex, R3} = small(R2),
    {OldUniq, _} = small(R3),
    {chg(leaf(iolist_to_binary([<<"#Fun<">>, M, $., integer_to_binary(OldIndex), $.,
                                integer_to_binary(OldUniq), $>]))), R};
e1(Bin, _) ->
    case is_atom_tag(Bin) of
        true ->
            {Name, R} = ename(Bin),
            {chg(leaf(atom_text(Name))), R};
        false ->
            error(badetf)
    end.

is_atom_tag(<<T, _/binary>>) -> lists:member(T, [82, 100, 115, 118, 119]);
is_atom_tag(_) -> false.

%% Atom name from an atom encoding.
ename(<<100, L:16, A:L/binary, R/binary>>) -> {latin1(A), R};
ename(<<115, L, A:L/binary, R/binary>>) -> {latin1(A), R};
ename(<<118, L:16, A:L/binary, R/binary>>) -> {A, R};
ename(<<119, L, A:L/binary, R/binary>>) -> {A, R};
ename(<<82, Ix, R/binary>>) ->
    Atoms = case get(eobs_etf_atoms) of
                T when is_tuple(T) -> T;
                _ -> {}
            end,
    case Ix < tuple_size(Atoms) of
        true -> {element(Ix + 1, Atoms), R};
        false -> {<<"<atom cache ", (integer_to_binary(Ix))/binary, ">">>, R}
    end.

latin1(A) -> unicode:characters_to_binary(A, latin1).

small(<<97, I, R/binary>>) -> {I, R};
small(<<98, I:32/signed, R/binary>>) -> {I, R};
small(<<110, N, S, D:N/binary, R/binary>>) ->
    V = binary:decode_unsigned(D, little),
    {case S of 0 -> V; _ -> -V end, R}.

big(S, D) ->
    V = binary:decode_unsigned(D, little),
    integer_to_binary(case S of 0 -> V; _ -> -V end).

elems(N, R0, Depth) ->
    Max = lim(items),
    elems(N, Max, R0, Depth, []).

elems(0, _, R, _, Acc) -> {lists:reverse(Acc), R};
elems(N, 0, R, _, Acc) ->
    {lists:reverse([ellipsis() | Acc]), skip_n(N, R)};
elems(N, Max, R0, Depth, Acc) ->
    {D, R} = e(R0, Depth + 1),
    elems(N - 1, Max - 1, R, Depth, [D | Acc]).

pairs(N, R0, Depth) ->
    pairs(N, lim(items), R0, Depth, []).

pairs(0, _, R, _, Acc) -> {lists:reverse(Acc), R};
pairs(N, 0, R, _, Acc) ->
    {lists:reverse([ellipsis() | Acc]), skip_n(2 * N, R)};
pairs(N, Max, R0, Depth, Acc) ->
    {K, R1} = e(R0, Depth + 1),
    {V, R} = e(R1, Depth + 1),
    pairs(N - 1, Max - 1, R, Depth, [{p, K, V} | Acc]).

skip_n(0, R) -> R;
skip_n(N, R) -> skip_n(N - 1, skip(R)).

skip(<<97, _, R/binary>>) -> R;
skip(<<98, _:32, R/binary>>) -> R;
skip(<<70, _:64, R/binary>>) -> R;
skip(<<99, _:31/binary, R/binary>>) -> R;
skip(<<110, N, _, _:N/binary, R/binary>>) -> R;
skip(<<111, N:32, _, _:N/binary, R/binary>>) -> R;
skip(<<106, R/binary>>) -> R;
skip(<<107, L:16, _:L/binary, R/binary>>) -> R;
skip(<<108, N:32, R/binary>>) -> skip(skip_n(N, R));
skip(<<104, N, R/binary>>) -> skip_n(N, R);
skip(<<105, N:32, R/binary>>) -> skip_n(N, R);
skip(<<116, N:32, R/binary>>) -> skip_n(2 * N, R);
skip(<<109, L:32, _:L/binary, R/binary>>) -> R;
skip(<<77, L:32, _, _:L/binary, R/binary>>) -> R;
skip(<<88, R/binary>>) -> <<_:12/binary, R1/binary>> = skip(R), R1;
skip(<<103, R/binary>>) -> <<_:9/binary, R1/binary>> = skip(R), R1;
skip(<<89, R/binary>>) -> <<_:8/binary, R1/binary>> = skip(R), R1;
skip(<<120, R/binary>>) -> <<_:12/binary, R1/binary>> = skip(R), R1;
skip(<<102, R/binary>>) -> <<_:5/binary, R1/binary>> = skip(R), R1;
skip(<<90, L:16, R/binary>>) -> N = 4 + L * 4, <<_:N/binary, R1/binary>> = skip(R), R1;
skip(<<114, L:16, R/binary>>) -> N = 1 + L * 4, <<_:N/binary, R1/binary>> = skip(R), R1;
skip(<<101, R/binary>>) -> <<_:5/binary, R1/binary>> = skip(R), R1;
skip(<<113, R/binary>>) -> skip(skip(skip(R)));
skip(<<112, Size:32, R/binary>>) -> binary:part(R, Size - 4, byte_size(R) - Size + 4);
skip(Bin) ->
    {_, R} = ename(Bin),
    R.

pid_text(Node, Id, Ser) ->
    iolist_to_binary([$<, node_part(Node), $., integer_to_binary(Id), $.,
                      integer_to_binary(Ser), $>]).

port_text(Node, Id) ->
    iolist_to_binary([<<"#Port<">>, node_part(Node), $., integer_to_binary(Id), $>]).

ref_text(Node, Ids) ->
    Ns = lists:reverse([integer_to_binary(I) || <<I:32>> <= Ids]),
    iolist_to_binary([<<"#Ref<">>, node_part(Node), [[$., N] || N <- Ns], $>]).

node_part(Node) ->
    case Node =:= dump_node() of
        true -> <<"0">>;
        false -> atom_text(Node)
    end.

dump_node() ->
    case get(eobs_term_st) of
        #{node := N} -> N;
        #{h := none} -> <<"nonode@nohost">>;
        #{h := H} = S ->
            N = eobs_dump:cache(H, {eobs_term, node}, fun() ->
                    case eobs_dump:sections(H, <<"node">>) of
                        [{Id, _, _} | _] when is_binary(Id) -> eobs_dump_parse:unquote_atom(Id);
                        _ -> <<"nonode@nohost">>
                    end
                end),
            put(eobs_term_st, S#{node => N}),
            N;
        _ -> <<"nonode@nohost">>
    end.

%% ---------------------------------------------------------------------
%% Heap lines by address

heap_line(Addr) ->
    H = st(h),
    Ctxs = case st(ctx) of
               {proc, Pid} -> [{proc, Pid}, literals];
               literals -> [literals]
           end,
    heap_line(H, Addr, Ctxs).

heap_line(_, _, []) -> none;
heap_line(H, Addr, [Ctx | Ctxs]) ->
    case heap_find(H, Ctx, Addr) of
        {ok, Off, Len, Rel} ->
            {Line, _} = read_line(H, Off + Rel, Off + Len),
            case binary:split(Line, <<":">>) of
                [_, Rest] -> {ok, Rest};
                _ -> none
            end;
        none ->
            heap_line(H, Addr, Ctxs)
    end.

%% A heap is dumped from its roots (stack, then messages, then the
%% dictionary), so terms near the roots sit near the section start. Big
%% heaps are first searched incrementally from the start (state kept for
%% the current request); the full sorted index is only built when the
%% address lies beyond ?INC_MAX, or once some other request built it.
heap_find(H, Ctx, Addr) ->
    {Tag, Id} = case Ctx of
                    {proc, Pid} -> {<<"proc_heap">>, Pid};
                    literals -> {<<"literals">>, null}
                end,
    case section(H, Tag, Id) of
        {Off, Len} ->
            Key = {eobs_heap, Tag, Id, Off, Len},
            Build = fun() -> build_heap_index(H, Off, Len) end,
            Index = case get({eobs_hidx, Key}) of
                        undefined ->
                            I = case Len =< ?SMALL_HEAP of
                                    true -> eobs_dump:cache(H, Key, Build);
                                    false -> peek_cache(H, Key)
                                end,
                            %% Remembered for the request: cache lookups are not free.
                            is_map(I) andalso put({eobs_hidx, Key}, I),
                            I;
                        I -> I
                    end,
            Found = case Index of
                        #{chunks := Chunks} -> find_addr(Chunks, Addr);
                        not_cached -> inc_find(H, Key, Off, Len, Addr, Build)
                    end,
            case Found of
                {ok, Rel} -> {ok, Off, Len, Rel};
                none -> none
            end;
        none ->
            none
    end.

peek_cache(H, Key) ->
    Ref = make_ref(),
    try eobs_dump:cache(H, Key, fun() -> throw({Ref, not_cached}) end)
    catch throw:{Ref, not_cached} -> not_cached
    end.

inc_find(H, Key, Off, Len, Addr, Build) ->
    {Pos, Map} = case get({eobs_inc, Key}) of
                     undefined -> {0, #{}};
                     St -> St
                 end,
    case Map of
        #{Addr := Rel} ->
            {ok, Rel};
        _ when Pos >= Len ->
            none;
        _ when Pos >= ?INC_MAX ->
            #{chunks := Chunks} = I = eobs_dump:cache(H, Key, Build),
            put({eobs_hidx, Key}, I),
            erase({eobs_inc, Key}),
            find_addr(Chunks, Addr);
        _ ->
            {Map1, Next} = fold_chunk(H, Off, Len, Pos,
                                      fun(R, Prefix, M) ->
                                              case hex(Prefix) of
                                                  {A, <<":", _/binary>>} -> M#{A => R};
                                                  _ -> M
                                              end
                                      end, Map),
            put({eobs_inc, Key}, {Next, Map1}),
            inc_find(H, Key, Off, Len, Addr, Build)
    end.

section(H, Tag, null) ->
    case eobs_dump:sections(H, Tag) of
        [{_, Off, Len} | _] -> {Off, Len};
        [] -> none
    end;
section(H, Tag, Id) ->
    case eobs_dump:lookup(H, Tag, Id) of
        [{Off, Len} | _] -> {Off, Len};
        [] -> none
    end.

%% Sorted <<Addr:64, RelOff:32>> chunks of up to 1M entries each.
build_heap_index(H, Off, Len0) ->
    Len = min(Len0, ?MAX_HEAP_INDEX),
    {_, Cur, Chunks} =
        fold_line_starts(H, Off, Len,
                         fun(Rel, Prefix, {N, Acc, Cs} = St) ->
                                 case hex(Prefix) of
                                     {A, <<":", _/binary>>} when N >= 1000000 ->
                                         {1, [{A, Rel}], [pack(Acc) | Cs]};
                                     {A, <<":", _/binary>>} ->
                                         {N + 1, [{A, Rel} | Acc], Cs};
                                     _ ->
                                         St
                                 end
                         end, {0, [], []}),
    #{off => Off, len => Len0, partial => Len < Len0,
      chunks => [pack(Cur) | Chunks]}.

pack(Pairs) ->
    << <<A:64, R:32>> || {A, R} <- lists:sort(Pairs) >>.

find_addr([], _) -> none;
find_addr([C | Cs], Addr) ->
    case bsearch(C, Addr, 0, byte_size(C) div 12 - 1) of
        none -> find_addr(Cs, Addr);
        Found -> Found
    end.

bsearch(_, _, Lo, Hi) when Lo > Hi -> none;
bsearch(C, Addr, Lo, Hi) ->
    Mid = (Lo + Hi) div 2,
    <<_:(Mid * 12)/binary, A:64, R:32, _/binary>> = C,
    if
        A =:= Addr -> {ok, R};
        A < Addr -> bsearch(C, Addr, Mid + 1, Hi);
        true -> bsearch(C, Addr, Lo, Mid - 1)
    end.

%% Call Fun(RelOff, Prefix, Acc) for each line start in [Off, Off+Len);
%% Prefix is up to 32 bytes of the line.
fold_line_starts(H, Off, Len, Fun, Acc) when Len > 0 ->
    fold_chunks(H, Off, Len, 0, Fun, Acc);
fold_line_starts(_, _, _, _, Acc) ->
    Acc.

fold_chunks(_, _, Len, Pos, _, Acc) when Pos >= Len -> Acc;
fold_chunks(H, Off, Len, Pos, Fun, Acc0) ->
    {Acc, Next} = fold_chunk(H, Off, Len, Pos, Fun, Acc0),
    fold_chunks(H, Off, Len, Next, Fun, Acc).

%% One ?CHUNK of line starts from Pos: {Acc, NextPos}.
fold_chunk(H, Off, Len, Pos, Fun, Acc0) ->
    Want = min(?CHUNK + 32, Len - Pos),
    case eobs_dump:read(H, Off + Pos, Want) of
        {ok, Chunk} when byte_size(Chunk) > 0 ->
            Span = min(?CHUNK, byte_size(Chunk)),
            Starts0 = [P + 1 || {P, _} <- binary:matches(Chunk, <<"\n">>, [{scope, {0, Span}}]),
                                P + 1 < byte_size(Chunk) orelse Pos + P + 1 < Len],
            Starts = case Pos of
                         0 -> [0 | Starts0];
                         _ -> Starts0
                     end,
            Acc = lists:foldl(
                    fun(S, A) when Pos + S < Len ->
                            Prefix = binary:part(Chunk, S, min(32, byte_size(Chunk) - S)),
                            Fun(Pos + S, Prefix, A);
                       (_, A) -> A
                    end, Acc0, Starts),
            {Acc, Pos + Span};
        _ ->
            {Acc0, Len}
    end.

%% ---------------------------------------------------------------------
%% Line-oriented sections

%% {Total, Lines} for lines [Offset, Offset+Limit) of a section.
lines(H, Tag, Id, Offset, Limit) ->
    try
        case section(H, Tag, Id) of
            {Off, Len} ->
                #{n := N, marks := Marks} = line_index(H, Tag, Id, Off, Len),
                case Offset < N andalso Limit > 0 of
                    true ->
                        M = Offset div ?LINE_MARK,
                        <<_:(M * 8)/binary, Rel:64, _/binary>> = Marks,
                        Lines = read_lines(H, Off + Rel, Off + Len, Offset rem ?LINE_MARK,
                                           min(Limit, N - Offset), []),
                        {N, Lines};
                    false ->
                        {N, []}
                end;
            none ->
                {0, []}
        end
    after
        end_step()
    end.

line_count(H, Tag, Id) ->
    case section(H, Tag, Id) of
        {Off, Len} -> maps:get(n, line_index(H, Tag, Id, Off, Len));
        none -> 0
    end.

line_index(H, Tag, Id, Off, Len) ->
    eobs_dump:cache(H, {eobs_lines, Tag, Id, Off, Len}, fun() ->
        {N, Marks} = fold_line_starts(H, Off, Len,
                                      fun(Rel, _, {I, Ms}) when I rem ?LINE_MARK =:= 0 ->
                                              {I + 1, [<<Rel:64>> | Ms]};
                                         (_, _, {I, Ms}) ->
                                              {I + 1, Ms}
                                      end, {0, []}),
        #{n => N, marks => iolist_to_binary(lists:reverse(Marks))}
    end).

read_lines(_, _, _, _, 0, Acc) -> lists:reverse(Acc);
read_lines(_, Pos, End, _, _, Acc) when Pos >= End -> lists:reverse(Acc);
read_lines(H, Pos, End, Skip, Take, Acc) ->
    {Line, Next} = read_line(H, Pos, End),
    case Skip of
        0 -> read_lines(H, Next, End, 0, Take - 1, [Line | Acc]);
        _ -> read_lines(H, Next, End, Skip - 1, Take, Acc)
    end.

%% Whole body of a section, at most Max bytes: {ok, Body, Truncated}.
section_text(H, Tag, Id, Max) ->
    case section(H, Tag, Id) of
        {Off, Len} ->
            case eobs_dump:read(H, Off, min(Len, Max)) of
                {ok, Body} -> {ok, Body, Len > Max};
                Error -> Error
            end;
        none ->
            {error, not_found}
    end.

%% One line at absolute position Pos (not past End): {Line, NextPos}.
%% Lines longer than ?MAX_LINE are cut (the rest is skipped).
read_line(H, Pos, End) ->
    read_line(H, Pos, End, Pos, []).

read_line(_, Start, End, Pos, Acc) when Pos >= End ->
    {cut(Start, Pos, Acc), End};
read_line(H, Start, End, Pos, Acc) ->
    BlockNo = Pos div ?BLOCK,
    case block(H, BlockNo) of
        <<>> ->
            {cut(Start, Pos, Acc), End};
        Block ->
            In = Pos - BlockNo * ?BLOCK,
            Avail = min(byte_size(Block) - In, End - Pos),
            case Avail =< 0 of
                true -> {cut(Start, Pos, Acc), End};
                false ->
                    case binary:match(Block, <<"\n">>, [{scope, {In, Avail}}]) of
                        {P, 1} ->
                            Piece = binary:part(Block, In, P - In),
                            {cut(Start, Pos, [Piece | Acc]), BlockNo * ?BLOCK + P + 1};
                        nomatch ->
                            Piece = binary:part(Block, In, Avail),
                            Acc1 = case Pos - Start < ?MAX_LINE of
                                       true -> [Piece | Acc];
                                       false -> Acc
                                   end,
                            read_line(H, Start, End, Pos + Avail, Acc1)
                    end
            end
    end.

cut(_, _, Acc) ->
    L = iolist_to_binary(lists:reverse(Acc)),
    L1 = case byte_size(L) > ?MAX_LINE of
             true -> binary:part(L, 0, ?MAX_LINE);
             false -> L
         end,
    case byte_size(L1) > 0 andalso binary:last(L1) of
        $\r -> binary:part(L1, 0, byte_size(L1) - 1);
        _ -> L1
    end.

block(H, N) ->
    Key = {eobs_blk, N},
    case get(Key) of
        undefined ->
            Count = case get(eobs_blk_n) of undefined -> 0; C -> C end,
            Count >= ?MAX_BLOCKS andalso erase_blocks(),
            B = case eobs_dump:read(H, N * ?BLOCK, ?BLOCK) of
                    {ok, Bin} -> Bin;
                    _ -> <<>>
                end,
            put(Key, B),
            put(eobs_blk_n, min(Count, ?MAX_BLOCKS - 1) + 1),
            B;
        B ->
            B
    end.

erase_blocks() ->
    [erase(K) || {{eobs_blk, _} = K, _} <- get()],
    erase(eobs_blk_n),
    ok.

%% Request-scoped state (block cache, incremental heap search) survives
%% across the items of one API call and is dropped at its end.
session(Fun) ->
    case get(eobs_term_session) of
        true -> Fun();
        _ ->
            put(eobs_term_session, true),
            try Fun()
            after
                erase(eobs_term_session),
                erase_all()
            end
    end.

end_step() ->
    case get(eobs_term_session) of
        true -> ok;
        _ -> erase_all()
    end.

erase_all() ->
    erase_blocks(),
    [erase(K) || {{T, _} = K, _} <- get(), T =:= eobs_inc orelse T =:= eobs_hidx],
    ok.
