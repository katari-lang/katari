pub mod agent;
pub mod for_loop;
pub mod handle;
pub mod par;
pub mod primitive;
pub mod request;
pub mod signal;
pub mod thread;

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::ir::instruction::Instruction;
use crate::ir::{ConstVal, IRModule, ThreadKind};
use crate::value::{self, Value};

use self::agent::{AgentState, AgentStatus};
use self::signal::Signal;
use self::thread::{HandlePhase, SuspendReason, ThreadState, ThreadStatus};

// ---------------------------------------------------------------------------
// Runtime — manages modules and agents
// ---------------------------------------------------------------------------

/// Result of an agent's event loop iteration.
pub enum RunResult {
    /// Root thread completed with Normal.
    Completed(Value),
    /// Root thread completed with FnReturn.
    Returned(Value),
    /// Agent is blocked waiting for external events.
    Blocked,
}

/// Katari Runtime — manages modules and agents.
pub struct Runtime {
    /// Current (latest) module. Each agent keeps its own Arc reference
    /// to the module it was created with, so re-applying a new module
    /// does not affect already-running agents.
    pub module: Option<Arc<IRModule>>,
    pub agents: HashMap<String, AgentState>,
    pub agent_name_map: HashMap<String, u32>,
    pub schemas: HashMap<String, serde_json::Value>,
    pub self_base_url: String,
}

impl Runtime {
    pub fn new(base_url: String) -> Self {
        Self {
            module: None,
            agents: HashMap::new(),
            agent_name_map: HashMap::new(),
            schemas: HashMap::new(),
            self_base_url: base_url,
        }
    }

    pub fn apply_module(
        &mut self,
        module: IRModule,
        name_map: HashMap<String, u32>,
        schemas: HashMap<String, serde_json::Value>,
    ) {
        self.agent_name_map = name_map;
        self.schemas = schemas;
        self.module = Some(Arc::new(module));
    }

    /// Spawn an agent by name (for POST /run).
    pub fn run_agent(
        &mut self,
        agent_name: &str,
        args: Vec<Value>,
    ) -> Result<String, String> {
        let module = self.module.clone().ok_or("no module loaded")?;

        let agent_def_id = self
            .agent_name_map
            .get(agent_name)
            .copied()
            .ok_or_else(|| format!("agent '{}' not found", agent_name))?;

        let agent_def = module
            .agents
            .iter()
            .find(|a| a.id == agent_def_id)
            .ok_or_else(|| format!("agent def {} not found", agent_def_id))?;

        let entry_tid = agent_def.entry;

        let agent_id = format!("agent-{}", uuid::Uuid::new_v4());
        let root_agent_id = format!("root-{}", uuid::Uuid::new_v4());

        let mut agent_state = AgentState::new(
            agent_id.clone(),
            agent_def_id,
            entry_tid,
            root_agent_id,
            String::new(),
            HashSet::new(),
            Arc::clone(&module),
        );

        // Bind args to entry thread params
        if let Some(ir_t) = module.threads.iter().find(|t| t.id == entry_tid) {
            for (param, arg) in ir_t.params.iter().zip(args.iter()) {
                agent_state.set_var(*param, arg.clone());
            }
        }

        let root_thread = ThreadState::new(entry_tid, ThreadKind::FnBody, None);
        agent_state.threads.insert(entry_tid, root_thread);

        self.agents.insert(agent_id.clone(), agent_state);

        // Run the global event loop (all agents that can make progress)
        self.run_event_loop();

        Ok(agent_id)
    }

    // -----------------------------------------------------------------------
    // Global flat event loop
    // -----------------------------------------------------------------------

    /// Run the global event loop until no agent can make progress.
    /// Processes ALL agents, not just one.
    pub fn run_event_loop(&mut self) {
        for _ in 0..100_000 {
            let mut progress = false;
            progress |= self.step_all_agents();
            progress |= self.spawn_pending_children();
            progress |= self.collect_completed_children();
            if !progress {
                break;
            }
        }
    }

