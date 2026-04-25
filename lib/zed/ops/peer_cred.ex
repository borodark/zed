defmodule Zed.Ops.PeerCred do
  @moduledoc """
  Peer-credential lookup for connected Unix-domain sockets (A5a.2).

  Wraps a small C NIF that calls `getpeereid(2)` on FreeBSD and macOS,
  and `getsockopt(SO_PEERCRED)` on Linux. Returns `{:ok, %{uid, gid}}`
  or `{:error, atom()}`.

  The NIF takes the OS file descriptor of an already-connected socket.
  Callers responsible for not racing the lookup against close/reuse —
  in practice we look up immediately on accept, before any payload
  flows.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:zed), ~c"peer_cred")
    :erlang.load_nif(path, 0)
  end

  @doc """
  Read the peer (uid, gid) from a connected socket FD.

  Returns `{:ok, %{uid: non_neg_integer, gid: non_neg_integer}}`.
  On syscall failure returns `{:error, errno_atom}` (e.g.
  `{:error, :"Bad file descriptor"}`).
  """
  @spec read(non_neg_integer) ::
          {:ok, %{uid: non_neg_integer, gid: non_neg_integer}} | {:error, atom}
  def read(fd) when is_integer(fd) and fd >= 0 do
    peer_cred_nif(fd)
  end

  defp peer_cred_nif(_fd), do: :erlang.nif_error(:nif_not_loaded)
end
