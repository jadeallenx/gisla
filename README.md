Gisla
=====
This is a library for Erlang that implements the [Saga][saga-paper] pattern for
error recovery/cleanup in distributed transactions.  The saga pattern describes
two call flows, a forward flow that represents progress, and an opposite
rollback flow which represents recovery and cleanup activities.

Concept
-------
The sagas pattern is a useful way to recover from long-running distributed
transactions. 

For example:

* you want to set up some cloud infrastructure which is dependent on other
  cloud infrastructure, and if that other cloud infrastructure fails, you want
  to clean up the resource allocations already performed.

* you have a microservice architecture and you have resources which need to be
  cleaned up if a downstream service fails

Using this library, you can create a "transaction" - a matched set of
operations organized into "steps" which will be executed one after the other.
The new state from the previous operation will be fed into subsequent
function calls.

Each operation in a step represents "forward" progress and "rollback".  When a
"forward" operation fails, gisla will use the accumulated state to execute
rollback operations attached to already completed steps in reverse
order.

```
Pipeline | F1 -> F2 -> F3 (boom) -> F4 ...
 Example | R1 <- R2 <- R3 <-+
```

Use
---

### Forward and rollback operations ###

First, you need to write the `forward` and `rollback` closures for each
step. Each closure should take at least one parameter, which is
the state of the transaction. State can be any arbitrary Erlang term
but proplists are the recommended format.

These closures may either be functions defined by `fun(State) -> ok end` or
`fun do_something/1` or they can be tuples in the form of `{Module, Function,
Arguments = []}` MFA tuples will automatically get the transaction state as
the last parameter of the argument list.

The transaction state will also get the pid of the gisla process so that your
operation may optionally return "checkpoint" state changes - these would be
incremental state mutations during the course of a step which you may want to
use during any unwinding operations that may come later.  It's **very**
important that any checkpoint states include all current state too - do not
just checkpoint the mutations. Gisla does not merge checkpoint changes - you
are responsible for doing that.

When a step is finished, the operation *must* return its final (possibly
mutated) state.  This will automatically be reported back to gisla as the
"step-complete" state, which would then be passed into the next stage of the
transaction.

An example might look something like this:

```erlang
example_forward(State) ->
    % definitely won't fail!
    Results0 = {terah_id, Id} = terah:assign_id(),
    NewState0 = [ Results0 | State ],

    %% The pid of the gisla process is injected automatically
    %% to the pipeline state for checkpointing purposes.
    gisla:checkpoint(NewState0),

    % might fail - TODO: fix real soon
    % but we checkpointed out new ID assignment
    true = unstable_network:activate_terah_id(Id),
    NewState1 = [ {terah_id_active, true} | NewState0 ],
    gisla:checkpoint(NewState1),

    % final operation, this updates an ETS table,
    % probably no failure.
    {terah_ets_tbl, TableName} = lists:keyfind(terah_ets_tbl, 1, State),
    true = terah:update_ets(TableName, Id),
    NewState2 = [ {terah_ets_updated, true} | NewState1 ],
    NewState2.
```

The rollback operation might be something like:

```erlang
example_rollback(State) ->
    %% gisla pid is in our state (if we want it)
    {terah_ets_tbl, TableName} = lists:keyfind(terah_ets_tbl, 1, State),
    true = terah:remove_ets(TableName, Id),

    {terah_id, Id} = lists:keyfind(terah_id, 1, State),
    true = unstable_network:deactivate_terah_id(Id),
    true = terah:make_id_failed(Id),
    [{ terah_id_rollback, Id } | State ].
```

In this example, we don't send any checkpoints during rollback, just the
final state update at the end of the function.

### Creating operations, steps and a transaction ###

Once the closures have been written, you are ready to create steps for your
transaction.

There are three abstractions in this library, from most specific to most
general:

#### Operations ####

Operation records wrap the closures which do the work of each operation.
Timeout information is also stored here - the default is 5000 millseconds.

Operation records have the following extra fields to provide additional
information on execution results:

* state: can be either `ready` meaning ready to run, or `complete` meaning
the function was executed.

* result: `success` or `failed`, depending on the outcome of execution

* reason: Contains the exit reason from a process on success or on an error.

They are created using the `new_operation/0,1,2` functions. There is also an
`update_operation_timeout/2` function by which you may adjust a timeout value.

#### Steps ####

Steps are containers that have a name (which may be an atom, a binary string
or a string), a single forward operation, and a matched rollback operation.

They are created using `new_step/0` or `new_stetp/3` functions. As a bit of
syntactic sugar, you may call `new_step/3` with either #operation records or
with naked functions or MFA tuples.

#### Transactions ####

A transaction is a container for a name (which again may be an atom, a binary
string or a string), and a ordered list of steps which will be executed left to
right.

Transactions can be made using the `new_transaction/0` along with `add_step/2` and
`delete_step/2` or `new_transaction/2`.  There is also a `describe_transaction/1`
function which outputs a simple list of the transaction name plus all step names
in order of execution.

### Executing a transaction ###

Once a transaction is constructed and the steps are organized, you are ready to
execute it.

You can do that using `execute/2`. The State parameter should be in the form
of a proplist.

When a transaction has been executed, it returns a tuple of `{'ok'|'rollback',
FinalT, FinalState}` where FinalT is the original transaction with updated
execution information in the operation records and FinalState is the
accumulated state mutations across all steps.

```erlang
State = [{foo, 1}, {bar, 2}, {baz, 3}],
Step1 = new_step(<<"step 1">>, fun frobulate/1, fun defrobulate/1),
Step2 = new_step(<<"step 2">>, fun activate_frob/1, fun deactivate_frob/1),
Transaction = gisla:new_transaction(<<"example">>, [ Step1, Step2 ]),
{Outcome, FinalT, FinalState} = gisla:execute(Transaction, State),

case Outcome of
  ok -> ok;
  rollback ->
      io:format("Transaction failed. Execution details: ~p, Final state: ~p~n", 
        [FinalT, FinalState]),
      error(transaction_rolled_back)
end.
```

### Errors / timeouts during rollback ###

If a crash or timeout occurs during rollback, gisla will itself crash.

Build
-----
gisla is built using [rebar3][rebar3-web]. It has a dependency on the
[hut][hut-lib] logging abstraction library in hopes that this would make using
it in both Erlang and Elixir easier. By default hut uses the built in
Erlang error_logger facility to log messages. Hut also supports a number
of other logging options including Elixir's built in logging library and lager.

#### About the name ####

It was inspired by the Icelandic saga [Gisla][gisla-saga].

[saga-paper]: http://www.cs.cornell.edu/andru/cs711/2002fa/reading/sagas.pdf
[gisla-saga]: https://en.wikipedia.org/wiki/G%C3%ADsla_saga
[hut-lib]: https://github.com/tolbrino/hut
[rebar3-web]: http://www.rebar3.org
