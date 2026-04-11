use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::ir::{IRModule, VarId};
use crate::value::Value;

use super::thread::{HandlePhase, SuspendReason, ThreadState, ThreadStatus};

/// Top-level agent lifecycle status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentStatus {
    Running,
    Completed,
}

/// Agent state — container for the thread tree.
#[derive(Debug)]
pub struct AgentState {
    pub agent_id: String,
    pub agent_def_id: u32,

    /// The IR module this agent was created with (versioned via Arc).
    pub module: Arc<IRModule>,

    /// Shared variable map (all threads within this agent share this).
    pub vars: HashMap<VarId, Value>,

    /// All active threads (flat map, tree via parent references).
    pub threads: HashMap<u32, ThreadState>,

    /// Root thread ID (FN_BODY).
    pub root_thread: u32,

    /// Parent agent info.
    pub parent_agent_id: String,
    pub parent_agent_where: String,

    /// child_agent_id → spawning thread ID.
    pub children: HashMap<String, u32>,

    /// Available requests inherited from parent agent.
    pub parent_available_requests: HashSet<u32>,

    /// Agent lifecycle status.
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

    /// Find a thread that is Running.
    pub fn find_running_thread(&self) -> Option<u32> {
        self.threads
            .values()
            .find(|t| t.is_running())
            .map(|t| t.thread_id)
    }

    /// Check if any thread has completed (needs signal dispatch).
    pub fn has_completed_thread(&self) -> bool {
        self.threads
            .values()
            .any(|t| matches!(t.status, ThreadStatus::Completed(_)))
    }

    /// Check if any handle scope has a processable request queue.
    pub fn has_processable_request_queue(&self) -> bool {
        self.threads.values().any(|t| {
            matches!(
                &t.status,
                ThreadStatus::Suspended(SuspendReason::Handle {
                    phase: HandlePhase::RunningBody { .. },
                    request_queue,
                    ..
                }) if !request_queue.is_empty()
            )
        })
    }

    /// Check if this agent can make progress in the event loop.
    pub fn can_make_progress(&self) -> bool {
        self.status == AgentStatus::Running
            && (self.find_running_thread().is_some()
                || self.has_completed_thread()
                || self.has_processable_request_queue())
    }

    /// Get variable value (cloned).
    pub fn get_var(&self, var_id: VarId) -> Value {
        self.vars.get(&var_id).cloned().unwrap_or(Value::Null)
    }

    /// Set variable value.
    pub fn set_var(&mut self, var_id: VarId, value: Value) {
        self.vars.insert(var_id, value);
    }
}
