use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Value {
    Null,
    Boolean(bool),
    Integer(i64),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(IndexMap<String, Value>),
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::Null, Value::Null) => true,
            (Value::Boolean(a), Value::Boolean(b)) => a == b,
            (Value::Integer(a), Value::Integer(b)) => a == b,
            (Value::Number(a), Value::Number(b)) => a == b,
            (Value::String(a), Value::String(b)) => a == b,
            (Value::Array(a), Value::Array(b)) => a == b,
            (Value::Object(a), Value::Object(b)) => a == b,
            _ => false,
        }
    }
}

impl Value {
    pub fn is_truthy(&self) -> bool {
        match self {
            Value::Null => false,
            Value::Boolean(b) => *b,
            Value::Integer(n) => *n != 0,
            Value::Number(n) => *n != 0.0,
            Value::String(s) => !s.is_empty(),
            Value::Array(_) | Value::Object(_) => true,
        }
    }

    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Null => "null",
            Value::Boolean(_) => "boolean",
            Value::Integer(_) => "integer",
            Value::Number(_) => "number",
            Value::String(_) => "string",
            Value::Array(_) => "array",
            Value::Object(_) => "object",
        }
    }

    pub fn to_display_string(&self) -> String {
        match self {
            Value::Null => "null".into(),
            Value::Boolean(true) => "true".into(),
            Value::Boolean(false) => "false".into(),
            Value::Integer(n) => n.to_string(),
            Value::Number(n) => format_f64(*n),
            Value::String(s) => s.clone(),
            Value::Array(_) | Value::Object(_) => {
                serde_json::to_string(self).unwrap_or_else(|_| "<value>".into())
            }
        }
    }

    pub fn as_integer(&self) -> Option<i64> {
        match self {
            Value::Integer(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_number(&self) -> Option<f64> {
        match self {
            Value::Number(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<Value>> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&IndexMap<String, Value>> {
        match self {
            Value::Object(o) => Some(o),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Boolean(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    /// Promote to f64 (integer → number)
    pub fn to_f64(&self) -> Option<f64> {
        match self {
            Value::Integer(n) => Some(*n as f64),
            Value::Number(n) => Some(*n),
            _ => None,
        }
    }
}

impl Default for Value {
    fn default() -> Self {
        Value::Null
    }
}

fn format_f64(n: f64) -> String {
    if n.is_infinite() {
        if n.is_sign_positive() {
            "Infinity".into()
        } else {
            "-Infinity".into()
        }
    } else if n.is_nan() {
        "NaN".into()
    } else {
        let s = format!("{n}");
        s
    }
}

// --- Arithmetic operations ---

#[derive(Debug, thiserror::Error)]
pub enum ValueError {
    #[error("type error: expected {expected}, got {got}")]
    TypeError {
        expected: &'static str,
        got: &'static str,
    },
    #[error("division by zero")]
    DivisionByZero,
    #[error("index out of bounds: {index} (len={len})")]
    IndexOutOfBounds { index: i64, len: usize },
    #[error("field not found: {0}")]
    FieldNotFound(String),
}

pub fn arith_add(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    match (lhs, rhs) {
        (Value::Integer(a), Value::Integer(b)) => Ok(Value::Integer(a.wrapping_add(*b))),
        _ => {
            let a = lhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: lhs.type_name(),
            })?;
            let b = rhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: rhs.type_name(),
            })?;
            Ok(Value::Number(a + b))
        }
    }
}

pub fn arith_sub(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    match (lhs, rhs) {
        (Value::Integer(a), Value::Integer(b)) => Ok(Value::Integer(a.wrapping_sub(*b))),
        _ => {
            let a = lhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: lhs.type_name(),
            })?;
            let b = rhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: rhs.type_name(),
            })?;
            Ok(Value::Number(a - b))
        }
    }
}

pub fn arith_mul(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    match (lhs, rhs) {
        (Value::Integer(a), Value::Integer(b)) => Ok(Value::Integer(a.wrapping_mul(*b))),
        _ => {
            let a = lhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: lhs.type_name(),
            })?;
            let b = rhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: rhs.type_name(),
            })?;
            Ok(Value::Number(a * b))
        }
    }
}

