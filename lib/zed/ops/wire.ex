defmodule Zed.Ops.Wire do
  @moduledoc """
  Wire format for the zedweb ↔ zedops Unix socket (A5a.2).

  Each frame is a length-prefixed binary; the framing itself is owned
  by `:gen_tcp`'s `packet: 4` mode (4-byte big-endian length, network
  order). This module's job is only to (de)serialise the payload —
  Erlang external term, decoded with `safe: true` so a hostile
  payload cannot mint atoms.

  Both ends are BEAM, so term format is the right tool: faithful
  preservation of tuples / atoms / maps with no JSON escaping cost.

  Payloads are bounded at 64 KiB. Every action we send is a tiny
  request envelope (action atom, request_id, args, signature); none
  legitimately approach the limit. A larger payload is a bug or an
  attack and we reject it without parsing.
  """

  @max_payload 64 * 1024

  @type request ::
          {:zedops, :v1, request_id :: binary, action :: atom, payload :: term, signature :: binary}

  @type reply ::
          {:zedops_reply, request_id :: binary, :ok | {:ok, term} | {:error, term}}

  @doc """
  Serialise `term` to a binary suitable for sending over a `packet: 4`
  socket. Returns `{:error, {:payload_too_large, n}}` if the encoded
  size exceeds `#{@max_payload}` bytes.
  """
  @spec encode(term) :: {:ok, binary} | {:error, {:payload_too_large, non_neg_integer}}
  def encode(term) do
    bin = :erlang.term_to_binary(term)

    case byte_size(bin) do
      n when n > @max_payload -> {:error, {:payload_too_large, n}}
      _ -> {:ok, bin}
    end
  end

  @doc """
  Decode a frame received from the socket. `safe: true` rejects atoms
  the local node has not seen — a hardening against atom-table
  exhaustion. Malformed payloads return `{:error, :bad_term}`.
  """
  @spec decode(binary) :: {:ok, term} | {:error, :bad_term | {:payload_too_large, non_neg_integer}}
  def decode(bin) when is_binary(bin) do
    cond do
      byte_size(bin) > @max_payload ->
        {:error, {:payload_too_large, byte_size(bin)}}

      true ->
        try do
          {:ok, :erlang.binary_to_term(bin, [:safe])}
        rescue
          ArgumentError -> {:error, :bad_term}
        end
    end
  end

  @doc "Maximum encoded payload size accepted in either direction."
  def max_payload, do: @max_payload
end
