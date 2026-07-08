//! ex_zapcode — Elixir NIF wrapper around `zapcode-core`, a minimal secure
//! TypeScript-subset interpreter in Rust.
//!
//! Mirrors the `ex_monty` start/resume interactive model: guest TS runs until it
//! calls a declared external function, at which point the VM suspends and hands
//! control back to Elixir with the call name + args + a snapshot. Elixir runs the
//! tool and calls `resume/2` with the return value. Repeats until `:complete`.

use std::sync::{Arc, Mutex, MutexGuard};

use indexmap::IndexMap;
use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, NifResult, Resource, ResourceArc, Term};
use zapcode_core::{ResourceLimits, Value, VmState, ZapcodeError, ZapcodeRun, ZapcodeSnapshot};

mod atoms {
    rustler::atoms! {
        error,
        complete,
        function_call,
        // error type tags
        parse_error,
        compile_error,
        runtime_error,
        type_error,
        reference_error,
        unknown_external_function,
        memory_limit,
        timeout,
        stack_overflow,
        allocation_limit,
        snapshot_error,
        sandbox_violation,
        snapshot_consumed,
    }
}

// ── Snapshot resource (one-shot; `resume` consumes the snapshot) ──────────────

fn lock_recover<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

pub struct SnapshotResource {
    snapshot: Mutex<Option<ZapcodeSnapshot>>,
}

impl SnapshotResource {
    fn new(snapshot: ZapcodeSnapshot) -> Self {
        Self {
            snapshot: Mutex::new(Some(snapshot)),
        }
    }

    fn take(&self) -> Option<ZapcodeSnapshot> {
        lock_recover(&self.snapshot).take()
    }
}

#[rustler::resource_impl]
impl Resource for SnapshotResource {}

// ── Value <-> Term marshalling ───────────────────────────────────────────────

fn encode_value<'a>(env: Env<'a>, v: &Value) -> NifResult<Term<'a>> {
    Ok(match v {
        Value::Undefined | Value::Null => rustler::types::atom::nil().encode(env),
        Value::Bool(b) => b.encode(env),
        Value::Int(n) => n.encode(env),
        Value::Float(f) => f.encode(env),
        Value::String(s) => s.as_ref().encode(env),
        Value::Array(arr) => {
            let items: Vec<Term> = arr
                .iter()
                .map(|x| encode_value(env, x))
                .collect::<NifResult<_>>()?;
            items.encode(env)
        }
        Value::Object(map) => {
            let mut m = rustler::types::map::map_new(env);
            for (k, val) in map {
                let key = k.as_ref().encode(env);
                let value = encode_value(env, val)?;
                m = m.map_put(key, value).unwrap();
            }
            m
        }
        // Functions/generators aren't JSON-safe; surface a marker rather than crash.
        Value::Function(_) | Value::Generator(_) | Value::BuiltinMethod { .. } => {
            "<function>".encode(env)
        }
        // Transient internal spread marker — never a completed value in practice.
        Value::Spread(inner) => encode_value(env, inner)?,
    })
}

fn term_to_key(term: Term) -> Arc<str> {
    if let Ok(s) = term.decode::<String>() {
        Arc::from(s.as_str())
    } else if term.is_atom() {
        Arc::from(term.atom_to_string().unwrap_or_default().as_str())
    } else {
        Arc::from(format!("{:?}", term).as_str())
    }
}

fn decode_value(term: Term) -> NifResult<Value> {
    if term.is_atom() {
        let s = term.atom_to_string().unwrap_or_default();
        return Ok(match s.as_str() {
            "nil" => Value::Null,
            "undefined" => Value::Undefined,
            "true" => Value::Bool(true),
            "false" => Value::Bool(false),
            other => Value::String(Arc::from(other)),
        });
    }
    if let Ok(n) = term.decode::<i64>() {
        return Ok(Value::Int(n));
    }
    if let Ok(f) = term.decode::<f64>() {
        return Ok(Value::Float(f));
    }
    if let Ok(s) = term.decode::<String>() {
        return Ok(Value::String(Arc::from(s.as_str())));
    }
    if let Ok(list) = term.decode::<Vec<Term>>() {
        let arr = list
            .into_iter()
            .map(decode_value)
            .collect::<NifResult<Vec<_>>>()?;
        return Ok(Value::Array(arr));
    }
    if let Ok(iter) = term.decode::<rustler::types::map::MapIterator>() {
        let mut m: IndexMap<Arc<str>, Value> = IndexMap::new();
        for (k, val) in iter {
            m.insert(term_to_key(k), decode_value(val)?);
        }
        return Ok(Value::Object(m));
    }
    Err(rustler::Error::BadArg)
}

// ── Limits & errors ──────────────────────────────────────────────────────────

