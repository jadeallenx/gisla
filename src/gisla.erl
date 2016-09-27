%% gisla
%%
%% Copyright (C) 2016 by Mark Allen.
%%
%% You may only use this software in accordance with the terms of the MIT
%% license in the LICENSE file.

-module(gisla).
-include("gisla.hrl").

-include_lib("hut/include/hut.hrl").

-export([
     new_flow/0,
     new_flow/2,
     name_flow/2,
     describe_flow/1,
     new_stage/0,
     new_stage/3,
     delete_stage/2,
     add_stage/2,
     new_sfunc/0,
     new_sfunc/1,
     new_sfunc/2,
     update_sfunc_timeout/2,
     execute/2
]).

%% Flows

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

name_flow(Name, Flow = #flow{}) ->
    true = is_valid_name(Name),
    Flow#flow{ name = Name }.

describe_flow(#flow{ name = N, pipeline = P }) ->
    {N, [ S#stage.name || S <- P ]}.

%% Stages

new_stage() ->
    #stage{}.

new_stage(Name, F = #sfunc{}, R = #sfunc{}) ->
    true = is_valid_name(Name),
    true = validate_stage_func(F),
    true = validate_stage_func(R),
    #stage{ name = Name, forward = F, rollback = R };
new_stage(Name, F, R) ->
    new_stage(Name, new_sfunc(F), new_sfunc(R)).

add_stage(E = #stage{}, Flow = #flow{ pipeline = P }) ->
    true = validate_stage(E),
    Flow#flow{ pipeline = P ++ [E] }.

delete_stage(#stage{name = N}, F = #flow{}) ->
   delete_stage(N, F);
delete_stage(Name, Flow = #flow{ pipeline = P }) ->
    true = is_valid_name(Name),
    NewPipeline = lists:keydelete(Name, #stage.name, P),
    Flow#flow{ pipeline = NewPipeline }.

%% sfunc

new_sfunc() ->
    #sfunc{}.

new_sfunc(F) ->
   new_sfunc(F, 5000).

new_sfunc(F, Timeout) ->
   true = validate_function(F),
   #sfunc{ f = F, timeout = Timeout }.

update_sfunc_timeout(T, S = #sfunc{}) when is_integer(T) 
                                           andalso T >= 0 ->
   S#sfunc{ timeout = T }.

%% execute

execute(F = #flow{ name = N, pipeline = P }, State) ->
    ?log(info, "Starting flow ~p", [N]),
    do_pipeline(P, F, State).

%% Private functions

%% XXX need to mark stage state - defined, running, complete, rollback, failed
do_pipeline([], F = #flow{ direction = forward }, State) -> 
    {ok, F, purge_meta_keys(State)};
do_pipeline([], F = #flow{ direction = rollback }, State) -> 
    {rollback, F, purge_meta_keys(State)};
do_pipeline([H|T], F = #flow{ direction = D }, State) ->
    {Tail, NewFlow, NewState} = case execute_stage_function(H, State, D) of
    {ok, NewStage0, State0} ->
        {T, update_flow(F, NewStage0), State0};
    {failed, NewStage1, State1} ->
        case D of
        forward ->
            UpdatedFlow = update_flow(F#flow{ direction = rollback}, NewStage1),
            ReversePipeline = lists:reverse(UpdatedFlow#flow.pipeline),
            Name = H#stage.name,
            NewTail = lists:dropwhile( fun(E) -> E#stage.name /= Name end, ReversePipeline ),
            {NewTail, UpdatedFlow, State1};
        rollback ->
            ?log(error, "Error during rollback. Giving up."),
            error(failed_rollback)
        end
    end,
    do_pipeline(Tail, NewFlow, NewState).

update_flow(F = #flow{ pipeline = P }, Stage = #stage{ name = N }) ->
    NewPipeline = lists:keyreplace(N, #stage.name, P, Stage),
    F#flow{ pipeline = NewPipeline }.

execute_stage_function(S = #stage{ name = N, rollback = R }, State, rollback) ->
    update_stage(S, rollback, do_stage(N, R, State));
execute_stage_function(S = #stage{ name = N, forward = F }, State, forward) ->
    update_stage(S, forward, do_stage(N, F, State)).

update_stage(Stage, rollback, {Reply, Func, State}) ->
    {Reply, Stage#stage{ rollback = Func }, State};
update_stage(Stage, forward, {Reply, Func, State}) ->
    {Reply, Stage#stage{ forward = Func }, State}.

do_stage(Name, Func, State) ->
    {F, Timeout} = make_closure(Func, self(), State),
    {Pid, Mref} = spawn_monitor(fun() -> F() end),
    ?log(info, "Started pid ~p to execute stage ~p", [Pid, Name]),
    handle_loop_return(loop(Mref, Pid, Timeout, State, false), Func).

handle_loop_return({ok, Reason, State}, Func) ->
    {ok, Func#sfunc{ state = complete, result = success, reason = Reason }, State};
handle_loop_return({failed, Reason, State}, Func) ->
    {failed, Func#sfunc{ state = complete, result = failed, reason = Reason }, State}.

loop(Mref, Pid, Timeout, State, NormalExitRcvd) ->
    receive
        race_conditions_are_bad_mmmkay ->
            ?log(debug, "Normal exit received, with no failure messages out of order."),
            {ok, normal, State};
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
            {failed, Reason, State};
        Msg ->
            ?log(warning, "Some rando message just showed up! ~p Ignoring.", [Msg]),
            loop(Mref, Pid, Timeout, State, NormalExitRcvd)
   after Timeout ->
        case NormalExitRcvd of
            false ->
                ?log(error, "Pid ~p timed out after ~p milliseconds", [Pid, Timeout]),
                {failed, timeout, State};
            true ->
                ?log(info, "We exited cleanly but timed out... *NOT* treating as a failure.", []),
                {ok, timeout, State}
        end
   end.

make_closure(#sfunc{ f = {M, F, A}, timeout = T }, ReplyPid, State) ->
   {fun() -> ReplyPid ! {complete, M:F(A ++ inject_meta_state({gisla_reply, ReplyPid}, State))} end, T};

make_closure(#sfunc{ f = F, timeout = T }, ReplyPid, State) when is_function(F) ->
   {fun() -> ReplyPid ! {complete, F(inject_meta_state({gisla_reply, ReplyPid}, State))} end, T}.

inject_meta_state(Meta = {K, _V}, State) ->
    case lists:keyfind(K, 1, State) of
       false ->
            [ Meta | State ];
       _ -> State
    end.

purge_meta_keys(State) ->
    lists:foldl(fun remove_meta/2, State, [gisla_reply]).

remove_meta(K, State) ->
    lists:keydelete(K, 1, State).

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

new_sfunc_test_() ->
   F = fun(E) -> E end,
   S = #sfunc{},
   S1 = S#sfunc{ f = F },
   S2 = S#sfunc{ f = F, timeout = 100 },
   [
     ?_assertEqual(S1, new_sfunc(F)),
     ?_assertEqual(S2, update_sfunc_timeout(100, new_sfunc(F)))
   ].

new_stage_test_() ->
   F = fun(E) -> E end,
   MFA = {?MODULE, test_function, []},
   SF = new_sfunc(F),
   SMFA = new_sfunc(MFA),
   [
      ?_assertEqual(#stage{ name = test, forward = SF, rollback = SMFA }, new_stage(test, F, MFA)),
      ?_assertEqual(#stage{ name = test, forward = SMFA,  rollback = SF }, new_stage(test, MFA, F))
   ].

validate_pipeline_test_() ->
    F = new_sfunc(fun(E) -> E, ok end),
    G = new_sfunc({?MODULE, test_function, [test]}),
    TestStage1 = #stage{ name = test1, forward = F, rollback = G },
    TestStage2 = #stage{ name = test2, forward = G, rollback = F },
    TestPipeline = [ TestStage1, TestStage2 ],
    BadPipeline = #flow{ name = foo, pipeline = kevin },
    [
      ?_assert(validate_pipeline(TestPipeline)),
      ?_assertEqual(false, validate_pipeline(BadPipeline))
    ].

new_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStage1 = new_stage(test, F, G),
   TestStage2 = new_stage(bar, F, G),
   [
      ?_assertEqual(#flow{}, new_flow()),
      ?_assertEqual(#stage{}, new_stage()),
      ?_assertEqual(#sfunc{}, new_sfunc()),
      ?_assertEqual(#flow{ name = test }, name_flow(test, new_flow())),
      ?_assertEqual(#flow{ name = baz, pipeline = [ TestStage1, TestStage2 ] }, new_flow(baz, [ TestStage1, TestStage2 ]))
   ].

mod_pipeline_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStage1 = new_stage(test, F, G),
   TestStage2 = new_stage(bar, F, G),

   [
      ?_assertEqual(#flow{ pipeline = [ TestStage1 ] }, add_stage(TestStage1, new_flow())),
      ?_assertEqual(#flow{ name = foo, pipeline = [ TestStage2 ] }, delete_stage(test, new_flow(foo, [ TestStage1, TestStage2 ])))
   ].

describe_flow_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStage1 = new_stage(stage1, F, G),
   TestStage2 = new_stage(stage2, F, G),
   TestFlow = new_flow(test, [ TestStage1, TestStage2 ]),
   [
      ?_assertEqual({ test, [stage1, stage2] }, describe_flow(TestFlow))
   ].

store_purge_meta_keys_test() ->
   Key = gisla_reply,
   State = [{Key, self()}],

   ?assertEqual([], purge_meta_keys(State)).

stage1(State) -> [ {stage1, true} | State ].
stage1_rollback(State) -> lists:keydelete(stage1, 1, State).

stage2(State) -> [ {stage2, true} | State ].
stage2_rollback(State) -> lists:keydelete(stage2, 1, State).

blowup(_State) -> error(blowup).
blowup_rollback(State) -> [ {blowup_rollback, true} | State ].

execute_forward_test() ->
   S1 = new_stage(stage1, fun stage1/1, fun stage1_rollback/1),
   S2 = new_stage(stage2, fun stage2/1, fun stage2_rollback/1),
   Flow = new_flow(test, [ S1, S2 ]),
   SortedState = lists:sort([{stage1, true}, {stage2, true}]),
   {ok, F, State} = execute(Flow, []),
   ?assertEqual(SortedState, lists:sort(State)),
   ?assertEqual([{complete, success}, {complete, success}],
                [{S#stage.forward#sfunc.state, S#stage.forward#sfunc.result}
                  || S <- F#flow.pipeline]),
   ?assertEqual([{ready, undefined}, {ready, undefined}],
                [{S#stage.rollback#sfunc.state, S#stage.rollback#sfunc.result}
                  || S <- F#flow.pipeline]).

execute_rollback_test() ->
   S1 = new_stage(stage1, fun stage1/1, fun stage1_rollback/1),
   S2 = new_stage(stage2, fun stage2/1, fun stage2_rollback/1),
   RollbackStage = new_stage(rollstage, fun blowup/1, fun blowup_rollback/1),
   Flow = new_flow(rolltest, [ S1, RollbackStage, S2 ]),
   {rollback, F, State} = execute(Flow, []),
   ?assertEqual([{blowup_rollback, true}], State),
   ?assertEqual([{complete, success}, {complete, failed}, {ready, undefined}],
                [{S#stage.forward#sfunc.state, S#stage.forward#sfunc.result}
                  || S <- F#flow.pipeline]),
   ?assertEqual([{complete, success}, {complete, success}, {ready, undefined}],
                [{S#stage.rollback#sfunc.state, S#stage.rollback#sfunc.result}
                  || S <- F#flow.pipeline]).

long_function(State) -> timer:sleep(10000), State.
long_function_rollback(State) -> [ {long_function_rollback, true} | State ].

execute_timeout_test() ->
   S1 = new_stage(stage1, fun stage1/1, fun stage1_rollback/1),
   S2 = new_stage(stage2, fun stage2/1, fun stage2_rollback/1),
   TimeoutSfunc = new_sfunc(fun long_function/1, 10), % timeout after 10 milliseconds
   TimeoutRollback = new_sfunc(fun long_function_rollback/1),
   TimeoutStage = new_stage( toutstage, TimeoutSfunc, TimeoutRollback ),
   Flow = new_flow( timeout, [ S1, TimeoutStage, S2 ] ),
   {rollback, _F, State} = execute(Flow, []),
   ?assertEqual([{long_function_rollback, true}], State).

checkpoint_function(State) ->
   {gisla_reply, Reply} = lists:keyfind(gisla_reply, 1, State),
   Reply ! {checkpoint, [{checkpoint_test, true}|State]},
   error(smod_was_here).
checkpoint_rollback(State) -> [{checkpoint_rollback, true}|State].

checkpoint_test() ->
   S1 = new_stage(stage1, fun stage1/1, fun stage1_rollback/1),
   S2 = new_stage(stage2, fun stage2/1, fun stage2_rollback/1),
   CheckpointStage = new_stage( chkstage, fun checkpoint_function/1, fun checkpoint_rollback/1 ),
   Flow = new_flow( chkflow, [ S1, CheckpointStage, S2 ] ),
   {rollback, _F, State} = execute(Flow, []),
   ?assertEqual([{checkpoint_rollback, true}, {checkpoint_test, true}], State).

-endif.
