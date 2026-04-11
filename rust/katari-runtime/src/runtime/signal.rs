use crate::ir::VarId;
use crate::value::Value;

/// Signal returned when a thread completes execution.
#[derive(Debug, Clone)]
pub enum Signal {
    /// IComplete — thread normal completion
    Normal(Value),
    /// IReturn — source `return` statement
    FnReturn(Value),
    /// IHandleBreak — handle scope exit
    HandleBreak(Value),
    /// IContinue — request handler → handle resume
    Continue(Value, Vec<(VarId, VarId)>),
    /// IForBreak — for loop exit
    ForBreak(Value),
    /// IForContinue — for body → next iteration
    ForContinue(Vec<(VarId, VarId)>),
}
