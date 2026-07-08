defmodule ExZapcode.Exception do
  @moduledoc """
  Represents an error raised while compiling or executing TypeScript.

  ## Fields

    * `:type` — the error class as an atom, one of:
      `:parse_error`, `:compile_error`, `:runtime_error`, `:type_error`,
      `:reference_error`, `:unknown_external_function`, `:memory_limit`,
      `:timeout`, `:stack_overflow`, `:allocation_limit`, `:snapshot_error`,
      `:sandbox_violation`
    * `:message` — the human-readable message string, or `nil`
    * `:traceback` — reserved for source-location frames; currently always `[]`
      (zapcode-core exposes an execution trace but line-level mapping is not
      yet surfaced through the NIF)
  """

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t() | nil,
          traceback: list()
        }

  defstruct [:type, :message, traceback: []]
end
