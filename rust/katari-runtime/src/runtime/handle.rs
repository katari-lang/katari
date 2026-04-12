use std::collections::HashMap;

use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::event::{self, Event, EventKind};
use super::execute::{finish_thread, resume_thread, spawn_child_thread};
use super::signal::Signal;
use super::thread::{
    HandlePhase, PendingRequest, RequestOrigin, SuspendReason, ThreadStatus,
};
use super::OutgoingReply;

/// Execute Handle instruction: suspend parent, spawn body thread.
pub fn setup(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    hid: u32,
    events: &mut Vec<Event>,
) {
    let handle_def = module
        .handles
        .iter()
        .find(|h| h.id == hid)
        .expect("handle def not found");

    // Initialize state variables
    let mut state_vars = HashMap::new();
    for (sv, iv) in handle_def
        .state_vars
        .iter()
        .zip(handle_def.state_inits.iter())
    {
        let val = agent.get_var(*iv);
        state_vars.insert(*sv, val);
    }

    let body_tid = handle_def.body;

    // Suspend parent
    if let Some(parent) = agent.threads.get_mut(&thread_id) {
        parent.status = ThreadStatus::Suspended(SuspendReason::Handle {
            handle_def_id: hid,
            dst,
            phase: HandlePhase::RunningBody {
                body_thread: body_tid,
            },
            state_vars,
        });
    }

    // Spawn body thread
    spawn_child_thread(
        agent,
        body_tid,
        crate::ir::ThreadKind::HandlerTarget,
        thread_id,
        events,
    );
}

/// Handle an incoming request routed to this handle scope.
pub fn dispatch_request(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    handler_tid: u32,
    request: PendingRequest,
    events: &mut Vec<Event>,
) {
    let body_thread = match agent.threads.get(&thread_id) {
        Some(t) => match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle {
                phase: HandlePhase::RunningBody { body_thread },
                ..
            }) => *body_thread,
            _ => return,
        },
        None => return,
    };

    // Copy state vars to agent.vars
    if let Some(t) = agent.threads.get(&thread_id) {
        if let ThreadStatus::Suspended(SuspendReason::Handle { state_vars, .. }) = &t.status {
            for (sv, val) in state_vars {
                agent.vars.insert(*sv, val.clone());
            }
        }
    }

    // Bind request args to handler params
    let handler_ir = module
        .threads
        .iter()
        .find(|t| t.id == handler_tid)
        .expect("handler thread not found");
    for (param, arg) in handler_ir.params.iter().zip(request.args.iter()) {
        agent.vars.insert(*param, arg.clone());
    }

    // Update phase to RunningHandler
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        if let ThreadStatus::Suspended(SuspendReason::Handle { phase, .. }) = &mut t.status {
            *phase = HandlePhase::RunningHandler {
                body_thread,
                handler_thread: handler_tid,
                requester: RequestOrigin {
                    from_agent_id: request.from_agent_id,
                    from_agent_where: request.from_agent_where,
                    request_id: request.request_id,
                },
            };
        }
    }

    // Spawn handler thread
    spawn_child_thread(
        agent,
        handler_tid,
        crate::ir::ThreadKind::RequestHandler,
        thread_id,
        events,
    );
}

/// Process signal from a completed RequestHandler thread.
pub fn process_handler_signal(
    agent: &mut AgentState,
    _module: &IRModule,
    owner_thread_id: u32,
    signal: Signal,
    events: &mut Vec<Event>,
    replies: &mut Vec<OutgoingReply>,
) {
    let (dst, phase) = match agent.threads.get(&owner_thread_id) {
        Some(t) => match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle { dst, phase, .. }) => {
                (*dst, phase.clone())
            }
            _ => return,
        },
        None => return,
    };

    match signal {
        Signal::Normal(value) => {
            // Treat as Continue(value, [])
            process_handler_signal(
                agent,
                _module,
                owner_thread_id,
                Signal::Continue(value, vec![]),
                events,
                replies,
            );
        }
        Signal::Continue(value, mutations) => {
            // Apply mutations to handle state
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                if let ThreadStatus::Suspended(SuspendReason::Handle { state_vars, .. }) =
                    &mut t.status
                {
                    for (sv, nv) in &mutations {
                        let val = agent.vars.get(nv).cloned().unwrap_or(Value::Null);
                        state_vars.insert(*sv, val);
                    }
                }
            }

            if let HandlePhase::RunningHandler {
                body_thread,
                ref requester,
                ..
            } = phase
            {
                // Route reply to requester
                route_reply(agent, requester, value, events, replies);

                // Set phase back to RunningBody
                if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                    if let ThreadStatus::Suspended(SuspendReason::Handle { phase, .. }) =
                        &mut t.status
                    {
                        *phase = HandlePhase::RunningBody { body_thread };
                    }
                }
            }
        }
        Signal::HandleBreak(value) => {
            // Cancel body thread
            if let HandlePhase::RunningHandler { body_thread, .. } = &phase {
                events.push(Event {
                    agent_id: agent.agent_id.clone(),
                    kind: EventKind::CancelThread(*body_thread),
                });
            }
            agent.set_var(dst, value);
            resume_thread(agent, owner_thread_id, events);
        }
        Signal::FnReturn(value) => {
            // Cancel body thread and propagate FnReturn
            if let HandlePhase::RunningHandler { body_thread, .. } = &phase {
                events.push(Event {
                    agent_id: agent.agent_id.clone(),
                    kind: EventKind::CancelThread(*body_thread),
                });
            }
            finish_thread(agent, owner_thread_id, Signal::FnReturn(value), events);
        }
        _ => {}
    }
}

