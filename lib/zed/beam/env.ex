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
  @spec resolve_cookie(cookie_ref) :: {:ok, binary} | {:error, term}
  def resolve_cookie({:env, var}) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, {:env_var_unset, var}}
      "" -> {:error, {:env_var_empty, var}}
      value -> {:ok, value}
    end
  end

  def resolve_cookie({:file, path}) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim_trailing(contents, "\n")}
      {:error, reason} -> {:error, {:cookie_file_read_failed, path, reason}}
    end
  end

  def resolve_cookie({:secret, slot}) when is_atom(slot) do
    {:error, {:secret_ref_not_yet_supported, slot}}
  end

  def resolve_cookie({:secret, slot, field}) when is_atom(slot) and is_atom(field) do
    {:error, {:secret_ref_not_yet_supported, slot, field}}
  end

  def resolve_cookie(bin) when is_binary(bin), do: {:ok, bin}

  def resolve_cookie(other), do: {:error, {:unsupported_cookie_ref, other}}

  @doc """
  Compose the env file contents for a jail-contained BEAM release.

  Given a node name atom and a resolved cookie binary, returns the
  string content the rc.d script sources — one KEY=value per line,
  trailing newline. Node name is quoted because mix release env
  files must be POSIX-shell parseable.

      iex> Zed.Beam.Env.compose_env_file(:"foo@10.0.0.1", "secret")
      "export RELEASE_DISTRIBUTION=name\\nexport RELEASE_NODE=\\"foo@10.0.0.1\\"\\nexport RELEASE_COOKIE=\\"secret\\"\\n"

  Three variables:
    * `RELEASE_DISTRIBUTION` — required by mix release to enable
      distribution. Set to `name` when the node atom's hostname
      contains a dot (FQDN or IP), `sname` otherwise. Without this,
      mix release starts non-distributed and the net_kernel bails
      with `{'EXIT', nodistribution}`.
    * `RELEASE_NODE` — the target node atom, quoted for POSIX shell.
    * `RELEASE_COOKIE` — the resolved cookie, quoted for POSIX shell.

  The `export` prefix is essential: without it, sourcing the file
  from the rc.d script sets the variables only in the sourcing
  shell's own environment; the child `bin/<app>` process doesn't
  inherit them and mix release falls back to auto-generating a
  short-name + random cookie.
  """
  @spec compose_env_file(node :: atom, cookie :: binary) :: binary
  def compose_env_file(node_name, cookie)
      when is_atom(node_name) and is_binary(cookie) do
    distribution = distribution_mode(node_name)

    """
    export RELEASE_DISTRIBUTION=#{distribution}
    export RELEASE_NODE="#{node_name}"
    export RELEASE_COOKIE="#{cookie}"
    """
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
