use std::collections::{HashMap, VecDeque};

use crate::ir::{HandlerId, ThreadKind, VarId};
use crate::value::Value;

use super::signal::Signal;

/// Pending request routed to a handle scope.
/// Contains only routing information — resume info is in SuspendReason::Request.
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

/// Thread status.
#[derive(Debug, Clone)]
pub enum ThreadStatus {
    Running,
    Suspended(SuspendReason),
    Completed(Signal),
}

/// Reason for thread suspension.
/// All scope/control-flow state is embedded here — no separate scope structs.
#[derive(Debug, Clone)]
pub enum SuspendReason {
    /// Waiting for handle scope (body → handlers → then → done).
    Handle {
        handle_def_id: HandlerId,
        dst: VarId,
        phase: HandlePhase,
        state_vars: HashMap<VarId, Value>,
        request_queue: VecDeque<PendingRequest>,
    },
    /// Iterating a for loop.
    For {
        for_def_id: u32,
        current_index: u32,
        min_length: u32,
        dst: VarId,
    },
    /// Waiting for parallel branches.
    Par {
        branch_threads: Vec<u32>,
        results: Vec<Option<Value>>,
        dst: VarId,
    },
    /// Waiting for a child agent to complete.
    Call {
        child_agent_id: String,
        agent_def_id: u32,
        args: Vec<Value>,
        dst: VarId,
    },
    /// Waiting for a request reply.
    Request {
        request_id: String,
        dst: VarId,
    },
}

/// Thread state machine.
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
