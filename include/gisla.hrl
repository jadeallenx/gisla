% gisla.hrl

-type operation_fun() :: mfa() | {function(), list()}.
-type operation_state() :: 'ready' | 'complete'.
-type execution_result() :: 'success' | 'failed'.

-record(operation, {
              f           :: operation_fun(),
          state = 'ready' :: operation_state(),
         result           :: execution_result(),
        timeout = 5000    :: non_neg_integer(),
         reason           :: term()
}).

-type gisla_name() :: atom() | binary() | string().

-record(step, {
                ref :: reference(),
               name :: gisla_name(),
            forward :: #operation{},
           rollback :: #operation{}
}).

-type steps() :: [ #step{} ].
-type transaction_direction() :: 'forward' | 'rollback'.

-record(transaction, {
         name           :: gisla_name(),
        steps = []      :: steps(),
    direction = forward :: transaction_direction()
}).

