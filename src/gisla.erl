%% gisla
%%
%% Copyright (C) 2016-2017 by Mark Allen.
%%
%% You may only use this software in accordance with the terms of the MIT
%% license in the LICENSE file.

-module(gisla).
-include("gisla.hrl").

-include_lib("hut/include/hut.hrl").

-export([
     new_transaction/0,
     new_transaction/2,
     name_transaction/2,
     describe_transaction/1,
     new_step/0,
     new_step/3,
     delete_step/2,
     add_step/2,
     new_operation/0,
     new_operation/1,
     new_operation/2,
     update_operation_timeout/2,
     update_function/2,
     checkpoint/1,
     execute/2
]).

%% transactions

%% @doc Creates a new empty `#transaction{}' record.
-spec new_transaction() -> #transaction{}.
new_transaction() ->
    #transaction{}.

%% @doc Given a valid name (atom, binary string or string), and a
%% ordered list of `#step{}' records, return a new `#transaction{}'.
-spec new_transaction( Name :: gisla_name(), Steps :: steps() ) -> #transaction{}.
new_transaction(Name, Steps) ->
    true = is_valid_name(Name),
    true = validate_steps(Steps),
    #transaction{
       name = Name,
       steps = Steps
    }.

%% @doc Rename a `#transaction{}' record to the given name.
-spec name_transaction ( Name :: gisla_name(), T :: #transaction{} ) -> #transaction{}.
name_transaction(Name, T = #transaction{}) ->
    true = is_valid_name(Name),
    T#transaction{ name = Name }.

%% @doc Given a `#transaction{}' record, output its name and the name of
%% each step in execution order.
-spec describe_transaction( T :: #transaction{} ) -> { gisla_name(), [ gisla_name() ] }.
describe_transaction(#transaction{ name = N, steps = S }) ->
    {N, [ Step#step.name || Step <- S ]}.

%% steps

%% @doc Return an empty `#step{}' record.
-spec new_step() -> #step{}.
new_step() ->
    #step{ ref = make_ref() }.

%% @doc Given a valid name, and either two step functions (`#operation{}') or
%% functions or MFA tuples, return a populated `#step{}' record.
-spec new_step(      Name :: gisla_name(),
                  Forward :: operation_fun() | #operation{},
                 Rollback :: operation_fun() | #operation{} ) -> #step{}.
new_step(Name, F = #operation{}, R = #operation{}) ->
    true = is_valid_name(Name),
    true = validate_operation_fun(F),
    true = validate_operation_fun(R),
    #step{ ref = make_ref(), name = Name, forward = F, rollback = R };
new_step(Name, F, R) ->
    true = is_valid_name(Name),
    Forward = new_operation(F),
    Rollback = new_operation(R),
    #step{ ref = make_ref(), name = Name, forward = Forward, rollback = Rollback }.

%% @doc Add the given step to a transaction's steps.
-spec add_step( Step :: #step{}, T :: #transaction{} ) -> #transaction{}.
add_step(E = #step{}, T = #transaction{ steps = P }) ->
    true = validate_step(E),
    T#transaction{ steps = P ++ [E] }.

%% @doc Remove the step having the given name from a transaction's steps.
-spec delete_step( Name :: gisla_name() | #step{}, T :: #transaction{} ) -> #transaction{}.
delete_step(#step{name = N}, F = #transaction{}) ->
   delete_step(N, F);
delete_step(Name, T = #transaction{ steps = P }) ->
    true = is_valid_name(Name),
    NewSteps = lists:keydelete(Name, #step.name, P),
    T#transaction{ steps = NewSteps }.

%% operation

%% @doc Return a new empty `#operation{}' record.
-spec new_operation() -> #operation{}.
new_operation() ->
    #operation{}.

%% @doc Wrap the given function in a `#operation{}' record. It will
%% get the default timeout of 5000 milliseconds.
-spec new_operation( Function :: function() | operation_fun() ) -> #operation{}.
new_operation(F) when is_function(F) ->
   new_operation({F, []});
new_operation(Fun = {_M, _F, _A}) ->
   new_operation(Fun, 5000);
new_operation(Fun = {_F, _A}) ->
   new_operation(Fun, 5000).

%% @doc Wrap the given function and use the given timeout value
%% instead of the default value. The timeout value must be
%% greater than zero (0).
-spec new_operation( Function :: function() | operation_fun(), Timeout :: pos_integer() ) -> #operation{}.
new_operation(F, Timeout) when is_integer(Timeout) andalso Timeout > 0 ->
   true = validate_function(F),
   #operation{ f = F, timeout = Timeout }.

%% @doc Replace the timeout value in the `#operation{}' record with the given
%% value.
-spec update_operation_timeout( Timeout :: pos_integer(), StepFunction :: #operation{} ) -> #operation{}.
update_operation_timeout(T, S = #operation{}) when is_integer(T) andalso T > 0 ->
   S#operation{ timeout = T }.

%% @doc Replace a function in an `#operation{}' record with the given
%% function.
update_function(F, S = #operation{}) when is_function(F) ->
   update_function({F, []}, S);
update_function(Fun = {_M,_F,_A}, S = #operation{}) ->
   true = validate_function(Fun),
   S#operation{ f = Fun };
update_function(Fun = {_F, _A}, S = #operation{}) ->
   true = validate_function(Fun),
   S#operation{ f = Fun }.

%% execute

%% @doc Execute the steps in the given transaction in order, passing the state
%% between steps as an accumulator using the rollback functions if a forward
%% operation fails or times out.
-spec execute( T :: #transaction{}, State :: term() ) -> {'ok'|'rollback', FinalT :: #transaction{}, FinalState :: term()}.
execute(F = #transaction{ name = N, steps = P }, State) ->
    ?log(info, "Starting transaction ~p", [N]),
    do_steps(P, F, State).

-spec checkpoint( State :: [ term() ] ) -> ok.
%% @doc Return an intermediate state during an operation. Automatically
%% removes gisla injected metadata before it sends the data.
checkpoint(State) ->
    ReplyPid = get_reply_pid(State),
    ReplyPid ! {checkpoint, purge_meta_keys(State)},
    ok.

%% Private functions
%% @private

do_steps([], T = #transaction{ direction = forward }, State) ->
    {ok, T, purge_meta_keys(State)};
do_steps([], T = #transaction{ direction = rollback }, State) ->
    {rollback, T, purge_meta_keys(State)};
do_steps([H|T], Txn = #transaction{ direction = D }, State) ->
    {Tail, NewT, NewState} = case execute_operation(H, State, D) of
    {ok, NewStep0, State0} ->
        {T, update_transaction(Txn, NewStep0), State0};
    {failed, NewStep1, State1} ->
        case D of
        forward ->
            UpdatedTxn = update_transaction(Txn#transaction{ direction = rollback}, NewStep1),
            ReverseSteps = lists:reverse(UpdatedTxn#transaction.steps),
            Ref = H#step.ref,
            NewTail = lists:dropwhile( fun(E) -> E#step.ref /= Ref end, ReverseSteps ),
            {NewTail, UpdatedTxn, State1};
        rollback ->
            ?log(error, "Error during rollback. Giving up."),
            error(failed_rollback)
        end
    end,
    do_steps(Tail, NewT, NewState).

update_transaction(T = #transaction{ steps = S }, Step = #step{ ref = Ref }) ->
    NewSteps = lists:keyreplace(Ref, #step.ref, S, Step),
    T#transaction{ steps = NewSteps }.

execute_operation(S = #step{ name = N, rollback = R }, State, rollback) ->
    update_step(S, rollback, do_step(N, R, State));
execute_operation(S = #step{ name = N, forward = F }, State, forward) ->
    update_step(S, forward, do_step(N, F, State)).

update_step(Step, rollback, {Reply, Func, State}) ->
    {Reply, Step#step{ rollback = Func }, State};
update_step(Step, forward, {Reply, Func, State}) ->
    {Reply, Step#step{ forward = Func }, State}.

do_step(Name, Func, State) ->
    {F, Timeout} = make_closure(Func, self(), State),
    {Pid, Mref} = spawn_monitor(fun() -> F() end),
    ?log(info, "Started pid ~p to execute step ~p", [Pid, Name]),
    TRef = erlang:start_timer(Timeout, self(), timeout),
    handle_loop_return(loop(Mref, Pid, TRef, State, false), Func).

handle_loop_return({ok, Reason, State}, Func) ->
    {ok, Func#operation{ state = complete, result = success, reason = Reason }, State};
handle_loop_return({failed, Reason, State}, Func) ->
    {failed, Func#operation{ state = complete, result = failed, reason = Reason }, State}.

loop(Mref, Pid, TRef, State, NormalExitRcvd) ->
    receive
        race_conditions_are_bad_mmmkay ->
            ?log(debug, "Normal exit received, with no failure messages out of order."),
            {ok, normal, State};
        {complete, NewState} ->
            ?log(info, "Step sent complete..."),
            demonitor(Mref, [flush]), %% prevent us from getting any spurious failures and clean out our mailbox
            self() ! race_conditions_are_bad_mmmkay,
            erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            loop(Mref, Pid, undef, NewState, true);
        {checkpoint, NewState} ->
            ?log(debug, "Got a checkpoint state"),
            loop(Mref, Pid, TRef, NewState, NormalExitRcvd);
        {'DOWN', Mref, process, Pid, normal} ->
            %% so we exited fine but didn't get a results reply yet... let's loop around maybe it will be
            %% the next message in our mailbox.
            loop(Mref, Pid, TRef, State, true);
        {'DOWN', Mref, process, Pid, Reason} ->
            %% We crashed for some reason
            ?log(error, "Pid ~p failed because ~p", [Pid, Reason]),
            erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            {failed, Reason, State};
        {timeout, TRef, _} ->
            case NormalExitRcvd of
                false ->
                    ?log(error, "Pid ~p timed out", [Pid]),
                    {failed, timeout, State};
                true ->
                    ?log(info, "We exited cleanly but timed out... *NOT* treating as a failure.", []),
                    {ok, timeout, State}
            end;
        Msg ->
            ?log(warning, "Some rando message just showed up! ~p Ignoring.", [Msg]),
            loop(Mref, Pid, TRef, State, NormalExitRcvd)
   end.

make_closure(#operation{ f = {M, F, A}, timeout = T }, ReplyPid, State) ->
   {fun() -> ReplyPid ! {complete, apply(M, F, A
                          ++ [maybe_inject_meta({gisla_reply, ReplyPid}, State)])}
    end, T};

make_closure(#operation{ f = {F, A}, timeout = T }, ReplyPid, State) ->
   {fun() -> ReplyPid ! {complete, apply(F, A
                          ++ [maybe_inject_meta({gisla_reply, ReplyPid}, State)])}
    end, T}.

maybe_inject_meta(Meta = {K, _V}, State) ->
    case lists:keyfind(K, 1, State) of
       false ->
            [ Meta | State ];
       _ -> State
    end.

get_reply_pid(State) ->
    {gisla_reply, Pid} = lists:keyfind(gisla_reply, 1, State),
    Pid.

purge_meta_keys(State) ->
    lists:foldl(fun remove_meta/2, State, [gisla_reply]).

remove_meta(K, State) ->
    lists:keydelete(K, 1, State).

validate_steps(Steps) when is_list(Steps) ->
    lists:all(fun validate_step/1, Steps);
validate_steps(_) -> false.

validate_step(#step{ ref = Ref, name = N, forward = F, rollback = R }) ->
    is_reference(Ref)
    andalso is_valid_name(N)
    andalso validate_operation_fun(F)
    andalso validate_operation_fun(R);
validate_step(_) -> false.

validate_operation_fun( #operation{ f = F, timeout = T } ) ->
    validate_function(F) andalso is_integer(T) andalso T >= 0;
validate_operation_fun(_) -> false.

validate_function({F, A}) when is_list(A) -> true andalso is_function(F, length(A) + 1);
validate_function({M, F, A}) when is_atom(M)
                                  andalso is_atom(F)
                                  andalso is_list(A) ->
    case code:ensure_loaded(M) of
        {module, M} ->
            erlang:function_exported(M, F, length(A) + 1);
        _ ->
            false
    end;
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
      ?_assert(validate_function({?MODULE, test_function, []})),
      ?_assert(validate_function({fun(E) -> E end, []})),
      ?_assert(validate_function({F, []})),
      ?_assertEqual(false, validate_function({?MODULE, test_function, [test]})),
      ?_assertEqual(false, validate_function({fun() -> ok end, []})),
      ?_assertEqual(false, validate_function(<<"function">>)),
      ?_assertEqual(false, validate_function(decepticons)),
      ?_assertEqual(false, validate_function("function")),
      ?_assertEqual(false, validate_function(42)),
      ?_assertEqual(false, validate_function({F, [foo, bar]})),
      ?_assertEqual(false, validate_function({?MODULE, test_function, [test1, test2]})),
      ?_assertEqual(false, validate_function({fake_module, test_function, [test]}))
    ].

new_operation_test_() ->
   F = fun(E) -> E end,
   S = #operation{},
   S1 = S#operation{ f = {F, []} },
   S2 = S#operation{ f = {F, []}, timeout = 100 },
   [
     ?_assertEqual(S1, new_operation(F)),
     ?_assertEqual(S2, update_operation_timeout(100, new_operation(F)))
   ].

new_step_test_() ->
   F = fun(E) -> E end,
   MFA = {?MODULE, test_function, []},
   SF = new_operation(F),
   SMFA = new_operation(MFA),
   [
      ?_assertMatch(#step{ ref = Ref, name = test, forward = SF, rollback = SMFA } when is_reference(Ref), new_step(test, F, MFA)),
      ?_assertMatch(#step{ ref = Ref, name = test, forward = SMFA,  rollback = SF } when is_reference(Ref), new_step(test, MFA, F))
   ].

validate_steps_test_() ->
    F = new_operation(fun(E) -> E, ok end),
    G = new_operation({?MODULE, test_function, []}),
    TestStep1 = #step{ ref = make_ref(), name = test1, forward = F, rollback = G },
    TestStep2 = #step{ ref = make_ref(), name = test2, forward = G, rollback = F },
    TestSteps = [ TestStep1, TestStep2 ],
    BadSteps = #transaction{ name = foo, steps = kevin },
    [
      ?_assert(validate_steps(TestSteps)),
      ?_assertEqual(false, validate_steps(BadSteps))
    ].

new_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStep1 = new_step(test, F, G),
   TestStep2 = new_step(bar, F, G),
   [
      ?_assertEqual(#transaction{}, new_transaction()),
      ?_assertMatch(#step{ ref = Ref} when is_reference(Ref), new_step()),
      ?_assertEqual(#operation{}, new_operation()),
      ?_assertEqual(#transaction{ name = test }, name_transaction(test, new_transaction())),
      ?_assertEqual(#transaction{ name = baz, steps = [ TestStep1, TestStep2 ] }, new_transaction(baz, [ TestStep1, TestStep2 ]))
   ].

mod_steps_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStep1 = new_step(test, F, G),
   TestStep2 = new_step(bar, F, G),

   [
      ?_assertEqual(#transaction{ steps = [ TestStep1 ] }, add_step(TestStep1, new_transaction())),
      ?_assertEqual(#transaction{ name = foo, steps = [ TestStep2 ] }, delete_step(test, new_transaction(foo, [ TestStep1, TestStep2 ])))
   ].

describe_transaction_test_() ->
   F = fun(E) -> E end,
   G = fun(X) -> X end,
   TestStep1 = new_step(step1, F, G),
   TestStep2 = new_step(step2, F, G),
   TestTxn = new_transaction(test, [ TestStep1, TestStep2 ]),
   [
      ?_assertEqual({ test, [step1, step2] }, describe_transaction(TestTxn))
   ].

store_purge_meta_keys_test() ->
   Key = gisla_reply,
   State = [{Key, self()}],

   ?assertEqual([], purge_meta_keys(State)).

step1(State) -> [ {step1, true} | State ].
step1_rollback(State) -> lists:keydelete(step1, 1, State).

step2(State) -> [ {step2, true} | State ].
step2_rollback(State) -> lists:keydelete(step2, 1, State).

blowup(_State) -> error(blowup).
blowup_rollback(State) -> [ {blowup_rollback, true} | State ].

execute_forward_test() ->
   S1 = new_step(step1, fun step1/1, fun step1_rollback/1),
   S2 = new_step(step2, fun step2/1, fun step2_rollback/1),
   T = new_transaction(test, [ S1, S2 ]),
   SortedState = lists:sort([{step1, true}, {step2, true}]),
   {ok, F, State} = execute(T, []),
   ?assertEqual(SortedState, lists:sort(State)),
   ?assertEqual([{complete, success}, {complete, success}],
                [{S#step.forward#operation.state, S#step.forward#operation.result}
                  || S <- F#transaction.steps]),
   ?assertEqual([{ready, undefined}, {ready, undefined}],
                [{S#step.rollback#operation.state, S#step.rollback#operation.result}
                  || S <- F#transaction.steps]).

execute_rollback_test() ->
   S1 = new_step(step1, fun step1/1, fun step1_rollback/1),
   S2 = new_step(step2, fun step2/1, fun step2_rollback/1),
   RollbackStep = new_step(rollstep, fun blowup/1, fun blowup_rollback/1),
   T = new_transaction(rolltest, [ S1, RollbackStep, S2 ]),
   {rollback, F, State} = execute(T, []),
   ?assertEqual([{blowup_rollback, true}], State),
   ?assertEqual([{complete, success}, {complete, failed}, {ready, undefined}],
                [{S#step.forward#operation.state, S#step.forward#operation.result}
                  || S <- F#transaction.steps]),
   ?assertEqual([{complete, success}, {complete, success}, {ready, undefined}],
                [{S#step.rollback#operation.state, S#step.rollback#operation.result}
                  || S <- F#transaction.steps]).

long_function(State) -> timer:sleep(10000), State.
long_function_rollback(State) -> [ {long_function_rollback, true} | State ].

execute_timeout_test() ->
   S1 = new_step(step1, fun step1/1, fun step1_rollback/1),
   S2 = new_step(step2, fun step2/1, fun step2_rollback/1),
   TimeoutFwd = new_operation({fun long_function/1, []}, 10), % timeout after 10 milliseconds
   TimeoutRollback = new_operation(fun long_function_rollback/1),
   TimeoutStep = new_step( toutstep, TimeoutFwd, TimeoutRollback ),
   T = new_transaction( timeout, [ S1, TimeoutStep, S2 ] ),
   {rollback, _F, State} = execute(T, []),
   ?assertEqual([{long_function_rollback, true}], State).

checkpoint_function(State) ->
   ok = gisla:checkpoint([{checkpoint_test, true}| State]),
   error(smod_was_here).
checkpoint_rollback(State) -> [{checkpoint_rollback, true}|State].

checkpoint_test() ->
   S1 = new_step(step1, fun step1/1, fun step1_rollback/1),
   S2 = new_step(step2, fun step2/1, fun step2_rollback/1),
   CheckpointStep = new_step( chkstep, fun checkpoint_function/1, fun checkpoint_rollback/1 ),
   T = new_transaction( chktransaction, [ S1, CheckpointStep, S2 ] ),
   {rollback, _F, State} = execute(T, []),
   ?assertEqual([{checkpoint_rollback, true}, {checkpoint_test, true}], State).

-endif.