/// Process signal from a completed HandlerTarget (body) thread.
pub fn process_body_signal(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    signal: Signal,
    events: &mut Vec<Event>,
) {
    let (hid, dst) = match agent.threads.get(&owner_thread_id) {
        Some(t) => match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle {
                handle_def_id,
                dst,
                ..
            }) => (*handle_def_id, *dst),
            _ => return,
        },
        None => return,
    };

    let handle_def = module
        .handles
        .iter()
        .find(|h| h.id == hid)
        .expect("handle def not found");

    match signal {
        Signal::Normal(value) => {
            if let Some(then_tid) = handle_def.then {
                // Bind body result to then's param
                let ir_thread = module
                    .threads
                    .iter()
                    .find(|t| t.id == then_tid)
                    .expect("then thread not found");
                if let Some(param) = ir_thread.params.first() {
                    agent.set_var(*param, value);
                }
                // Update phase
                if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                    if let ThreadStatus::Suspended(SuspendReason::Handle { phase, .. }) =
                        &mut t.status
                    {
                        *phase = HandlePhase::RunningThen {
                            then_thread: then_tid,
                        };
                    }
                }
                spawn_child_thread(
                    agent,
                    then_tid,
                    crate::ir::ThreadKind::HandleThen,
                    owner_thread_id,
                    events,
                );
            } else {
                // No then clause — set dst and resume parent
                agent.set_var(dst, value);
                resume_thread(agent, owner_thread_id, events);
            }
        }
        Signal::FnReturn(value) => {
            finish_thread(agent, owner_thread_id, Signal::FnReturn(value), events);
        }
        _ => {}
    }
}

/// Process signal from a completed HandleThen thread.
pub fn process_then_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    signal: Signal,
    events: &mut Vec<Event>,
) {
    let dst = match agent.threads.get(&owner_thread_id) {
        Some(t) => match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle { dst, .. }) => *dst,
            _ => return,
        },
        None => return,
    };

    match signal {
        Signal::Normal(value) => {
            agent.set_var(dst, value);
            resume_thread(agent, owner_thread_id, events);
        }
        Signal::FnReturn(value) => {
            finish_thread(agent, owner_thread_id, Signal::FnReturn(value), events);
        }
        _ => {}
    }
}

/// Route a reply to the requester (internal → direct resume, external → OutgoingReply).
fn route_reply(
    agent: &mut AgentState,
    requester: &RequestOrigin,
    value: Value,
    events: &mut Vec<Event>,
    replies: &mut Vec<OutgoingReply>,
) {
    if requester.from_agent_id == agent.agent_id {
        // Internal: find waiting thread and resume directly
        if let Some(waiting_tid) = event::find_request_thread(agent, &requester.request_id) {
            if let Some(ThreadStatus::Suspended(SuspendReason::Request { dst, .. })) =
                agent.threads.get(&waiting_tid).map(|t| &t.status)
            {
                let dst = *dst;
                agent.set_var(dst, value);
                resume_thread(agent, waiting_tid, events);
            }
        }
    } else {
        // External: push outgoing reply
        replies.push(OutgoingReply {
            to_agent_id: requester.from_agent_id.clone(),
            to_agent_where: requester.from_agent_where.clone(),
            request_id: requester.request_id.clone(),
            value,
        });
    }
}
