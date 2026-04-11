pub mod leb128;

use std::io::{self, Cursor, Read};

use crate::ir::{
    ConstVal, IRAgentDef, IRForDef, IRHandleDef, IRModule, IRRequestDef, IRThread, NameTable,
    ThreadKind,
    instruction::Instruction,
};

use self::leb128::{read_signed, read_u32};

const MAGIC: [u8; 4] = [0x4b, 0x54, 0x52, 0x49]; // "KTRI"
const VERSION: [u8; 2] = [0x00, 0x02];

#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    #[error("IO error: {0}")]
    Io(#[from] io::Error),
    #[error("invalid magic bytes")]
    InvalidMagic,
    #[error("unsupported version: {0}.{1}")]
    UnsupportedVersion(u8, u8),
    #[error("unknown opcode: 0x{0:02x}")]
    UnknownOpcode(u8),
    #[error("unknown thread kind: {0}")]
    UnknownThreadKind(u8),
    #[error("unknown const tag: 0x{0:02x}")]
    UnknownConstTag(u8),
}

pub fn decode_module(data: &[u8]) -> Result<IRModule, DecodeError> {
    let mut r = Cursor::new(data);

    // Header
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic)?;
    if magic != MAGIC {
        return Err(DecodeError::InvalidMagic);
    }
    let mut ver = [0u8; 2];
    r.read_exact(&mut ver)?;
    if ver != VERSION {
        return Err(DecodeError::UnsupportedVersion(ver[0], ver[1]));
    }

    let name = read_text(&mut r)?;
    let consts = read_vec(&mut r, read_const)?;
    let requests = read_vec(&mut r, read_request_def)?;
    let threads = read_vec(&mut r, read_thread)?;
    let handles = read_vec(&mut r, read_handle_def)?;
    let fors = read_vec(&mut r, read_for_def)?;
    let agents = read_vec(&mut r, read_agent_def)?;

    Ok(IRModule {
        name,
        name_table: NameTable::default(),
        consts,
        requests,
        threads,
        handles,
        fors,
        agents,
    })
}

fn read_text<R: Read>(r: &mut R) -> Result<String, DecodeError> {
    let len = read_u32(r)? as usize;
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    String::from_utf8(buf).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e).into())
}

fn read_maybe<R: Read, T>(
    r: &mut R,
    read_item: fn(&mut R) -> Result<T, DecodeError>,
) -> Result<Option<T>, DecodeError> {
    let mut tag = [0u8; 1];
    r.read_exact(&mut tag)?;
    match tag[0] {
        0 => Ok(None),
        1 => Ok(Some(read_item(r)?)),
        _ => Err(io::Error::new(io::ErrorKind::InvalidData, "invalid maybe tag").into()),
    }
}

fn read_const<R: Read>(r: &mut R) -> Result<ConstVal, DecodeError> {
    let mut tag = [0u8; 1];
    r.read_exact(&mut tag)?;
    match tag[0] {
        0x00 => Ok(ConstVal::Null),
        0x01 => {
            let mut b = [0u8; 1];
            r.read_exact(&mut b)?;
            Ok(ConstVal::Bool(b[0] != 0))
        }
        0x02 => {
            let v = read_signed(r)?;
            Ok(ConstVal::Int(v))
        }
        0x03 => {
            let mut buf = [0u8; 8];
            r.read_exact(&mut buf)?;
            Ok(ConstVal::Num(f64::from_le_bytes(buf)))
        }
        0x04 => {
            let s = read_text(r)?;
            Ok(ConstVal::Str(s))
        }
        other => Err(DecodeError::UnknownConstTag(other)),
    }
}

fn read_request_def<R: Read>(r: &mut R) -> Result<IRRequestDef, DecodeError> {
    let id = read_u32(r)?;
    let name = read_text(r)?;
    let from = read_maybe(r, read_text)?;
    Ok(IRRequestDef { id, name, from })
}

fn read_thread<R: Read>(r: &mut R) -> Result<IRThread, DecodeError> {
    let id = read_u32(r)?;
    let mut kind_byte = [0u8; 1];
    r.read_exact(&mut kind_byte)?;
    let kind = match kind_byte[0] {
        0 => ThreadKind::FnBody,
        1 => ThreadKind::Block,
        2 => ThreadKind::HandlerTarget,
        3 => ThreadKind::RequestHandler,
        4 => ThreadKind::HandleThen,
        5 => ThreadKind::ForBody,
        6 => ThreadKind::ForThen,
        other => return Err(DecodeError::UnknownThreadKind(other)),
    };
    let params = read_vec(r, read_u32_item)?;
    let body = read_vec(r, read_instruction)?;
    Ok(IRThread {
        id,
        kind,
        params,
        body,
    })
}

fn read_handle_def<R: Read>(r: &mut R) -> Result<IRHandleDef, DecodeError> {
    let id = read_u32(r)?;
    let state_vars = read_vec(r, read_u32_item)?;
    let state_inits = read_vec(r, read_u32_item)?;
    let body = read_u32(r)?;
    let req_cases = read_vec(r, |r| {
        let rid = read_u32(r)?;
        let tid = read_u32(r)?;
        Ok((rid, tid))
    })?;
    let then = read_maybe(r, read_u32_item)?;
    Ok(IRHandleDef {
        id,
        state_vars,
        state_inits,
        body,
        req_cases,
        then,
    })
}

fn read_for_def<R: Read>(r: &mut R) -> Result<IRForDef, DecodeError> {
    let id = read_u32(r)?;
    let iter_vars = read_vec(r, read_u32_item)?;
    let arrays = read_vec(r, read_u32_item)?;
    let state_vars = read_vec(r, read_u32_item)?;
    let state_inits = read_vec(r, read_u32_item)?;
    let body = read_u32(r)?;
    let then = read_maybe(r, read_u32_item)?;
    Ok(IRForDef {
        id,
        iter_vars,
        arrays,
        state_vars,
        state_inits,
        body,
        then,
    })
}