/// Limits arrive as a 4-tuple of non-negative integers, built by the Elixir
/// wrapper: {time_limit_ms, memory_limit_bytes, max_stack_depth, max_allocations}.
fn decode_limits(term: Term) -> NifResult<ResourceLimits> {
    let (time_limit_ms, memory_limit_bytes, max_stack_depth, max_allocations): (
        u64,
        usize,
        usize,
        usize,
    ) = term.decode()?;
    Ok(ResourceLimits {
        memory_limit_bytes,
        time_limit_ms,
        max_stack_depth,
        max_allocations,
    })
}

fn error_tag(e: &ZapcodeError) -> rustler::types::atom::Atom {
    match e {
        ZapcodeError::ParseError(_) => atoms::parse_error(),
        ZapcodeError::UnsupportedSyntax { .. } => atoms::parse_error(),
        ZapcodeError::CompileError(_) => atoms::compile_error(),
        ZapcodeError::RuntimeError(_) => atoms::runtime_error(),
        ZapcodeError::TypeError(_) => atoms::type_error(),
        ZapcodeError::ReferenceError(_) => atoms::reference_error(),
        ZapcodeError::UnknownExternalFunction(_) => atoms::unknown_external_function(),
        ZapcodeError::MemoryLimitExceeded(_) => atoms::memory_limit(),
        ZapcodeError::TimeLimitExceeded => atoms::timeout(),
        ZapcodeError::StackOverflow(_) => atoms::stack_overflow(),
        ZapcodeError::AllocationLimitExceeded => atoms::allocation_limit(),
        ZapcodeError::SnapshotError(_) => atoms::snapshot_error(),
        ZapcodeError::SandboxViolation(_) => atoms::sandbox_violation(),
    }
}

fn encode_error<'a>(env: Env<'a>, e: &ZapcodeError) -> Term<'a> {
    make_tuple(
        env,
        &[
            atoms::error().encode(env),
            error_tag(e).encode(env),
            e.to_string().encode(env),
        ],
    )
}

// ── Progress encoding ────────────────────────────────────────────────────────

fn encode_state<'a>(env: Env<'a>, state: VmState, stdout: &str) -> NifResult<Term<'a>> {
    let out = stdout.encode(env);
    match state {
        VmState::Complete(v) => {
            let vt = encode_value(env, &v)?;
            Ok(make_tuple(env, &[atoms::complete().encode(env), vt, out]))
        }
        VmState::Suspended {
            function_name,
            args,
            snapshot,
        } => {
            let name_t = function_name.encode(env);
            let args_t: Vec<Term> = args
                .iter()
                .map(|a| encode_value(env, a))
                .collect::<NifResult<_>>()?;
            let args_list = args_t.encode(env);
            let snap = ResourceArc::new(SnapshotResource::new(snapshot)).encode(env);
            Ok(make_tuple(
                env,
                &[
                    atoms::function_call().encode(env),
                    name_t,
                    args_list,
                    snap,
                    out,
                ],
            ))
        }
    }
}

// ── NIFs ─────────────────────────────────────────────────────────────────────

#[rustler::nif(schedule = "DirtyCpu")]
fn start<'a>(
    env: Env<'a>,
    code: String,
    input_names: Vec<String>,
    external_fns: Vec<String>,
    inputs: Vec<(String, Term<'a>)>,
    limits: Term<'a>,
) -> NifResult<Term<'a>> {
    let rl = decode_limits(limits)?;

    let runner = match ZapcodeRun::new(code, input_names, external_fns, rl) {
        Ok(r) => r,
        Err(e) => return Ok(encode_error(env, &e)),
    };

    let input_vals: Vec<(String, Value)> = inputs
        .into_iter()
        .map(|(k, t)| Ok((k, decode_value(t)?)))
        .collect::<NifResult<_>>()?;

    match runner.run(input_vals) {
        Ok(result) => encode_state(env, result.state, &result.stdout),
        Err(e) => Ok(encode_error(env, &e)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn resume<'a>(
    env: Env<'a>,
    snapshot: ResourceArc<SnapshotResource>,
    value: Term<'a>,
) -> NifResult<Term<'a>> {
    // Decode the (attacker-controlled) return value before consuming the
    // snapshot, so a malformed value leaves it intact for a retry.
    let return_value = decode_value(value)?;

    let snap = match snapshot.take() {
        Some(s) => s,
        None => {
            return Ok(make_tuple(
                env,
                &[
                    atoms::error().encode(env),
                    atoms::snapshot_consumed().encode(env),
                    "snapshot already consumed".encode(env),
                ],
            ))
        }
    };

    match snap.resume(return_value) {
        // `resume` returns VmState only; stdout produced after resume is not
        // captured by zapcode-core v1.5.3 (a known fidelity gap vs Monty).
        Ok(state) => encode_state(env, state, ""),
        Err(e) => Ok(encode_error(env, &e)),
    }
}

rustler::init!("Elixir.ExZapcode.Native");
