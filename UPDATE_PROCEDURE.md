# ExZapcode Update Procedure

Run this procedure periodically to pull upstream [zapcode](https://github.com/TheUncharted/zapcode)
changes into ExZapcode.

## Overview

ExZapcode depends on the `zapcode-core` crate via a git dependency pinned to a
release tag in `native/ex_zapcode/Cargo.toml`; the exact commit is locked in
`native/ex_zapcode/Cargo.lock` (committed, and shipped in the Hex package, so
builds are reproducible). Upstream zapcode is experimental and under active
development — its README warns "APIs may change." This procedure walks through
pulling, assessing, and integrating changes.

**Track tagged releases, not `master`.** Upstream uses release-please to cut
`vX.Y.Z` tags; target the latest tag unless you explicitly need an unreleased fix.

---

## Phase 1: Pull and Assess

### 1.1 Find the latest upstream tag

```bash
git ls-remote --tags https://github.com/TheUncharted/zapcode.git \
  | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -5
```

Pick the highest `vX.Y.Z` tag. That's the **target tag** for this update.

### 1.2 Identify our current pin

```bash
grep 'tag = ' native/ex_zapcode/Cargo.toml
grep -A2 'name = "zapcode-core"' native/ex_zapcode/Cargo.lock   # exact locked commit
```

### 1.3 Review changes since our pin

This is the critical step. The entire public surface we bind to is re-exported
from `crates/zapcode-core/src/lib.rs`, so diff that first (clone or browse on
GitHub):

```bash
git clone https://github.com/TheUncharted/zapcode.git /tmp/zapcode
cd /tmp/zapcode
git diff <OUR_TAG>..<TARGET_TAG> -- crates/zapcode-core/src/lib.rs
```

Then the modules behind the types we actually use:

```bash
git diff <OUR_TAG>..<TARGET_TAG> -- \
  crates/zapcode-core/src/vm/mod.rs       `# VmState, ZapcodeRun, RunResult` \
  crates/zapcode-core/src/value.rs        `# Value enum (our marshalling)` \
  crates/zapcode-core/src/snapshot.rs     `# ZapcodeSnapshot::resume` \
  crates/zapcode-core/src/sandbox.rs      `# ResourceLimits` \
  crates/zapcode-core/src/error.rs        `# ZapcodeError variants`
```

### 1.4 Read the commit log for context

```bash
git log --oneline <OUR_TAG>..<TARGET_TAG> -- crates/zapcode-core/
```

---

## Phase 2: Classify Changes

### Breaking (must fix before bump)

Everything ExZapcode binds to lives in one file, `native/ex_zapcode/src/lib.rs`:

| We use | Where in `lib.rs` |
|--------|-------------------|
| `ZapcodeRun::new(code, inputs, external_fns, limits)` / `.run()` | `start` NIF |
| `RunResult { state, stdout }` | `start` NIF |
| `VmState::{Complete, Suspended { function_name, args, snapshot }}` | `encode_state` |
| `ZapcodeSnapshot::resume(self, Value)` | `resume` NIF |
| `Value` variants (`Undefined/Null/Bool/Int/Float/String/Array/Object/…`) | `encode_value`, `decode_value` |
| `ResourceLimits { memory_limit_bytes, time_limit_ms, max_stack_depth, max_allocations }` | `decode_limits` |
| `ZapcodeError` variants | `error_tag` |

Watch especially for:

- **New `Value` variants** → add an arm to `encode_value` (and `decode_value` if
  it can arrive from Elixir). A non-exhaustive match is a compile error.
- **New `ZapcodeError` variants** → add an arm to `error_tag` and a matching atom
  in the `atoms!` block; surface it in `ExZapcode.Exception`'s `@type`.
- **Changed `ResourceLimits` fields** → update `decode_limits` and the
  `to_tuple/1` builder in `lib/ex_zapcode.ex`.
- **A second `VmState` suspension reason** (today there is only one) → extend
  `encode_state` and the `ExZapcode.Sandbox` loop.

### Non-breaking

- Bug fixes / new builtins / broader TypeScript-subset coverage (verify with the
  probe below).
- Performance improvements.

---

## Phase 3: Update

### 3.1 Point at a local checkout for iteration (optional)

```toml
# native/ex_zapcode/Cargo.toml — swap the git dep for a path dep while iterating:
# zapcode-core = { git = "https://github.com/TheUncharted/zapcode.git", tag = "v1.5.3" }
zapcode-core = { path = "/tmp/zapcode/crates/zapcode-core" }
```

### 3.2 Build and fix compile errors

```bash
cd native/ex_zapcode && cargo check
```

### 3.3 Run the suite

```bash
EXZAPCODE_BUILD=1 mix test
```

### 3.4 Re-characterize the TypeScript subset

Upstream is where language coverage grows or regresses. Re-run a probe of common
agent-generated constructs (array spread, object spread, `switch`, `Object.entries`,
`Number.prototype` methods, regex `replace`, async callbacks that suspend) and
update the "Known gaps" table in `README.md`. Silent *wrong answers* (e.g. a
non-flattening array spread) matter more than outright errors — check values, not
just that it ran.

---

## Phase 4: Pin and Ship

### 4.1 Switch back to the git tag and re-lock

```toml
zapcode-core = { git = "https://github.com/TheUncharted/zapcode.git", tag = "<TARGET_TAG>" }
```

```bash
cd native/ex_zapcode && cargo update -p zapcode-core
cd ../.. && mix clean && EXZAPCODE_BUILD=1 mix test
```

Confirm `Cargo.lock` now records the target tag's commit.

### 4.2 Update CHANGELOG.md

Add an entry under `[Unreleased]` summarizing what changed from the ExZapcode
user's perspective (new/removed error types, subset coverage changes, etc.).

### 4.3 Release

```bash
just release   # bumps mix.exs + CHANGELOG, tags, pushes; CI builds NIFs + publishes to Hex
```
