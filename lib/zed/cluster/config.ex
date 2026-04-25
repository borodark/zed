defmodule Zed.Cluster.Config do
  @moduledoc """
  Read and write the converge-time cluster artifact (S2 consumer wiring).

  Splits the IR's compile-time knowledge from the running app's
  runtime.exs in a way that doesn't make every app depend on the
  `:zed` library:

      converge time           runtime
      ─────────────           ────────
      Zed.Cluster.Topology    Zed.Cluster.Config.load!/1
      Zed.Cluster.Config        ↓
      .write!/3 ─────►  artifact file  ─────►   libcluster topologies
                       <base>/zed/cluster/<id>.config

  The artifact is an Erlang term-binary so the consumer is one
  `:erlang.binary_to_term/1` call away from the topology map. Apps
  that want to avoid the `:zed` dep entirely can read the file and
  decode themselves; apps that have `:zed` in their deps can use the
  helpers here for the type-safe path.

  Cookie is intentionally **not** written to the artifact — cookies
  belong in the encrypted secrets dataset, never in a world-readable
  config file. Apps resolve the cookie separately via
  `read_cookie!/1` (file form) or via release env (env form).

  ## Path layout

      <base>/zed/cluster/                       (ZFS-managed dir, mode 0755)
      <base>/zed/cluster/<cluster_id>.config    (mode 0644, term-binary)

  ## Atomic writes

  `write!/3` writes to a sibling tempfile and renames into place so
  the consumer never sees a half-written artifact. The rename is
  POSIX-atomic on the same filesystem.
  """

  alias Zed.Cluster.Topology
  alias Zed.IR

  @subdir "cluster"

  @doc """
  Write every cluster's libcluster topology to its artifact file
  under `<base>/zed/<subdir>/<cluster_id>.config`.

  Returns `{:ok, [path1, path2, ...]}` on success.

  Idempotent: re-running with the same IR rewrites the same file
  with the same contents (and the rename is a no-op if contents
  match — but we always rewrite to surface mtime changes for
  consumers that watch).
  """
  @spec write!(IR.t(), Path.t(), keyword) :: {:ok, [Path.t()]}
  def write!(%IR{} = ir, base_mountpoint, opts \\ []) when is_binary(base_mountpoint) do
    dir = Keyword.get(opts, :subdir, Path.join(base_mountpoint, @subdir))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)

    topologies = Topology.from_ir(ir)

    paths =
      Enum.map(topologies, fn {cluster_id, topology} ->
        path = Path.join(dir, "#{cluster_id}.config")
        write_atomic!(path, topology)
        path
      end)

    {:ok, paths}
  end

  @doc """
  Load a single cluster's libcluster topology from its artifact
  file. Returns the topology keyword shape expected by
  `config :libcluster, topologies: %{cluster_id => topology}` —
  i.e. one cluster's worth.

  Caller wraps in a map under the cluster id:

      config :libcluster, topologies: %{
        demo: Zed.Cluster.Config.load!("/var/db/zed/cluster/demo.config")
      }

  Raises if the file is missing, unreadable, or contains anything
  other than an Erlang term decoded via `:safe`.
  """
  @spec load!(Path.t()) :: keyword
  def load!(path) when is_binary(path) do
    bin = File.read!(path)
    :erlang.binary_to_term(bin, [:safe])
  end

  @doc """
  Resolve a cookie reference into a binary suitable for
  `Node.set_cookie/2`. Three accepted shapes:

    * `{:file, path}` — read the file, trim trailing newline.
    * `{:env, var}`   — read `System.get_env(var)`, raise if unset.
    * binary          — passed through (escape hatch for tests).

  Note `{:secret, ...}` IR refs are NOT accepted here — they have to
  be resolved into one of the concrete forms above by the converge
  engine before write-time. The runtime path doesn't have access to
  the IR or the Catalog and shouldn't resolve secrets directly.
  """
  @spec read_cookie!({:file, Path.t()} | {:env, binary} | binary) :: binary
  def read_cookie!({:file, path}) when is_binary(path) do
    path |> File.read!() |> String.trim_trailing("\n")
  end

  def read_cookie!({:env, var}) when is_binary(var) do
    case System.get_env(var) do
      nil -> raise "Zed.Cluster.Config: env var #{inspect(var)} unset"
      v -> v
    end
  end

  def read_cookie!(bin) when is_binary(bin), do: bin

  def read_cookie!(other) do
    raise ArgumentError,
          "Zed.Cluster.Config.read_cookie!/1: unexpected ref #{inspect(other)} — accepted: {:file, path}, {:env, var}, or a binary"
  end

  # POSIX-atomic write: tmp + rename. Same-directory rename is
  # atomic on every filesystem we care about (ZFS, tmpfs, ext4, ufs).
  defp write_atomic!(path, term) do
    bin = :erlang.term_to_binary(term)
    tmp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"
    File.write!(tmp, bin)
    File.chmod!(tmp, 0o644)
    File.rename!(tmp, path)
  end
end