    /// Run one round of the cooperative loop for every agent that can make progress.
    fn step_all_agents(&mut self) -> bool {
        let agent_ids: Vec<String> = self
            .agents
            .iter()
            .filter(|(_, a)| a.can_make_progress())
            .map(|(id, _)| id.clone())
            .collect();

        let mut any_progress = false;

        for agent_id in agent_ids {
            let module = match self.agents.get(&agent_id) {
                Some(a) if a.status == AgentStatus::Running => Arc::clone(&a.module),
                _ => continue,
            };

            let agent = match self.agents.get_mut(&agent_id) {
                Some(a) => a,
                None => continue,
            };

            let result = run_agent_loop(agent, &module);

            match result {
                RunResult::Completed(_) | RunResult::Returned(_) => {
                    agent.status = AgentStatus::Completed;
                }
                RunResult::Blocked => {}
            }
            any_progress = true;
        }

        any_progress
    }

    /// Find agents with pending ICall suspensions and spawn child agents.
    fn spawn_pending_children(&mut self) -> bool {
        let mut spawns: Vec<PendingSpawn> = Vec::new();

        for (agent_id, agent) in &self.agents {
            if agent.status != AgentStatus::Running {
                continue;
            }
            for (_, thread) in &agent.threads {
                if let ThreadStatus::Suspended(SuspendReason::Call {
                    child_agent_id,
                    agent_def_id,
                    args,
                    ..
                }) = &thread.status
                {
                    if !self.agents.contains_key(child_agent_id.as_str()) {
                        if let Some(agent_def) =
                            agent.module.agents.iter().find(|a| a.id == *agent_def_id)
                        {
                            spawns.push(PendingSpawn {
                                parent_agent_id: agent_id.clone(),
                                child_agent_id: child_agent_id.clone(),
                                agent_def_id: *agent_def_id,
                                entry_tid: agent_def.entry,
                                args: args.clone(),
                            });
                        }
                    }
                }
            }
        }

        let any_spawned = !spawns.is_empty();

        for spawn in spawns {
            let module = self
                .agents
                .get(&spawn.parent_agent_id)
                .map(|a| Arc::clone(&a.module))
                .unwrap();

            let parent_available = self
                .agents
                .get(&spawn.parent_agent_id)
                .map(|a| a.parent_available_requests.clone())
                .unwrap_or_default();

            let mut child = AgentState::new(
                spawn.child_agent_id.clone(),
                spawn.agent_def_id,
                spawn.entry_tid,
                spawn.parent_agent_id.clone(),
                self.self_base_url.clone(),
                parent_available,
                Arc::clone(&module),
            );

            // Bind args
            if let Some(ir_t) = module.threads.iter().find(|t| t.id == spawn.entry_tid) {
                for (param, arg) in ir_t.params.iter().zip(spawn.args.iter()) {
                    child.set_var(*param, arg.clone());
                }
            }

            let root_thread = ThreadState::new(spawn.entry_tid, ThreadKind::FnBody, None);
            child.threads.insert(spawn.entry_tid, root_thread);

            self.agents.insert(spawn.child_agent_id, child);
        }

        any_spawned
    }

    /// Collect results from completed child agents and resume parent threads.
    fn collect_completed_children(&mut self) -> bool {
        let mut completions: Vec<(String, String, Value)> = Vec::new();

        for (agent_id, agent) in &self.agents {
            if agent.status != AgentStatus::Completed {
                continue;
            }
            let parent_id = &agent.parent_agent_id;
            if let Some(parent) = self.agents.get(parent_id) {
                if parent.children.contains_key(agent_id) {
                    let result = get_agent_result(agent);
                    completions.push((agent_id.clone(), parent_id.clone(), result));
                }
            }
        }

        let any_collected = !completions.is_empty();

        for (child_id, parent_id, result) in completions {
            if let Some(parent) = self.agents.get_mut(&parent_id) {
                request::on_child_return(parent, &child_id, result);
            }
            self.agents.remove(&child_id);
        }

        any_collected
    }

    // -----------------------------------------------------------------------
    // Agent status queries
    // -----------------------------------------------------------------------

    /// Get the result value from a completed agent (convenience for tests/API).
    pub fn get_agent_result(&self, agent_id: &str) -> Value {
        self.agents
            .get(agent_id)
            .map(|a| get_agent_result(a))
            .unwrap_or(Value::Null)
    }

