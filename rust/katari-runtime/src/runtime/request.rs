use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::handle;
use super::thread::{HandlePhase, PendingRequest, SuspendReason, ThreadStatus};

/// Execute IRequest instruction.
pub fn handle_irequest(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    rid: u32,
    args: &[u32],
) {
    let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
    let request_id = uuid::Uuid::new_v4().to_string();

    let request = PendingRequest {
        request_id: request_id.clone(),
        req_def_id: rid,
        args: arg_values,
        from_agent_id: agent.agent_id.clone(),
        from_agent_where: String::new(), // same agent
    };

    // Suspend the requesting thread (will be resumed on reply)
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Request {
            request_id: request_id.clone(),
            dst,
        });
    }

    // Route the request through the thread tree
    route_request(agent, module, thread_id, request);
}

/// Route a request by traversing the thread tree upward.
pub fn route_request(
    agent: &mut AgentState,
    module: &IRModule,
    source_thread_id: u32,
    request: PendingRequest,
) {
    let mut current = source_thread_id;

    loop {
        let parent = agent.threads.get(&current).and_then(|t| t.parent);
        match parent {
            None => {
                // Root thread reached — forward to parent agent
                forward_to_parent(agent, request);
                return;
            }
            Some(parent_id) => {
                // Check if parent thread has a matching handle scope
                let handler_tid = {
                    let parent_thread = agent.threads.get(&parent_id);
                    parent_thread.and_then(|t| match &t.status {
                        ThreadStatus::Suspended(SuspendReason::Handle {
                            handle_def_id,
                            phase,
                            ..
                        }) => {
                            // Skip if in RunningThen (scope inactive)
                            if matches!(phase, HandlePhase::RunningThen { .. }) {
                                return None;
                            }
                            let handle_def =
                                module.handles.iter().find(|h| h.id == *handle_def_id);
                            handle_def.and_then(|hd| {
                                hd.req_cases
                                    .iter()
                                    .find(|(rid, _)| *rid == request.req_def_id)
                                    .map(|(_, tid)| *tid)
                            })
                        }
                        _ => None,
                    })
                };

                if let Some(handler_tid) = handler_tid {
                    handle::handle_request_in_scope(
                        agent,
                        module,
                        parent_id,
                        handler_tid,
                        request,
                    );
                    return;
                }

                // No match or phase inactive — continue up
                current = parent_id;
            }
        }
    }
}

/// Forward request to parent agent (external).
fn forward_to_parent(agent: &AgentState, request: PendingRequest) {
    // The requesting thread is already Suspended(Request).
    // When the parent replies via HTTP, on_reply will resume it.
    tracing::warn!(
        agent_id = %agent.agent_id,
        request_id = %request.request_id,
        req_def_id = request.req_def_id,
        "forwarding request to parent agent (HTTP not yet implemented)"
    );
    // TODO: send HTTP POST /agent/request to parent_agent_where
}

/// Execute ICall instruction.
pub fn handle_icall(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    agent_def_id: u32,
    args: &[u32],
) {
    let agent_def = module.agents.iter().find(|a| a.id == agent_def_id);

    // Check for primitive agents (handled synchronously)
    if let Some(def) = agent_def {
        if def.name.starts_with("prim.") {
            let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
            let result = super::primitive::call_primitive(&def.name, &arg_values);
            agent.set_var(dst, result);
            return; // No suspension — thread continues
        }
    }

    // Non-primitive: suspend thread, Runtime will handle spawning
    let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
    let child_agent_id = format!("agent-{}", uuid::Uuid::new_v4());

    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Call {
            child_agent_id: child_agent_id.clone(),
            agent_def_id,
            args: arg_values,
            dst,
        });
    }

    agent.children.insert(child_agent_id, thread_id);
}

/// Handle reply for a pending request (internal or external).
pub fn on_reply(agent: &mut AgentState, request_id: &str, value: Value) {
    // Find thread waiting for this request_id
    let waiting_thread = agent
        .threads
        .iter()
        .find(|(_, t)| {
            matches!(
                &t.status,
                ThreadStatus::Suspended(SuspendReason::Request { request_id: rid, .. })
                    if rid == request_id
            )
        })
        .map(|(id, _)| *id);

    if let Some(tid) = waiting_thread {
        let dst = {
            let t = agent.threads.get(&tid).unwrap();
            match &t.status {
                ThreadStatus::Suspended(SuspendReason::Request { dst, .. }) => *dst,
                _ => unreachable!(),
            }
        };
        agent.set_var(dst, value);
        if let Some(t) = agent.threads.get_mut(&tid) {
            t.status = ThreadStatus::Running;
        }
    }
}

/// Handle child agent completion.
pub fn on_child_return(agent: &mut AgentState, child_agent_id: &str, value: Value) {
    if let Some(&spawning_tid) = agent.children.get(child_agent_id) {
        let dst = {
            let t = agent.threads.get(&spawning_tid);
            match t.map(|t| &t.status) {
                Some(ThreadStatus::Suspended(SuspendReason::Call { dst, .. })) => *dst,
                _ => return,
            }
        };
        agent.set_var(dst, value);
        if let Some(t) = agent.threads.get_mut(&spawning_tid) {
            t.status = ThreadStatus::Running;
        }
        agent.children.remove(child_agent_id);
    }
}

/// Handle external request from a child agent.
pub fn on_external_request(agent: &mut AgentState, module: &IRModule, request: PendingRequest) {
    // Find the thread that spawned the child agent
    let forwarded_by = &request.from_agent_id;
    if let Some(&spawning_tid) = agent.children.get(forwarded_by.as_str()) {
        route_request(agent, module, spawning_tid, request);
    } else {
        tracing::warn!(
            "received request from unknown child agent: {}",
            forwarded_by
        );
    }
}
