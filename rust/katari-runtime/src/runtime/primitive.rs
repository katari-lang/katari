use crate::value::Value;

/// Execute a primitive agent synchronously.
/// Returns the result value.
pub fn call_primitive(name: &str, args: &[Value]) -> Value {
    match name {
        "prim.to_string" => {
            let v = args.first().unwrap_or(&Value::Null);
            Value::String(v.to_display_string())
        }
        "prim.div" => {
            // Floor division: integer result
            match (args.first(), args.get(1)) {
                (Some(Value::Integer(a)), Some(Value::Integer(b))) => {
                    if *b == 0 {
                        Value::Null // division by zero
                    } else {
                        Value::Integer(a.div_euclid(*b))
                    }
                }
                (Some(a), Some(b)) => {
                    match (a.to_f64(), b.to_f64()) {
                        (Some(a), Some(b)) if b != 0.0 => Value::Integer((a / b).floor() as i64),
                        _ => Value::Null,
                    }
                }
                _ => Value::Null,
            }
        }
        "prim.mod" => {
            match (args.first(), args.get(1)) {
                (Some(Value::Integer(a)), Some(Value::Integer(b))) => {
                    if *b == 0 {
                        Value::Null
                    } else {
                        Value::Integer(a.rem_euclid(*b))
                    }
                }
                (Some(a), Some(b)) => {
                    match (a.to_f64(), b.to_f64()) {
                        (Some(a), Some(b)) if b != 0.0 => Value::Number(a % b),
                        _ => Value::Null,
                    }
                }
                _ => Value::Null,
            }
        }
        "prim.parse_integer" => {
            match args.first() {
                Some(Value::String(s)) => {
                    s.trim().parse::<i64>().map(Value::Integer).unwrap_or(Value::Null)
                    // TODO: raise prim.parse_error request on failure
                }
                _ => Value::Null,
            }
        }
        "prim.parse_number" => {
            match args.first() {
                Some(Value::String(s)) => {
                    s.trim().parse::<f64>().map(Value::Number).unwrap_or(Value::Null)
                }
                _ => Value::Null,
            }
        }
        "prim.parse_boolean" => {
            match args.first() {
                Some(Value::String(s)) => match s.as_str() {
                    "true" => Value::Boolean(true),
                    "false" => Value::Boolean(false),
                    _ => Value::Null, // TODO: raise prim.parse_error
                },
                _ => Value::Null,
            }
        }
        "prim.log.info" => {
            if let Some(Value::String(msg)) = args.first() {
                tracing::info!("{}", msg);
            }
            Value::Null
        }
        "prim.log.warn" => {
            if let Some(Value::String(msg)) = args.first() {
                tracing::warn!("{}", msg);
            }
            Value::Null
        }
        "prim.log.error" => {
            if let Some(Value::String(msg)) = args.first() {
                tracing::error!("{}", msg);
            }
            Value::Null
        }
        "prim.length" => {
            match args.first() {
                Some(Value::Array(arr)) => Value::Integer(arr.len() as i64),
                _ => Value::Integer(0),
            }
        }
        "prim.slice" => {
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
            }
        }
        _ => {
            tracing::warn!("unknown primitive agent: {}", name);
            Value::Null
        }
    }
}
