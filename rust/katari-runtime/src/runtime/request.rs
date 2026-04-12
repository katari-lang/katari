use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::event::{self, Event, EventKind};
use super::thread::{PendingRequest, SuspendReason, ThreadStatus};

/// Execute IRequest instruction.
/// Suspends the thread and routes the request inline.
pub fn handle_irequest(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    rid: u32,
    args: &[u32],
    events: &mut Vec<Event>,
) {
    let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
    let request_id = uuid::Uuid::new_v4().to_string();

    // Suspend the requesting thread
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Request {
            request_id: request_id.clone(),
            dst,
        });
    }

    // Inline routing
    let pending = PendingRequest {
        request_id,
        req_def_id: rid,
        args: arg_values,
        from_agent_id: agent.agent_id.clone(),
        from_agent_where: String::new(),
    };

    match event::route_request_to_handle(agent, module, thread_id, rid) {
        Some((handle_owner_tid, handler_def_tid)) => {
            events.push(Event {
                agent_id: agent.agent_id.clone(),
                kind: EventKind::IncomingRequest {
                    owner_thread_id: handle_owner_tid,
                    request: pending,
                    handler_def_tid,
                },
            });
        }
        None => {
            tracing::warn!(
                agent_id = %agent.agent_id,
                "no handle scope found for request, forwarding to parent (not yet implemented)"
            );
        }
    }
}

/// Execute ICall instruction.
pub fn handle_icall(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    agent_def_id: u32,
    args: &[u32],
    events: &mut Vec<Event>,
) {
    let agent_def = module.agents.iter().find(|a| a.id == agent_def_id);

    // Check for primitive agents (handled synchronously)
    if let Some(def) = agent_def {
        if def.name.starts_with("prim.") {
            let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
            match super::primitive::call_primitive(&def.name, &arg_values) {
                super::primitive::PrimitiveResult::Ok(value) => {
                    agent.set_var(dst, value);
                    return;
                }
                super::primitive::PrimitiveResult::RaiseRequest {
                    req_name,
                    args: req_args,
                } => {
                    let rid = module
                        .requests
                        .iter()
                        .find(|r| r.name == req_name)
                        .map(|r| r.id);
                    if let Some(rid) = rid {
                        let request_id = uuid::Uuid::new_v4().to_string();
                        if let Some(t) = agent.threads.get_mut(&thread_id) {
                            t.status = ThreadStatus::Suspended(SuspendReason::Request {
                                request_id: request_id.clone(),
                                dst,
                            });
                        }
                        let pending = PendingRequest {
                            request_id,
                            req_def_id: rid,
                            args: req_args,
                            from_agent_id: agent.agent_id.clone(),
                            from_agent_where: String::new(),
                        };
                        match event::route_request_to_handle(agent, module, thread_id, rid) {
                            Some((handle_owner_tid, handler_def_tid)) => {
                                events.push(Event {
                                    agent_id: agent.agent_id.clone(),
                                    kind: EventKind::IncomingRequest {
                                        owner_thread_id: handle_owner_tid,
                                        request: pending,
                                        handler_def_tid,
                                    },
                                });
                            }
                            None => {
                                tracing::warn!(
                                    "primitive raised request with no handle scope"
                                );
                            }
                        }
                    } else {
                        tracing::warn!("primitive raised unknown request: {}", req_name);
                        agent.set_var(dst, Value::Null);
                    }
                    return;
                }
            }
        }
    }

    // Non-primitive: suspend thread, push SpawnChildAgent event
    let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
    let child_agent_id = format!("agent-{}", uuid::Uuid::new_v4());

    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Call {
            child_agent_id: child_agent_id.clone(),
            dst,
        });
    }

    agent.children.insert(child_agent_id.clone(), thread_id);

    events.push(Event {
        agent_id: agent.agent_id.clone(),
        kind: EventKind::SpawnChildAgent {
            child_agent_id,
            agent_def_id,
            args: arg_values,
        },
    });
}
