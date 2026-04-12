use std::collections::HashMap;

use crate::ir::{HandlerId, ThreadKind, VarId};
use crate::value::Value;

/// Pending request routed to a handle scope.
#[derive(Debug, Clone)]
pub struct PendingRequest {
    pub request_id: String,
    pub req_def_id: u32,
    pub args: Vec<Value>,
    pub from_agent_id: String,
    pub from_agent_where: String,
}

/// Origin of a request (for reply routing).
#[derive(Debug, Clone)]
pub struct RequestOrigin {
    pub from_agent_id: String,
    pub from_agent_where: String,
    pub request_id: String,
}

/// Handle execution phase.
#[derive(Debug, Clone)]
pub enum HandlePhase {
    RunningBody { body_thread: u32 },
    RunningHandler {
        body_thread: u32,
        handler_thread: u32,
        requester: RequestOrigin,
    },
    RunningThen { then_thread: u32 },
}

/// Thread status. Threads are removed on completion, so no Completed variant.
#[derive(Debug, Clone)]
pub enum ThreadStatus {
    Running,
    Suspended(SuspendReason),
}

/// Reason for thread suspension.
#[derive(Debug, Clone)]
pub enum SuspendReason {
    Handle {
        handle_def_id: HandlerId,
        dst: VarId,
        phase: HandlePhase,
        state_vars: HashMap<VarId, Value>,
    },
    For {
        for_def_id: u32,
        current_index: u32,
        min_length: u32,
        dst: VarId,
    },
    Par {
        branch_threads: Vec<u32>,
        results: Vec<Option<Value>>,
        dst: VarId,
    },
    Call {
        child_agent_id: String,
        dst: VarId,
    },
    Request {
        request_id: String,
        dst: VarId,
    },
}

/// Thread state.
#[derive(Debug, Clone)]
pub struct ThreadState {
    pub thread_id: u32,
    pub kind: ThreadKind,
    pub pc: u32,
    pub status: ThreadStatus,
    pub parent: Option<u32>,
}

impl ThreadState {
    pub fn new(thread_id: u32, kind: ThreadKind, parent: Option<u32>) -> Self {
        Self {
            thread_id,
            kind,
            pc: 0,
            status: ThreadStatus::Running,
            parent,
        }
    }

    pub fn is_running(&self) -> bool {
        matches!(self.status, ThreadStatus::Running)
    }
}
