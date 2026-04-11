use super::{AgentId, ConstId, ForId, HandlerId, RequestId, ThreadId, VarId};

#[derive(Debug, Clone, PartialEq)]
pub enum Instruction {
    // Constants & Movement
    LoadConst(VarId, ConstId),
    LoadNull(VarId),
    Move(VarId, VarId),

    // Object
    NewObject(VarId, Vec<(ConstId, VarId)>),
    GetField(VarId, VarId, ConstId),
    SetField(VarId, VarId, ConstId, VarId), // new_obj, obj, field, val
    HasField(VarId, VarId, ConstId),

    // Array
    NewArray(VarId, Vec<VarId>),
    ArrGet(VarId, VarId, VarId),
    ArrLen(VarId, VarId),
    ArrPush(VarId, VarId, VarId),
    ArrSlice(VarId, VarId, VarId, VarId),

    // Arithmetic
    Add(VarId, VarId, VarId),
    Sub(VarId, VarId, VarId),
    Mul(VarId, VarId, VarId),
    Div(VarId, VarId, VarId),
    Mod(VarId, VarId, VarId),
    Neg(VarId, VarId),

    // Comparison
    CmpEq(VarId, VarId, VarId),
    CmpNe(VarId, VarId, VarId),
    CmpLt(VarId, VarId, VarId),
    CmpLe(VarId, VarId, VarId),
    CmpGt(VarId, VarId, VarId),
    CmpGe(VarId, VarId, VarId),

    // Logical
    And(VarId, VarId, VarId),
    Or(VarId, VarId, VarId),
    Not(VarId, VarId),

    // String/Type
    Concat(VarId, VarId, VarId),
    ToString(VarId, VarId),
    TypeOf(VarId, VarId),

    // Control flow
    Jump(u32),
    Branch(VarId, u32, u32),
    Switch(VarId, Vec<(ConstId, u32)>, u32),
    Complete(VarId),
    Return(VarId),

    // Agent operations
    Call(VarId, AgentId, Vec<VarId>),
    Par(VarId, Vec<ThreadId>),
    Request(VarId, RequestId, Vec<VarId>),

    // Handle
    Handle(VarId, HandlerId),
    Continue(VarId, Vec<(VarId, VarId)>),
    HandleBreak(VarId),

    // For
    For(VarId, ForId),
    ForContinue(Vec<(VarId, VarId)>),
    ForBreak(VarId),
}
