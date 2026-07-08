# Substrate evaluation — why zapcode, and what else we looked at

Notes on the Rust TS/JS engines considered as the substrate for ex_zapcode, and
why the "less complete" one is the right fit. Written so a future reader (or a
future us) doesn't re-litigate this from scratch.

## What we actually need

ex_zapcode runs **untrusted, AI-agent-generated TypeScript** that calls back into
the host (tools), inside the BEAM. That imposes three hard requirements that
override raw language completeness:

1. **Bounded execution.** Untrusted code must not be able to hang or OOM the node.
   An infinite loop would pin a dirty-scheduler thread forever; unbounded
   allocation would OOM-kill the whole VM. Wall-clock, memory, allocation, and
   stack-depth limits are non-negotiable.
2. **Durable suspend/resume.** When guest code awaits a tool, we want to
   serialize the paused computation to bytes, persist it (DB/queue/another node),
   run the tool out-of-band (slow job, human approval, webhook), and resume later
   — possibly in a different process or after a restart.
3. **A synchronous-enough tool bridge** where the tool runs on a normal BEAM
   process, not inside the NIF.

Language completeness matters, but it's fourth. Agent glue code is loops,
conditionals, data-shaping, and tool calls — not npm libraries.

## The core architectural tradeoff

Every candidate sits on one side of a single line:

- **Value-typed, no-GC** (zapcode): values are cloned by value; no heap of
  pointers. Limited semantics (aliasing/shared-mutation are faked with
  write-backs; functions-as-objects is bolted on). **But** the entire VM state is
  a flat, acyclic, `postcard`-serializable blob, and resource metering is
  natural. Snapshot-to-bytes is trivial and sound.
- **GC heap with references** (tsrun, pydantic/monty, V8/deno_core): real objects,
  closures, prototypes, cycles. Far more complete. **But** a GC heap of pointers
  and cycles is exactly what makes state hard to serialize, and fuel/memory
  accounting has to be threaded through the allocator and op loop.

You cannot cheaply have both. For **untrusted + durable + sandboxed**, the
value-typed side is the enabling constraint, not a weakness. zapcode's
"limitations" are why its resource limits and `dump_snapshot`/`load_snapshot`
work at all.

## tsrun (DmitryBochkarev/tsrun) — evaluated 2026-07

A genuinely impressive, more mature project than zapcode: register-based bytecode
VM, a real **GC heap** (so real objects/closures/prototypes), ES modules,
generators, decorators, namespaces, and `Proxy`/`Reflect`/`Symbol`/`Date`/`RegExp`/
`Map`/`Set`. Published on crates.io (v0.1.23 at eval time), `no_std`, C/WASM APIs,
fuzzed, with its own Test262 runner scoring higher than zapcode on hard areas
(e.g. `arguments-object` ~49% vs our ~3%). Its **"Orders"** suspension model is
*more* capable than zapcode's: async, Promise-based, with concurrent pending host
calls and cancellation (`StepResult::Suspended` → host `fulfill_orders()` → `step()`).

Head-to-head against our requirements:

| Requirement | zapcode | tsrun |
|---|---|---|
| Language completeness | subset (~22% Test262) | **much higher** — GC heap, modules, Proxy/Reflect/Symbol/Date |
| Tool-call bridge | sync, single suspension | **richer** — async concurrent Orders/Promises |
| **Resource limits** | **yes** — time/mem/alloc/stack | **none** — `step()` has no budget; only a low-level op-by-op hook you'd meter yourself, and no memory cap |
| **Durable serializable suspend/resume** | **yes** — `dump/load_snapshot` | **no** — interpreter/VM/heap has no `Serialize`; GC pointers make it hard to add |
| Threat model | untrusted-by-design (no eval/Date/net/fs) | **trusted config files** (eval/Date on by default) |

Confirmed by reading the source: `pub fn step(&mut self) -> Result<StepResult, JsError>`
takes no budget; there are no `fuel`/`gas`/`max_steps`/`memory_limit` paths
(only static compile-time caps like "too many registers"); and no `derive(Serialize)`
on the interpreter, `bytecode_vm`, `value`, or `gc` state.

**Verdict: not a better substrate for these goals.** tsrun took the GC-heap path
→ completeness, and consequently lacks the two safety-critical things we can't
compromise on (bounded untrusted execution + durable snapshots) — the exact
things a GC heap makes most expensive to retrofit. This is the same tradeoff, seen
from the other side. It's a strong validation of the zapcode choice, not a reason
to switch.

### Lessons worth stealing from tsrun

1. **Orders/Promise async suspension.** If we ever need `Promise.all` over several
   *concurrent* tool calls (parallel fan-out), tsrun's design is the north-star.
   zapcode's single synchronous suspension is simpler but strictly serial.
2. **Guard-based embedding API.** GC guards + `create_*`/`get_*`/`call_function`
   helpers are a clean reference if ex_zapcode's host surface grows.
3. **Built-in implementations** (Proxy/Reflect/Symbol/Date/Map/Set, MIT) are a
   study reference if we extend zapcode's built-ins.
4. It **runs the real Test262 harness** — independent confirmation that a complete
   object model (functions-as-objects + heap) is the completeness lever, exactly
   what we flagged as zapcode's biggest remaining investment.

### When tsrun would win

Flip the priorities: **trusted** code (config files, first-party plugins) where
you want maximum language fidelity and don't need a hard sandbox or durable
persistence. That's its stated design center. Revisit it if a future use case
looks like that rather than untrusted-durable-agent-execution.

## The other candidates (for the record)

- **deno_core / rusty_v8** — full TS via V8; battle-tested; but heavy embed, an
  event loop that fights the sync tool bridge, isolate-based (not fuel-based)
  limits, and no free durable serialization. The "full fidelity, heavy" option.
- **rquickjs (QuickJS)** — real JS, small C dep, sync host functions; but you
  assemble TS-stripping + limits + the bridge yourself, and reentrant host calls.
- **boa** — pure Rust, easy to build; JS-only, incomplete, slower.
- **bun** — not embeddable (JavaScriptCore + a standalone binary; the "67% Rust"
  is tooling, not the engine). Ruled out immediately.
- **pydantic/monty** — the Python sibling we wrap in `ex_monty`. Same GC-heap +
  cell/free-var closure model as tsrun; same serialization tension. We studied its
  closure design (CPython-style cells) as the reference for zapcode's biggest
  scaling issue (O(n²) capture), documented in the fork's `CONFORMANCE.md`.

## Decision

Build on **zapcode** (our fork, with the correctness fixes) for ex_zapcode. The
value-typed model is the right tradeoff for untrusted, durable, sandboxed agent
execution. Keep the two big levers documented but un-taken unless the need is
proven: (a) heap/reference semantics for completeness, and (b) the free-variable
scope pass for the closure-capture blowup — both in the fork's `CONFORMANCE.md`.
