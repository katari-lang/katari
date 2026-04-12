use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::thread::{SuspendReason, ThreadStatus};

/// Execute IRequest instruction.
/// Suspends the thread and records the request — routing is handled by the event loop.
pub fn handle_irequest(
    agent: &mut AgentState,
    _module: &IRModule,
    thread_id: u32,
    dst: u32,
    rid: u32,
    args: &[u32],
) {
    let arg_values: Vec<Value> = args.iter().map(|v| agent.get_var(*v)).collect();
    let request_id = uuid::Uuid::new_v4().to_string();

    // Record outgoing request for harvest
    agent.outgoing_requests.push((
        thread_id,
        super::thread::PendingRequest {
            request_id: request_id.clone(),
            req_def_id: rid,
            args: arg_values,
            from_agent_id: agent.agent_id.clone(),
            from_agent_where: String::new(),
        },
    ));

    // Suspend the requesting thread (will be resumed on Reply event)
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Request {
            request_id,
            dst,
        });
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
