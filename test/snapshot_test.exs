defmodule ExZapcode.SnapshotTest do
  @moduledoc """
  Durable suspend/resume: a run pauses at an external function call, its snapshot
  is serialized to a binary, and it resumes — possibly in a different process or
  after a restart — when the tool result is available.
  """
  use ExUnit.Case, async: true

  alias ExZapcode.Exception

  describe "external function calling (the tool bridge)" do
    test "start suspends at an awaited external function with name + args" do
      code = "const w = await getWeather(city); `${city}: ${w.temp}`"

      assert {:function_call, "getWeather", [city], _snapshot, _out} =
               ExZapcode.start(code, functions: ["getWeather"], inputs: %{"city" => "London"})

      assert city == "London"
    end

    test "resume feeds the tool result back into the guest to completion" do
      code = "const w = await getWeather(city); `${city}: ${w.temp}C`"

      {:function_call, "getWeather", ["London"], snap, _} =
        ExZapcode.start(code, functions: ["getWeather"], inputs: %{"city" => "London"})

      assert {:complete, "London: 18C", _} = ExZapcode.resume(snap, %{"temp" => 18})
    end

    test "multiple sequential tool calls each suspend and resume in order" do
      code = """
      const a = await fetch(1);
      const b = await fetch(2);
      a + b
      """

      p1 = ExZapcode.start(code, functions: ["fetch"])
      assert {:function_call, "fetch", [1], s1, _} = p1
      p2 = ExZapcode.resume(s1, 10)
      assert {:function_call, "fetch", [2], s2, _} = p2
      assert {:complete, 30, _} = ExZapcode.resume(s2, 20)
    end
  end

  describe "save / resume (snapshot serialization)" do
    test "round-trips through a binary: dump -> load -> resume" do
      code = "const w = await getWeather(city); w.temp * 2"

      {:function_call, "getWeather", ["Paris"], snap, _} =
        ExZapcode.start(code, functions: ["getWeather"], inputs: %{"city" => "Paris"})

      # Persist the paused computation as opaque bytes...
      assert {:ok, bytes} = ExZapcode.dump_snapshot(snap)
      assert byte_size(bytes) > 0

      # ...and later (here: a fresh snapshot ref, as if in another process) resume.
      assert {:ok, restored} = ExZapcode.load_snapshot(bytes)
      assert {:complete, 44, _} = ExZapcode.resume(restored, %{"temp" => 22})
    end

    test "dump is non-destructive — the original snapshot is still resumable" do
      code = "await f() + 1"
      {:function_call, "f", [], snap, _} = ExZapcode.start(code, functions: ["f"])

      assert {:ok, _bytes} = ExZapcode.dump_snapshot(snap)
      # Unlike ExMonty, dumping does not consume the snapshot:
      assert {:complete, 100, _} = ExZapcode.resume(snap, 99)
    end

    test "survives multiple suspensions with a persist/restore at each hop" do
      code = "const a = await step(1); const b = await step(a); a + b"

      {:function_call, "step", [1], s1, _} = ExZapcode.start(code, functions: ["step"])
      {:ok, b1} = ExZapcode.dump_snapshot(s1)
      {:ok, r1} = ExZapcode.load_snapshot(b1)

      {:function_call, "step", [5], s2, _} = ExZapcode.resume(r1, 5)
      {:ok, b2} = ExZapcode.dump_snapshot(s2)
      {:ok, r2} = ExZapcode.load_snapshot(b2)

      assert {:complete, 55, _} = ExZapcode.resume(r2, 50)
    end

    test "resuming an already-consumed in-memory snapshot errors cleanly" do
      {:function_call, "f", [], snap, _} = ExZapcode.start("await f()", functions: ["f"])
      assert {:complete, 1, _} = ExZapcode.resume(snap, 1)
      # snap was consumed by resume; a second resume must not crash.
      assert {:error, %Exception{type: :snapshot_consumed}} = ExZapcode.resume(snap, 2)
    end

    test "the loaded result matches the in-memory result exactly" do
      code = "const x = await g(); ({ doubled: x * 2, plus: x + 1 })"

      {:function_call, "g", [], snap, _} = ExZapcode.start(code, functions: ["g"])
      {:ok, bytes} = ExZapcode.dump_snapshot(snap)
      {:ok, restored} = ExZapcode.load_snapshot(bytes)

      {:complete, in_memory, _} = ExZapcode.resume(snap, 21)
      {:complete, from_disk, _} = ExZapcode.resume(restored, 21)
      assert in_memory == from_disk
      assert from_disk == %{"doubled" => 42, "plus" => 22}
    end
  end
end
