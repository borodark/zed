defmodule Zed.Platform.Bastille.Runner do
  @moduledoc """
  Runner behaviour for invoking the `bastille` CLI.

  Two implementations:

    * `Zed.Platform.Bastille.Runner.System` (default) — shells out
      via `System.cmd/3`. Used in production and `:bastille_live`
      integration tests.
    * `Zed.Platform.Bastille.Runner.Mock` (test only) — records
      calls in a `:persistent_term`-backed Agent, returns canned
      responses. Used in pure-Elixir unit tests so the suite runs on
      the dev host (Linux) without `bastille` installed.

  The runner module is selected via Application env:

      config :zed, Zed.Platform.Bastille,
        runner: Zed.Platform.Bastille.Runner.System,
        binary: "bastille",
        jails_dir: "/usr/local/bastille/jails"

  `subcommand` is the bastille verb (`:create`, `:start`, etc.).
  `argv` is the rest of the argument vector. Returning `{output,
  exit_code}` matches `System.cmd/3`'s shape.
  """

  @type subcommand :: atom()
  @type argv :: [binary()]
  @type opts :: keyword()
  @type result :: {output :: binary(), exit_code :: non_neg_integer()}

  @callback run(subcommand(), argv(), opts()) :: result()
end

defmodule Zed.Platform.Bastille.Runner.System do
  @moduledoc """
  Production runner — `System.cmd/3` against the real `bastille`
  binary.

  Special case: `:destroy` pipes `yes` into `bastille` because
  `bastille destroy` always prompts for confirmation regardless of
  flags (see `scripts/verify-bastille-host.sh` history). Implemented
  via `sh -c "yes | bastille destroy -f <name>"` rather than Port
  stdin so the implementation stays simple and matches the verify
  script's pattern.
  """

  @behaviour Zed.Platform.Bastille.Runner

  @impl true
  def run(:destroy, [name | rest], _opts) do
    bastille = Zed.Platform.Bastille.binary()
    sudo_prefix = privilege_prefix_string()

    extra =
      rest
      |> Enum.map(&shell_escape/1)
      |> Enum.join(" ")

    cmd = "yes | #{sudo_prefix}#{bastille} destroy -f #{shell_escape(name)} #{extra}"
    System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
  end

  def run(subcommand, argv, _opts) do
    bastille = Zed.Platform.Bastille.binary()
    full_args = [Atom.to_string(subcommand) | argv]

    case Zed.Platform.Bastille.privilege_prefix() do
      nil ->
        System.cmd(bastille, full_args, stderr_to_stdout: true)

      esc when is_binary(esc) ->
        System.cmd(esc, [bastille | full_args], stderr_to_stdout: true)
    end
  end

  defp privilege_prefix_string do
    case Zed.Platform.Bastille.privilege_prefix() do
      nil -> ""
      esc when is_binary(esc) -> esc <> " "
    end
  end

  # Conservative shell-escape: assume the input is alphanumeric +
  # `-_./` already (jail names are validated upstream). Anything
  # outside that set is wrapped in single quotes.
  defp shell_escape(s) when is_binary(s) do
    if Regex.match?(~r{^[A-Za-z0-9_./\-]+$}, s) do
      s
    else
      "'" <> String.replace(s, "'", "'\\''") <> "'"
    end
  end
end
