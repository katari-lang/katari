pub mod agent;
pub mod event;
pub mod for_loop;
pub mod handle;
pub mod par;
pub mod primitive;
pub mod request;
pub mod signal;
pub mod thread;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use crate::ir::instruction::Instruction;
use crate::ir::{ConstVal, IRModule, ThreadKind};
use crate::value::{self, Value};

use self::agent::{AgentState, AgentStatus};
use self::event::{Event, EventKind};
use self::signal::Signal;
use self::thread::{SuspendReason, ThreadState, ThreadStatus};

// ---------------------------------------------------------------------------
// Runtime — manages modules, agents, and the global event queue
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

    /// Global event queue. Events have fully resolved targets.
    pub event_queue: VecDeque<Event>,

    /// Outgoing replies to external agents, collected during event processing.
    /// Server protocol layer drains this after run_event_loop().
    pub outgoing_replies: Vec<OutgoingReply>,
}

/// A reply that needs to be sent to an external agent via HTTP.
#[derive(Debug, Clone)]
pub struct OutgoingReply {
    pub to_agent_id: String,
    pub to_agent_where: String,
    pub request_id: String,
    pub value: Value,
}

impl Runtime {
    pub fn new(base_url: String) -> Self {
        Self {
            module: None,
            agents: HashMap::new(),
            agent_name_map: HashMap::new(),
            schemas: HashMap::new(),
            self_base_url: base_url,
            event_queue: VecDeque::new(),
            outgoing_replies: Vec::new(),
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

        // Push Start event for the root thread
        self.event_queue.push_back(Event {
            agent_id: agent_id.clone(),
            thread_id: entry_tid,
            kind: EventKind::Start,
        });

        // Run the global event loop
        self.run_event_loop();

        Ok(agent_id)
    }

    // -----------------------------------------------------------------------
    // Global event-driven loop
    // -----------------------------------------------------------------------

    /// Run the global event loop until no applicable events remain
    /// and no agent can make internal progress.
    pub fn run_event_loop(&mut self) {
        for _ in 0..100_000 {
            let mut progress = false;

            // Phase 1: Process the first applicable event
            progress |= self.process_one_event();

            // Phase 2: Spawn pending children (ICall suspensions)
            progress |= self.spawn_pending_children();

            // Phase 3: Collect completed children → push events
            progress |= self.collect_completed_children();

            // Phase 4: Remove orphaned agents (parent no longer tracks them)
            progress |= self.remove_orphaned_agents();

            if !progress {
                break;
            }
        }

        // Purge stale events targeting non-existent agents or threads
        self.event_queue.retain(|e| {
            if let Some(agent) = self.agents.get(&e.agent_id) {
                // Keep Terminate events even if thread doesn't exist
                matches!(e.kind, EventKind::Terminate) || agent.threads.contains_key(&e.thread_id)
            } else {
                false
            }
        });
    }

    /// Scan the event queue for the first applicable event, apply it,
    /// then harvest effects (new events from state changes).
    fn process_one_event(&mut self) -> bool {
        // Find first applicable event
        let idx = self
            .event_queue
            .iter()
            .position(|e| event::is_applicable(e, &self.agents));

        let event = match idx {
            Some(i) => self.event_queue.remove(i).unwrap(),
            None => return false,
        };

        self.apply_event(event);
        true
    }

    /// Apply a single event and harvest resulting effects.
    fn apply_event(&mut self, event: Event) {
        let agent_id = event.agent_id.clone();
        let thread_id = event.thread_id;

        match event.kind {
            EventKind::Start => {
                // Execute the thread until next async point
                let module = match self.agents.get(&agent_id) {
                    Some(a) => Arc::clone(&a.module),
                    None => return,
                };
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    execute_thread(agent, &module, thread_id);
                }
            }

            EventKind::ChildThreadCompleted {
                child_thread_id,
                child_kind,
                signal,
            } => {
                let module = match self.agents.get(&agent_id) {
                    Some(a) => Arc::clone(&a.module),
                    None => return,
                };
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    let (reply, cancels) = dispatch_child_signal(
                        agent,
                        &module,
                        thread_id,
                        child_thread_id,
                        child_kind,
                        signal,
                    );
                    if let Some(reply) = reply {
                        self.outgoing_replies.push(reply);
                    }
                    for tid in cancels {
                        self.event_queue.push_back(Event {
                            agent_id: agent_id.clone(),
                            thread_id: tid,
                            kind: EventKind::CancelThread,
                        });
                    }
                }
            }

            EventKind::ChildAgentCompleted {
                child_agent_id,
                result,
            } => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    // Resume the Call suspension
                    let dst = match agent.threads.get(&thread_id).map(|t| &t.status) {
                        Some(ThreadStatus::Suspended(SuspendReason::Call { dst, .. })) => *dst,
                        _ => return,
                    };
                    agent.set_var(dst, result);
                    if let Some(t) = agent.threads.get_mut(&thread_id) {
                        t.status = ThreadStatus::Running;
                    }
                    agent.children.remove(&child_agent_id);
                }
            }

            EventKind::Reply { request_id: _, value } => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    let dst = match agent.threads.get(&thread_id).map(|t| &t.status) {
                        Some(ThreadStatus::Suspended(SuspendReason::Request { dst, .. })) => *dst,
                        _ => return,
                    };
                    agent.set_var(dst, value);
                    if let Some(t) = agent.threads.get_mut(&thread_id) {
                        t.status = ThreadStatus::Running;
                    }
                }
            }

            EventKind::IncomingRequest {
                request,
                handler_def_tid,
            } => {
                let module = match self.agents.get(&agent_id) {
                    Some(a) => Arc::clone(&a.module),
                    None => return,
                };
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    handle::handle_request_in_scope(
                        agent,
                        &module,
                        thread_id,
                        handler_def_tid,
                        request,
                    );
                }
            }

            EventKind::CancelThread => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    // Push CancelThread for direct children (propagation)
                    let children: Vec<u32> = agent
                        .threads
                        .iter()
                        .filter(|(_, t)| t.parent == Some(thread_id))
                        .map(|(tid, _)| *tid)
                        .collect();
                    for child_tid in children {
                        self.event_queue.push_back(Event {
                            agent_id: agent_id.clone(),
                            thread_id: child_tid,
                            kind: EventKind::CancelThread,
                        });
                    }

                    // Detach child agent if Call-suspended
                    if let Some(t) = agent.threads.get(&thread_id) {
                        if let ThreadStatus::Suspended(SuspendReason::Call {
                            child_agent_id, ..
                        }) = &t.status
                        {
                            let cid = child_agent_id.clone();
                            agent.children.remove(&cid);
                        }
                    }

                    // Remove the thread
                    agent.threads.remove(&thread_id);
                }
                // CancelThread is self-propagating — no harvest needed
                return;
            }

            EventKind::Terminate => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    agent.status = AgentStatus::Completed;
                }
            }
        }

        // Harvest effects from the agent
        self.harvest_agent_effects(&agent_id);
    }

    /// Harvest new events from an agent's state changes.
    fn harvest_agent_effects(&mut self, agent_id: &str) {
        let mut new_events: Vec<Event> = Vec::new();

        let agent = match self.agents.get_mut(agent_id) {
            Some(a) => a,
            None => return,
        };

        // 1. Harvest outgoing requests
        let outgoing = std::mem::take(&mut agent.outgoing_requests);
        let aid = agent.agent_id.clone();
        let module = Arc::clone(&agent.module);

        for (source_tid, req) in outgoing {
            // Route through thread tree to find matching handle
            match event::route_request_to_handle(agent, &module, source_tid, req.req_def_id) {
                Some((handle_owner_tid, handler_def_tid)) => {
                    new_events.push(Event {
                        agent_id: aid.clone(),
                        thread_id: handle_owner_tid,
                        kind: EventKind::IncomingRequest {
                            request: req,
                            handler_def_tid,
                        },
                    });
                }
                None => {
                    // No local handle found — forward to parent agent
                    tracing::warn!(
                        agent_id = %aid,
                        request_id = %req.request_id,
                        "forwarding request to parent agent (not yet implemented)"
                    );
                }
            }
        }

        // 2. Harvest completed threads → push ChildThreadCompleted events.
        //    After generating events, remove them from the thread map to prevent
        //    duplicate event generation on subsequent harvest calls.
        let completed: Vec<(u32, Signal, ThreadKind, Option<u32>)> = agent
            .threads
            .iter()
            .filter(|(tid, t)| {
                matches!(t.status, ThreadStatus::Completed(_)) && **tid != agent.root_thread
            })
            .map(|(tid, t)| {
                let signal = match &t.status {
                    ThreadStatus::Completed(s) => s.clone(),
                    _ => unreachable!(),
                };
                (*tid, signal, t.kind, t.parent)
            })
            .collect();

        for (child_tid, signal, kind, parent_id) in &completed {
            if let Some(parent_id) = parent_id {
                new_events.push(Event {
                    agent_id: aid.clone(),
                    thread_id: *parent_id,
                    kind: EventKind::ChildThreadCompleted {
                        child_thread_id: *child_tid,
                        child_kind: *kind,
                        signal: signal.clone(),
                    },
                });
            }
        }

        // Remove harvested completed threads
        for (child_tid, _, _, _) in &completed {
            agent.threads.remove(child_tid);
        }

        // 3. Harvest Running threads → push Start events
        let running: Vec<u32> = agent
            .threads
            .iter()
            .filter(|(_, t)| t.is_running())
            .map(|(tid, _)| *tid)
            .collect();

        for tid in running {
            new_events.push(Event {
                agent_id: aid.clone(),
                thread_id: tid,
                kind: EventKind::Start,
            });
        }

        // 4. Check if root thread is completed → mark agent as Completed
        if let Some(root) = agent.threads.get(&agent.root_thread) {
            if matches!(root.status, ThreadStatus::Completed(_)) {
                agent.status = AgentStatus::Completed;
            }
        }

        // Push all new events
        for e in new_events {
            self.event_queue.push_back(e);
        }
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

            // Push Start event for the child's root thread
            self.event_queue.push_back(Event {
                agent_id: spawn.child_agent_id.clone(),
                thread_id: spawn.entry_tid,
                kind: EventKind::Start,
            });

            self.agents.insert(spawn.child_agent_id, child);
        }

        any_spawned
    }

    /// Collect results from completed child agents → push ChildAgentCompleted events.
    fn collect_completed_children(&mut self) -> bool {
        let mut completions: Vec<(String, String, u32, Value)> = Vec::new();

        for (agent_id, agent) in &self.agents {
            if agent.status != AgentStatus::Completed {
                continue;
            }
            let parent_id = &agent.parent_agent_id;
            if let Some(parent) = self.agents.get(parent_id) {
                if let Some(&spawning_tid) = parent.children.get(agent_id) {
                    let result = get_agent_result(agent);
                    completions.push((
                        agent_id.clone(),
                        parent_id.clone(),
                        spawning_tid,
                        result,
                    ));
                }
            }
        }

        let any_collected = !completions.is_empty();

        for (child_id, parent_id, spawning_tid, result) in completions {
            self.event_queue.push_back(Event {
                agent_id: parent_id,
                thread_id: spawning_tid,
                kind: EventKind::ChildAgentCompleted {
                    child_agent_id: child_id.clone(),
                    result,
                },
            });
            self.agents.remove(&child_id);
        }

        any_collected
    }

    /// Remove agents whose parent no longer tracks them (orphaned by terminate_thread_tree).
    /// Also purges any events targeting those agents from the queue.
    fn remove_orphaned_agents(&mut self) -> bool {
        let orphans: Vec<String> = self
            .agents
            .iter()
            .filter(|(agent_id, agent)| {
                // An agent is orphaned if:
                // 1. It has a parent in the runtime
                // 2. But the parent's children map no longer contains it
                if let Some(parent) = self.agents.get(&agent.parent_agent_id) {
                    !parent.children.contains_key(agent_id.as_str())
                        && agent.parent_agent_id != **agent_id
                } else {
                    false
                }
            })
            .map(|(id, _)| id.clone())
            .collect();

        if orphans.is_empty() {
            return false;
        }

        for orphan_id in &orphans {
            self.agents.remove(orphan_id);
        }

        // Purge events targeting removed agents
        self.event_queue
            .retain(|e| !orphans.contains(&e.agent_id));

        true
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

    /// Push an external event into the queue (for server protocol handlers).
    pub fn push_event(&mut self, event: Event) {
        self.event_queue.push_back(event);
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
// Signal dispatch
// ---------------------------------------------------------------------------

/// Dispatch a child thread's completion signal to its parent.
/// Returns `(outgoing_reply, cancel_list)` where cancel_list contains
/// thread IDs that should receive CancelThread events.
fn dispatch_child_signal(
    agent: &mut AgentState,
    module: &IRModule,
    parent_thread_id: u32,
    child_thread_id: u32,
    child_kind: ThreadKind,
    signal: Signal,
) -> (Option<OutgoingReply>, Vec<u32>) {
    match child_kind {
        ThreadKind::Block => {
            let cancels =
                par::process_par_branch_signal(agent, parent_thread_id, child_thread_id, signal);
            (None, cancels)
        }
        ThreadKind::HandlerTarget => {
            handle::process_body_signal(agent, module, parent_thread_id, signal);
            (None, vec![])
        }
        ThreadKind::RequestHandler => {
            let (reply_info, cancels) =
                handle::process_handler_signal(agent, module, parent_thread_id, signal);
            let outgoing = if let Some((requester, value)) = reply_info {
                if requester.from_agent_id == agent.agent_id {
                    // Internal request — find the waiting thread and resume it
                    if let Some(waiting_tid) =
                        event::find_request_thread(agent, &requester.request_id)
                    {
                        if let Some(ThreadStatus::Suspended(SuspendReason::Request {
                            dst, ..
                        })) = agent.threads.get(&waiting_tid).map(|t| &t.status)
                        {
                            let dst = *dst;
                            agent.set_var(dst, value);
                            if let Some(t) = agent.threads.get_mut(&waiting_tid) {
                                t.status = ThreadStatus::Running;
                            }
                        }
                    }
                    None
                } else {
                    Some(OutgoingReply {
                        to_agent_id: requester.from_agent_id,
                        to_agent_where: requester.from_agent_where,
                        request_id: requester.request_id,
                        value,
                    })
                }
            } else {
                None
            };
            (outgoing, cancels)
        }
        ThreadKind::HandleThen => {
            handle::process_then_signal(agent, parent_thread_id, child_thread_id, signal);
            (None, vec![])
        }
        ThreadKind::ForBody => {
            for_loop::process_for_body_signal(agent, module, parent_thread_id, signal);
            (None, vec![])
        }
        ThreadKind::ForThen => {
            for_loop::process_for_then_signal(agent, parent_thread_id, child_thread_id, signal);
            (None, vec![])
        }
        ThreadKind::FnBody => (None, vec![]),
    }
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
