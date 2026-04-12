use crate::ir::IRModule;
use crate::value::Value;

use super::agent::AgentState;
use super::signal::Signal;
use super::thread::{SuspendReason, ThreadState, ThreadStatus};

/// Execute IPar instruction.
pub fn handle_ipar(
    agent: &mut AgentState,
    _module: &IRModule,
    thread_id: u32,
    dst: u32,
    tids: &[u32],
) {
    let mut branch_threads = Vec::with_capacity(tids.len());

    // Create all BLOCK child threads
    for &tid in tids {
        let block_thread = ThreadState::new(tid, crate::ir::ThreadKind::Block, Some(thread_id));
        agent.threads.insert(tid, block_thread);
        branch_threads.push(tid);
    }

    // Suspend parent
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Suspended(SuspendReason::Par {
            branch_threads: branch_threads.clone(),
            results: vec![None; branch_threads.len()],
            dst,
        });
    }

    // All branch threads are Running — cooperative scheduler will execute them.
}

/// Process signal from a completed BLOCK (par branch) thread.
/// Returns a list of thread IDs that should receive CancelThread events.
pub fn process_par_branch_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    branch_tid: u32,
    signal: Signal,
) -> Vec<u32> {
    // Defensive: owner may have been cancelled/removed already
    let owner = match agent.threads.get(&owner_thread_id) {
        Some(t) => t,
        None => return vec![],
    };

    // If the owner is no longer in Par suspension, drop the signal
    if !matches!(
        owner.status,
        ThreadStatus::Suspended(SuspendReason::Par { .. })
    ) {
        return vec![];
    }

    match signal {
        Signal::Normal(value) => {
            // Find branch index and store result
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
                // All branches complete — collect results
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
                if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                    t.status = ThreadStatus::Running;
                }
            }
            vec![]
        }
        Signal::FnReturn(value) => {
            let cancels = other_branch_tids(agent, owner_thread_id, branch_tid);
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::FnReturn(value));
            }
            cancels
        }
        Signal::HandleBreak(value) => {
            let cancels = other_branch_tids(agent, owner_thread_id, branch_tid);
            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::HandleBreak(value));
            }
            cancels
        }
        // Cancelled or other signals — silently absorbed
        _ => vec![],
    }
}

/// Collect thread IDs of all par branches except `except_tid`.
fn other_branch_tids(agent: &AgentState, owner_thread_id: u32, except_tid: u32) -> Vec<u32> {
    let t = match agent.threads.get(&owner_thread_id) {
        Some(t) => t,
        None => return vec![],
    };
    if let ThreadStatus::Suspended(SuspendReason::Par { branch_threads, .. }) = &t.status {
        branch_threads
            .iter()
            .filter(|&&tid| tid != except_tid)
            .copied()
            .collect()
    } else {
        vec![]
    }
}
