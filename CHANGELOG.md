# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## 0.1.0

Initial release.

- Elixir NIF wrapper around `zapcode-core` v1.5.3 (a minimal secure
  TypeScript-subset interpreter in Rust).
- Interactive `start`/`resume` execution model with a suspend-at-external-call
  tool bridge — the tool runs on a normal BEAM process, not inside the NIF.
- `ExZapcode.Sandbox.run/2` high-level driver and `ExZapcode.eval/2`, mirroring
  the `ExMonty` return contract (`{:ok, value, output} | {:error, %Exception{}}`).
- Resource limits: wall-clock time, memory, stack depth, allocations.
- Full value marshalling between TypeScript and Elixir terms.
- Precompiled NIFs for macOS and Linux (`aarch64`/`x86_64`) via
  `rustler_precompiled`.
