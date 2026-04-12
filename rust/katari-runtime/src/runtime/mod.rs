pub mod agent;
pub mod event;
pub mod execute;
pub mod for_loop;
pub mod handle;
pub mod par;
pub mod primitive;
pub mod request;
pub mod signal;
pub mod thread;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use crate::ir::{IRModule, ThreadKind};
use crate::value::Value;

use self::agent::{AgentState, AgentStatus};
use self::event::{Event, EventKind};
use self::signal::Signal;
use self::thread::{PendingRequest, SuspendReason, ThreadState, ThreadStatus};

use katari_protocol::OutgoingMessage;

// ---------------------------------------------------------------------------
// Runtime — manages modules, agents, and the global event queue
// ---------------------------------------------------------------------------

/// Katari Runtime — manages modules and agents.
pub struct Runtime {
    pub module: Option<Arc<IRModule>>,
    pub agents: HashMap<String, AgentState>,
    pub agent_name_map: HashMap<String, u32>,
    pub schemas: HashMap<String, serde_json::Value>,
    pub self_base_url: String,
    pub event_queue: VecDeque<Event>,
    pub outgoing_messages: Vec<OutgoingMessage>,
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
            outgoing_messages: Vec::new(),
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
    pub fn run_agent(&mut self, agent_name: &str, args: Vec<Value>) -> Result<String, String> {
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
            self.self_base_url.clone(),
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

        // Push Execute event for the root thread
        self.event_queue.push_back(Event {
            agent_id: agent_id.clone(),
            kind: EventKind::Execute(entry_tid),
        });

        // Run the global event loop
        self.run_event_loop();

        Ok(agent_id)
    }

    // -----------------------------------------------------------------------
    // Global event-driven loop
    // -----------------------------------------------------------------------

    /// Run the global event loop until no applicable events remain.
    pub fn run_event_loop(&mut self) {
        for _ in 0..100_000 {
            let idx = self
                .event_queue
                .iter()
                .position(|e| event::is_applicable(e, &self.agents));
            match idx {
                Some(i) => {
                    let event = self.event_queue.remove(i).unwrap();
                    self.apply_event(event);
                }
                None => break,
            }
        }
        // Purge stale events targeting non-existent agents
        self.event_queue
            .retain(|e| self.agents.contains_key(&e.agent_id));
    }

    /// Apply a single event.
    fn apply_event(&mut self, event: Event) {
        let mut events = Vec::new();
        let mut messages = Vec::new();
        let agent_id = event.agent_id.clone();

        match event.kind {
            EventKind::Execute(tid) => {
                let module = match self.agents.get(&agent_id) {
                    Some(a) => Arc::clone(&a.module),
                    None => return,
                };
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    execute::execute_thread(agent, &module, tid, &mut events);
                }
            }

            EventKind::ThreadCompleted {
                parent_id,
                child_id,
                child_kind,
                signal,
            } => {
                let module = match self.agents.get(&agent_id) {
                    Some(a) => Arc::clone(&a.module),
                    None => return,
                };
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    dispatch_signal(
                        agent,
                        &module,
                        parent_id,
                        child_id,
                        child_kind,
                        signal,
                        &mut events,
                        &mut messages,
                    );
                }
            }

