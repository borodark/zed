# S5a status: Plausible + craftplan releases

**Completed:** 2026-04-26, mac-247 (192.168.0.247)

## Craftplan

- **Repo:** `192.168.0.33:/mnt/jeff/home/git/repos/craftplan.git` (branch `main`)
- **Commit:** `3fd59a1` — S5a: craftplan release scaffold + cluster wiring
- **Artifact:** `~/craftplan/_build/prod/rel/craftplan/`
- **Build:** `MIX_ENV=prod mix release craftplan` (stock OTP 26 + Elixir 1.17.3)
- **Changes:**
  - `releases:` block added to mix.exs
  - `libcluster` dep added
  - Cluster prologue in runtime.exs (reads topology + cookie from `/var/db/zed/`)
  - `Cluster.Supervisor` wired into Application
  - `rel/env.sh.eex` — RELEASE_COOKIE + RELEASE_NODE=craftplan@10.17.89.11
  - `imprintor` (Typst PDF NIF) marked `targets:` to skip FreeBSD — PDF generation non-essential for demo
  - Endpoint: `server: true`, binds 0.0.0.0:4000

## Plausible

- **Repo:** `192.168.0.33:/mnt/jeff/home/git/repos/plausible_analytics.git` (branch `master`)
- **Commit:** `e81f63a` — S5a: plausible release scaffold + cluster wiring
- **Artifact:** `~/analytics/_build/prod/rel/plausible/`
- **Build requires OTP 27 + Elixir 1.18 + Rust:**
  ```sh
  . ~/.kerl/installs/27.3.4.11/activate
  source ~/.kiex/elixirs/elixir-1.18.4-27.env
  export PATH=$HOME/bin:$PATH   # ~/bin/make -> gmake for siphash NIF
  MJML_BUILD=true MIX_ENV=prod mix release plausible --overwrite
  ```
- **Changes:**
  - Cluster prologue in runtime.exs (plain File.read, no zed dep)
  - `rel/env.sh.eex` — RELEASE_COOKIE + RELEASE_NODE=plausible@10.17.89.12
  - `{:rustler, optional: true}` added so mjml NIF builds from source
- **FreeBSD build prerequisites installed on mac-247:**
  - OTP 27.3.4.11 via kerl at `~/.kerl/installs/27.3.4.11/`
  - Elixir 1.18.4 via kiex at `~/.kiex/elixirs/elixir-1.18.4-27.env`
  - Rust 1.94.0 (`pkg install rust`)
  - `~/bin/make -> /usr/local/bin/gmake` (siphash NIF needs GNU make)

## Cluster wiring pattern (both apps)

Both apps read cluster config from disk at boot — no `zed` dep needed:

```elixir
# runtime.exs prologue (identical shape in both apps)
cluster_config_path = "/var/db/zed/cluster/demo.config"
if File.exists?(cluster_config_path) do
  hosts = cluster_config_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.to_atom/1)
  topologies = [demo: [strategy: Cluster.Strategy.Epmd, config: [hosts: hosts]]]
  config :libcluster, topologies: topologies
end
```

Cookie loaded from `/var/db/zed/secrets/demo_cluster_cookie` in both `rel/env.sh.eex` (RELEASE_COOKIE) and runtime.exs (belt-and-braces `set_cookie`).

## What's next

S5b (mac-248 scope): zedweb, livebook, exmc releases + pg/ch bootstrap scripts.
Then S6: end-to-end converge against this Mac Pro.
