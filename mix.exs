defmodule ExZapcode.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jtippett/ex_zapcode"

  def project do
    [
      app: :ex_zapcode,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "ExZapcode",
      description:
        "Elixir NIF wrapper for zapcode, a minimal secure TypeScript-subset interpreter written in Rust",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37", optional: true},
      {:rustler_precompiled, "~> 0.8"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib native/ex_zapcode/Cargo.toml native/ex_zapcode/Cargo.lock native/ex_zapcode/src checksum-Elixir.ExZapcode.Native.exs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
