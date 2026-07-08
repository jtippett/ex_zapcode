# ExZapcode

[![CI](https://github.com/jtippett/ex_zapcode/actions/workflows/ci.yml/badge.svg)](https://github.com/jtippett/ex_zapcode/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_zapcode.svg)](https://hex.pm/packages/ex_zapcode)

Elixir NIF wrapper for [zapcode](https://github.com/TheUncharted/zapcode), a
minimal secure **TypeScript-subset** interpreter written in Rust.

ExZapcode is the TypeScript sibling of [ExMonty](https://hex.pm/packages/ex_monty)
(Python). Both embed a small, sandboxed interpreter as a NIF and expose the same
interactive **start / resume** model — designed for running AI-agent-generated
code that calls back into your application.

- **Microsecond startup** — a bytecode VM, no Node/V8 process
- **Interactive execution** — guest code pauses at external function calls, hands
  control to Elixir, and resumes with the result
- **Resource limits** — cap wall-clock time, memory, stack depth, and allocations
- **Language-level sandbox** — no filesystem, network, env, `eval`, `import`, or
  `require`; the *only* way guest code reaches the host is through the external
  functions you register

## Installation

```elixir
def deps do
  [{:ex_zapcode, "~> 0.1"}]
end
```

Precompiled NIFs are published for `aarch64`/`x86_64` macOS and Linux, so most
users need no Rust toolchain. To force a local build, set `EXZAPCODE_BUILD=1`
(requires a stable Rust toolchain).

## Quick start

```elixir
# Evaluate an expression — the last expression is the result
{:ok, 7, ""} = ExZapcode.eval("1 + 2 * 3")

# Bind inputs as globals
{:ok, "hi Sam", ""} = ExZapcode.eval("`hi ${name}`", inputs: %{"name" => "Sam"})
```

## The tool bridge

Register host functions the guest may `await`. Execution suspends at each call,
you run the tool in ordinary Elixir (DB access, HTTP, whatever), and it resumes
with the return value:

```elixir
{:ok, 3, ""} =
  ExZapcode.Sandbox.run(
    """
    const a = await execute_sql({ statement: "SELECT 1 as n" });
    const b = await execute_sql({ statement: "SELECT 2 as n" });
    a.rows[0].n + b.rows[0].n
    """,
    functions: %{
      "execute_sql" => fn [%{"statement" => sql}] ->
        {:ok, run_query(sql)}   # -> %{"rows" => [...]}
      end
    }
  )
```

A handler is `fn args -> {:ok, value} | {:error, type, message}` (or
`fn args, kwargs` for `ExMonty` parity — `kwargs` is always `%{}` since
TypeScript calls are positional). By convention a tool is called with a single
options object, so `args` is typically `[opts_map]`.

The suspend/resume design means the tool runs on a normal BEAM process, **not**
inside the NIF — so it can safely do database and network I/O with no reentrancy
concerns.

### Low-level interactive API

`Sandbox.run/2` drives the loop for you. If you need manual control:

```elixir
{:function_call, "getWeather", [city], snapshot, _out} =
  ExZapcode.start("await getWeather(city)",
    inputs: %{"city" => "London"}, functions: ["getWeather"])

{:complete, %{"temp" => 18}, _out} =
  ExZapcode.resume(snapshot, %{"temp" => 18})
```

## Value mapping

| TypeScript          | Elixir            |
|---------------------|-------------------|
| `number` (integer)  | `integer`         |
| `number` (float)    | `float`           |
| `string`            | `String.t`        |
| `boolean`           | `true` / `false`  |
| `null` / `undefined`| `nil`             |
| array               | `list`            |
| object              | `map` (string keys) |

Objects and arrays passed *in* (inputs, tool return values) are converted the
same way in reverse. Elixir map keys become object keys as strings.

## Errors

Every public function reports failures as `{:error, %ExZapcode.Exception{type:, message:}}`,
where `type` is one of `:parse_error`, `:compile_error`, `:runtime_error`,
`:type_error`, `:reference_error`, `:unknown_external_function`, `:memory_limit`,
`:timeout`, `:stack_overflow`, `:allocation_limit`, `:snapshot_error`, or
`:sandbox_violation`.

## TypeScript subset coverage

zapcode implements a **subset** of TypeScript (types are stripped by
[oxc](https://github.com/oxc-project/oxc); a bytecode VM runs the result). It is
sized for agent glue code — data shaping and tool orchestration — not for running
npm libraries. It runs against **our fork** of `zapcode-core`
([jtippett/zapcode](https://github.com/jtippett/zapcode)), which carries
correctness fixes not yet upstream (see below).

**Works well:** `const`/`let`, arrow & named functions, recursion, template
literals, ternary, `for…of`, arrow `.map`/`.filter`/`.reduce`, array & object
destructuring (incl. **destructuring parameters** — `.map(([k, v]) => …)`),
**array & object spread** (`[...a, x]`, `{...o}`), **in-place array mutation**
(`push`/`pop`/`shift`/`unshift`/`splice`/`reverse`/`fill`), **`switch`**,
optional chaining (`?.`), nullish coalescing (`??`), `JSON.stringify`/`JSON.parse`,
common `String` methods (incl. `replace` with a string argument),
`Object.keys`/`values`/`entries`, `Math`, `class`, `typeof`, `try`/`catch`, and
async callbacks that suspend on external calls
(e.g. `cities.map(async c => await getWeather(c))`).

**Fixed in our fork** (were broken/silently-wrong in upstream v1.5.3):
array & object spread, in-place array mutation, `switch` (a bare `break` looped
forever), destructuring parameters, and regex (see below).

**Known gaps** — all now fail **loudly** (no silent wrong answers); verify against
your workload and re-check on upgrade:

| Construct | Behavior |
|-----------|----------|
| Regular expressions (`/re/`) | rejected at parse time with a clear error (use string methods) |
| `Number.prototype` methods (`toFixed`, …) | unsupported → `type_error` |
| `Date` | unsupported (deliberate — no clock in the sandbox) → `type_error` |
| `await` inside a `for…of` loop body | not yet snapshot-serializable → `snapshot_error` |

The design goal is **no silent wrong answers**: unsupported constructs raise a
tagged `ExZapcode.Exception` rather than returning a plausible-but-wrong value.
The gap table is re-characterized on every upstream bump (see
[`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md)).

## Relationship to ExMonty

The public surface intentionally mirrors `ExMonty`: `Sandbox.run/2` returns the
same `{:ok, value, output} | {:error, %Exception{}}` shape, and `%ExZapcode.Exception{}`
mirrors `%ExMonty.Exception{}`. Code that dispatches to a Python runtime can add a
TypeScript one as a near-copy.

One structural difference: zapcode has **no filesystem/OS layer** — its sandbox
denies all host access except registered functions. There is no `os:` handler
equivalent to Monty's `pathlib`/mount routing; expose file-like operations as
explicit external functions if a guest needs them.

## Development

```bash
just test    # EXZAPCODE_BUILD=1 mix test  (builds the NIF locally)
just fmt     # mix format + cargo fmt
just release # interactive version bump, tag, and push (CI builds + publishes)
```

## Fork

This package depends on [jtippett/zapcode](https://github.com/jtippett/zapcode),
a fork of [TheUncharted/zapcode](https://github.com/TheUncharted/zapcode) carrying
correctness patches (spread, array mutation, `switch`, destructuring params,
regex rejection) that are not yet upstream. The dependency is pinned by commit in
`native/ex_zapcode/Cargo.lock`. Tracking upstream and rebasing our patches: see
[`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md).

## License

MIT © James Tippett. zapcode is MIT © its authors.
