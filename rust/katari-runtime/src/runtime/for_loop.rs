use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::event::Event;
use super::execute::{finish_thread, resume_thread, spawn_child_thread};
use super::signal::Signal;
use super::thread::{SuspendReason, ThreadStatus};

/// Execute For instruction: init state, suspend parent, start first iteration.
pub fn setup(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    dst: u32,
    fid: u32,
    events: &mut Vec<Event>,
) {
    let for_def = module
        .fors
        .iter()
        .find(|f| f.id == fid)
        .expect("for def not found");

    // Initialize state variables
    for (sv, iv) in for_def
        .state_vars
        .iter()
        .zip(for_def.state_inits.iter())
    {
        let val = agent.get_var(*iv);
        agent.set_var(*sv, val);
    }

    // Calculate min array length
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

    // Suspend parent
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::For {
            for_def_id: fid,
            current_index: 0,
            min_length: min_len,
            dst,
        });
    }

    if min_len > 0 {
        start_iteration(agent, module, thread_id, fid, 0, events);
    } else {
        finish_loop(agent, module, thread_id, fid, dst, events);
    }
}

/// Start a single iteration of the for loop.
fn start_iteration(
    agent: &mut AgentState,
    module: &IRModule,
    parent_thread_id: u32,
    fid: u32,
    index: u32,
    events: &mut Vec<Event>,
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

    spawn_child_thread(
        agent,
        for_def.body,
        crate::ir::ThreadKind::ForBody,
        parent_thread_id,
        events,
    );
}

/// Process signal from a completed ForBody thread.
pub fn process_body_signal(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    signal: Signal,
    events: &mut Vec<Event>,
) {
    let (fid, current_index, min_length, dst) = match agent.threads.get(&owner_thread_id) {
        Some(t) => match &t.status {
            ThreadStatus::Suspended(SuspendReason::For {
                for_def_id,
                current_index,
                min_length,
                dst,
            }) => (*for_def_id, *current_index, *min_length, *dst),
            _ => return,
        },
        None => return,
    };

    match signal {
        Signal::ForContinue(mutations) => {
            for (sv, nv) in &mutations {
                let val = agent.get_var(*nv);
                agent.set_var(*sv, val);
            }
            advance(
                agent,
                module,
                owner_thread_id,
                fid,
                current_index,
                min_length,
                dst,
                events,
            );
        }
        Signal::Normal(_) => {
            // Treat as ForContinue([]) — no mutations
            advance(
                agent,
                module,
                owner_thread_id,
                fid,
                current_index,
                min_length,
                dst,
                events,
            );
        }
        Signal::ForBreak(value) => {
            agent.set_var(dst, value);
            resume_thread(agent, owner_thread_id, events);
        }
        Signal::FnReturn(value) => {
            finish_thread(agent, owner_thread_id, Signal::FnReturn(value), events);
        }
        Signal::HandleBreak(value) => {
            finish_thread(
                agent,
                owner_thread_id,
                Signal::HandleBreak(value),
                events,
            );
        }
        _ => {}
    }
}

/// Advance to the next iteration or finish.
fn advance(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    fid: u32,
    current_index: u32,
    min_length: u32,
    dst: u32,
    events: &mut Vec<Event>,
) {
    let next_index = current_index + 1;
    if next_index < min_length {
        if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
            t.status = ThreadStatus::Suspended(SuspendReason::For {
                for_def_id: fid,
                current_index: next_index,
                min_length,
                dst,
            });
        }
        start_iteration(agent, module, owner_thread_id, fid, next_index, events);
    } else {
        finish_loop(agent, module, owner_thread_id, fid, dst, events);
    }
}

/// Finish for loop (all iterations done or empty array).
fn finish_loop(
    agent: &mut AgentState,
    module: &IRModule,
    owner_thread_id: u32,
    fid: u32,
    dst: u32,
    events: &mut Vec<Event>,
) {
    let for_def = module
        .fors
        .iter()
        .find(|f| f.id == fid)
        .expect("for def not found");

    if let Some(then_tid) = for_def.then {
        spawn_child_thread(
            agent,
            then_tid,
            crate::ir::ThreadKind::ForThen,
            owner_thread_id,
            events,
        );
    } else {
        agent.set_var(dst, Value::Null);
        resume_thread(agent, owner_thread_id, events);
    }
}

/// Process signal from a completed ForThen thread.
pub fn process_then_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    signal: Signal,
    events: &mut Vec<Event>,
) {
    let dst = match agent.threads.get(&owner_thread_id) {
        Some(t) => match &t.status {
            ThreadStatus::Suspended(SuspendReason::For { dst, .. }) => *dst,
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