            EventKind::CancelThread(tid) => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    // Propagate to children
                    let children: Vec<u32> = agent
                        .threads
                        .iter()
                        .filter(|(_, t)| t.parent == Some(tid))
                        .map(|(id, _)| *id)
                        .collect();
                    for child_tid in children {
                        events.push(Event {
                            agent_id: agent_id.clone(),
                            kind: EventKind::CancelThread(child_tid),
                        });
                    }
                    // Detach child agent if Call-suspended
                    if let Some(t) = agent.threads.get(&tid) {
                        if let ThreadStatus::Suspended(SuspendReason::Call {
                            child_agent_id, ..
                        }) = &t.status
                        {
                            let cid = child_agent_id.clone();
                            agent.children.remove(&cid);
                        }
                    }
                    agent.threads.remove(&tid);
                }
            }

            EventKind::IncomingRequest {
                owner_thread_id,
                request,
                handler_def_tid,
            } => {
                let module = match self.agents.get(&agent_id) {
                    Some(a) => Arc::clone(&a.module),
                    None => return,
                };
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    handle::dispatch_request(
                        agent,
                        &module,
                        owner_thread_id,
                        handler_def_tid,
                        request,
                        &mut events,
                    );
                }
            }

            EventKind::Reply {
                thread_id, value, ..
            } => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    let dst = match agent.threads.get(&thread_id).map(|t| &t.status) {
                        Some(ThreadStatus::Suspended(SuspendReason::Request { dst, .. })) => *dst,
                        _ => return,
                    };
                    agent.set_var(dst, value);
                    execute::resume_thread(agent, thread_id, &mut events);
                }
            }

            EventKind::SpawnChildAgent {
                child_agent_id,
                agent_def_id,
                args,
            } => {
                let (module, parent_available) = match self.agents.get(&agent_id) {
                    Some(a) => (
                        Arc::clone(&a.module),
                        a.parent_available_requests.clone(),
                    ),
                    None => return,
                };
                let agent_def = match module.agents.iter().find(|a| a.id == agent_def_id) {
                    Some(d) => d,
                    None => return,
                };
                let entry_tid = agent_def.entry;

                let mut child = AgentState::new(
                    child_agent_id.clone(),
                    agent_def_id,
                    entry_tid,
                    agent_id.clone(),
                    self.self_base_url.clone(),
                    parent_available,
                    Arc::clone(&module),
                    self.self_base_url.clone(),
                );

                if let Some(ir_t) = module.threads.iter().find(|t| t.id == entry_tid) {
                    for (param, arg) in ir_t.params.iter().zip(args.iter()) {
                        child.set_var(*param, arg.clone());
                    }
                }

                let root_thread = ThreadState::new(entry_tid, ThreadKind::FnBody, None);
                child.threads.insert(entry_tid, root_thread);

                events.push(Event {
                    agent_id: child_agent_id.clone(),
                    kind: EventKind::Execute(entry_tid),
                });

                self.agents.insert(child_agent_id, child);
            }

            EventKind::AgentCompleted => {
                let (parent_agent_id, result) = match self.agents.get(&agent_id) {
                    Some(a) => {
                        let result = match &a.status {
                            AgentStatus::Completed(v) => v.clone(),
                            _ => Value::Null,
                        };
                        (a.parent_agent_id.clone(), result)
                    }
                    None => return,
                };

                // Check if parent agent exists and tracks this child
                if let Some(parent) = self.agents.get(&parent_agent_id) {
                    if let Some(&spawning_tid) = parent.children.get(&agent_id) {
                        events.push(Event {
                            agent_id: parent_agent_id,
                            kind: EventKind::ChildAgentCompleted {
                                thread_id: spawning_tid,
                                child_agent_id: agent_id.clone(),
                                result,
                            },
                        });
                        self.agents.remove(&agent_id);
                    }
                    // Parent doesn't track this child → top-level, keep it
                }
                // Parent doesn't exist in runtime → top-level, keep it
            }

            EventKind::ChildAgentCompleted {
                thread_id,
                child_agent_id,
                result,
            } => {
                if let Some(agent) = self.agents.get_mut(&agent_id) {
                    let dst = match agent.threads.get(&thread_id).map(|t| &t.status) {
                        Some(ThreadStatus::Suspended(SuspendReason::Call { dst, .. })) => *dst,
                        _ => return,
                    };
                    agent.set_var(dst, result);
                    agent.children.remove(&child_agent_id);
                    execute::resume_thread(agent, thread_id, &mut events);
                }
            }
        }

        // Drain events and messages
        for e in events {
            self.event_queue.push_back(e);
        }
        self.outgoing_messages.extend(messages);
    }

    // -----------------------------------------------------------------------
    // Agent status queries
    // -----------------------------------------------------------------------

    /// Get the result value from a completed agent.
    pub fn get_agent_result(&self, agent_id: &str) -> Value {
        self.agents
            .get(agent_id)
            .map(|a| match &a.status {
                AgentStatus::Completed(v) => v.clone(),
                _ => Value::Null,
            })
            .unwrap_or(Value::Null)
    }

    /// Get the status of an agent: ("running"|"completed"|"error", Option<Value>)
    pub fn get_agent_status(&self, agent_id: &str) -> Option<(&str, Option<Value>)> {
        let agent = self.agents.get(agent_id)?;
        match &agent.status {
            AgentStatus::Running => Some(("running", None)),
            AgentStatus::Completed(v) => Some(("completed", Some(v.clone()))),
            AgentStatus::Error => Some(("error", None)),
        }
    }

    /// Push an external event into the queue (for server protocol handlers).
    pub fn push_event(&mut self, event: Event) {
        self.event_queue.push_back(event);
    }
}

