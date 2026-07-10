defmodule Zed.Beam.Env do
  @moduledoc """
  Converge-time resolution of a mix-release env file for a
  jail-contained app.

  Path C3 needs to bridge the DSL's cookie/env references
  (`{:env, "VAR"}`, `{:file, path}`, `{:secret, slot[, field]}`) into
  an actual `KEY=value` env file inside the jail's rootfs. The
  release's `bin/<app>` script reads `RELEASE_COOKIE` and
  `RELEASE_NODE` from its environment; the rc.d script Zed generates
  already sources the env file before invoking `command`, so writing
  those two lines is enough to boot a distributed BEAM node
  correctly.

  This module intentionally mirrors `Zed.Cluster.Config.read_cookie!/1`
  for the `{:env, VAR}` and `{:file, path}` shapes. `{:secret, ...}`
  resolution is not yet implemented — it needs the ZFS-property
  lookup for `com.zed:secret.<slot>.path` and coordination with
  `Zed.Bootstrap`. Deferred until an app actually declares one; for
  now `resolve_cookie/1` returns a clear error.
  """

  @type cookie_ref ::
          {:env, binary}
          | {:file, Path.t()}
          | {:secret, atom}
          | {:secret, atom, atom}
          | binary

  @doc """
  Resolve a cookie reference to its literal binary value at converge
  time. Returns `{:ok, binary}` on success or `{:error, reason}`.

  For `{:env, VAR}`, reads the current process's environment via
  `System.get_env/1`. This is the operator's responsibility to set
  before invoking converge — SmokeContainedRealApp expects the
  operator to `export SMOKE_COOKIE=...` (or equivalent) in the shell
  that launches iex.

  For `{:file, path}`, reads the file and trims one trailing newline.
  """
  @spec resolve_cookie(cookie_ref, keyword) :: {:ok, binary} | {:error, term}
  def resolve_cookie(ref, opts \\ [])

  def resolve_cookie({:env, var}, _opts) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, {:env_var_unset, var}}
      "" -> {:error, {:env_var_empty, var}}
      value -> {:ok, value}
    end
  end

  def resolve_cookie({:file, path}, _opts) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim_trailing(contents, "\n")}
      {:error, reason} -> {:error, {:cookie_file_read_failed, path, reason}}
    end
  end

  # Path C6: {:secret, slot[, field]} resolves against the Zed
  # metadata dataset stamped by Bootstrap. Caller must pass
  # `dataset:` opt with the base dataset name (e.g. "mac_zroot/zed").
  # Falls closed — no dataset means no resolution.
  def resolve_cookie({:secret, slot, field}, opts) when is_atom(slot) and is_atom(field) do
    case Keyword.fetch(opts, :dataset) do
      {:ok, dataset} when is_binary(dataset) ->
        case Zed.Secrets.Resolve.resolve(dataset, slot, field) do
          {:ok, bytes} -> {:ok, String.trim_trailing(bytes, "\n")}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, {:secret_dataset_not_provided, slot, field}}
    end
  end

  def resolve_cookie({:secret, slot}, opts) when is_atom(slot) do
    resolve_cookie({:secret, slot, :value}, opts)
  end

  def resolve_cookie(bin, _opts) when is_binary(bin), do: {:ok, bin}

  def resolve_cookie(other, _opts), do: {:error, {:unsupported_cookie_ref, other}}

  @doc """
  Resolve an env-value reference for `extra_env`. Same shape family as
  `resolve_cookie/2` — accepts a binary passthrough, `{:env, "VAR"}`,
  `{:file, path}`, or `{:secret, slot[, field]}`. The `dataset:` opt
  is required only for the `:secret` form.

  Used by `compose_env_file/3` to walk the operator's `env %{...}` map
  at converge time. Any `{:error, _}` propagates out unchanged so the
  executor can log a coherent failure alongside the cookie's own
  resolution errors.
  """
  @spec resolve_env_value(cookie_ref, keyword) :: {:ok, binary} | {:error, term}
  def resolve_env_value(ref, opts \\ [])

  def resolve_env_value({:env, var}, _opts) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, {:env_var_unset, var}}
      "" -> {:error, {:env_var_empty, var}}
      value -> {:ok, value}
    end
  end

  def resolve_env_value({:file, path}, _opts) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim_trailing(contents, "\n")}
      {:error, reason} -> {:error, {:env_file_read_failed, path, reason}}
    end
  end

  def resolve_env_value({:secret, slot, field}, opts) when is_atom(slot) and is_atom(field) do
    case Keyword.fetch(opts, :dataset) do
      {:ok, dataset} when is_binary(dataset) ->
        case Zed.Secrets.Resolve.resolve(dataset, slot, field) do
          {:ok, bytes} -> {:ok, String.trim_trailing(bytes, "\n")}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, {:secret_dataset_not_provided, slot, field}}
    end
  end

  def resolve_env_value({:secret, slot}, opts) when is_atom(slot) do
    resolve_env_value({:secret, slot, :value}, opts)
  end

  def resolve_env_value(bin, _opts) when is_binary(bin), do: {:ok, bin}

  def resolve_env_value(other, _opts), do: {:error, {:unsupported_env_ref, other}}

  @doc """
  Compose the env file contents for a jail-contained BEAM release.

  Given a node name atom and a resolved cookie binary, returns the
  string content the rc.d script sources — one KEY=value per line,
  trailing newline. Node name is quoted because mix release env
  files must be POSIX-shell parseable.

      iex> Zed.Beam.Env.compose_env_file(:"foo@10.0.0.1", "secret")
      "export RELEASE_DISTRIBUTION=name\\nexport RELEASE_NODE=\\"foo@10.0.0.1\\"\\nexport RELEASE_COOKIE=\\"secret\\"\\n"

  Three baseline variables:
    * `RELEASE_DISTRIBUTION` — required by mix release to enable
      distribution. Set to `name` when the node atom's hostname
      contains a dot (FQDN or IP), `sname` otherwise. Without this,
      mix release starts non-distributed and the net_kernel bails
      with `{'EXIT', nodistribution}`.
    * `RELEASE_NODE` — the target node atom, quoted for POSIX shell.
    * `RELEASE_COOKIE` — the resolved cookie, quoted for POSIX shell.

  Optional `extra_env` map merges after the baseline — its keys must
  be strings; values must be strings after any reference resolution.
  Use for application config the release reads from its own
  environment (Path C4's PEER_NODE for the two-node cluster smoke,
  for example).

  Path C7: this arity takes only pre-resolved binaries in the map.
  See `compose_env_file/4` for a variant that resolves `{:secret, ...}`
  / `{:env, ...}` / `{:file, ...}` refs in `extra_env` values before
  interpolation.

  The `export` prefix is essential: without it, sourcing the file
  from the rc.d script sets the variables only in the sourcing
  shell's own environment; the child `bin/<app>` process doesn't
  inherit them and mix release falls back to auto-generating a
  short-name + random cookie.
  """
  @spec compose_env_file(node :: atom, cookie :: binary, extra_env :: %{binary => binary}) ::
          binary
  def compose_env_file(node_name, cookie, extra_env \\ %{})
      when is_atom(node_name) and is_binary(cookie) and is_map(extra_env) do
    distribution = distribution_mode(node_name)

    baseline = """
    export RELEASE_DISTRIBUTION=#{distribution}
    export RELEASE_NODE="#{node_name}"
    export RELEASE_COOKIE="#{cookie}"
    """

    extra_lines =
      extra_env
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> ~s(export #{k}="#{v}"\n) end)
      |> Enum.join()

    baseline <> extra_lines
  end

  @doc """
  Resolving variant of `compose_env_file/3`. `extra_env` values may be
  binaries (passthrough) or refs (`{:env, ...}`, `{:file, ...}`,
  `{:secret, ...}`). `opts` is threaded to `resolve_env_value/2` — in
  particular `dataset:` is needed for `:secret` refs.

  Returns `{:ok, iodata}` on success or `{:error, {:env_key, key,
  reason}}` on the first failed resolution. Sort order is stable
  (alphabetical by key) so the first error is deterministic.
  """
  @spec compose_env_file(node :: atom, cookie :: binary, extra_env :: map, opts :: keyword) ::
          {:ok, binary} | {:error, term}
  def compose_env_file(node_name, cookie, extra_env, opts)
      when is_atom(node_name) and is_binary(cookie) and is_map(extra_env) and is_list(opts) do
    Enum.reduce_while(Enum.sort_by(extra_env, fn {k, _} -> k end), {:ok, %{}}, fn
      {k, v}, {:ok, acc} ->
        case resolve_env_value(v, opts) do
          {:ok, resolved} -> {:cont, {:ok, Map.put(acc, k, resolved)}}
          {:error, reason} -> {:halt, {:error, {:env_key, k, reason}}}
        end
    end)
    |> case do
      {:ok, resolved_map} -> {:ok, compose_env_file(node_name, cookie, resolved_map)}
      {:error, _} = err -> err
    end
  end

  # `name` when the hostname contains a dot — matches Erlang's long-
  # names mode. `sname` for bare hostnames.
  defp distribution_mode(node_name) do
    case node_name |> Atom.to_string() |> String.split("@", parts: 2) do
      [_name, host] ->
        if String.contains?(host, "."), do: "name", else: "sname"

      _ ->
        "sname"
    end
  end
end
