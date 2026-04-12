use crate::ir::instruction::Instruction;
use crate::ir::{ConstVal, IRModule, ThreadKind};
use crate::value::{self, Value};

use super::agent::{AgentState, AgentStatus};
use super::event::{Event, EventKind};
use super::signal::Signal;
use super::thread::{ThreadState, ThreadStatus};
use super::{handle, for_loop, par, request};

// ---------------------------------------------------------------------------
// Thread lifecycle helpers
// ---------------------------------------------------------------------------

/// Complete a thread with the given signal.
/// Root thread: store result in AgentStatus, remove thread, push AgentCompleted.
/// Non-root: remove thread, push ThreadCompleted to parent.
pub fn finish_thread(
    agent: &mut AgentState,
    thread_id: u32,
    signal: Signal,
    events: &mut Vec<Event>,
) {
    if thread_id == agent.root_thread {
        agent.status = match &signal {
            Signal::Normal(v) | Signal::FnReturn(v) => AgentStatus::Completed(v.clone()),
            _ => AgentStatus::Error,
        };
        agent.threads.remove(&thread_id);
        events.push(Event {
            agent_id: agent.agent_id.clone(),
            kind: EventKind::AgentCompleted,
        });
    } else {
        let (kind, parent) = match agent.threads.get(&thread_id) {
            Some(t) => (t.kind, t.parent),
            None => return,
        };
        agent.threads.remove(&thread_id);
        if let Some(parent_id) = parent {
            events.push(Event {
                agent_id: agent.agent_id.clone(),
                kind: EventKind::ThreadCompleted {
                    parent_id,
                    child_id: thread_id,
                    child_kind: kind,
                    signal,
                },
            });
        }
    }
}

/// Resume a suspended thread and push an Execute event.
pub fn resume_thread(
    agent: &mut AgentState,
    thread_id: u32,
    events: &mut Vec<Event>,
) {
    if let Some(t) = agent.threads.get_mut(&thread_id) {
        t.status = ThreadStatus::Running;
    }
    events.push(Event {
        agent_id: agent.agent_id.clone(),
        kind: EventKind::Execute(thread_id),
    });
}

/// Create a new child thread and push an Execute event.
pub fn spawn_child_thread(
    agent: &mut AgentState,
    tid: u32,
    kind: ThreadKind,
    parent: u32,
    events: &mut Vec<Event>,
) {
    let thread = ThreadState::new(tid, kind, Some(parent));
    agent.threads.insert(tid, thread);
    events.push(Event {
        agent_id: agent.agent_id.clone(),
        kind: EventKind::Execute(tid),
    });
}

// ---------------------------------------------------------------------------
// Thread execution
// ---------------------------------------------------------------------------

/// Execute a thread's instructions until it suspends or completes.
pub fn execute_thread(
    agent: &mut AgentState,
    module: &IRModule,
    thread_id: u32,
    events: &mut Vec<Event>,
) {
    let ir_thread = match module.threads.iter().find(|t| t.id == thread_id) {
        Some(t) => t,
        None => {
            finish_thread(agent, thread_id, Signal::Normal(Value::Null), events);
            return;
        }
    };

    loop {
        let pc = match agent.threads.get(&thread_id) {
            Some(t) if t.is_running() => t.pc as usize,
            _ => return,
        };

        if pc >= ir_thread.body.len() {
            finish_thread(agent, thread_id, Signal::Normal(Value::Null), events);
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
                finish_thread(agent, thread_id, Signal::Normal(v), events);
                return;
            }
            Instruction::Return(val) => {
                let v = agent.get_var(val);
                finish_thread(agent, thread_id, Signal::FnReturn(v), events);
                return;
            }
            Instruction::HandleBreak(val) => {
                let v = agent.get_var(val);
                finish_thread(agent, thread_id, Signal::HandleBreak(v), events);
                return;
            }
            Instruction::Continue(val, mutations) => {
                let v = agent.get_var(val);
                finish_thread(agent, thread_id, Signal::Continue(v, mutations), events);
                return;
            }
            Instruction::ForBreak(val) => {
                let v = agent.get_var(val);
                finish_thread(agent, thread_id, Signal::ForBreak(v), events);
                return;
            }
            Instruction::ForContinue(mutations) => {
                finish_thread(agent, thread_id, Signal::ForContinue(mutations), events);
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
                let target = if v.is_truthy() { then_target } else { else_target };
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
                handle::setup(agent, module, thread_id, dst, hid, events);
                return;
            }
            Instruction::For(dst, fid) => {
                for_loop::setup(agent, module, thread_id, dst, fid, events);
                return;
            }
            Instruction::Par(dst, tids) => {
                par::setup(agent, thread_id, dst, &tids, events);
                return;
            }
            Instruction::Call(dst, aid, args) => {
                request::handle_icall(agent, module, thread_id, dst, aid, &args, events);
                if !agent
                    .threads
                    .get(&thread_id)
                    .is_some_and(|t| t.is_running())
                {
                    return;
                }
            }
            Instruction::Request(dst, rid, args) => {
                request::handle_irequest(agent, module, thread_id, dst, rid, &args, events);
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
                agent.set_var(dst, value::logic_and(&l, &r).unwrap_or(Value::Boolean(false)));
            }
            Instruction::Or(dst, lhs, rhs) => {
                let (l, r) = (agent.get_var(lhs), agent.get_var(rhs));
                agent.set_var(dst, value::logic_or(&l, &r).unwrap_or(Value::Boolean(false)));
            }
            Instruction::Not(dst, src) => {
                let v = agent.get_var(src);
                agent.set_var(dst, value::logic_not(&v).unwrap_or(Value::Boolean(false)));
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
// Helpers
// ---------------------------------------------------------------------------

pub fn load_const(consts: &[ConstVal], cid: u32) -> Value {
    match consts.get(cid as usize) {
        Some(ConstVal::Null) => Value::Null,
        Some(ConstVal::Bool(b)) => Value::Boolean(*b),
        Some(ConstVal::Int(n)) => Value::Integer(*n),
        Some(ConstVal::Num(n)) => Value::Number(*n),
        Some(ConstVal::Str(s)) => Value::String(s.clone()),
        None => Value::Null,
    }
}

pub fn const_as_string(consts: &[ConstVal], cid: u32) -> String {
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
