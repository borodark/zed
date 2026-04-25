defmodule Zed.Platform.Bastille do
  @moduledoc """
  Typed adapter around the `bastille` CLI for jail lifecycle.

  Each function returns `:ok | {:error, reason}` (lifecycle ops) or
  `{:ok, output} | {:error, reason}` (info / cmd ops). All shells out
  via the configured `Runner`; tests swap in `Runner.Mock`.

  ## Configuration

      config :zed, Zed.Platform.Bastille,
        runner: Zed.Platform.Bastille.Runner.System,
        binary: "bastille",
        jails_dir: "/usr/local/bastille/jails",
        default_release: "15.0-RELEASE"

  ## Jail naming

  Jail names accepted by this adapter are restricted to
  `[A-Za-z0-9_-]+`. The bastille CLI itself accepts dots, but `.` in
  a name means "all jails" in some Bastille subcommands — disallowed
  here to avoid foot-guns. Any name that doesn't match the regex
  yields `{:error, :invalid_name}` without invoking the runner.

  ## Subcommands covered (A5.1)

    * `create/2`  — `bastille create <name> <release> <ip>`
    * `start/1`   — `bastille start <name>`
    * `stop/1`    — `bastille stop <name>`
    * `destroy/2` — `yes | bastille destroy -f <name>` (confirmation
       always answered yes — see `Runner.System.run/3`)
    * `cmd/2`     — `bastille cmd <name> <argv...>`
    * `exists?/1` — filesystem check at `<jails_dir>/<name>/`; does not
       call bastille at all (more reliable across Bastille versions)

  Future iterations (A5.2) add `rdr`, `network`, etc.
  """

  alias Zed.Platform.Bastille.Runner

  @name_regex ~r{^[A-Za-z0-9_\-]+$}

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @spec create(name :: binary(), opts :: keyword()) :: :ok | {:error, term()}
  def create(name, opts) when is_binary(name) and is_list(opts) do
    with :ok <- validate_name(name),
         {:ok, ip} <- Keyword.fetch(opts, :ip) |> ok_or({:missing_opt, :ip}) do
      release = Keyword.get(opts, :release, default_release())
      classify(runner().run(:create, [name, release, ip], []))
    end
  end

  @spec start(name :: binary()) :: :ok | {:error, term()}
  def start(name) when is_binary(name) do
    with :ok <- validate_name(name) do
      classify(runner().run(:start, [name], []))
    end
  end

  @spec stop(name :: binary()) :: :ok | {:error, term()}
  def stop(name) when is_binary(name) do
    with :ok <- validate_name(name) do
      classify(runner().run(:stop, [name], []))
    end
  end

  @spec destroy(name :: binary(), opts :: keyword()) :: :ok | {:error, term()}
  def destroy(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with :ok <- validate_name(name),
         :ok <- classify(runner().run(:destroy, [name], opts)) do
      # Bastille 1.4 has been observed to exit 0 while leaving the
      # jail in place (e.g. when -a was missing for a running jail).
      # Verify the post-condition; surface a clear error if the
      # adapter's contract was violated by the underlying CLI.
      if exists?(name) do
        {:error, {:destroy_did_nothing, name}}
      else
        :ok
      end
    end
  end

  @spec cmd(name :: binary(), argv :: [binary()]) :: {:ok, binary()} | {:error, term()}
  def cmd(name, argv) when is_binary(name) and is_list(argv) do
    with :ok <- validate_name(name) do
      case runner().run(:cmd, [name | argv], []) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, {:bastille_exit, code, String.trim(output)}}
      end
    end
  end

  @doc """
  Returns `true` iff `bastille list` includes a row whose Name
  column equals `name`.

  We tried two filesystem-only strategies first; both failed:
    1. `File.dir?(<jails_dir>/<name>)` — false-positive on the
       empty mountpoint stub bastille leaves after destroy.
    2. Directory-non-empty check — false-negative when the BEAM
       runs as a non-root user that can't read the root-owned
       jail directory (`File.ls` returns `:eacces`).

  Authoritative answer comes from bastille itself: invoke
  `bastille list` (via the runner, which prepends doas / sudo as
  configured) and look for the name in the second column. This
  works regardless of jail-state, ZFS-vs-UFS backend, or bastille
  version.
  """
  @spec exists?(name :: binary()) :: boolean()
  def exists?(name) when is_binary(name) do
    case validate_name(name) do
      :ok ->
        case runner().run(:list, [], []) do
          {output, 0} -> name_in_list?(output, name)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp name_in_list?(output, name) do
    output
    |> String.split("\n", trim: true)
    |> Enum.any?(&list_row_matches?(&1, name))
  end

  defp list_row_matches?(line, name) do
    # bastille list output (default columns):
    #   JID  Name        Boot  Prio  State  Type  IP Address  Published Ports  Release  Tags
    # Name is column 2 (index 1).
    case String.split(line) do
      [_jid, ^name | _rest] -> true
      _ -> false
    end
  end

  # ----------------------------------------------------------------
  # Configuration accessors (also used by Runner.System)
  # ----------------------------------------------------------------

  @doc "Path to the `bastille` binary, from app env (default `bastille`)."
  def binary, do: config(:binary, "bastille")

  @doc "Bastille jails root directory, from app env (default `/usr/local/bastille/jails`)."
  def jails_dir, do: config(:jails_dir, "/usr/local/bastille/jails")

  @doc "Default FreeBSD release for create/2, from app env."
  def default_release, do: config(:default_release, "15.0-RELEASE")

  @doc """
  Privilege-escalation command to prepend to `bastille` invocations.

  Bastille refuses to run as a non-root user, exiting with
  `Bastille: Permission Denied / root / sudo / doas required`. Set
  this to `"doas"` (or `"sudo"`) on hosts where the zed BEAM
  process runs as a non-root user. `nil` (the default) means call
  bastille directly — appropriate when zed runs as root or when
  `bastille` is invoked through some other escalation already.

      config :zed, Zed.Platform.Bastille, privilege_prefix: "doas"

  The :bastille_live integration test sets this to "doas" so the
  test runner (typically the `io` user with a wheel-doas rule for
  `cmd bastille`) can drive the round-trip without manual sudo.
  """
  def privilege_prefix, do: config(:privilege_prefix, nil)

  defp runner, do: config(:runner, Runner.System)

  defp config(key, default) do
    :zed
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_regex, name) do
      :ok
    else
      {:error, :invalid_name}
    end
  end

  defp ok_or(:error, fallback), do: {:error, fallback}
  defp ok_or({:ok, v}, _), do: {:ok, v}

  # Returns :ok on exit 0; otherwise a structured error with the
  # captured (stderr-merged) output. Trim trailing newlines so
  # error-string comparisons in tests are stable.
  defp classify({_output, 0}), do: :ok
  defp classify({output, code}), do: {:error, {:bastille_exit, code, String.trim(output)}}
end
