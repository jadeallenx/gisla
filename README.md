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

Using this library, you can create a "pipeline" of function calls which will be
executed one after the other.  The new state from the previous function call
will be fed into subsequent function calls.

Each entry in the pipeline has a "forward" progress function and a "rollback"
function.  When a "forward" function fails, gisla will use the accumulated
state to execute rollback functions attached to already completed pipeline
entries in reverse order.

```
Pipeline | F1 -> F2 -> F3 (boom) -> F4 ...
 Example | R1 <- R2 <- R3 <-+
```

Use
---

### Forward and rollback functions ###

First, you need to write the `forward` and `rollback` closures for each
pipeline stage. Each closure should take at least one parameter, which is
the state of the pipeline. The state can be any arbitrary Erlang term
but proplists are the recommended format.

These closures may either be functions defined by `fun(State) -> ok end` or
they can be MFA tuples in the form of `{Module, Function, Arguments = []}`
MFA tuples will automatically get the pipeline state as the last parameter
of the argument list.

The pipeline state will also get the pid of the gisla process so that your
function may optionally return "checkpoint" state changes - these would be
incremental state mutations during the course of a stage execution which
you may want to use during any unwinding operations that may come later.
It's **very** important that any checkpoint states include all current
state too - do not just checkpoint the mutations. Gisla does not merge
checkpoint changes - you are responsible for doing that.

When the stage is finished, the function *must* return its final
(possibly mutated) state.  This will automatically be reported back to gisla as
the "stage-complete" state, which would then (assuming success) be passed into
the next stage of the pipeline.

An example might look something like this:

```erlang
example_forward(State) ->
    %% The pid of the gisla process is injected automatically
    %% to the pipeline state for checkpointing purposes.
    {gisla_reply, Reply} = lists:keyfind(gisla_reply, 1, State),

    % definitely won't fail!
    Results0 = {terah_id, Id} = terah:assign_id(),
    NewState0 = [ Results0 | State ],
    Reply ! {checkpoint, NewState0},

    % might fail - TODO: fix real soon
    % but we checkpointed out new ID assignment
    true = unstable_network:activate_terah_id(Id),
    NewState1 = [ {terah_id_active, true} | NewState0 ],
    Reply ! {checkpoint, NewState1},

    % final operation, this updates an ETS table,
    % probably no failure.
    {terah_ets_tbl, TableName} = lists:keyfind(terah_ets_tbl, 1, State),
    true = terah:update_ets(TableName, Id),
    NewState2 = [ {terah_ets_updated, true} | NewState1 ],
    NewState2.
```

The rollback function might be something like:

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

### Creating stages and pipelines ###

Once the closures have been written, you are ready to create stages for
your pipeline.  Use the `make_stage/3` or `make_stage/4` functions to
build stage records. By default, stages get a 5 second timeout. You
can adjust this timeout using `make_stage/4` - and a value of 0 means
`infinity`

Names for flows and stages may be atoms, binary strings, or strings.

Example:
```erlang
%% gets default timeout value of 5000 milliseconds
Stage1 = gisla:make_stage(stage_1, {example_module, forward1, []},
    {example_module, rollback1, []}),

%% this stage takes a long time, so make the timeout 30 seconds
Forward = fun(State) -> forward2(State) end,
Rollback = fun(State) -> rollback2(State) end,
Stage2 = gisla:make_stage(stage_2, Forward, Rollback, 30*1000),
```

Once we have the stages, we are ready to start adding them to a flow using
`new_flow/2` and `add_stage/2`.

Example:
```erlang
Flow = gisla:new_flow(flow0, [ Stage1, Stage2 ]),
```

or we could do it this way:

```erlang
Empty = gisla:new_flow(),
Flow0 = gisla:name_flow(hard_way, Empty),
Flow1 = gisla:add_stage(Stage1, Flow0),
Flow2 = gisla:add_stage(Stage2, Flow1),
```

You can remove a stage by its name using `delete_stage/2`.

```erlang
UpdatedFlow = gisla:delete_stage(stage3, OldFlow)
```

And you can get a brief look at a flow by using `describe_flow/1`

```erlang
io:format("~p", gisla:describe_flow(Flow))
```

### Executing a flow ###

Once a flow is constructed and the stages are organized into a pipeline, you
are ready to execute it.

You can do that using `execute/2`

```erlang
State = [{foo, 1}, {bar, 2}, {baz, 3}],
Flow = gisla:new_flow(<<"example">>, [ Stage1, Stage2 ],
{Direction, FinalState} = gisla:execute(Flow, State),

case Direction of
  forward -> ok;
  rollback -> error(flow_rolled_back)
end.
```

### Errors / timeouts during rollback ###

If a crash or timeout occurs during rollback, gisla will itself crash.


Build
-----


#### About the name ####

It was inspired by the Icelandic saga [Gisla][gisla-saga].


[saga-paper]: http://www.cs.cornell.edu/andru/cs711/2002fa/reading/sagas.pdf
[gisla-saga]: https://en.wikipedia.org/wiki/G%C3%ADsla_saga