pub fn arith_div(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    // IDiv always returns Number
    let a = lhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: lhs.type_name(),
    })?;
    let b = rhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: rhs.type_name(),
    })?;
    Ok(Value::Number(a / b))
}

pub fn arith_mod(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    match (lhs, rhs) {
        (Value::Integer(a), Value::Integer(b)) => {
            if *b == 0 {
                return Err(ValueError::DivisionByZero);
            }
            Ok(Value::Integer(a % b))
        }
        _ => {
            let a = lhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: lhs.type_name(),
            })?;
            let b = rhs.to_f64().ok_or(ValueError::TypeError {
                expected: "number",
                got: rhs.type_name(),
            })?;
            Ok(Value::Number(a % b))
        }
    }
}

pub fn arith_neg(val: &Value) -> Result<Value, ValueError> {
    match val {
        Value::Integer(n) => Ok(Value::Integer(-n)),
        Value::Number(n) => Ok(Value::Number(-n)),
        _ => Err(ValueError::TypeError {
            expected: "number",
            got: val.type_name(),
        }),
    }
}

// --- Comparison ---

pub fn cmp_eq(lhs: &Value, rhs: &Value) -> Value {
    Value::Boolean(lhs == rhs)
}

pub fn cmp_ne(lhs: &Value, rhs: &Value) -> Value {
    Value::Boolean(lhs != rhs)
}

pub fn cmp_lt(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    let a = lhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: lhs.type_name(),
    })?;
    let b = rhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: rhs.type_name(),
    })?;
    Ok(Value::Boolean(a < b))
}

pub fn cmp_le(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    let a = lhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: lhs.type_name(),
    })?;
    let b = rhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: rhs.type_name(),
    })?;
    Ok(Value::Boolean(a <= b))
}

pub fn cmp_gt(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    let a = lhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: lhs.type_name(),
    })?;
    let b = rhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: rhs.type_name(),
    })?;
    Ok(Value::Boolean(a > b))
}

pub fn cmp_ge(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    let a = lhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: lhs.type_name(),
    })?;
    let b = rhs.to_f64().ok_or(ValueError::TypeError {
        expected: "number",
        got: rhs.type_name(),
    })?;
    Ok(Value::Boolean(a >= b))
}

// --- Logical ---

pub fn logic_and(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    let a = lhs.as_bool().ok_or(ValueError::TypeError {
        expected: "boolean",
        got: lhs.type_name(),
    })?;
    let b = rhs.as_bool().ok_or(ValueError::TypeError {
        expected: "boolean",
        got: rhs.type_name(),
    })?;
    Ok(Value::Boolean(a && b))
}

pub fn logic_or(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    let a = lhs.as_bool().ok_or(ValueError::TypeError {
        expected: "boolean",
        got: lhs.type_name(),
    })?;
    let b = rhs.as_bool().ok_or(ValueError::TypeError {
        expected: "boolean",
        got: rhs.type_name(),
    })?;
    Ok(Value::Boolean(a || b))
}

pub fn logic_not(val: &Value) -> Result<Value, ValueError> {
    let b = val.as_bool().ok_or(ValueError::TypeError {
        expected: "boolean",
        got: val.type_name(),
    })?;
    Ok(Value::Boolean(!b))
}

// --- Concat ---

pub fn concat(lhs: &Value, rhs: &Value) -> Result<Value, ValueError> {
    match (lhs, rhs) {
        (Value::String(a), Value::String(b)) => {
            let mut s = a.clone();
            s.push_str(b);
            Ok(Value::String(s))
        }
        (Value::Array(a), Value::Array(b)) => {
            let mut v = a.clone();
            v.extend(b.iter().cloned());
            Ok(Value::Array(v))
        }
        _ => Err(ValueError::TypeError {
            expected: "string or array",
            got: lhs.type_name(),
        }),
    }
}
