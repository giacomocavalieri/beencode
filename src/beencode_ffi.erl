-module(beencode_ffi).
-export([compare/2]).

compare(X, X) ->
    eq;
compare(X, Y) ->
    case X > Y of
        true -> gt;
        false -> lt
    end.
