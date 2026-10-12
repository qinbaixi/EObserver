%% @doc Converts collected Erlang terms to JSON. Pids, ports, refs, funs and
%% tuples become strings so the browser never has to parse Erlang syntax.
-module(eobs_json).

-export([encode/1, decode/1, to_json/1]).

encode(Term) ->
    jsx:encode(to_json(Term)).

decode(Bin) ->
    jsx:decode(Bin, [return_maps]).

to_json(Term) when is_map(Term) ->
    maps:fold(fun(K, V, Acc) -> Acc#{key(K) => to_json(V)} end, #{}, Term);
to_json(Term) when is_list(Term) ->
    case io_lib:printable_unicode_list(Term) andalso Term =/= [] of
        true -> unicode:characters_to_binary(Term);
        false -> [to_json(T) || T <- Term]
    end;
to_json(true) -> true;
to_json(false) -> false;
to_json(null) -> null;
to_json(undefined) -> null;
to_json(Term) when is_atom(Term) -> atom_to_binary(Term, utf8);
to_json(Term) when is_integer(Term); is_float(Term) -> Term;
to_json(Term) when is_binary(Term) ->
    case unicode:characters_to_binary(Term) of
        Bin when is_binary(Bin) -> Bin;
        _ -> format(Term)
    end;
to_json(Term) ->
    format(Term).

key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_binary(K) -> K;
key(K) -> format(K).

format(Term) ->
    iolist_to_binary(io_lib:format("~0tp", [Term])).