// ---------------------------------------------------------------------------
// Signal dispatch
// ---------------------------------------------------------------------------

/// Dispatch a child thread's completion signal to its parent.
fn dispatch_signal(
    agent: &mut AgentState,
    module: &IRModule,
    parent_id: u32,
    child_id: u32,
    child_kind: ThreadKind,
    signal: Signal,
    events: &mut Vec<Event>,
    messages: &mut Vec<OutgoingMessage>,
) {
    match child_kind {
        ThreadKind::Block => {
            par::process_branch_signal(agent, parent_id, child_id, signal, events);
        }
        ThreadKind::HandlerTarget => {
            handle::process_body_signal(agent, module, parent_id, signal, events);
        }
        ThreadKind::RequestHandler => {
            handle::process_handler_signal(agent, module, parent_id, signal, events, messages);
        }
        ThreadKind::HandleThen => {
            handle::process_then_signal(agent, parent_id, signal, events);
        }
        ThreadKind::ForBody => {
            for_loop::process_body_signal(agent, module, parent_id, signal, events);
        }
        ThreadKind::ForThen => {
            for_loop::process_then_signal(agent, parent_id, signal, events);
        }
        ThreadKind::FnBody => {}
    }
}

// ---------------------------------------------------------------------------
// KatariProtocol implementation
// ---------------------------------------------------------------------------

impl katari_protocol::KatariProtocol for Runtime {
    fn list_requests(&self, _module_name: Option<&str>) -> Vec<katari_protocol::RequestInfo> {
        let module = match &self.module {
            Some(m) => m,
            None => return vec![],
        };
        module
            .requests
            .iter()
            .map(|r| katari_protocol::RequestInfo {
                request_id: r.id.to_string(),
                request_where: self.self_base_url.clone(),
                name: r.name.clone(),
                description: String::new(),
                arg_types: vec![],
                return_type: serde_json::Value::Null,
            })
            .collect()
    }

    fn list_agent_defs(&self, _module_name: Option<&str>) -> Vec<katari_protocol::AgentDefInfo> {
        let module = match &self.module {
            Some(m) => m,
            None => return vec![],
        };
        module
            .agents
            .iter()
            .map(|a| katari_protocol::AgentDefInfo {
                agent_def_id: a.id.to_string(),
                agent_def_where: self.self_base_url.clone(),
                name: a.name.clone(),
                description: String::new(),
                arg_types: vec![],
                return_type: serde_json::Value::Null,
                with_effects: vec![],
            })
            .collect()
    }

    fn list_agents(&self) -> Vec<katari_protocol::AgentSummary> {
        self.agents
            .iter()
            .map(|(id, a)| katari_protocol::AgentSummary {
                agent_id: id.clone(),
                agent_where: a.self_where.clone(),
                agent_def_id: a.agent_def_id.to_string(),
                args: vec![],
            })
            .collect()
    }

