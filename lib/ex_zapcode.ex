defmodule ExZapcode do
  @moduledoc """
  Elixir wrapper for [zapcode](https://github.com/TheUncharted/zapcode), a
  minimal secure **TypeScript-subset** interpreter written in Rust.

  ExZapcode is the TypeScript sibling of [ExMonty](https://hex.pm/packages/ex_monty)
  (Python). Both embed a small, sandboxed interpreter as a NIF and share the same
  interactive **start/resume** model:

    * **Microsecond startup** — no Node/V8, just a bytecode VM
    * **Interactive execution** — guest code pauses at external function calls,
      hands control to Elixir, and resumes with the result
    * **Resource limits** — cap wall-clock time, memory, stack depth, allocations
    * **Language-level sandbox** — no filesystem, network, env, `eval`, or
      `import`; the *only* way guest code reaches the host is through the
      external functions you register

  ## Quick start

      # Evaluate an expression (the last expression is the result)
      {:ok, 7, ""} = ExZapcode.eval("1 + 2 * 3")

      # With inputs bound as globals
      {:ok, "hi Sam", ""} =
        ExZapcode.eval("`hi ${name}`", inputs: %{"name" => "Sam"})

  ## The tool bridge

  Register host functions the guest may `await`. Execution suspends at each call,
  you run the tool in ordinary Elixir, and it resumes with the return value:

      {:ok, 2, ""} =
        ExZapcode.Sandbox.run(
          "const r = await db({ sql: \\"SELECT 1\\" }); r.rows[0].n + 1",
          functions: %{"db" => fn [%{"sql" => _}] -> {:ok, %{"rows" => [%{"n" => 1}]}} end}
        )

  See `ExZapcode.Sandbox` for the high-level driver that automates the loop.

  ## Interactive API (low level)

      {:function_call, "getWeather", [city], snapshot, _out} =
        ExZapcode.start("await getWeather(city)", inputs: %{"city" => "London"},
          functions: ["getWeather"])

      {:complete, value, _out} = ExZapcode.resume(snapshot, %{"temp" => 18})
  """

  alias ExZapcode.{Exception, Native}

  # Conservative defaults for untrusted code. A caller-supplied `:limits` map is
  # merged over these, so specifying one limit doesn't drop the others.
  @default_limits %{
    max_duration_secs: 5.0,
    max_memory: 64 * 1024 * 1024,
    max_stack_depth: 512,
    max_allocations: 1_000_000
  }

  @type snapshot :: reference()

  @type progress ::
          {:function_call, name :: String.t(), args :: list(), snapshot(), output :: String.t()}
          | {:complete, term(), output :: String.t()}
          | {:error, Exception.t()}

  @doc "The resource limits applied when `:limits` is omitted."
  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  @doc """
  Begins interactive execution of TypeScript `code`.

  ## Options

    * `:inputs` — map of `name => value` bound as globals (default: `%{}`)
    * `:functions` — the names of host functions the guest may `await`. Either a
      list of names, or a map whose keys are the names (values ignored here).
      They must be declared up front: zapcode compiles calls to them as
      suspension points.
    * `:limits` — resource limits map, merged over `default_limits/0`
    * `:script_name` — accepted for `ExMonty` parity; currently unused

  Returns a `t:progress/0` tuple.
  """
  @spec start(String.t(), keyword()) :: progress()
  def start(code, opts \\ []) do
    inputs = opts |> Keyword.get(:inputs, %{})
    external_fns = opts |> Keyword.get(:functions, []) |> external_names()
    limits = opts |> Keyword.get(:limits) |> normalize_limits()

    input_list = Enum.map(inputs, fn {k, v} -> {to_string(k), v} end)
    input_names = Enum.map(input_list, &elem(&1, 0))

    Native.start(code, input_names, external_fns, input_list, limits) |> wrap()
  end

  @doc """
  Resumes a suspended run with the external function's return value.

  Returns the next `t:progress/0` — another `:function_call` if the guest awaits
  again, or `:complete` when it finishes.

  ## Examples

      {:function_call, "getWeather", ["London"], snap, _} =
        ExZapcode.start("await getWeather(city)",
          functions: ["getWeather"], inputs: %{"city" => "London"})

      {:complete, %{"temp" => 18}, ""} = ExZapcode.resume(snap, %{"temp" => 18})
  """
  @spec resume(snapshot(), term()) :: progress()
  def resume(snapshot, value), do: Native.resume(snapshot, value) |> wrap()

  @doc """
  Serializes a suspended snapshot to a binary for storage or transport.

  The pausing use case: a run suspends at an external function (`:function_call`),
  you `dump_snapshot/1` the snapshot to a binary, persist it (DB, queue, another
  node), run the tool whenever, then `load_snapshot/1` and `resume/2` with the
  result — possibly in a different process or after a restart.

  Non-destructive: unlike `ExMonty.dump_snapshot/1`, this does **not** consume the
  snapshot, so the same in-memory snapshot can still be `resume/2`d afterward.

  > #### Trusted input only {: .warning}
  > Only `load_snapshot/1` binaries your application produced and stored in a
  > trusted location. The bytes deserialize directly into native VM state.
  """
  @spec dump_snapshot(snapshot()) :: {:ok, binary()} | {:error, Exception.t()}
  def dump_snapshot(snapshot) do
    case Native.dump_snapshot(snapshot) do
      {:error, type, message} -> {:error, %Exception{type: type, message: message}}
      bin when is_binary(bin) -> {:ok, bin}
    end
  end

  @doc """
  Deserializes a snapshot binary produced by `dump_snapshot/1` into a snapshot
  usable with `resume/2`.
  """
  @spec load_snapshot(binary()) :: {:ok, snapshot()} | {:error, Exception.t()}
  def load_snapshot(bytes) do
    case Native.load_snapshot(bytes) do
      {:error, type, message} -> {:error, %Exception{type: type, message: message}}
      ref -> {:ok, ref}
    end
  end

  @doc """
  Compiles and runs `code` to completion, with no external functions.

  Convenience over `ExZapcode.Sandbox.run/2` for pure expressions.

      {:ok, 4, ""} = ExZapcode.eval("2 + 2")
  """
  @spec eval(String.t(), keyword()) ::
          {:ok, term(), String.t()} | {:error, Exception.t()}
  def eval(code, opts \\ []), do: ExZapcode.Sandbox.run(code, opts)

  # ── internals ───────────────────────────────────────────────────────────────

  # Turn the NIF's `{:error, type, message}` into `{:error, %Exception{}}`, so
  # every public surface reports errors as a struct (mirrors ExMonty).
  defp wrap({:error, type, message}) when is_atom(type),
    do: {:error, %Exception{type: type, message: message}}

  defp wrap(progress), do: progress

  defp external_names(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp external_names(map) when is_map(map), do: map |> Map.keys() |> Enum.map(&to_string/1)

  defp normalize_limits(nil), do: to_tuple(@default_limits)
  defp normalize_limits(map) when is_map(map), do: to_tuple(Map.merge(@default_limits, map))

  # NIF limits arrive as {time_limit_ms, memory_limit_bytes, max_stack_depth, max_allocations}.
  defp to_tuple(%{
         max_duration_secs: secs,
         max_memory: mem,
         max_stack_depth: depth,
         max_allocations: allocs
       }) do
    {round(secs * 1000), mem, depth, allocs}
  end
end
