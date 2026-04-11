pub mod instruction;

use std::collections::HashMap;

pub type VarId = u32;
pub type AgentId = u32;
pub type RequestId = u32;
pub type ConstId = u32;
pub type HandlerId = u32;
pub type ForId = u32;
pub type ThreadId = u32;

#[derive(Debug, Clone, PartialEq)]
pub enum ConstVal {
    Null,
    Bool(bool),
    Int(i64),
    Num(f64),
    Str(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThreadKind {
    FnBody,
    Block,
    HandlerTarget,
    RequestHandler,
    HandleThen,
    ForBody,
    ForThen,
}

#[derive(Debug, Clone)]
pub struct IRThread {
    pub id: ThreadId,
    pub kind: ThreadKind,
    pub params: Vec<VarId>,
    pub body: Vec<instruction::Instruction>,
}

#[derive(Debug, Clone)]
pub struct IRHandleDef {
    pub id: HandlerId,
    pub state_vars: Vec<VarId>,
    pub state_inits: Vec<VarId>,
    pub body: ThreadId,
    pub req_cases: Vec<(RequestId, ThreadId)>,
    pub then: Option<ThreadId>,
}

#[derive(Debug, Clone)]
pub struct IRForDef {
    pub id: ForId,
    pub iter_vars: Vec<VarId>,
    pub arrays: Vec<VarId>,
    pub state_vars: Vec<VarId>,
    pub state_inits: Vec<VarId>,
    pub body: ThreadId,
    pub then: Option<ThreadId>,
}

#[derive(Debug, Clone)]
pub struct IRAgentDef {
    pub id: AgentId,
    pub name: String,
    pub entry: ThreadId,
}

#[derive(Debug, Clone)]
pub struct IRRequestDef {
    pub id: RequestId,
    pub name: String,
    pub from: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct NameTable {
    pub vars: HashMap<VarId, String>,
    pub agents: HashMap<AgentId, String>,
    pub requests: HashMap<RequestId, String>,
}

#[derive(Debug, Clone)]
pub struct IRModule {
    pub name: String,
    pub name_table: NameTable,
    pub consts: Vec<ConstVal>,
    pub requests: Vec<IRRequestDef>,
    pub threads: Vec<IRThread>,
    pub handles: Vec<IRHandleDef>,
    pub fors: Vec<IRForDef>,
    pub agents: Vec<IRAgentDef>,
}
