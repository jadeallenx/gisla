-module(prop_gisla).
-include_lib("proper/include/proper.hrl").
-include_lib("gisla/include/gisla.hrl").

-compile([export_all]).

gen_atom() -> non_empty(atom()).

gen_operation() ->
    ?LET(F, gen_atom(), {gisla:new_operation(fun(S) -> [ F | S ] end),
                         gisla:new_operation(fun(R) -> R -- [F] end)}).

gen_step() ->
    ?LET({N, {F, R}}, {gen_atom(), gen_operation()}, gisla:new_step(N, F, R)).

gen_transaction() ->
    ?LET({N, S}, {gen_atom(), non_empty(list(gen_step()))}, gisla:new_transaction(N, S)).

prop_forward_ok() ->
    ?FORALL(T, gen_transaction(), test_transaction(T)).

test_transaction(T = #transaction{ steps = S }) ->
    L = length(S),
    {Result, _Final, State} = gisla:execute(T, []),
    Result == ok andalso L == length(State).
