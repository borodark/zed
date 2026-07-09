defmodule HelloBeam.MixProject do
  use Mix.Project

  # HelloBeam — Path C3's smoke-fixture BEAM release. Purpose-built
  # tiny app to prove the Zed jail-contained-app deployment pipeline
  # with a REAL mix release (not the shell stub of C1/C2). Not
  # intended to run anything useful; it just needs to boot a
  # distributed BEAM node and respond to :net_adm.ping.

  def project do
    [
      app: :hello_beam,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        hello_beam: [
          # include_erts so the release is self-contained inside the
          # jail — no need to install erlang-runtime27 pkg.
          include_erts: true,
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HelloBeam.Application, []}
    ]
  end

  defp deps do
    [
      # Path C5: libcluster reads the topology written by Zed's
      # :cluster_config :create step (via Zed.Cluster.Config.write!)
      # and manages Node.connect over Cluster.Strategy.Epmd.
      {:libcluster, "~> 3.3"}
    ]
  end
end
