% gisla.hrl

-type stage_func() :: mfa() | function().
-type func_state() :: 'ready' | 'complete'.
-type execution_result() :: 'success' | 'failed'.

-record(sfunc, {
              f           :: stage_func(),
          state = 'ready' :: func_state(),
         result           :: execution_result(),
        timeout = 5000    :: non_neg_integer(),
         reason           :: term()
}).

-type gisla_name() :: atom() | binary() | string().

-record(stage, {
               name :: gisla_name(),
            forward :: #sfunc{},
           rollback :: #sfunc{}
}).

-type pipeline() :: [ #stage{} ].
-type flow_direction() :: 'forward' | 'rollback'.

-record(flow, {
          name          :: gisla_name(),
     pipeline = []      :: pipeline(),
    direction = forward :: flow_direction()
}).