    fn get_agent(
        &self,
        agent_id: &str,
    ) -> Result<katari_protocol::AgentDetail, katari_protocol::ProtocolError> {
        let agent = self
            .agents
            .get(agent_id)
            .ok_or_else(|| katari_protocol::ProtocolError::AgentNotFound(agent_id.to_string()))?;

        let module = &agent.module;
        let with_effects: Vec<String> = agent
            .parent_available_requests
            .iter()
            .filter_map(|rid| module.requests.iter().find(|r| r.id == *rid))
            .map(|r| r.name.clone())
            .collect();

        let child_agents: Vec<katari_protocol::ChildAgentRef> = agent
            .children
            .keys()
            .map(|cid| {
                let child_where = self
                    .agents
                    .get(cid)
                    .map(|c| c.self_where.clone())
                    .unwrap_or_default();
                katari_protocol::ChildAgentRef {
                    agent_id: cid.clone(),
                    agent_where: child_where,
                }
            })
            .collect();

        Ok(katari_protocol::AgentDetail {
            agent_id: agent_id.to_string(),
            agent_where: agent.self_where.clone(),
            agent_def_id: agent.agent_def_id.to_string(),
            args: vec![],
            parent_agent_id: agent.parent_agent_id.clone(),
            parent_agent_where: agent.parent_agent_where.clone(),
            with_effects,
            child_agents,
        })
    }

    fn spawn_agent(
        &mut self,
        req: &katari_protocol::SpawnAgentRequest,
    ) -> Result<
        (
            katari_protocol::SpawnAgentResponse,
            Vec<OutgoingMessage>,
        ),
        katari_protocol::ProtocolError,
    > {
        let module = self
            .module
            .clone()
            .ok_or_else(|| katari_protocol::ProtocolError::Internal("no module loaded".into()))?;

        let agent_def_id: u32 = req
            .agent_def_id
            .parse()
            .map_err(|_| katari_protocol::ProtocolError::AgentNotFound(req.agent_def_id.clone()))?;

        let agent_def = module
            .agents
            .iter()
            .find(|a| a.id == agent_def_id)
            .ok_or_else(|| {
                katari_protocol::ProtocolError::AgentNotFound(req.agent_def_id.clone())
            })?;

        let entry_tid = agent_def.entry;
        let agent_id = format!("agent-{}", uuid::Uuid::new_v4());

        let args: Vec<Value> = req
            .args
            .iter()
            .map(|v| serde_json::from_value(v.clone()).unwrap_or(Value::Null))
            .collect();

        let with_effects: HashSet<u32> = req
            .with_effects
            .iter()
            .filter_map(|name| module.requests.iter().find(|r| r.name == *name).map(|r| r.id))
            .collect();

        let mut agent_state = AgentState::new(
            agent_id.clone(),
            agent_def_id,
            entry_tid,
            req.parent_agent_id.clone(),
            req.parent_agent_where.clone(),
            with_effects,
            Arc::clone(&module),
            self.self_base_url.clone(),
        );

        if let Some(ir_t) = module.threads.iter().find(|t| t.id == entry_tid) {
            for (param, arg) in ir_t.params.iter().zip(args.iter()) {
                agent_state.set_var(*param, arg.clone());
            }
        }

        let root_thread = ThreadState::new(entry_tid, ThreadKind::FnBody, None);
        agent_state.threads.insert(entry_tid, root_thread);
        self.agents.insert(agent_id.clone(), agent_state);

        self.event_queue.push_back(Event {
            agent_id: agent_id.clone(),
            kind: EventKind::Execute(entry_tid),
        });
        self.run_event_loop();

        let response = katari_protocol::SpawnAgentResponse {
            agent_id: agent_id.clone(),
            agent_where: self.self_base_url.clone(),
        };
        Ok((response, std::mem::take(&mut self.outgoing_messages)))
    }

