import Config

if config_env() == :prod do
  # Zed's :jail_app :deploy executor writes an env file at
  # /var/db/zed/hello_beam.env inside the jail with RELEASE_NODE and
  # RELEASE_COOKIE. The rc.d Zed generates sources it before
  # invoking bin/hello_beam. Fail loudly at boot if either is
  # missing — mix release's default env.sh handles the actual node/
  # cookie assignment; we just crash early if operator didn't wire
  # it up.
  System.fetch_env!("RELEASE_NODE")
  System.fetch_env!("RELEASE_COOKIE")

  # Path C5: libcluster topology from Zed's cluster artifact. The
  # `:cluster_config :create` executor step writes
  # /var/db/zed/cluster/<cluster_id>.config on the host; each jail
  # nullfs-mounts /var/db/zed/cluster read-only so the same path
  # inside the jail returns the same list. One node atom per line;
  # blank lines and lines starting with `#` are tolerated.
  cluster_config_path = "/var/db/zed/cluster/demo.config"

  if File.exists?(cluster_config_path) do
    hosts =
      cluster_config_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.to_atom/1)

    config :libcluster,
      topologies: [
        demo: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: hosts]
        ]
      ]
  end
end
