# Demo cluster: per-app `runtime.exs` snippets

Each of the five BEAM apps in the demo joins the same distributed
Erlang cluster by reading two artifacts that Zed's converge writes
to disk inside the jail:

| Artifact | Path inside jail | Owner | Mode |
|---|---|---|---|
| Cluster topology | `/var/db/zed/cluster/demo.config` | the app's run-as user (read-only) | 0644 |
| Cluster cookie | `/var/db/zed/secrets/demo_cluster_cookie` | the app's run-as user (read-only) | 0400 |

Both files are nullfs-mounted from the host's `/var/db/zed/...` into
each jail's filesystem at the same path, so the app code is
host-agnostic. (The `nullfs_mount` DSL verb that produces the mount
config is part of S3 — see `specs/demo-cluster-plan.md`.)

The pattern below is identical across all five apps; only the
app-specific env (DATABASE_URL, PHX_HOST, port bindings, etc.)
differs.

---

## Universal preamble

Every demo app needs `:libcluster` in `mix.exs`:

```elixir
defp deps do
  [
    {:libcluster, "~> 3.4"},
    # ... existing deps
  ]
end
```

And a child spec under the app's main supervisor (typically in
`lib/<app>/application.ex`):

```elixir
defp cluster_supervisor_spec do
  case Application.get_env(:libcluster, :topologies) do
    nil -> []
    topologies -> [{Cluster.Supervisor, [topologies, [name: MyApp.ClusterSupervisor]]}]
  end
end

@impl true
def start(_type, _args) do
  children = cluster_supervisor_spec() ++ [
    # ... existing children
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

Putting the cluster supervisor first means peers start connecting
before the rest of the app comes up, which is what you want for
`:global` registration to work cleanly.

---

## Per-app `runtime.exs`

The snippets below are what each app's `config/runtime.exs`
contains in `:prod`. The `if config_env() == :prod do` guard keeps
dev/test untouched. Topologies and cookie come from disk — never
from compile-time config or release env.

### Pattern (all five apps share this prologue)

```elixir
import Config

if config_env() == :prod do
  # --- Cluster: read the artifact zed wrote at converge ---
  topologies = %{
    demo: Zed.Cluster.Config.load!("/var/db/zed/cluster/demo.config")
  }

  config :libcluster, topologies: topologies

  # --- Cookie: read from the encrypted secrets dataset ---
  cookie =
    Zed.Cluster.Config.read_cookie!({:file, "/var/db/zed/secrets/demo_cluster_cookie"})

  # libcluster doesn't set the cookie itself; the BEAM has to be
  # started with --cookie or have it set before distribution starts.
  # Releases set RELEASE_COOKIE from the env at boot — write the
  # cookie file's contents into RELEASE_COOKIE in rel/env.sh.eex
  # (one place per app, see below) so libcluster + Node.connect/1
  # both use the same value.
  #
  # The line below is a defensive belt-and-braces: if the env path
  # didn't fire, set the cookie now from the file we already read.
  if Node.alive?() and :erlang.get_cookie() != String.to_atom(cookie) do
    :erlang.set_cookie(Node.self(), String.to_atom(cookie))
  end
end
```

Each app then adds **its own** runtime config below. `:zed` is in
each app's deps so `Zed.Cluster.Config` is callable; if you'd
rather avoid the dep, vendor the ~30 lines of that module inline.

### `rel/env.sh.eex` (per app, writes RELEASE_COOKIE before BEAM start)

The mix release boot script reads `RELEASE_COOKIE` to set the
node's cookie *before* distribution starts, which is the only
correct place for it. Each app's `rel/env.sh.eex` reads the cookie
file and exports the env var:

```sh
#!/bin/sh

# Demo cluster cookie — same file is nullfs-mounted into every
# jail by zed converge. Reading it here means RELEASE_COOKIE is
# set before erl boots, so distributed Erlang and libcluster see
# the same value with no race.
COOKIE_FILE="/var/db/zed/secrets/demo_cluster_cookie"
if [ -r "$COOKIE_FILE" ]; then
    RELEASE_COOKIE="$(cat "$COOKIE_FILE")"
    export RELEASE_COOKIE
fi

# Distribution name — set so Node.self() resolves to the address
# bastille0 routes from. RELEASE_NODE is the mix release env var.
RELEASE_NODE="<%= @release.name %>@$(hostname -I | awk '{print $1}')"
export RELEASE_NODE
```

`hostname -I` works on Linux; on FreeBSD use `ifconfig bastille0 |
awk '/inet /{print $2; exit}'` or hardcode the jail's IP per the
demo plan (10.17.89.10–14).

### App-specific snippets

Each appends to the prologue above.

#### `zedweb` (zed repo)

```elixir
if config_env() == :prod do
  # ... prologue ...

  config :zed, ZedWeb.Endpoint,
    server: true,
    http: [ip: {10, 17, 89, 10}, port: 4040],
    secret_key_base:
      Zed.Cluster.Config.read_cookie!({:file, "/var/db/zed/secrets/secret_key_base"})

  config :zed, :role, :web
