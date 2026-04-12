use crate::value::Value;

/// Result of a primitive call.
pub enum PrimitiveResult {
    /// Synchronous result value.
    Ok(Value),
    /// Raise a request (e.g. prim.parse_error).
    RaiseRequest { req_name: String, args: Vec<Value> },
}

fn parse_error(msg: String) -> PrimitiveResult {
    PrimitiveResult::RaiseRequest {
        req_name: "prim.parse_error".to_string(),
        args: vec![Value::String(msg)],
    }
}

/// Execute a primitive agent synchronously.
pub fn call_primitive(name: &str, args: &[Value]) -> PrimitiveResult {
    let val = |v| PrimitiveResult::Ok(v);

    match name {
        "prim.to_string" => {
            let v = args.first().unwrap_or(&Value::Null);
            val(Value::String(v.to_display_string()))
        }
        "prim.div" => val(match (args.first(), args.get(1)) {
            (Some(Value::Integer(a)), Some(Value::Integer(b))) => {
                if *b == 0 {
                    Value::Null
                } else {
                    Value::Integer(a.div_euclid(*b))
                }
            }
            (Some(a), Some(b)) => match (a.to_f64(), b.to_f64()) {
                (Some(a), Some(b)) if b != 0.0 => Value::Integer((a / b).floor() as i64),
                _ => Value::Null,
            },
            _ => Value::Null,
        }),
        "prim.mod" => val(match (args.first(), args.get(1)) {
            (Some(Value::Integer(a)), Some(Value::Integer(b))) => {
                if *b == 0 {
                    Value::Null
                } else {
                    Value::Integer(a.rem_euclid(*b))
                }
            }
            (Some(a), Some(b)) => match (a.to_f64(), b.to_f64()) {
                (Some(a), Some(b)) if b != 0.0 => Value::Number(a % b),
                _ => Value::Null,
            },
            _ => Value::Null,
        }),
        "prim.parse_integer" => match args.first() {
            Some(Value::String(s)) => match s.trim().parse::<i64>() {
                Ok(n) => val(Value::Integer(n)),
                Err(_) => parse_error(format!("failed to parse '{}' as integer", s)),
            },
            _ => parse_error("parse_integer: expected string argument".to_string()),
        },
        "prim.parse_number" => match args.first() {
            Some(Value::String(s)) => match s.trim().parse::<f64>() {
                Ok(n) => val(Value::Number(n)),
                Err(_) => parse_error(format!("failed to parse '{}' as number", s)),
            },
            _ => parse_error("parse_number: expected string argument".to_string()),
        },
        "prim.parse_boolean" => match args.first() {
            Some(Value::String(s)) => match s.as_str() {
                "true" => val(Value::Boolean(true)),
                "false" => val(Value::Boolean(false)),
                _ => parse_error(format!("failed to parse '{}' as boolean", s)),
            },
            _ => parse_error("parse_boolean: expected string argument".to_string()),
        },
        "prim.log.info" => {
            if let Some(Value::String(msg)) = args.first() {
                tracing::info!("{}", msg);
            }
            val(Value::Null)
        }
        "prim.log.warn" => {
            if let Some(Value::String(msg)) = args.first() {
                tracing::warn!("{}", msg);
            }
            val(Value::Null)
        }
        "prim.log.error" => {
            if let Some(Value::String(msg)) = args.first() {
                tracing::error!("{}", msg);
            }
            val(Value::Null)
        }
        "prim.length" => val(match args.first() {
            Some(Value::Array(arr)) => Value::Integer(arr.len() as i64),
            _ => Value::Integer(0),
        }),
        "prim.slice" => val(
            match (args.first(), args.get(1), args.get(2)) {
                (Some(Value::Array(arr)), Some(Value::Integer(start)), Some(Value::Integer(end))) => {
                    let s = (*start).max(0) as usize;
                    let e = (*end).max(0) as usize;
                    let s = s.min(arr.len());
                    let e = e.min(arr.len());
                    if s <= e {
                        Value::Array(arr[s..e].to_vec())
                    } else {
                        Value::Array(vec![])
                    }
                }
                _ => Value::Array(vec![]),
            },
        ),
        _ => {
            tracing::warn!("unknown primitive agent: {}", name);
            val(Value::Null)
        }
    }
}
