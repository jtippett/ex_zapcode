defmodule ExZapcode.Native do
  @moduledoc false

  @version Mix.Project.config()[:version]

  # Use precompiled NIFs from GitHub releases. Falls back to building locally
  # when `EXZAPCODE_BUILD=1` is set, or automatically before the first release
  # (while no committed checksum file exists yet).
  use RustlerPrecompiled,
    otp_app: :ex_zapcode,
    crate: "ex_zapcode",
    base_url: "https://github.com/jtippett/ex_zapcode/releases/download/v#{@version}",
    version: @version,
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
    ),
    force_build:
      System.get_env("EXZAPCODE_BUILD") in ["1", "true"] or
        not File.exists?("checksum-Elixir.ExZapcode.Native.exs")

  # Replaced at load time by the NIF. If these raise, the NIF failed to load.
  def start(_code, _input_names, _external_fns, _inputs, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def resume(_snapshot, _value), do: :erlang.nif_error(:nif_not_loaded)
end
