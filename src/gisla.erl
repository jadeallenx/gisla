%% gisla
%%
%% Copyright (C) 2016 by Mark Allen.
%%
%% You may only use this software in accordance with the terms of the MIT
%% license in the LICENSE file.

-module(gisla).
-include("gisla.hrl").

-define(log(X,Y,Z), ok).
-define(log(X,Y), ok).
%-include_lib("hut/include/hut.hrl").

-export([
     new_flow/0,
     new_flow/2,
     new_stage/0,
     new_sfunc/0,
     name_flow/2,
     make_stage/3,
     make_sfunc/1,
     make_sfunc/2,
     add_stage/2,
     delete_stage/2,
     describe_flow/1,
     execute/2
]).

new_flow() ->
    #flow{}.

new_flow(Name, Flow) when is_list(Flow)
                          andalso ( is_atom(Name)
                          orelse is_binary(Name)
                          orelse is_list(Name) ) ->
    true = is_valid_name(Name),
    true = validate_pipeline(Flow),
    #flow{
       name = Name,
       pipeline = Flow
    }.

new_stage() ->
    #stage{}.

new_sfunc() ->
    #sfunc{}.

name_flow(Name, Flow = #flow{}) ->
    true = is_valid_name(Name),
    Flow#flow{ name = Name }.

make_stage(Name, F, R) when ( is_function(F) orelse is_tuple(F) ) 
                    andalso ( is_function(R) orelse is_tuple(R) ) ->
    make_stage(Name, make_sfunc(F), make_sfunc(R));

make_stage(Name, F, R) ->
    true = is_valid_name(Name),
    true = validate_stage_func(F),
    true = validate_stage_func(R),
    #stage{ name = Name, forward = F, rollback = R }.

make_sfunc(F) ->
   make_sfunc(F, 5000).

make_sfunc(F, Timeout) ->
   true = validate_function(F),
   #sfunc{ f = F, timeout = Timeout }.



add_stage(E = #stage{}, Flow = #flow{ pipeline = P }) ->
    true = validate_stage(E),
    Flow#flow{ pipeline = P ++ [E] }.

delete_stage(#stage{name = N}, F = #flow{}) ->
   delete_stage(N, F);
delete_stage(Name, Flow = #flow{ pipeline = P }) ->
    true = is_valid_name(Name),
    NewPipeline = lists:keydelete(Name, #stage.name, P),
    Flow#flow{ pipeline = NewPipeline }.

describe_flow(#flow{ name = N, pipeline = P }) ->
    {N, [ S#stage.name || S <- P ]}.



execute(F = #flow{ name = N, pipeline = P }, State) ->
    ?log(info, "Starting flow ~p", [N]),
    do_pipeline(P, F, State).

%% Private functions

%% XXX need to mark stage state - defined, running, complete, rollback, failed
do_pipeline([], Flow, State) -> Flow#flow{ state = State };
do_pipeline([H|T], F = #flow{ pipeline = P, direction = D }, State) ->
    {Tail, NewFlow, NewState} = case execute_stage_function(H, State, D) of
    {ok, State0} ->
        {T, F, State0};
    {failed, State1} ->
        case D of
        forward ->
            Name = H#stage.name,
            ReversePipeline = lists:reverse(P),
            NewTail = lists:dropwhile( fun(E) -> E#stage.name /= Name end, ReversePipeline ),
            {NewTail, F#flow{ direction = rollback }, State1};
        rollback ->
            ?log(error, "Error during rollback. Giving up."),
            error(failed_rollback)
        end
    end,
    do_pipeline(Tail, NewFlow, NewState).

execute_stage_function(#stage{ name = N, rollback = R }, State, rollback) ->
    do_stage(N, R, State);
execute_stage_function(#stage{ name = N, forward = F }, State, forward) ->
    do_stage(N, F, State).

do_stage(Name, Func, State) ->
    {F, Timeout} = make_closure(Func, self(), State),
    {Mref, Pid} = spawn_monitor(fun() -> F() end),
    ?log(info, "Started pid ~p to execute stage ~p", [Pid, Name]),
    loop(Mref, Pid, Timeout, State, false).

loop(Mref, Pid, Timeout, State, NormalExitRcvd) ->
    receive
        race_conditions_are_bad_mmmkay ->
            ?log(debug, "Normal exit received, with no failure messages out of order."),
            {ok, State};
        {complete, NewState} ->
            ?log(info, "Stage sent complete..."),
            demonitor(Mref, [flush]), %% prevent us from getting any spurious failures and clean out our mailbox
            self() ! race_conditions_are_bad_mmmkay,
            loop(Mref, Pid, Timeout, NewState, true);
        {checkpoint, NewState} ->
            ?log(debug, "Got a checkpoint state"),
            loop(Mref, Pid, Timeout, NewState, NormalExitRcvd);
        {'DOWN', Mref, process, Pid, normal} ->
            %% so we exited fine but didn't get a results reply yet... let's loop around maybe it will be
            %% the next message in our mailbox.
            loop(Mref, Pid, Timeout, State, true);
        {'DOWN', Mref, process, Pid, Reason} ->
            %% We crashed for some reason
            ?log(error, "Pid ~p failed because ~p", [Pid, Reason]),
            {failed, State};
        Msg ->
            ?log(warning, "Some rando message just showed up! ~p Ignoring.", [Msg]),
            loop(Mref, Pid, Timeout, State, NormalExitRcvd)
   after Timeout ->
        case NormalExitRcvd of
            false ->
                ?log(error, "Pid ~p timed out after ~p milliseconds", [Pid, Timeout]),
                {failed, State};
            true ->
                ?log(info, "We exited cleanly but timed out... *NOT* treating as a failure.", []),
                {ok, State}
        end
   end.

make_closure(#sfunc{ f = {M, F, A}, timeout = T }, ReplyPid, State) ->
   {fun() -> ReplyPid ! {complete, M:F(A ++ inject_meta_state({gisla_reply, ReplyPid}, State))} end, T};

make_closure(#sfunc{ f = F, timeout = T }, ReplyPid, State) when is_function(F) ->
   {fun() -> ReplyPid ! {complete, F(inject_meta_state({gisla_reply, ReplyPid}, State))} end, T}.

inject_meta_state(Meta, State) ->
    lists:flatten([ Meta | State ]).

validate_pipeline(Pipeline) when is_list(Pipeline) ->
    lists:all(fun validate_stage/1, Pipeline);
validate_pipeline(_) -> false.

validate_stage(#stage{ name = N, forward = F, rollback = R }) ->
    is_valid_name(N)
    andalso validate_stage_func(F)
    andalso validate_stage_func(R);
validate_stage(_) -> false.

validate_stage_func( #sfunc{ f = F, timeout = T } ) ->
    validate_function(F) andalso is_integer(T) andalso T >= 0;
validate_stage_func(_) -> false.

validate_function(E) when is_function(E) -> true;
validate_function({M, F, A}) when is_atom(M)
                                             andalso is_atom(F)
                                             andalso is_list(A) -> true;
validate_function(_) -> false.

is_valid_name(N) ->
    is_atom(N) orelse is_binary(N) orelse is_list(N).

%% unit tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-compile([export_all]).

test_function(S) -> S.

valid_name_test_() ->
    [
      ?_assert(is_valid_name("moogle")),
      ?_assert(is_valid_name(<<"froogle">>)),
      ?_assert(is_valid_name(good)),
      ?_assertEqual(false, is_valid_name(1))
    ].

validate_function_test_() ->
    F = fun(E) -> E, ok end,
    [
      ?_assert(validate_function(fun() -> ok end)),
      ?_assert(validate_function({?MODULE, test_function, [test]})),
      ?_assert(validate_function(F)),
      ?_assertEqual(false, validate_function(<<"function">>)),
      ?_assertEqual(false, validate_function(decepticons)),
      ?_assertEqual(false, validate_function("function")),
      ?_assertEqual(false, validate_function(42))
    ].

validate_pipeline_test_() ->
    F = fun(E) -> E, ok end,
    G = {?MODULE, test_function, [test]},
    TestStage1 = #stage{ name = test1, forward = F, rollback = G },
    TestStage2 = #stage{ name = test2, forward = G, rollback = F },
    TestPipeline = [ TestStage1, TestStage2 ],
    BadPipeline = #flow{ name = foo, pipeline = kevin },
    [
      ?_assert(validate_pipeline(TestPipeline)),
      ?_assertEqual(false, validate_pipeline(BadPipeline))
    ].

make_stage_test_() ->
   F = fun(E) -> E end,
   MFA = {?MODULE, test_function, []},

   [
      ?_assertEqual(#stage{ name = test, forward = #sfunc{}, rollback = #sfunc{} }, make_stage(test, F, MFA)),
      ?_assertEqual(#stage{ name = test, forward = #sfunc{},  rollback = #sfunc{} }, make_stage(test, MFA, F))
   ].

new_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStage1 = make_stage(test, F, G),
   TestStage2 = make_stage(bar, F, G),
   TestFlow = new_flow(baz, [TestStage1, TestStage2]),
   [
      ?_assertEqual(#flow{}, new_flow()),
      ?_assertEqual(#stage{}, new_stage()),
      ?_assertEqual(#flow{ name = test }, name_flow(test, new_flow())),
      ?_assertEqual(#flow{ name = baz, pipeline = [ TestStage1, TestStage2 ] }, new_flow(baz, [ TestStage1, TestStage2 ]))
   ].


mod_pipeline_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStage1 = make_stage(test, F, G),
   TestStage2 = make_stage(bar, F, G),

   [
      ?_assertEqual(#flow{ pipeline = [ TestStage1 ] }, add_stage(TestStage1, new_flow())),
      ?_assertEqual(#flow{ name = foo, pipeline = [ TestStage2 ] }, delete_stage(test, new_flow(foo, [ TestStage1, TestStage2 ])))
   ].

describe_flow_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStage1 = make_stage(stage1, F, G),
   TestStage2 = make_stage(stage2, F, G),
   TestFlow = new_flow(test, [ TestStage1, TestStage2 ]),
   [
      ?_assertEqual({ test, [stage1, stage2] }, describe_flow(TestFlow))
   ].



-endif.