fn read_agent_def<R: Read>(r: &mut R) -> Result<IRAgentDef, DecodeError> {
    let id = read_u32(r)?;
    let name = read_text(r)?;
    let entry = read_u32(r)?;
    Ok(IRAgentDef { id, name, entry })
}

fn read_u32_item<R: Read>(r: &mut R) -> Result<u32, DecodeError> {
    Ok(read_u32(r)?)
}

fn read_instruction<R: Read>(r: &mut R) -> Result<Instruction, DecodeError> {
    let mut op = [0u8; 1];
    r.read_exact(&mut op)?;

    match op[0] {
        // Constants & Movement
        0x01 => Ok(Instruction::LoadConst(read_u32(r)?, read_u32(r)?)),
        0x02 => Ok(Instruction::LoadNull(read_u32(r)?)),
        0x03 => Ok(Instruction::Move(read_u32(r)?, read_u32(r)?)),

        // Object
        0x10 => {
            let dst = read_u32(r)?;
            let fields = read_vec(r, |r| {
                let c = read_u32(r)?;
                let v = read_u32(r)?;
                Ok((c, v))
            })?;
            Ok(Instruction::NewObject(dst, fields))
        }
        0x11 => Ok(Instruction::GetField(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x12 => Ok(Instruction::SetField(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x13 => Ok(Instruction::HasField(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),

        // Array
        0x20 => {
            let dst = read_u32(r)?;
            let elems = read_vec(r, read_u32_item)?;
            Ok(Instruction::NewArray(dst, elems))
        }
        0x21 => Ok(Instruction::ArrGet(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x22 => Ok(Instruction::ArrLen(read_u32(r)?, read_u32(r)?)),
        0x23 => Ok(Instruction::ArrPush(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x25 => Ok(Instruction::ArrSlice(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),

        // Arithmetic
        0x30 => Ok(Instruction::Add(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x31 => Ok(Instruction::Sub(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x32 => Ok(Instruction::Mul(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x33 => Ok(Instruction::Div(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x34 => Ok(Instruction::Mod(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x35 => Ok(Instruction::Neg(read_u32(r)?, read_u32(r)?)),

        // Comparison
        0x50 => Ok(Instruction::CmpEq(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x51 => Ok(Instruction::CmpNe(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x52 => Ok(Instruction::CmpLt(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x53 => Ok(Instruction::CmpLe(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x54 => Ok(Instruction::CmpGt(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x55 => Ok(Instruction::CmpGe(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),

        // Logical
        0x60 => Ok(Instruction::And(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x61 => Ok(Instruction::Or(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x62 => Ok(Instruction::Not(read_u32(r)?, read_u32(r)?)),

        // String/Type
        0x70 => Ok(Instruction::Concat(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x71 => Ok(Instruction::ToString(read_u32(r)?, read_u32(r)?)),
        0x73 => Ok(Instruction::TypeOf(read_u32(r)?, read_u32(r)?)),

        // Control flow
        0x80 => Ok(Instruction::Jump(read_u32(r)?)),
        0x81 => Ok(Instruction::Branch(
            read_u32(r)?,
            read_u32(r)?,
            read_u32(r)?,
        )),
        0x82 => {
            let val = read_u32(r)?;
            let cases = read_vec(r, |r| {
                let c = read_u32(r)?;
                let t = read_u32(r)?;
                Ok((c, t))
            })?;
            let default = read_u32(r)?;
            Ok(Instruction::Switch(val, cases, default))
        }
        0x83 => Ok(Instruction::Return(read_u32(r)?)),
        0x84 => Ok(Instruction::Complete(read_u32(r)?)),

        // Agent operations
        0x90 => {
            let dst = read_u32(r)?;
            let tid = read_u32(r)?;
            let args = read_vec(r, read_u32_item)?;
            Ok(Instruction::Call(dst, tid, args))
        }
        0x91 => {
            let dst = read_u32(r)?;
            let tids = read_vec(r, read_u32_item)?;
            Ok(Instruction::Par(dst, tids))
        }
        0x92 => {
            let dst = read_u32(r)?;
            let rid = read_u32(r)?;
            let args = read_vec(r, read_u32_item)?;
            Ok(Instruction::Request(dst, rid, args))
        }

        // Handle
        0xa0 => Ok(Instruction::Handle(read_u32(r)?, read_u32(r)?)),
        0xa2 => {
            let val = read_u32(r)?;
            let upds = read_vec(r, |r| {
                let sv = read_u32(r)?;
                let nv = read_u32(r)?;
                Ok((sv, nv))
            })?;
            Ok(Instruction::Continue(val, upds))
        }
        0xa3 => Ok(Instruction::HandleBreak(read_u32(r)?)),

        // For
        0xb0 => {
            let upds = read_vec(r, |r| {
                let sv = read_u32(r)?;
                let nv = read_u32(r)?;
                Ok((sv, nv))
            })?;
            Ok(Instruction::ForContinue(upds))
        }
        0xb1 => Ok(Instruction::ForBreak(read_u32(r)?)),
        0xb2 => Ok(Instruction::For(read_u32(r)?, read_u32(r)?)),

        other => Err(DecodeError::UnknownOpcode(other)),
    }
}

// read_vec needs a closure version for inline lambdas
fn read_vec<R: Read, T>(
    r: &mut R,
    read_item: impl Fn(&mut R) -> Result<T, DecodeError>,
) -> Result<Vec<T>, DecodeError> {
    let count = read_u32(r)? as usize;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        items.push(read_item(r)?);
    }
    Ok(items)
}