    /// Get the status of an agent: ("running"|"completed"|"error", Option<Value>)
    pub fn get_agent_status(&self, agent_id: &str) -> Option<(&str, Option<Value>)> {
        let agent = self.agents.get(agent_id)?;
        let root = agent.threads.get(&agent.root_thread)?;
        match &root.status {
            ThreadStatus::Completed(Signal::Normal(v))
            | ThreadStatus::Completed(Signal::FnReturn(v)) => {
                Some(("completed", Some(v.clone())))
            }
            ThreadStatus::Completed(_) => Some(("error", None)),
            _ => Some(("running", None)),
        }
    }
}

struct PendingSpawn {
    parent_agent_id: String,
    child_agent_id: String,
    agent_def_id: u32,
    entry_tid: u32,
    args: Vec<Value>,
}

/// Get the result value from a completed agent.
fn get_agent_result(agent: &AgentState) -> Value {
    agent
        .threads
        .get(&agent.root_thread)
        .map(|root| match &root.status {
            ThreadStatus::Completed(Signal::Normal(v))
            | ThreadStatus::Completed(Signal::FnReturn(v)) => v.clone(),
            _ => Value::Null,
        })
        .unwrap_or(Value::Null)
}

// ---------------------------------------------------------------------------
// Per-agent cooperative event loop
// ---------------------------------------------------------------------------

/// Run an agent's cooperative event loop until no more internal progress can be made.
pub fn run_agent_loop(agent: &mut AgentState, module: &IRModule) -> RunResult {
    loop {
        // 1. Process completed threads
        if let Some(tid) = find_completed_thread(agent) {
            let is_root = tid == agent.root_thread;
            process_thread_completion(agent, module, tid);

            if is_root || is_root_completed(agent) {
                return match agent.threads.get(&agent.root_thread) {
                    Some(t) => match &t.status {
                        ThreadStatus::Completed(Signal::Normal(v)) => {
                            RunResult::Completed(v.clone())
                        }
                        ThreadStatus::Completed(Signal::FnReturn(v)) => {
                            RunResult::Returned(v.clone())
                        }
                        _ => RunResult::Blocked,
                    },
                    None => RunResult::Blocked,
                };
            }
            continue;
        }

        // 2. Execute a Running thread
        if let Some(tid) = agent.find_running_thread() {
            execute_thread(agent, module, tid);
            continue;
        }

        // 3. Process pending requests in handle scope queues
        if process_pending_request_queues(agent, module) {
            continue;
        }

        // 4. Check if root is completed
        if is_root_completed(agent) {
            return match agent.threads.get(&agent.root_thread) {
                Some(t) => match &t.status {
                    ThreadStatus::Completed(Signal::Normal(v)) => {
                        RunResult::Completed(v.clone())
                    }
                    ThreadStatus::Completed(Signal::FnReturn(v)) => {
                        RunResult::Returned(v.clone())
                    }
                    _ => RunResult::Blocked,
                },
                None => RunResult::Blocked,
            };
        }

        // 5. No more work — agent is blocked
        return RunResult::Blocked;
    }
}

fn is_root_completed(agent: &AgentState) -> bool {
    agent
        .threads
        .get(&agent.root_thread)
        .is_some_and(|t| matches!(t.status, ThreadStatus::Completed(_)))
}

fn find_completed_thread(agent: &AgentState) -> Option<u32> {
    agent
        .threads
        .iter()
        .find(|(tid, t)| {
            matches!(t.status, ThreadStatus::Completed(_)) && **tid != agent.root_thread
        })
        .or_else(|| {
            agent
                .threads
                .iter()
                .find(|(_, t)| matches!(t.status, ThreadStatus::Completed(_)))
        })
        .map(|(id, _)| *id)
}

/// Process a completed thread's signal by dispatching to its parent.
fn process_thread_completion(agent: &mut AgentState, module: &IRModule, thread_id: u32) {
    let (signal, kind, parent_id) = {
        let t = match agent.threads.get(&thread_id) {
            Some(t) => t,
            None => return,
        };
        let signal = match &t.status {
            ThreadStatus::Completed(s) => s.clone(),
            _ => return,
        };
        (signal, t.kind, t.parent)
    };

    match parent_id {
        None => {}
        Some(parent_id) => match kind {
            ThreadKind::Block => {
                par::process_par_branch_signal(agent, parent_id, thread_id, signal);
            }
            ThreadKind::HandlerTarget => {
                handle::process_body_signal(agent, module, parent_id, signal);
            }
            ThreadKind::RequestHandler => {
                handle::process_handler_signal(agent, module, parent_id, signal);
            }
            ThreadKind::HandleThen => {
                handle::process_then_signal(agent, parent_id, thread_id, signal);
            }
            ThreadKind::ForBody => {
                for_loop::process_for_body_signal(agent, module, parent_id, signal);
            }
            ThreadKind::ForThen => {
                for_loop::process_for_then_signal(agent, parent_id, thread_id, signal);
            }
            ThreadKind::FnBody => {}
        },
    }
}

