defmodule Zed.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :zed,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Zed.CLI],
      deps: deps(),
      description: "Declarative BEAM deployment on ZFS. FreeBSD and illumos."
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets],
      mod: {Zed.Application, []}
    ]
  end

  defp deps do
    [
      {:propcheck, "~> 1.4", only: :test, runtime: false}
    ]
  end
end
