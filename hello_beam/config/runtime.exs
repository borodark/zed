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
end
