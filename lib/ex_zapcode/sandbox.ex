defmodule ExZapcode.Sandbox do
  @moduledoc """
  High-level driver for interactive TypeScript execution — the `ExMonty.Sandbox`
  analog for zapcode.

  Automates the start/resume loop: each external function the guest `await`s is
  dispatched to a handler in the `:functions` map, and the run is resumed with
  the result until it completes. The return contract matches `ExMonty.Sandbox.run/2`
  so the two are drop-in siblings:

      {:ok, value, output} | {:error, %ExZapcode.Exception{}}

  ## Example

      {:ok, 1, ""} =
        ExZapcode.Sandbox.run(
          \"\"\"
          const r = await execute_sql({ statement: "SELECT 1 as val" });
          r.rows[0].val
          \"\"\",
          functions: %{
            "execute_sql" => fn [args] -> {:ok, %{"rows" => [%{"val" => 1}]}} end
          }
        )

  ## Handlers

  A handler is `fn args -> result` (or `fn args, kwargs -> result` for `ExMonty`
  parity — `kwargs` is always `%{}` since TypeScript calls are positional). By TS
  convention a tool is called with a single options object, so `args` is
  typically `[opts_map]`.

  Return `{:ok, value}` or `{:error, type, message}`.

  > #### Fidelity gap vs Monty {: .warning}
  > zapcode-core's `resume` only accepts a return value — there is no way to
  > inject a *throwable* error into the guest. So a handler `{:error, ...}`
  > aborts the whole run and is returned to the caller, rather than raising a
  > catchable exception inside the TypeScript (which Monty supports).
  """

  @type handler_result :: {:ok, term()} | {:error, atom(), String.t()}

  @doc """
  Compiles and runs TypeScript `code` with automatic handler dispatch.

  ## Options

    * `:inputs` — map of `name => value` bound as globals (default: `%{}`)
    * `:functions` — map of function-name strings to handler funs (default: `%{}`)
    * `:limits` — resource limits map (merged over `ExZapcode.default_limits/0`)
    * `:script_name` — accepted for `ExMonty` parity; currently unused

  ## Examples

      # Pure expression — no tools
      {:ok, 6, ""} = ExZapcode.Sandbox.run("[1, 2, 3].reduce((a, b) => a + b, 0)")

      # With a tool the guest awaits
      {:ok, 2, ""} =
        ExZapcode.Sandbox.run(
          ~s(const r = await db({ sql: "SELECT 1" }); r.rows[0].n + 1),
          functions: %{"db" => fn [%{"sql" => _}] -> {:ok, %{"rows" => [%{"n" => 1}]}} end}
        )

      # A handler error aborts the run
      {:error, %ExZapcode.Exception{type: :runtime_error}} =
        ExZapcode.Sandbox.run("await boom()",
          functions: %{"boom" => fn _ -> {:error, :runtime_error, "kaboom"} end})
  """
  @spec run(String.t(), keyword()) ::
          {:ok, term(), String.t()} | {:error, ExZapcode.Exception.t()}
  def run(code, opts \\ []) do
    functions = opts |> Keyword.get(:functions, %{}) |> normalize_functions()

    start_opts =
      opts
      |> Keyword.take([:inputs, :limits, :script_name])
      |> Keyword.put(:functions, Map.keys(functions))

    code
    |> ExZapcode.start(start_opts)
    |> loop(functions, "")
  end

  defp loop(progress, functions, acc_output) do
    case progress do
      {:function_call, name, args, snapshot, output} ->
        acc_output = acc_output <> output

        case dispatch(name, args, functions) do
          {:ok, value} ->
            snapshot
            |> ExZapcode.resume(value)
            |> loop(functions, acc_output)

          {:error, type, message} ->
            {:error, %ExZapcode.Exception{type: type, message: message}}
        end

      {:complete, value, output} ->
        {:ok, value, acc_output <> output}

      {:error, %ExZapcode.Exception{}} = err ->
        err
    end
  end

  defp dispatch(name, args, functions) do
    case Map.fetch(functions, name) do
      {:ok, fun} ->
        try do
          fun |> call_handler(args) |> normalize_result()
        rescue
          e -> {:error, :runtime_error, Exception.message(e)}
        end

      :error ->
        {:error, :reference_error, "external function '#{name}' is not defined"}
    end
  end

  # Support both `fn args` and `fn args, kwargs` (kwargs always %{} for TS).
  defp call_handler(fun, args) when is_function(fun, 1), do: fun.(args)
  defp call_handler(fun, args) when is_function(fun, 2), do: fun.(args, %{})

  defp normalize_result({:ok, _} = ok), do: ok

  defp normalize_result({:error, type, msg}) when is_atom(type),
    do: {:error, type, to_string(msg)}

  defp normalize_result({:error, msg}), do: {:error, :runtime_error, to_string(msg)}

  defp normalize_result(other),
    do: {:error, :runtime_error, "invalid handler result: #{inspect(other)}"}

  defp normalize_functions(functions) do
    Map.new(functions, fn {k, v} -> {to_string(k), v} end)
  end
end
