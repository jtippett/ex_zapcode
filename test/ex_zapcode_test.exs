defmodule ExZapcodeTest do
  use ExUnit.Case, async: true

  alias ExZapcode.Exception
  alias ExZapcode.Sandbox

  describe "basic execution" do
    test "evaluates a simple expression (last expression is the result)" do
      assert {:ok, 7, ""} = Sandbox.run("1 + 2 * 3")
    end

    test "returns complex JSON-safe values" do
      code = """
      ({
        string: "hello",
        number: 3.14,
        boolean: true,
        null_val: null,
        array: [1, 2, 3],
        nested: { key: "value" }
      })
      """

      assert {:ok, result, ""} = Sandbox.run(code)
      assert result["string"] == "hello"
      assert result["number"] == 3.14
      assert result["boolean"] == true
      assert result["null_val"] == nil
      assert result["array"] == [1, 2, 3]
      assert result["nested"] == %{"key" => "value"}
    end

    test "binds inputs as globals" do
      code = "`Hello, ${name}! You are ${age}.`"

      assert {:ok, "Hello, Zapcode! You are 30.", ""} =
               Sandbox.run(code, inputs: %{"name" => "Zapcode", "age" => 30})
    end
  end

  describe "external functions (the tool bridge)" do
    test "single external call, result flows back into the guest" do
      code = """
      const r = await execute_sql({ statement: "SELECT 1 as val" });
      r.rows[0].val
      """

      functions = %{
        "execute_sql" => fn [%{"statement" => _}] ->
          {:ok, %{"rows" => [%{"val" => 1}]}}
        end
      }

      assert {:ok, 1, ""} = Sandbox.run(code, functions: functions)
    end

    test "chains multiple external calls with result propagation" do
      code = """
      const r1 = await execute_sql({ statement: "SELECT 1 as val" });
      const r2 = await execute_sql({ statement: "SELECT 2 as val" });
      ({
        first: r1.rows[0].val,
        second: r2.rows[0].val,
        sum: r1.rows[0].val + r2.rows[0].val
      })
      """

      functions = %{
        "execute_sql" => fn [%{"statement" => stmt}] ->
          val = if String.contains?(stmt, "1"), do: 1, else: 2
          {:ok, %{"rows" => [%{"val" => val}]}}
        end
      }

      assert {:ok, %{"first" => 1, "second" => 2, "sum" => 3}, ""} =
               Sandbox.run(code, functions: functions)
    end

    test "host receives the guest's call arguments" do
      code = ~S|await echo({ a: 1, b: [2, 3], c: "x" })|

      parent = self()

      functions = %{
        "echo" => fn [args] ->
          send(parent, {:got, args})
          {:ok, args}
        end
      }

      assert {:ok, %{"a" => 1, "b" => [2, 3], "c" => "x"}, ""} =
               Sandbox.run(code, functions: functions)

      assert_received {:got, %{"a" => 1, "b" => [2, 3], "c" => "x"}}
    end

    test "arity-2 handlers work too (ExMonty parity; kwargs always empty)" do
      functions = %{"dbl" => fn [n], kwargs -> {:ok, %{"n" => n * 2, "kw" => kwargs}} end}

      assert {:ok, %{"n" => 42, "kw" => %{}}, ""} =
               Sandbox.run("await dbl(21)", functions: functions)
    end
  end

  describe "resource limits" do
    test "an infinite loop is stopped by a limit" do
      assert {:error, %Exception{type: type}} =
               Sandbox.run("while (true) {}", limits: %{max_duration_secs: 0.2})

      assert type in [:timeout, :allocation_limit, :memory_limit]
    end
  end

  describe "errors" do
    test "a parse/syntax error surfaces as a tagged Exception" do
      assert {:error, %Exception{type: type}} = Sandbox.run("const = = =")
      assert type in [:parse_error, :compile_error]
    end

    test "calling an undeclared external function is a reference error" do
      assert {:error, %Exception{}} = Sandbox.run("await nope()", functions: %{})
    end

    test "a handler error aborts the run (documented fidelity gap vs Monty)" do
      functions = %{"boom" => fn _ -> {:error, :runtime_error, "kaboom"} end}

      assert {:error, %Exception{type: :runtime_error, message: "kaboom"}} =
               Sandbox.run("await boom()", functions: functions)
    end
  end
end
