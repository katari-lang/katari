use crate::value::Value;

use super::agent::AgentState;
use super::event::{Event, EventKind};
use super::execute::{finish_thread, resume_thread, spawn_child_thread};
use super::signal::Signal;
use super::thread::{SuspendReason, ThreadStatus};

/// Execute Par instruction: suspend parent, spawn all branch threads.
pub fn setup(
    agent: &mut AgentState,
    thread_id: u32,
    dst: u32,
    tids: &[u32],
    events: &mut Vec<Event>,
) {
    let branch_threads: Vec<u32> = tids.to_vec();

    // Suspend parent
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Par {
            branch_threads: branch_threads.clone(),
            results: vec![None; tids.len()],
            dst,
        });
    }

    // Spawn all branch threads
    for &tid in tids {
        spawn_child_thread(
            agent,
            tid,
            crate::ir::ThreadKind::Block,
            thread_id,
            events,
        );
    }
}

/// Process signal from a completed Block (par branch) thread.
pub fn process_branch_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    branch_tid: u32,
    signal: Signal,
    events: &mut Vec<Event>,
) {
    let owner = match agent.threads.get(&owner_thread_id) {
        Some(t) => t,
        None => return,
    };

    if !matches!(
        owner.status,
        ThreadStatus::Suspended(SuspendReason::Par { .. })
    ) {
        return;
    }

    match signal {
        Signal::Normal(value) => {
            let all_done = {
                let t = agent
                    .threads
                    .get_mut(&owner_thread_id)
                    .expect("owner checked above");
                if let ThreadStatus::Suspended(SuspendReason::Par {
                    branch_threads,
                    results,
                    ..
                }) = &mut t.status
                {
                    if let Some(idx) = branch_threads.iter().position(|&tid| tid == branch_tid) {
                        results[idx] = Some(value);
                    }
                    results.iter().all(|r| r.is_some())
                } else {
                    false
                }
            };

            if all_done {
                let (dst, results) = {
                    let t = agent
                        .threads
                        .get_mut(&owner_thread_id)
                        .expect("owner checked above");
                    if let ThreadStatus::Suspended(SuspendReason::Par { dst, results, .. }) =
                        &mut t.status
                    {
                        let d = *dst;
                        let r: Vec<Value> = results.iter().map(|v| v.clone().unwrap()).collect();
                        (d, r)
                    } else {
                        unreachable!()
                    }
                };

                agent.set_var(dst, Value::Array(results));
                resume_thread(agent, owner_thread_id, events);
            }
        }
        Signal::FnReturn(value) => {
            cancel_other_branches(agent, owner_thread_id, branch_tid, events);
            finish_thread(agent, owner_thread_id, Signal::FnReturn(value), events);
        }
        Signal::HandleBreak(value) => {
            cancel_other_branches(agent, owner_thread_id, branch_tid, events);
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

/// Push CancelThread events for all par branches except the given one.
fn cancel_other_branches(
    agent: &AgentState,
    owner_thread_id: u32,
    except_tid: u32,
    events: &mut Vec<Event>,
) {
    if let Some(t) = agent.threads.get(&owner_thread_id) {
        if let ThreadStatus::Suspended(SuspendReason::Par { branch_threads, .. }) = &t.status {
            for &tid in branch_threads {
                if tid != except_tid {
                    events.push(Event {
                        agent_id: agent.agent_id.clone(),
                        kind: EventKind::CancelThread(tid),
                    });
                }
            }
        }
    }
}
