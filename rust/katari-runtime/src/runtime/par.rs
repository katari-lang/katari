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
pub fn process_par_branch_signal(
    agent: &mut AgentState,
    owner_thread_id: u32,
    branch_tid: u32,
    signal: Signal,
) {
    match signal {
        Signal::Normal(value) => {
            // Find branch index and store result
            let all_done = {
                let t = agent.threads.get_mut(&owner_thread_id).expect("owner must exist");
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

            // Remove completed branch thread
            agent.threads.remove(&branch_tid);

            if all_done {
                // All branches complete — collect results
                let (dst, results) = {
                    let t = agent.threads.get_mut(&owner_thread_id).expect("owner must exist");
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
        }
        Signal::FnReturn(value) => {
            // Terminate other branches
            terminate_other_branches(agent, owner_thread_id, branch_tid);
            agent.threads.remove(&branch_tid);

            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::FnReturn(value));
            }
        }
        Signal::HandleBreak(value) => {
            terminate_other_branches(agent, owner_thread_id, branch_tid);
            agent.threads.remove(&branch_tid);

            if let Some(t) = agent.threads.get_mut(&owner_thread_id) {
                t.status = ThreadStatus::Completed(Signal::HandleBreak(value));
            }
        }
        _ => {
            agent.threads.remove(&branch_tid);
        }
    }
}

/// Terminate all par branches except the one that produced the signal.
fn terminate_other_branches(agent: &mut AgentState, owner_thread_id: u32, except_tid: u32) {
    let branch_tids: Vec<u32> = {
        let t = agent.threads.get(&owner_thread_id).expect("owner must exist");
        if let ThreadStatus::Suspended(SuspendReason::Par { branch_threads, .. }) = &t.status {
            branch_threads
                .iter()
                .filter(|&&tid| tid != except_tid)
                .copied()
                .collect()
        } else {
            vec![]
        }
    };

    for tid in branch_tids {
        // TODO: recursively terminate child threads and child agents
        agent.threads.remove(&tid);
    }
}
