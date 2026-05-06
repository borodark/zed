defmodule Zed.Cluster.Config do
  @moduledoc """
  Read and write the converge-time cluster artifact (S2 consumer wiring).

  Splits the IR's compile-time knowledge from the running app's
  runtime.exs WITHOUT requiring the app to depend on the `:zed`
  library. The artifact is a **plain-text file**, one node atom per
  line — universally consumable by `File.read |> String.split |>
  Enum.map(&String.to_atom/1)` from any Elixir app, with no decoder
  dance.

      converge time           runtime
      ─────────────           ────────
      Zed.Cluster.Config       app's runtime.exs (zed-less):
      .write!/3 ─────►  artifact file  ─────►  hosts = File.read! ...
                       <base>/zed/cluster/<id>.config
                                              app's runtime.exs (zed-dep):
                                              hosts = Config.load!/1

  Plain text was chosen over Erlang term-binary after mac-247's S5a
  work showed that real apps (Plausible, craftplan) prefer to keep
  their dep tree small and read the artifact directly. The plain
  format is the format both ends agree on; the `load!/1` and
  `topology!/1` helpers are conveniences for the in-zed-tree path,
  not the only path.

  Cookie is intentionally **not** written to the artifact — cookies
  belong in the encrypted secrets dataset, never in a world-readable
  config file. Apps resolve the cookie separately via
  `read_cookie!/1` (file form) or via release env (env form).

  ## Path layout

      <base>/zed/cluster/                       (ZFS-managed dir, mode 0755)
      <base>/zed/cluster/<cluster_id>.config    (mode 0644, plain text)

  ## File format (per cluster)

      zedweb@10.17.89.10
      craftplan@10.17.89.11
      plausible@10.17.89.12
      livebook@10.17.89.13
      exmc@10.17.89.14

  Empty lines and lines starting with `#` are tolerated as comments.
  No structured strategy/options on disk — every consumer in the demo
  uses libcluster Epmd; reconstruct the keyword shape at the consumer
  if you want it (or use `topology!/1`).

  ## Atomic writes

  `write!/3` writes to a sibling tempfile and renames into place so
  the consumer never sees a half-written artifact. The rename is
  POSIX-atomic on the same filesystem.
  """

  alias Zed.IR

  @subdir "cluster"

  @doc """
  Write every cluster's host list to its artifact file under
  `<base>/zed/<subdir>/<cluster_id>.config` as plain text.

  Returns `{:ok, [path1, path2, ...]}` on success.

  Idempotent: re-running with the same IR rewrites the same file
  with the same contents (still a real rewrite — atomic via
  tmp+rename — to surface mtime changes for consumers that watch).
  """
  @spec write!(IR.t(), Path.t(), keyword) :: {:ok, [Path.t()]}
  def write!(%IR{clusters: clusters}, base_mountpoint, opts \\ []) when is_binary(base_mountpoint) do
    dir = Keyword.get(opts, :subdir, Path.join(base_mountpoint, @subdir))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)

    paths =
      Enum.map(clusters, fn cluster ->
        path = Path.join(dir, "#{cluster.id}.config")
        members = cluster.config[:members] || []
        text = render_text(members)
        write_atomic!(path, text)
        path
      end)

    {:ok, paths}
  end

  @doc """
  Load the host list from a cluster's artifact file. Returns a list
  of node atoms.

      iex> Zed.Cluster.Config.load!("/var/db/zed/cluster/demo.config")
      [:"web@10.0.0.1", :"worker@10.0.0.2"]

  Tolerates blank lines and `#`-prefix comments. Raises if the file
  is missing or any non-comment line isn't a well-shaped node atom
  (`name@host`).
  """
  @spec load!(Path.t()) :: [atom]
  def load!(path) when is_binary(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&parse_node!/1)
  end

  @doc """
  Convenience: load the host list and wrap it in the libcluster
  Epmd keyword shape, ready to drop into
  `config :libcluster, topologies: %{cluster_id => topology}`.

      config :libcluster, topologies: %{
        demo: Zed.Cluster.Config.topology!("/var/db/zed/cluster/demo.config")
      }

  Apps that prefer to keep `:zed` out of their dep tree just inline
  the three-line `File.read |> split |> map(&String.to_atom/1)`
  pattern instead.
  """
  @spec topology!(Path.t()) :: keyword
  def topology!(path) when is_binary(path) do
    [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: load!(path)]
    ]
  end

  defp render_text(members) do
    members
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp parse_node!(s) when is_binary(s) do
    case String.split(s, "@", parts: 2) do
      [name, host] when name != "" and host != "" -> String.to_atom(s)
      _ ->
        raise ArgumentError,
              "Zed.Cluster.Config: line #{inspect(s)} is not a valid node atom (expected name@host)"
    end
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
  defp write_atomic!(path, contents) when is_binary(contents) do
    tmp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"
    File.write!(tmp, contents)
    File.chmod!(tmp, 0o644)
    File.rename!(tmp, path)
  end
end
