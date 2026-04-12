use std::collections::HashMap;

use crate::ir::{IRModule, ThreadKind};
use crate::value::Value;

use super::agent::AgentState;
use super::signal::Signal;
use super::thread::{HandlePhase, PendingRequest, SuspendReason, ThreadStatus};

/// Event in the global event queue.
/// Every event has a fully resolved target (agent + thread).
#[derive(Debug, Clone)]
pub struct Event {
    pub agent_id: String,
    pub thread_id: u32,
    pub kind: EventKind,
}

#[derive(Debug, Clone)]
pub enum EventKind {
    /// Execute thread from current PC to next async point.
    Start,

    /// A child thread completed with a signal.
    ChildThreadCompleted {
        child_thread_id: u32,
        child_kind: ThreadKind,
        signal: Signal,
    },

    /// Child agent completed → resume Call suspension.
    ChildAgentCompleted {
        child_agent_id: String,
        result: Value,
    },

    /// Reply to a pending Request suspension.
    Reply {
        request_id: String,
        value: Value,
    },

    /// Incoming request routed to a handle scope.
    IncomingRequest {
        request: PendingRequest,
        handler_def_tid: u32,
    },

    /// Cancel a specific thread. Propagates downward: pushes CancelThread
    /// for direct children, detaches child agents, then removes the thread.
    CancelThread,

    /// Terminate the agent.
    Terminate,
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
        EventKind::Start => {
            // Thread must exist and be Running
            agent
                .threads
                .get(&event.thread_id)
                .is_some_and(|t| t.is_running())
                && !is_held_by_handler(agent, event.thread_id)
        }

        EventKind::ChildThreadCompleted {
            child_thread_id, ..
        } => {
            // Target thread must exist
            let t = match agent.threads.get(&event.thread_id) {
                Some(t) => t,
                None => return false,
            };
            // Special: if target is a handle in RunningHandler, only handler
            // completion is applicable (this is what unblocks the handle).
            if let ThreadStatus::Suspended(SuspendReason::Handle {
                phase: HandlePhase::RunningHandler { handler_thread, .. },
                ..
            }) = &t.status
            {
                return *child_thread_id == *handler_thread;
            }
            !is_held_by_handler(agent, event.thread_id)
        }

        EventKind::IncomingRequest { .. } => {
            // Only applicable if handle is in RunningBody and not held by outer handler.
            if let Some(t) = agent.threads.get(&event.thread_id) {
                if let ThreadStatus::Suspended(SuspendReason::Handle {
                    phase: HandlePhase::RunningBody { .. },
                    ..
                }) = &t.status
                {
                    return !is_held_by_handler(agent, event.thread_id);
                }
            }
            false
        }

        EventKind::ChildAgentCompleted { .. } | EventKind::Reply { .. } => {
            // Target thread must exist
            if !agent.threads.contains_key(&event.thread_id) {
                return false;
            }
            !is_held_by_handler(agent, event.thread_id)
        }

        // CancelThread is always applicable if the thread exists
        EventKind::CancelThread => agent.threads.contains_key(&event.thread_id),

        EventKind::Terminate => true,
    }
}

/// Check if a thread is in the body subtree of a RunningHandler handle.
///
/// Walk up the parent chain. If we encounter a handle in RunningHandler
/// and we came from its body_thread side, the thread is "held" (frozen).
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

/// Route an incoming request through the thread tree to find the matching
/// handle scope. Returns `Some((handle_owner_tid, handler_def_tid))` or
/// `None` if no match was found (should forward to parent agent).
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
                    let hd = module.handles.iter().find(|h| h.id == *handle_def_id);
                    if let Some(hd) = hd {
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
