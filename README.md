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
Pipeline: F1 -> F2 -> F3 (boom) -> F4 ...
 Example: R1 <- R2 <- R3 <-+
```

Use
---




Build
-----


#### About the name ####

It was inspired by the Icelandic saga [Gisla][gisla-saga].


[saga-paper]: http://www.cs.cornell.edu/andru/cs711/2002fa/reading/sagas.pdf
[gisla-saga]: https://en.wikipedia.org/wiki/G%C3%ADsla_saga
