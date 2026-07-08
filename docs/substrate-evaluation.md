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

It's tempting to draw one line ("value-typed → serializable, GC heap → not"), but
that's too binary. There are **three** points on the spectrum, and the middle one
matters:

1. **Value-typed, no heap** (zapcode): values cloned by value; no pointers.
   Limited semantics (aliasing/shared-mutation faked with write-backs;
   functions-as-objects bolted on). **But** the whole VM state is a flat, acyclic,
   `postcard`-serializable blob, and resource metering is trivial. Snapshot-to-
   bytes is sound and cheap.
2. **Arena heap, indexed handles + refcount** (pydantic/monty): real reference
   semantics (aliasing, shared mutation, cell-based closures) **and** serializable,
   because handles are `HeapId` *indices* into a serde-able arena — not pointers.
   This is the sweet spot, and `ex_monty`'s `dump_snapshot` is the existence proof
   that a heap can be both complete *and* durable.
3. **Tracing GC, raw pointers** (tsrun, V8/deno_core): real semantics + fast, but
   handles are raw pointers into a live graph with cycles — exactly what makes
   state hard to serialize, and fuel/memory accounting must be threaded through the
   allocator and op loop.

So a "combined" engine (full object model + durable snapshots + hard limits) is
**not** a research project — it's monty's architecture (point 2) applied to JS.
The obstacle is engineering effort, not feasibility.

For **untrusted + durable + sandboxed**, zapcode (point 1) is the cheapest correct
answer today. Its "limitations" are precisely why its limits and
`dump_snapshot`/`load_snapshot` work at all.

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

**Its GC is pointer-based, not index-based** — `Gc<T>` is `{ ptr: NonNull<GcBox<T>> }`
and object identity is the pointer address (`id() = self.ptr.as_ptr() as usize`).
So it's point 3 on the spectrum above, not point 2. Adding durable serialization
would mean either re-architecting the handle to an arena index (monty-shaped) or
writing a full cycle-aware object-graph serializer with pointer fixup — a real
undertaking, not a serde derive. This is what tips "build on tsrun" toward "only
if in-memory suspend/resume is enough" (its Orders model handles that well).

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

## The openapi-fetch razor

A sharp test for "is this a language core or a platform": can it run a real npm
library like `openapi-fetch` (a typed fetch client)? We read its actual runtime
(`index.mjs` v0.17.0). It needs:

- **regex** (`const PATH_PARAM_RE = /\{[^{}]+\}/g`) — zapcode rejects by design;
- **Proxy** (×3, client dispatch) — zapcode has none; an engine feature, unshimmable;
- **Web platform**: `Headers` (×19), `Response`/`Request` (×13/2), `URLSearchParams`,
  `URL`, `globalThis` — none in zapcode, but shimmable as guest JS;
- **ESM** `export` — needs bundling to a flat script;
- `fetch` (×1) — the *easy* part: that's exactly the tool bridge (host-provide it).

The irony: `fetch` is the one thing already solved. What kills it is **regex +
Proxy** — engine features you can't shim. The razor cleanly separates the two
identities: a **sandbox for agent glue** (zapcode — `openapi-fetch` is out of
scope by design; the agent calls a tool, not an HTTP client) vs a **runtime for
real npm** (needs full Web platform → deno_core/Deno, since even tsrun has the
language but not the Web APIs). For untrusted agent code, needing `openapi-fetch`
is usually a smell that the agent should call a tool instead.

## denox (gsmlg-dev/denox) — evaluated 2026-07

The productized "Deno in Elixir" NIF, and a real step up from the older DenoRider.
Wraps the **full `deno_runtime`** (not just deno_core): JS/TS eval, swc transpile,
ES modules, dynamic `import()`, CDN/npm/jsr imports, bundling, a **runtime pool**,
`:telemetry`, a permissions model, and JS→Elixir callbacks (the tool bridge, via a
`CallbackHandler` GenServer). Hex-published, precompiled, CI, and a 32 KB design
doc with risk tables. **Documentation and packaging are at or beyond the ex_monty
bar — do not build `ex_deno` ourselves; this is the mature option.** It also
answers the openapi-fetch razor outright: being real Deno, it runs it.

