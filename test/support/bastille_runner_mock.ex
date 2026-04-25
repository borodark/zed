defmodule Zed.Platform.Bastille.Runner.Mock do
  @moduledoc """
  Test-only runner. Records every call and returns canned responses.

  ## Usage

      setup do
        {:ok, _} = Zed.Platform.Bastille.Runner.Mock.start_link()
        Application.put_env(:zed, Zed.Platform.Bastille,
          runner: Zed.Platform.Bastille.Runner.Mock)

        on_exit(fn ->
          Application.delete_env(:zed, Zed.Platform.Bastille)
        end)

        :ok
      end

      test "create dispatches" do
        Mock.expect(:create, {"verify-sandbox: created\\n", 0})
        assert :ok = Bastille.create("foo", ip: "10.17.89.50/24")
        assert [{:create, ["foo", "15.0-RELEASE", "10.17.89.50/24"], _}] = Mock.calls()
      end

  Per-subcommand expectations: if no expectation is set for a
  subcommand, the mock returns `{"", 0}` (success, empty output).
  """

  @behaviour Zed.Platform.Bastille.Runner

  use Agent

  defstruct calls: [], expectations: %{}

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Set the response for `subcommand`'s next invocation. {output, exit_code}."
  def expect(subcommand, {output, code}) when is_atom(subcommand) and is_integer(code) do
    Agent.update(__MODULE__, fn state ->
      %{state | expectations: Map.put(state.expectations, subcommand, {output, code})}
    end)
  end

  @doc "All recorded calls, oldest first."
  def calls do
    Agent.get(__MODULE__, fn s -> Enum.reverse(s.calls) end)
  end

  @doc "Reset call log + expectations."
  def reset do
    Agent.update(__MODULE__, fn _ -> %__MODULE__{} end)
  end

  @impl true
  def run(subcommand, argv, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      response = Map.get(state.expectations, subcommand, {"", 0})
      new_state = %{state | calls: [{subcommand, argv, opts} | state.calls]}
      {response, new_state}
    end)
  end
end
