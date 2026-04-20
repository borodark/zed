defmodule Zed.QR do
  @moduledoc """
  QR rendering for zed pairing flows.

  Wraps `ProbnikQR` (path dep, sibling of zed in the workspace) with
  zed-specific payload builders. The `ProbnikQR` ANSI renderer handles
  any Erlang term; zed adds a payload constructor per flow so the wire
  format is explicit in one place and the mobile companion app
  (planned `zedz`, Layer B) parses against a stable shape.

  Admin login payload:
      {:zed_admin,
        node :: atom(),
        host_ip :: {0..255, 0..255, 0..255, 0..255},
        port :: pos_integer(),
        cert_fingerprint :: binary(),   # "sha256:<hex>"
        ott :: binary(),                # 256-bit random, base64url
        expires_at :: integer()}        # unix seconds

  The tuple format — rather than JSON — matches probnik_qr's existing
  wire protocol, reusing the mobile scanner's Erlang term regex parser
  instead of introducing a second serialisation format.
  """

  @type ip_tuple :: {0..255, 0..255, 0..255, 0..255}
  @type admin_payload ::
          {:zed_admin, atom(), ip_tuple(), pos_integer(), binary(), binary(), integer()}

  @doc """
  Build a `:zed_admin` payload term.

  `host_ip` is a 4-tuple of octets (IPv4). `port` is the zed-web
  listening port. `cert_fingerprint` should be the sha256-of-DER
  identifier returned by `Zed.Bootstrap.cert_der_fingerprint/1`. `ott`
  and `expires_at` come from `Zed.Admin.OTT.issue/1`.
  """
  @spec admin_payload(ip_tuple(), pos_integer(), binary(), binary(), integer()) ::
          admin_payload()
  def admin_payload({a, b, c, d}, port, cert_fingerprint, ott, expires_at)
      when is_integer(port) and is_binary(cert_fingerprint) and is_binary(ott) and
             is_integer(expires_at) do
    {:zed_admin, Node.self(), {a, b, c, d}, port, cert_fingerprint, ott, expires_at}
  end

  @doc "Print the ANSI QR for `payload` to stdout. Returns `:ok` or `{:error, reason}`."
  @spec show(tuple()) :: :ok | {:error, term()}
  def show(payload) when is_tuple(payload), do: ProbnikQR.show_term(payload)

  @doc "Return `{:ok, iodata}` with the ANSI QR for `payload`, without printing."
  @spec render(tuple()) :: {:ok, iodata()} | {:error, term()}
  def render(payload) when is_tuple(payload), do: ProbnikQR.render_term(payload)

  @doc """
  Return the serialised binary form of `payload`.

  Useful for logging or for callers that want to render the QR
  themselves. Matches `io_lib:format("~p", [Term])`.
  """
  @spec payload_bin(tuple()) :: binary()
  def payload_bin(payload) when is_tuple(payload), do: ProbnikQR.payload_term(payload)
end
