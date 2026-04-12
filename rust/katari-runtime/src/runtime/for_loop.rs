use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::signal::Signal;
use super::thread::{SuspendReason, ThreadState, ThreadStatus};

/// Execute IFor instruction.
pub fn handle_ifor(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    fid: u32,
) {
    let for_def = module
        .fors
        .iter()
        .find(|f| f.id == fid)
        .expect("for def not found");

    // 1. Initialize state variables
    for (sv, iv) in for_def
        .state_vars
        .iter()
        .zip(for_def.state_inits.iter())
    {
        let val = agent.get_var(*iv);
        agent.set_var(*sv, val);
    }

    // 2. Calculate min array length
    let min_len = for_def
        .arrays
        .iter()
        .map(|arr_var| {
            agent
                .get_var(*arr_var)
                .as_array()
                .map(|a| a.len())
                .unwrap_or(0)
        })
        .min()
        .unwrap_or(0) as u32;

    // 3. Suspend parent
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::For {
            for_def_id: fid,
            current_index: 0,
            min_length: min_len,
            dst,
        });
    }

    // 4. Start first iteration or finish
    if min_len > 0 {
        start_for_iteration(agent, module, thread_id, fid, 0);
    } else {
        finish_for(agent, module, thread_id, fid, dst);
    }
}

/// Start a single iteration of the for loop.
pub fn start_for_iteration(
    agent: &mut AgentState,
    module: &IRModule,
    parent_thread_id: u32,
    fid: u32,
    index: u32,
) {
    let for_def = module
        .fors
        .iter()
        .find(|f| f.id == fid)
        .expect("for def not found");

    // Bind element variables
    for (i, iter_var) in for_def.iter_vars.iter().enumerate() {
        if let Some(arr) = agent.get_var(for_def.arrays[i]).as_array() {
            if let Some(elem) = arr.get(index as usize) {
                agent.set_var(*iter_var, elem.clone());
            }
        }
    }

    // Create FOR_BODY child thread
    let body_tid = for_def.body;
    let body_thread = ThreadState::new(
        body_tid,
        crate::ir::ThreadKind::ForBody,
        Some(parent_thread_id),
    );
    agent.threads.insert(body_tid, body_thread);

    // Body is now Running — the event loop will pick it up.
}

/// Process signal from FOR_BODY.
pub fn process_for_body_signal(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    signal: Signal,
) {
    // Defensive: owner may have been cancelled/removed already
    let (fid, current_index, min_length, dst) = {
        let t = match agent.threads.get(&owner_thread_id) {
            Some(t) => t,
            None => return,
        };
        match &t.status {
            ThreadStatus::Suspended(SuspendReason::For {
                for_def_id,
                current_index,
                min_length,
                dst,
            }) => (*for_def_id, *current_index, *min_length, *dst),
            _ => return,
        }
    };

    let for_def = match module.fors.iter().find(|f| f.id == fid) {
        Some(f) => f,
        None => return,
    };

    // Note: body thread removal is handled by harvest
    let _ = for_def.body;

    match signal {
        Signal::ForContinue(mutations) => {
            // Apply mutations
            for (sv, nv) in &mutations {
                let val = agent.get_var(*nv);
                agent.set_var(*sv, val);
            }
            advance_for(
                agent,
                module,
                owner_thread_id,
                fid,
                current_index,
                min_length,
                dst,
            );
        }
        Signal::Normal(_) => {
            // Treat as ForContinue([]) — no mutations
            advance_for(
                agent,
                module,
                owner_thread_id,
                fid,
                current_index,
                min_length,
                dst,
            );
        }
        Signal::ForBreak(value) => {
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
        Signal::HandleBreak(value) => {
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::HandleBreak(value));
            }
        }
        _ => {}
    }
}

/// Advance to the next for iteration or finish.
fn advance_for(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    fid: u32,
    current_index: u32,
    min_length: u32,
    dst: u32,
) {
    let next_index = current_index + 1;
    if next_index < min_length {
        // Update index in suspend reason
        if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
            t.status = ThreadStatus::Suspended(SuspendReason::For {
                for_def_id: fid,
                current_index: next_index,
                min_length,
                dst,
            });
        }
        start_for_iteration(agent, module, owner_thread_id, fid, next_index);
    } else {
        finish_for(agent, module, owner_thread_id, fid, dst);
    }
}

/// Finish for loop (all iterations done or empty array).
fn finish_for(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    fid: u32,
    dst: u32,
) {
    let for_def = module
        .fors
        .iter()
        .find(|f| f.id == fid)
        .expect("for def not found");

    if let Some(then_tid) = for_def.then {
        // Create FOR_THEN child thread
        let then_thread = ThreadState::new(
            then_tid,
            crate::ir::ThreadKind::ForThen,
            Some(owner_thread_id),
        );
        agent.threads.insert(then_tid, then_thread);
        // Then thread is Running — event loop will pick it up.
    } else {
        agent.set_var(dst, Value::Null);
        if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
            t.status = ThreadStatus::Running;
        }
    }
}

/// Process signal from FOR_THEN.
pub fn process_for_then_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    _then_tid: u32,
    signal: Signal,
) {
    let dst = {
        let t = match agent.threads.get(&owner_thread_id) {
            Some(t) => t,
            None => return,
        };
        match &t.status {
            ThreadStatus::Suspended(SuspendReason::For { dst, .. }) => *dst,
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
