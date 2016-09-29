-module(prop_gisla).
-include_lib("proper/include/proper.hrl").
-include_lib("gisla/include/gisla.hrl").

-compile([export_all]).

gen_atom() -> non_empty(atom()).

gen_sfunc() ->
    ?LET(F, gen_atom(), {gisla:new_sfunc(fun(S) -> [ F | S ] end),
                         gisla:new_sfunc(fun(R) -> R -- [F] end)}).

gen_stage() ->
    ?LET({N, {F, R}}, {gen_atom(), gen_sfunc()}, gisla:new_stage(N, F, R)).

gen_flow() ->
    ?LET({N, P}, {gen_atom(), non_empty(list(gen_stage()))}, gisla:new_flow(N, P)).

prop_forward_ok() ->
    ?FORALL(Flow, gen_flow(), test_flow(Flow)).

test_flow(F = #flow{ pipeline = P }) ->
    L = length(P),
    {Result, _Final, State} = gisla:execute(F, []),
    Result == ok andalso L == length(State).
