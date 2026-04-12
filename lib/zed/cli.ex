defmodule Zed.CLI do
  @moduledoc """
  CLI entry point for the `zed` escript.
  """

  def main(args) do
    {opts, command, _} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          verbose: :boolean,
          target: :string,
          module: :string
        ],
        aliases: [n: :dry_run, v: :verbose, t: :target, m: :module]
      )

    case command do
      ["converge"] -> cmd_converge(opts)
      ["diff"] -> cmd_diff(opts)
      ["rollback"] -> cmd_rollback(opts)
      ["status"] -> cmd_status(opts)
      ["version"] -> IO.puts("zed #{Zed.version()}")
      _ -> print_usage()
    end
  end

  defp cmd_converge(opts) do
    ir = load_ir(opts)
    dry_run = Keyword.get(opts, :dry_run, false)

    result = Zed.Converge.run(ir, dry_run: dry_run)
    Zed.Output.print_result(result)
  end

  defp cmd_diff(opts) do
    ir = load_ir(opts)
    diff = Zed.Converge.Diff.compute(ir)
    Zed.Output.print_diff(diff)
  end

  defp cmd_rollback(opts) do
    ir = load_ir(opts)
    target = Keyword.get(opts, :target, "@latest")

    case Zed.Converge.rollback(ir, target) do
      :ok -> IO.puts("Rollback complete.")
      {:error, reason} -> IO.puts("Rollback failed: #{inspect(reason)}")
    end
  end

  defp cmd_status(opts) do
    ir = load_ir(opts)
    state = Zed.State.read(ir)
    Zed.Output.print_status(state)
  end

  defp load_ir(opts) do
    case Keyword.get(opts, :module) do
      nil ->
        IO.puts("Error: --module (-m) is required.")
        System.halt(1)

      mod_string ->
        module = Module.concat([mod_string])

        if Code.ensure_loaded?(module) && function_exported?(module, :__zed_ir__, 0) do
          module.__zed_ir__()
        else
          IO.puts("Error: #{mod_string} is not a Zed deployment module.")
          IO.puts("Make sure it uses `use Zed.DSL` and defines a `deploy` block.")
          System.halt(1)
        end
    end
  end

  defp print_usage do
    IO.puts("""
    zed — ZFS + Elixir Deploy

    Usage: zed <command> [options]

    Commands:
      converge    Make reality match the declared state
      diff        Show what would change
      rollback    Roll back to a previous version or snapshot
      status      Show current deployment state
      version     Show zed version

    Options:
      -m, --module MODULE   Deployment module (e.g., MyInfra.Trading)
      -n, --dry-run         Show what would happen without applying
      -t, --target TARGET   Rollback target (version string or @latest)
      -v, --verbose         Verbose output
    """)
  end
end
