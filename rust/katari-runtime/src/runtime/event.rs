use std::collections::HashMap;

use crate::ir::{IRModule, ThreadKind};
use crate::value::Value;

use super::agent::AgentState;
use super::signal::Signal;
use super::thread::{HandlePhase, PendingRequest, SuspendReason, ThreadStatus};

/// Event in the global event queue. Target thread is inside each EventKind variant.
#[derive(Debug, Clone)]
pub struct Event {
    pub agent_id: String,
    pub kind: EventKind,
}

#[derive(Debug, Clone)]
pub enum EventKind {
    /// Execute thread from current PC to next suspension point.
    Execute(u32),

    /// A child thread completed (already removed). Dispatch signal to parent.
    ThreadCompleted {
        parent_id: u32,
        child_id: u32,
        child_kind: ThreadKind,
        signal: Signal,
    },

    /// Cancel a thread and all descendants.
    CancelThread(u32),

    /// Incoming request routed to a handle scope.
    IncomingRequest {
        owner_thread_id: u32,
        request: PendingRequest,
        handler_def_tid: u32,
    },

    /// Reply to a pending Request suspension.
    Reply {
        thread_id: u32,
        request_id: String,
        value: Value,
    },

    /// Spawn a child agent (from ICall).
    SpawnChildAgent {
        child_agent_id: String,
        agent_def_id: u32,
        args: Vec<Value>,
    },

    /// Agent completed (root thread finished). Notifies parent, removes self.
    AgentCompleted,

    /// Child agent completed → resume Call suspension.
    ChildAgentCompleted {
        thread_id: u32,
        child_agent_id: String,
        result: Value,
    },
}

// ---------------------------------------------------------------------------
// Applicability
// ---------------------------------------------------------------------------

/// Check if an event can be applied right now.
pub fn is_applicable(event: &Event, agents: &HashMap<String, AgentState>) -> bool {
    let agent = match agents.get(&event.agent_id) {
        Some(a) => a,
        None => return false,
    };

    match &event.kind {
        EventKind::Execute(tid) => {
            agent
                .threads
                .get(tid)
                .is_some_and(|t| t.is_running())
                && !is_held_by_handler(agent, *tid)
        }

        EventKind::ThreadCompleted {
            parent_id,
            child_id,
            ..
        } => {
            let t = match agent.threads.get(parent_id) {
                Some(t) => t,
                None => return false,
            };
            if let ThreadStatus::Suspended(SuspendReason::Handle {
                phase: HandlePhase::RunningHandler { handler_thread, .. },
                ..
            }) = &t.status
            {
                return *child_id == *handler_thread;
            }
            !is_held_by_handler(agent, *parent_id)
        }

        EventKind::CancelThread(tid) => agent.threads.contains_key(tid),

        EventKind::IncomingRequest {
            owner_thread_id, ..
        } => {
            if let Some(t) = agent.threads.get(owner_thread_id) {
                if let ThreadStatus::Suspended(SuspendReason::Handle {
                    phase: HandlePhase::RunningBody { .. },
                    ..
                }) = &t.status
                {
                    return !is_held_by_handler(agent, *owner_thread_id);
                }
            }
            false
        }

        EventKind::Reply { thread_id, .. } | EventKind::ChildAgentCompleted { thread_id, .. } => {
            agent.threads.contains_key(thread_id)
                && !is_held_by_handler(agent, *thread_id)
        }

        EventKind::SpawnChildAgent { .. } | EventKind::AgentCompleted => true,
    }
}

/// Check if a thread is in the body subtree of a RunningHandler handle.
pub fn is_held_by_handler(agent: &AgentState, thread_id: u32) -> bool {
    let mut current = thread_id;
    loop {
        let parent_id = match agent.threads.get(&current).and_then(|t| t.parent) {
            Some(p) => p,
            None => return false,
        };
        if let Some(parent) = agent.threads.get(&parent_id) {
            if let ThreadStatus::Suspended(SuspendReason::Handle {
                phase: HandlePhase::RunningHandler { body_thread, .. },
                ..
            }) = &parent.status
            {
                if current == *body_thread {
                    return true;
                }
            }
        }
        current = parent_id;
    }
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

/// Route a request through the thread tree to find the matching handle scope.
pub fn route_request_to_handle(
    agent: &AgentState,
    module: &IRModule,
    source_thread_id: u32,
    req_def_id: u32,
) -> Option<(u32, u32)> {
    let mut current = source_thread_id;
    loop {
        let parent_id = match agent.threads.get(&current).and_then(|t| t.parent) {
            Some(p) => p,
            None => return None,
        };
        if let Some(t) = agent.threads.get(&parent_id) {
            if let ThreadStatus::Suspended(SuspendReason::Handle {
                handle_def_id,
                phase,
                ..
            }) = &t.status
            {
                if !matches!(phase, HandlePhase::RunningThen { .. }) {
                    if let Some(hd) = module.handles.iter().find(|h| h.id == *handle_def_id) {
                        if let Some((_, tid)) = hd
                            .req_cases
                            .iter()
                            .find(|(rid, _)| *rid == req_def_id)
                        {
                            return Some((parent_id, *tid));
                        }
                    }
                }
            }
        }
        current = parent_id;
    }
}

/// Find the thread waiting for a specific request_id.
pub fn find_request_thread(agent: &AgentState, request_id: &str) -> Option<u32> {
    agent
        .threads
        .iter()
        .find(|(_, t)| {
            matches!(
                &t.status,
                ThreadStatus::Suspended(SuspendReason::Request { request_id: rid, .. })
                    if rid == request_id
            )
        })
        .map(|(id, _)| *id)
}
