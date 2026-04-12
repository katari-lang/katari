use std::collections::HashMap;

use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::signal::Signal;
use super::thread::{
    HandlePhase, PendingRequest, RequestOrigin, SuspendReason, ThreadState, ThreadStatus,
};

/// Execute IHandle instruction.
pub fn handle_ihandle(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    hid: u32,
) {
    let handle_def = module
        .handles
        .iter()
        .find(|h| h.id == hid)
        .expect("handle def not found");

    // 1. Initialize state variables
    let mut state_vars = HashMap::new();
    for (sv, iv) in handle_def
        .state_vars
        .iter()
        .zip(handle_def.state_inits.iter())
    {
        let val = agent.get_var(*iv);
        state_vars.insert(*sv, val);
    }

    // 2. Create HANDLER_TARGET child thread
    let body_tid = handle_def.body;
    let body_thread = ThreadState::new(
        body_tid,
        crate::ir::ThreadKind::HandlerTarget,
        Some(thread_id),
    );
    agent.threads.insert(body_tid, body_thread);

    // 3. Suspend parent with all handle state in SuspendReason
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

    // Body thread is now Running — the event loop will pick it up.
}

/// Handle a request that was routed to this thread's handle scope.
/// Only called when the handle is in RunningBody phase (checked by applicability).
pub fn handle_request_in_scope(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    handler_tid: u32,
    request: PendingRequest,
) {
    let t = agent
        .threads
        .get(&thread_id)
        .expect("owner thread must exist");

    let body_thread = match &t.status {
        ThreadStatus::Suspended(SuspendReason::Handle {
            phase: HandlePhase::RunningBody { body_thread },
            ..
        }) => *body_thread,
        _ => return, // Not in RunningBody — event should not have been dispatched
    };

    // 1. Copy state vars to agent.vars
    if let ThreadStatus::Suspended(SuspendReason::Handle { state_vars, .. }) = &t.status {
        for (sv, val) in state_vars {
            agent.vars.insert(*sv, val.clone());
        }
    }

    // 2. Bind request args to handler params
    let handler_ir = module
        .threads
        .iter()
        .find(|t| t.id == handler_tid)
        .expect("handler thread not found");
    for (param, arg) in handler_ir.params.iter().zip(request.args.iter()) {
        agent.vars.insert(*param, arg.clone());
    }

    // 3. Create handler thread
    let handler_thread = ThreadState::new(
        handler_tid,
        crate::ir::ThreadKind::RequestHandler,
        Some(thread_id),
    );
    agent.threads.insert(handler_tid, handler_thread);

    // 4. Update phase to RunningHandler
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

    // Handler thread is now Running — the event loop will pick it up.
}

/// Process signal from a completed REQUEST_HANDLER thread.
/// Returns `(reply_info, cancel_list)`:
/// - `reply_info`: Some if a reply needs to be routed to the requester.
/// - `cancel_list`: Thread IDs that should receive CancelThread events.
pub fn process_handler_signal(
    agent: &mut AgentState,
    _module: &IRModule,
    owner_thread_id: u32,
    signal: Signal,
) -> (Option<(RequestOrigin, Value)>, Vec<u32>) {
    let (_hid, dst, phase) = {
        let t = match agent.threads.get(&owner_thread_id) {
            Some(t) => t,
            None => return (None, vec![]),
        };
        match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle {
                handle_def_id,
                dst,
                phase,
                ..
            }) => (*handle_def_id, *dst, phase.clone()),
            _ => return (None, vec![]),
        }
    };

    match signal {
        Signal::Normal(value) => {
            // Treat as Continue(value, [])
            process_handler_signal(
                agent,
                _module,
                owner_thread_id,
                Signal::Continue(value, vec![]),
            )
        }
        Signal::Continue(value, mutations) => {
            // 1. Apply mutations to handle state
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

            let mut reply_info = None;

            if let HandlePhase::RunningHandler {
                body_thread,
                ref requester,
                ..
            } = phase
            {
                reply_info = Some((requester.clone(), value));

                // Handler thread is already Completed — harvest removes it.
                // Set phase back to RunningBody.
                if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                    if let ThreadStatus::Suspended(SuspendReason::Handle { phase, .. }) =
                        &mut t.status
                    {
                        *phase = HandlePhase::RunningBody { body_thread };
                    }
                }
            }

            (reply_info, vec![])
        }
        Signal::HandleBreak(value) => {
            // Cancel body thread (handler is already Completed/removed by harvest)
            let cancels = match &phase {
                HandlePhase::RunningHandler { body_thread, .. } => vec![*body_thread],
                _ => vec![],
            };

            agent.set_var(dst, value);
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Running;
            }
            (None, cancels)
        }
        Signal::FnReturn(value) => {
            // Cancel body thread and propagate FnReturn
            let cancels = match &phase {
                HandlePhase::RunningHandler { body_thread, .. } => vec![*body_thread],
                _ => vec![],
            };

            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::FnReturn(value));
            }
            (None, cancels)
        }
        // Cancelled or other — silently absorbed
        _ => (None, vec![]),
    }
}

/// Process signal from a completed HANDLER_TARGET (body) thread.
pub fn process_body_signal(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    signal: Signal,
) {
    let (hid, dst) = {
        let t = match agent.threads.get(&owner_thread_id) {
            Some(t) => t,
            None => return, // owner already removed (cancelled)
        };
        match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle {
                handle_def_id,
                dst,
                ..
            }) => (*handle_def_id, *dst),
            _ => return,
        }
    };

    let handle_def = module
        .handles
        .iter()
        .find(|h| h.id == hid)
        .expect("handle def not found");

    match signal {
        Signal::Normal(value) => {
            // Body completed normally
            if let Some(then_tid) = handle_def.then {
                // Run then clause
                let ir_thread = module
                    .threads
                    .iter()
                    .find(|t| t.id == then_tid)
                    .expect("then thread not found");
                // Bind body result to then's param
                if let Some(param) = ir_thread.params.first() {
                    agent.set_var(*param, value);
                }
                let then_thread = ThreadState::new(
                    then_tid,
                    crate::ir::ThreadKind::HandleThen,
                    Some(owner_thread_id),
                );
                agent.threads.insert(then_tid, then_thread);

                if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                    if let ThreadStatus::Suspended(SuspendReason::Handle { phase, .. }) =
                        &mut t.status
                    {
                        *phase = HandlePhase::RunningThen {
                            then_thread: then_tid,
                        };
                    }
                }
            } else {
                // No then clause — set dst and resume parent
                agent.set_var(dst, value);
                if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                    t.status = ThreadStatus::Running;
                }
            }
        }
        Signal::FnReturn(value) => {
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::FnReturn(value));
            }
        }
        _ => {}
    }
}

/// Process signal from a completed HANDLE_THEN thread.
pub fn process_then_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    _then_tid: u32,
    signal: Signal,
) {
    let dst = {
        let t = match agent.threads.get(&owner_thread_id) {
            Some(t) => t,
            None => return, // owner already removed (cancelled)
        };
        match &t.status {
            ThreadStatus::Suspended(SuspendReason::Handle { dst, .. }) => *dst,
            _ => return,
        }
    };

    match signal {
        Signal::Normal(value) => {
            agent.set_var(dst, value);
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Running;
            }
        }
        Signal::FnReturn(value) => {
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::FnReturn(value));
            }
        }
        _ => {}
    }
}