It offers two execution models — **in-process** NIF (`Denox.Run`, fast) and
**out-of-process** (`Denox.CLI.Run`, separate OS process per instance, isolated).

Precompiled: it *does* use `rustler_precompiled` (4 targets: aarch64/x86_64 ×
macOS/Linux-**gnu**, nif 2.16/2.17). The real gap isn't "no precompiled" — it's
that the matrix is **glibc-only (no musl/Alpine, no Windows)**, and because it's
V8, a matrix miss triggers a **20–30 min from-source build**. ex_monty/ex_zapcode
share the same 4-target matrix but their fallback build is ~1–2 min, so a miss is
annoying; for denox a miss (e.g. an Alpine Docker image — a common Elixir base) is
catastrophic. That's a deploy-DX hazard inherent to shipping V8.

But the decisive concern for our use case is **crash safety**, and it's not
theoretical:

- The design doc's own risk table admits *"V8 crash takes down BEAM … don't run
  untrusted code in-process … for untrusted code, consider a port/sidecar."*
- **[Issue #3](https://github.com/gsmlg-dev/denox/issues/3)** (OPEN, "unable to
  resolve", severity: blocker): *repeated `eval_async_decode` calls can crash the
  BEAM with exit 139 (SIGSEGV)*. Minimal repro is two runtimes + one eval. It
  surfaced in the maintainer's *own* other project (Backplane), and — worst of
  all — **the maintainer cannot reproduce it locally** (passes on OTP 27/28, nif
  2.17, precompiled and source-built, stress tests green), so it's a
  nondeterministic native crash, not a fixable known bug.

The triggering pattern — **a fresh V8 runtime per script evaluation in a
long-lived BEAM** — is *exactly* what you'd do to isolate untrusted agent scripts.
And it segfaults. This is the same V8-in-NIF fragility that made DenoRider crashy,
now concretely documented and unresolved.

Verdict: denox is excellent for **running real, trusted-ish TS/JS** (ecosystem,
npm, openapi-fetch) — and for that, use it, don't reinvent it. But for **repeated
evaluation of untrusted scripts in a long-lived BEAM**, in-process denox carries a
live, unreproducible BEAM-segfault risk (issue #3), no hard resource limits, and
no durable snapshots. For that niche use out-of-process mode (`Denox.CLI.Run`,
accepting IPC cost) or an engine with no native crash surface at all (zapcode).

This is also the cleanest validation of the whole thesis: zapcode's value-typed,
no-V8 model has **no segfault surface** — the worst case is a caught Rust panic or
a clean resource-limit error, never a BEAM-killing SIGSEGV. That safety *is* the
product.

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

Two tools, two jobs:

- **ex_zapcode** for **sandboxed, untrusted, durable agent glue** — bounded
  execution, `dump/load_snapshot`, and (its quiet superpower) *no native crash
  surface*. The value-typed model is the enabling constraint, not a weakness.
- **denox** if/when we need to run **real, trusted-ish TS/JS** (npm ecosystem,
  openapi-fetch, libraries). Don't build `ex_deno` — denox is mature and beyond
  the ex_monty bar. But keep it **out-of-process** for anything untrusted or for
  repeated fresh-runtime evaluation (issue #3), and mind the glibc-only precompiled
  matrix on Alpine deploys.

They're complementary; a system could use both. For the current
untrusted-durable-sandboxed target, build on zapcode.

Two big levers stay documented but un-taken unless the need is proven (both in the
fork's `CONFORMANCE.md`): (a) heap/reference semantics for completeness — and if we
ever take it, do it monty-shaped (arena + indexed handles) so serialization
survives, *not* tsrun/V8-shaped (raw-pointer GC); (b) the free-variable scope pass
for the closure-capture blowup.