/// Process pending request queues in handle scopes.
fn process_pending_request_queues(agent: &mut AgentState, module: &IRModule) -> bool {
    let pending: Option<(u32, thread::PendingRequest)> = agent
        .threads
        .iter()
        .find_map(|(tid, t)| {
            if let ThreadStatus::Suspended(SuspendReason::Handle {
                phase: HandlePhase::RunningBody { .. },
                request_queue,
                ..
            }) = &t.status
            {
                request_queue.front().map(|req| (*tid, req.clone()))
            } else {
                None
            }
        });

    if let Some((tid, req)) = pending {
        // Pop from queue
        if let Some(t) = agent.threads.get_mut(&tid) {
            if let ThreadStatus::Suspended(SuspendReason::Handle { request_queue, .. }) =
                &mut t.status
            {
                request_queue.pop_front();
            }
        }

        // Find matching handler
        let handler_tid = {
            let t = agent.threads.get(&tid);
            t.and_then(|t| match &t.status {
                ThreadStatus::Suspended(SuspendReason::Handle {
                    handle_def_id, ..
                }) => module
                    .handles
                    .iter()
                    .find(|h| h.id == *handle_def_id)
                    .and_then(|hd| {
                        hd.req_cases
                            .iter()
                            .find(|(rid, _)| *rid == req.req_def_id)
                            .map(|(_, tid)| *tid)
                    }),
                _ => None,
            })
        };

        if let Some(handler_tid) = handler_tid {
            handle::handle_request_in_scope(agent, module, tid, handler_tid, req);
            return true;
        }
    }

    false
}

// ---------------------------------------------------------------------------
// Thread execution
// ---------------------------------------------------------------------------