end
```

#### `craftplan`

```elixir
if config_env() == :prod do
  # ... prologue ...

  config :craftplan, Craftplan.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :craftplan, CraftplanWeb.Endpoint,
    http: [ip: {10, 17, 89, 11}, port: 4000],
    server: true,
    url: [host: "10.17.89.11", port: 4000],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
```

DATABASE_URL is set by zed in the jail's env to
`postgres://craftplan:<pg_admin_passwd>@10.17.89.20/craftplan`.

#### `plausible`

```elixir
if config_env() == :prod do
  # ... prologue ...

  config :plausible, Plausible.Repo,
    url: System.fetch_env!("DATABASE_URL")

  config :plausible, Plausible.ClickhouseRepo,
    url: System.fetch_env!("CLICKHOUSE_DATABASE_URL")

  config :plausible, PlausibleWeb.Endpoint,
    http: [ip: {10, 17, 89, 12}, port: 8000],
    server: true,
    url: [host: "10.17.89.12", port: 8000],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
```

CLICKHOUSE_DATABASE_URL points at the `ch` jail; whether ClickHouse
is reachable at all depends on S4's findings.

#### `livebook`

```elixir
if config_env() == :prod do
  # ... prologue ...

  config :livebook,
    ip: {10, 17, 89, 13},
    port: 8080,
    iframe_port: 8081,
    password:
      Zed.Cluster.Config.read_cookie!({:file, "/var/db/zed/secrets/livebook_passwd"})
end
```

Livebook treats its login password the same way as a cookie — a
file in the secrets dataset, read at boot.

#### `exmc` (trial runner)

```elixir
if config_env() == :prod do
  # ... prologue ...

  config :exmc, :compiler, :binary_backend
  config :exmc, :alpaca,
    api_key: System.fetch_env!("ALPACA_API_KEY_ID"),
    secret_key: System.fetch_env!("ALPACA_SECRET_KEY")
end
```

Alpaca creds intentionally come from env, not a file — operator
sets them in the jail's env file (under `<jail>/etc/rc.conf.d/`)
since they're operator-supplied, not auto-generated. See the demo
plan's S2 catalog note.

GPU is disabled (BinaryBackend) because jails can't pass GPU
devices through. The cluster mechanic is what's being demoed, not
high-perf trading.

---

## Verification

After `MyInfra.Demo.converge()` returns and all health checks pass,
ssh into any jail's BEAM (e.g., `bastille console zedweb` then
`iex --remsh zedweb@10.17.89.10 --cookie "$(cat
/var/db/zed/secrets/demo_cluster_cookie)"`) and confirm the cluster:

```elixir
iex(zedweb@10.17.89.10)1> Node.list()
[:"craftplan@10.17.89.11", :"plausible@10.17.89.12",
 :"livebook@10.17.89.13",  :"exmc@10.17.89.14"]

iex(zedweb@10.17.89.10)2> :rpc.call(:"livebook@10.17.89.13", :erlang, :node, [])
:"livebook@10.17.89.13"
```

If a node is missing from `Node.list()`:

1. Confirm the cookie file is the same on both ends:
   `bastille cmd <jail> cat /var/db/zed/secrets/demo_cluster_cookie`.
2. Confirm bastille0 routes between the two IPs:
   `bastille cmd <jail-A> ping -c1 <jail-B-ip>`.
3. Confirm the topology was actually written:
   `cat /var/db/zed/cluster/demo.config | hd | head` (binary file).
4. Confirm libcluster's polling kicked in:
   tail the app's stdout for `Cluster.Strategy.Epmd` lines.

The most common failure is a cookie mismatch from the file being
edited mid-deploy. The prologue's belt-and-braces `set_cookie`
catches that case at iex-attach time but won't help if the BEAM
was started with the wrong cookie.

---

## What this doesn't cover

- **Cookie rotation.** The plan's S2 catalog has `demo_cluster_cookie`
  as a generated slot; rotating it via `Bootstrap.rotate/3` will
  change the file but the running BEAMs keep the old cookie until
  restart. The runtime snippet doesn't watch the file. A future
  iteration could add a `:file_system` watcher; for the demo, a
  rolling restart is the answer.
- **Per-app TLS.** Demo runs http on bastille0 (loopback-style
  network); pf rdr terminates external TLS at the host, not at the
  jail. Each app's endpoint is plain http internally.
- **Auth between apps.** Distributed Erlang cookie-only — no
  per-call mTLS or capability tokens. Demo trust boundary is the
  host; cross-host security comes with the multi-host layer.
