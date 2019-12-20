defmodule Crawly.Request do
  @moduledoc """
  Request wrapper

  Defines Crawly request structure.
  """
  defstruct url: nil, headers: [], prev_response: nil, options: [], retries: 0

  @type header() :: {key(), value()}
  @typep key :: binary()
  @typep value :: binary()

  @type retries :: non_neg_integer()

  @type option :: {atom(), binary()}

  @type t :: %__MODULE__{
    url: binary(),
    headers: [header()],
    prev_response: %{},
    retries: 0,
    options: [option()]
  }
end