/// Execute a thread's instructions until it suspends or completes.
pub fn execute_thread(agent: &mut AgentState, module: &IRModule, thread_id: u32) {
    let ir_thread = match module.threads.iter().find(|t| t.id == thread_id) {
        Some(t) => t,
        None => {
            if let Some(t) = agent.threads.get_mut(&thread_id) {
                t.status = ThreadStatus::Completed(Signal::Normal(Value::Null));
            }
            return;
        }
    };

    loop {
        let pc = match agent.threads.get(&thread_id) {
            Some(t) if t.is_running() => t.pc as usize,
            _ => return,
        };

        if pc >= ir_thread.body.len() {
            if let Some(t) = agent.threads.get_mut(&thread_id) {
                t.status = ThreadStatus::Completed(Signal::Normal(Value::Null));
            }
            return;
        }

        let instr = ir_thread.body[pc].clone();

        if let Some(t) = agent.threads.get_mut(&thread_id) {
            t.pc += 1;
        }

        match instr {
            // === Terminal instructions ===
            Instruction::Complete(val) => {
                let v = agent.get_var(val);
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.status = ThreadStatus::Completed(Signal::Normal(v));
                }
                return;
            }
            Instruction::Return(val) => {
                let v = agent.get_var(val);
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.status = ThreadStatus::Completed(Signal::FnReturn(v));
                }
                return;
            }
            Instruction::HandleBreak(val) => {
                let v = agent.get_var(val);
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.status = ThreadStatus::Completed(Signal::HandleBreak(v));
                }
                return;
            }
            Instruction::Continue(val, mutations) => {
                let v = agent.get_var(val);
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.status = ThreadStatus::Completed(Signal::Continue(v, mutations));
                }
                return;
            }
            Instruction::ForBreak(val) => {
                let v = agent.get_var(val);
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.status = ThreadStatus::Completed(Signal::ForBreak(v));
                }
                return;
            }
            Instruction::ForContinue(mutations) => {
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.status = ThreadStatus::Completed(Signal::ForContinue(mutations));
                }
                return;
            }

            // === Control flow ===
            Instruction::Jump(target) => {
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.pc = target;
                }
            }
            Instruction::Branch(cond, then_target, else_target) => {
                let v = agent.get_var(cond);
                let target = if v.is_truthy() {
                    then_target
                } else {
                    else_target
                };
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.pc = target;
                }
            }
            Instruction::Switch(val, cases, default) => {
                let v = agent.get_var(val);
                let target = find_switch_target(&v, &cases, default, &module.consts);
                if let Some(t) = agent.threads.get_mut(&thread_id) {
                    t.pc = target;
                }
            }

            // === Suspension points ===
            Instruction::Handle(dst, hid) => {
                handle::handle_ihandle(agent, module, thread_id, dst, hid);
                return;
            }
            Instruction::For(dst, fid) => {
                for_loop::handle_ifor(agent, module, thread_id, dst, fid);
                return;
            }
            Instruction::Par(dst, tids) => {
                par::handle_ipar(agent, module, thread_id, dst, &tids);
                return;
            }
            Instruction::Call(dst, aid, args) => {
                request::handle_icall(agent, module, thread_id, dst, aid, &args);
                if !agent
                    .threads
                    .get(&thread_id)
                    .is_some_and(|t| t.is_running())
                {
                    return;
                }
            }
            Instruction::Request(dst, rid, args) => {
                request::handle_irequest(agent, module, thread_id, dst, rid, &args);
                return;
            }

            // === Constants & movement ===
            Instruction::LoadConst(dst, cid) => {
                let val = load_const(&module.consts, cid);
                agent.set_var(dst, val);
            }
            Instruction::LoadNull(dst) => {
                agent.set_var(dst, Value::Null);
            }
            Instruction::Move(dst, src) => {
                let v = agent.get_var(src);
                agent.set_var(dst, v);
            }

            // === Object operations ===
            Instruction::NewObject(dst, fields) => {
                let mut obj = indexmap::IndexMap::new();
                for (cid, vid) in fields {
                    let key = const_as_string(&module.consts, cid);
                    let val = agent.get_var(vid);
                    obj.insert(key, val);
                }
                agent.set_var(dst, Value::Object(obj));
            }
            Instruction::GetField(dst, obj, field_cid) => {
                let o = agent.get_var(obj);
                let key = const_as_string(&module.consts, field_cid);
                let val = o
                    .as_object()
                    .and_then(|m| m.get(&key))
                    .cloned()
                    .unwrap_or(Value::Null);
                agent.set_var(dst, val);
            }
            Instruction::SetField(new_dst, obj, field_cid, val) => {
                let o = agent.get_var(obj);
                let key = const_as_string(&module.consts, field_cid);
                let v = agent.get_var(val);
                let mut new_obj = match o {
                    Value::Object(map) => map,
                    _ => indexmap::IndexMap::new(),
                };
                new_obj.insert(key, v);
                agent.set_var(new_dst, Value::Object(new_obj));
            }
            Instruction::HasField(dst, obj, field_cid) => {
                let o = agent.get_var(obj);
                let key = const_as_string(&module.consts, field_cid);
                let has = o.as_object().is_some_and(|m| m.contains_key(&key));
                agent.set_var(dst, Value::Boolean(has));
            }

            // === Array operations ===
            Instruction::NewArray(dst, elems) => {
                let arr: Vec<Value> = elems.iter().map(|v| agent.get_var(*v)).collect();
                agent.set_var(dst, Value::Array(arr));
            }
            Instruction::ArrGet(dst, arr, idx) => {
                let a = agent.get_var(arr);
                let i = agent.get_var(idx);
                let val = match (a.as_array(), i.as_integer()) {
                    (Some(arr), Some(idx)) => {
                        let idx = if idx < 0 {
                            (arr.len() as i64 + idx) as usize
                        } else {
                            idx as usize
                        };
                        arr.get(idx).cloned().unwrap_or(Value::Null)
                    }
                    _ => Value::Null,
                };
                agent.set_var(dst, val);
            }
            Instruction::ArrLen(dst, arr) => {
                let a = agent.get_var(arr);
                let len = a.as_array().map_or(0, |a| a.len());
                agent.set_var(dst, Value::Integer(len as i64));
            }
            Instruction::ArrPush(dst, arr, elem) => {
                let a = agent.get_var(arr);
                let e = agent.get_var(elem);
                let mut v = match a {
                    Value::Array(arr) => arr,
                    _ => vec![],
                };
                v.push(e);
                agent.set_var(dst, Value::Array(v));
            }
            Instruction::ArrSlice(dst, arr, start, end) => {
                let a = agent.get_var(arr);
                let s = agent.get_var(start);
                let e = agent.get_var(end);
                let val = match (a.as_array(), s.as_integer(), e.as_integer()) {
                    (Some(arr), Some(s), Some(e)) => {
                        let s = (s.max(0) as usize).min(arr.len());
                        let e = (e.max(0) as usize).min(arr.len());
                        if s <= e {
                            Value::Array(arr[s..e].to_vec())
                        } else {
                            Value::Array(vec![])
                        }
                    }
                    _ => Value::Array(vec![]),
                };
                agent.set_var(dst, val);
            }

            // === Arithmetic ===
            Instruction::Add(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::arith_add(&l, &r).unwrap_or(Value::Null));
            }
            Instruction::Sub(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::arith_sub(&l, &r).unwrap_or(Value::Null));
            }
            Instruction::Mul(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::arith_mul(&l, &r).unwrap_or(Value::Null));
            }
            Instruction::Div(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::arith_div(&l, &r).unwrap_or(Value::Null));
            }
            Instruction::Mod(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::arith_mod(&l, &r).unwrap_or(Value::Null));
            }
            Instruction::Neg(dst, src) => {
                let v = agent.get_var(src);
                agent.set_var(dst, value::arith_neg(&v).unwrap_or(Value::Null));
            }

            // === Comparison ===
            Instruction::CmpEq(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::cmp_eq(&l, &r));
            }
            Instruction::CmpNe(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::cmp_ne(&l, &r));
            }
            Instruction::CmpLt(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::cmp_lt(&l, &r).unwrap_or(Value::Boolean(false)));
            }
            Instruction::CmpLe(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::cmp_le(&l, &r).unwrap_or(Value::Boolean(false)));
            }
            Instruction::CmpGt(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::cmp_gt(&l, &r).unwrap_or(Value::Boolean(false)));
            }
            Instruction::CmpGe(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::cmp_ge(&l, &r).unwrap_or(Value::Boolean(false)));
            }

            // === Logical ===
            Instruction::And(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(
                    dst,
                    value::logic_and(&l, &r).unwrap_or(Value::Boolean(false)),
                );
            }
            Instruction::Or(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(
                    dst,
                    value::logic_or(&l, &r).unwrap_or(Value::Boolean(false)),
                );
            }
            Instruction::Not(dst, src) => {
                let v = agent.get_var(src);
                agent.set_var(
                    dst,
                    value::logic_not(&v).unwrap_or(Value::Boolean(false)),
                );
            }

            // === String/Type ===
            Instruction::Concat(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::concat(&l, &r).unwrap_or(Value::Null));
            }
            Instruction::ToString(dst, src) => {
                let v = agent.get_var(src);
                agent.set_var(dst, Value::String(v.to_display_string()));
            }
            Instruction::TypeOf(dst, src) => {
                let v = agent.get_var(src);
                agent.set_var(dst, Value::String(v.type_name().to_string()));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

fn load_const(consts: &[ConstVal], cid: u32) -> Value {
    match consts.get(cid as usize) {
        Some(ConstVal::Null) => Value::Null,
        Some(ConstVal::Bool(b)) => Value::Boolean(*b),
        Some(ConstVal::Int(n)) => Value::Integer(*n),
        Some(ConstVal::Num(n)) => Value::Number(*n),
        Some(ConstVal::Str(s)) => Value::String(s.clone()),
        None => Value::Null,
    }
}

fn const_as_string(consts: &[ConstVal], cid: u32) -> String {
    match consts.get(cid as usize) {
        Some(ConstVal::Str(s)) => s.clone(),
        _ => String::new(),
    }
}

fn find_switch_target(val: &Value, cases: &[(u32, u32)], default: u32, consts: &[ConstVal]) -> u32 {
    for (cid, target) in cases {
        let case_val = load_const(consts, *cid);
        if val == &case_val {
            return *target;
        }
    }
    default
}
