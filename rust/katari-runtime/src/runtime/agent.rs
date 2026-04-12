use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::ir::{IRModule, VarId};
use crate::value::Value;

use super::thread::ThreadState;

/// Agent lifecycle status. Carries the result value on completion.
#[derive(Debug, Clone)]
pub enum AgentStatus {
    Running,
    Completed(Value),
    Error,
}

/// Agent state — container for the thread tree.
#[derive(Debug)]
pub struct AgentState {
    pub agent_id: String,
    pub agent_def_id: u32,
    pub module: Arc<IRModule>,
    pub vars: HashMap<VarId, Value>,
    pub threads: HashMap<u32, ThreadState>,
    pub root_thread: u32,
    pub parent_agent_id: String,
    pub parent_agent_where: String,
    pub children: HashMap<String, u32>,
    pub parent_available_requests: HashSet<u32>,
    pub status: AgentStatus,
}

impl AgentState {
    pub fn new(
        agent_id: String,
        agent_def_id: u32,
        root_thread: u32,
        parent_agent_id: String,
        parent_agent_where: String,
        parent_available_requests: HashSet<u32>,
        module: Arc<IRModule>,
    ) -> Self {
        Self {
            agent_id,
            agent_def_id,
            module,
            vars: HashMap::new(),
            threads: HashMap::new(),
            root_thread,
            parent_agent_id,
            parent_agent_where,
            children: HashMap::new(),
            parent_available_requests,
            status: AgentStatus::Running,
        }
    }

    pub fn get_var(&self, var_id: VarId) -> Value {
        self.vars.get(&var_id).cloned().unwrap_or(Value::Null)
    }

    pub fn set_var(&mut self, var_id: VarId, value: Value) {
        self.vars.insert(var_id, value);
    }
}