    fn deliver_request(
        &mut self,
        req: &katari_protocol::AgentRequestBody,
    ) -> Result<Vec<OutgoingMessage>, katari_protocol::ProtocolError> {
        // Find the parent agent that has from_agent_id as a child
        let (agent_id, source_thread_id) = self
            .agents
            .iter()
            .find_map(|(aid, a)| {
                a.children
                    .get(&req.from_agent_id)
                    .map(|&tid| (aid.clone(), tid))
            })
            .ok_or_else(|| {
                katari_protocol::ProtocolError::ChildNotFound(req.from_agent_id.clone())
            })?;

        let module = Arc::clone(
            &self
                .agents
                .get(&agent_id)
                .expect("agent must exist")
                .module,
        );

        // Resolve request_name → req_def_id
        let req_def_id = module
            .requests
            .iter()
            .find(|r| r.name == req.request_name)
            .map(|r| r.id)
            .ok_or_else(|| {
                katari_protocol::ProtocolError::RequestNotFound(req.request_name.clone())
            })?;

        let args: Vec<Value> = req
            .args
            .iter()
            .map(|v| serde_json::from_value(v.clone()).unwrap_or(Value::Null))
            .collect();

        let pending = PendingRequest {
            request_id: req.request_id.clone(),
            req_def_id,
            args,
            from_agent_id: req.from_agent_id.clone(),
            from_agent_where: req.from_agent_where.clone(),
        };

        let agent = self.agents.get(&agent_id).expect("agent must exist");
        match event::route_request_to_handle(agent, &module, source_thread_id, req_def_id) {
            Some((owner_tid, handler_tid)) => {
                self.push_event(Event {
                    agent_id: agent_id.clone(),
                    kind: EventKind::IncomingRequest {
                        owner_thread_id: owner_tid,
                        request: pending,
                        handler_def_tid: handler_tid,
                    },
                });
            }
            None => {
                tracing::warn!(
                    request_name = %req.request_name,
                    "no handle scope for external request"
                );
            }
        }

        self.run_event_loop();
        Ok(std::mem::take(&mut self.outgoing_messages))
    }

    fn deliver_reply(
        &mut self,
        req: &katari_protocol::AgentReplyBody,
    ) -> Result<Vec<OutgoingMessage>, katari_protocol::ProtocolError> {
        let agent = self
            .agents
            .get(&req.agent_id)
            .ok_or_else(|| katari_protocol::ProtocolError::AgentNotFound(req.agent_id.clone()))?;

        let thread_id =
            event::find_request_thread(agent, &req.request_id).ok_or_else(|| {
                katari_protocol::ProtocolError::RequestNotFound(req.request_id.clone())
            })?;

        let value: Value = serde_json::from_value(req.result.clone()).unwrap_or(Value::Null);

        self.push_event(Event {
            agent_id: req.agent_id.clone(),
            kind: EventKind::Reply {
                thread_id,
                request_id: req.request_id.clone(),
                value,
            },
        });

        self.run_event_loop();
        Ok(std::mem::take(&mut self.outgoing_messages))
    }

    fn terminate_agent(
        &mut self,
        _req: &katari_protocol::TerminateBody,
    ) -> Result<Vec<OutgoingMessage>, katari_protocol::ProtocolError> {
        Err(katari_protocol::ProtocolError::NotImplemented(
            "terminate not yet implemented".into(),
        ))
    }

    fn deliver_return(
        &mut self,
        req: &katari_protocol::AgentReturnBody,
    ) -> Result<Vec<OutgoingMessage>, katari_protocol::ProtocolError> {
        // agent_id = parent agent (on this server)
        // from_agent_id = completed child agent
        let agent = self
            .agents
            .get(&req.agent_id)
            .ok_or_else(|| katari_protocol::ProtocolError::AgentNotFound(req.agent_id.clone()))?;

        let spawning_tid = agent
            .children
            .get(&req.from_agent_id)
            .copied()
            .ok_or_else(|| {
                katari_protocol::ProtocolError::ChildNotFound(req.from_agent_id.clone())
            })?;

        let result: Value = serde_json::from_value(req.result.clone()).unwrap_or(Value::Null);

        self.push_event(Event {
            agent_id: req.agent_id.clone(),
            kind: EventKind::ChildAgentCompleted {
                thread_id: spawning_tid,
                child_agent_id: req.from_agent_id.clone(),
                result,
            },
        });

        // Remove child tracking
        if let Some(agent) = self.agents.get_mut(&req.agent_id) {
            agent.children.remove(&req.from_agent_id);
        }

        self.run_event_loop();
        Ok(std::mem::take(&mut self.outgoing_messages))
    }

    fn deliver_terminate_ack(
        &mut self,
        _req: &katari_protocol::TerminateAckBody,
    ) -> Result<Vec<OutgoingMessage>, katari_protocol::ProtocolError> {
        Err(katari_protocol::ProtocolError::NotImplemented(
            "terminate_ack not yet implemented".into(),
        ))
    }
}
