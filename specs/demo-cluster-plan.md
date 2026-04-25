# Demo: off Docker Compose, onto Zed — five apps, one FreeBSD host

**Status:** speculative; concrete enough to execute against. April 2026.
**Framing:** the demo's narrative is **migration off docker-compose**.
craftplan ships a `docker-compose.yml` today. Plausible ships
`plausible/community-edition` (docker-compose with Postgres +
ClickHouse + multiple sidecars). Livebook has a Docker image. The
demo takes those existing compose stacks and translates them
stanza-by-stanza into one Zed module — no Docker daemon, no
container runtime, no Kubernetes, no Helm. Same topology, same
public surface, FreeBSD jails as the boundary instead of containers.
**Goal:** demonstrate everything Zed currently is by replacing five
real docker-compose deployments with one Zed module on one Mac Pro,
with every component (apps + dependency databases) running in its
own Bastille jail.
**Audience:** the dataalienist.com follow-up blog (working title:
**"Off Docker Compose: Five Apps, One Box, No Containers"**), and a
reference rollout we can replay on demand.

---

## Decisions locked 2026-04-25

| # | Decision | Value |
|---|---|---|
| 0 | **Framing** | **Off docker-compose, onto Zed.** Each app's existing `docker-compose.yml` is the source-of-truth for what topology to reproduce. The DSL block per app is intended to map 1:1 with the compose stanzas (services, volumes, env, depends_on, ports). Side-by-side comparison goes in the blog. |
| 1 | Scope | **Single host.** Multi-host orchestration ("Layer M") not built; do not block the demo on it. |
| 2 | Apps | craftplan (off `docker-compose.prod.yml`), Plausible (off `plausible/community-edition`), zedz admin LiveView (already a Zed release), Livebook (off `livebook/livebook` image), exmc trial runner (currently bare-metal; included for the BEAM cluster diversity) |
| 3 | Dependency placement | **Every dependency in a jail too.** Postgres and ClickHouse are jails on the same host; the apps that need them route over bastille0. Mirrors what `docker-compose` does today with named services. |
| 4 | Cluster | Distributed Erlang over bastille0; one shared cookie; libcluster `:static_topology` strategy. The five BEAM jails form one cluster; DB jails are not BEAM. (docker-compose has no equivalent — this is what BEAM offers and containers don't.) |
| 5 | zedops placement | **Host process, not a jail.** `bastille create/destroy` cannot run from inside a jail without elaborate delegation; zedops stays on the host. zedweb (the admin LiveView) IS the "zedz admin" jail. |
| 6 | Storage backing | One ZFS dataset per jail under `<pool>/jails/<name>`; one extra dataset per stateful jail under `<pool>/data/<name>` mounted into the jail at the right path (PG data dir, ClickHouse store, etc.). Replaces docker-compose's named volumes. |
| 7 | Network | bastille0 (lo1-cloned) on `10.17.89.0/24`; demo uses `10.17.89.10–19`. pf rdr exposes only the admin LiveView (zedweb) and Livebook on the host's external IP; everything else is loopback-only. Replaces docker-compose's port + network blocks. |
| 8 | Demo deliverable | (a) Recorded screen capture of the converge + each app live; (b) blog post with side-by-side compose↔Zed; (c) replay script that anyone with the host can run end-to-end. |

---

## Topology

```
                            HOST (FreeBSD 15.0 Mac Pro, free-macpro-gpu)
                            ─────────────────────────────────────────────
                            zedops (uid 8502, host process)
                            │
                            └─► /var/run/zed/ops.sock  ◄── zedweb (jail #1)

         JAIL  IP                NAME              ROLE                         DEPS
         ────  ──────────        ─────             ───────                      ─────
         #1    10.17.89.10       zedweb            zed admin LiveView           —
         #2    10.17.89.11       craftplan         Phoenix ERP                  pg
         #3    10.17.89.12       plausible         analytics                    pg, ch
         #4    10.17.89.13       livebook          notebook server              —
         #5    10.17.89.14       exmc              MCMC trial runner            —
         #6    10.17.89.20       pg (postgres)     shared DB                    —
         #7    10.17.89.21       ch (clickhouse)   plausible's events DB        —

         BEAM cluster: zedweb ↔ craftplan ↔ plausible ↔ livebook ↔ exmc
                       (full mesh via libcluster :static_topology)

         pf rdr on host external interface:
           ext_if:443  ─►  10.17.89.10:4040    (zedweb)
           ext_if:8080 ─►  10.17.89.13:8080    (livebook)
         (everything else is private to bastille0)
```

---

## Source-of-truth: the existing compose stacks

The demo's per-app translation pulls from the upstream docker-compose
files. Reading each one before touching the DSL block.

| Demo jail | Source | Compose services replaced | Compose volumes replaced |
|---|---|---|---|
| `craftplan` | `~/projects/learn_erl/sim_ex/research/craftplan/docker-compose.prod.yml` | `app`, `db` (Postgres) | named volume for PG data |
| `pg` | shared between craftplan + plausible | (consolidated) | merged into one Zed dataset |
| `plausible` | upstream `plausible/community-edition` `docker-compose.yml` | `plausible`, `plausible_db`, `plausible_events_db` (ClickHouse), `mail` (Postfix; **dropped from demo**) | `db-data`, `event-data`, `geoip` |
| `ch` | from Plausible's `plausible_events_db` | (consolidated) | merged into one Zed dataset |
| `livebook` | upstream `livebook/livebook` Docker image | single service | none (notebooks live in `/data` mount) |
| `zedweb` | (no compose; this is Zed itself) | n/a | `/var/run/zed/ops.sock` nullfs from host |
| `exmc` | (no compose; bare-metal today) | n/a | trial logs/checkpoints under `<pool>/data/exmc` |

The blog's payoff section lays the original `docker-compose.yml`
next to the per-app Zed DSL block and lets the reader count lines.
Order-of-magnitude smaller is the prediction; we'll measure when the
real translation lands.

---

## Per-jail layout

### Common pattern

Each BEAM jail gets:
- `<pool>/jails/<name>` — root dataset, mountpoint `/usr/local/bastille/jails/<name>`
- `<pool>/jails/<name>/root/srv/<app>` — the release tarball unpack target
- `vnet` interface bound to bastille0 with the static IP from the table above
- An rc.d service that runs `<app>/bin/<app> daemon`
- `RELEASE_COOKIE` file at `/var/db/<app>/cookie`, mode 0400, owned by the app's run-as user (`zed` user inside the jail; not the same as the host's `zedops`)
- `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=<app>@<jail-ip>` exported via the rc.d env

### Stateful jails (#6 pg, #7 ch)

Each gets an additional `<pool>/data/<name>` dataset mounted into the jail at the canonical path:
- `<pool>/data/pg` → `/var/db/postgres` inside the pg jail
- `<pool>/data/ch` → `/var/lib/clickhouse` inside the ch jail

ZFS user properties on the data datasets carry the schema version and last-known-good snapshot pointer, so a `zed rollback` can revert the DB volume to a pre-deploy snapshot atomically.

### exmc-specific: GPU disabled for the demo

The trial runner normally uses EXLA on the host's RTX 3060 Ti. **GPU
passthrough into a jail is not supported on FreeBSD** without VT-d
shenanigans we don't want to depend on. For the demo, run exmc with
`Application.put_env(:exmc, :compiler, :binary_backend)` — slower but
proves the cluster mechanic, which is what the demo is for. Re-enable
GPU after the multi-host layer ships and exmc can run on a host
process while the cluster lives in jails.

---

## The Zed DSL spec

A single Elixir module describes the entire deployment. This is what
`MyInfra.Demo.converge/0` walks.

```elixir
defmodule MyInfra.Demo do
  use Zed.DSL

  @cluster_cookie {:secret, :demo_cluster_cookie, :value}

  deploy :demo, pool: "zroot_mac" do
    # ---------------------------------------------------------- secrets
    secret :demo_cluster_cookie, algo: :random_256_b64
    secret :pg_admin_passwd,     algo: :pbkdf2_sha256
    secret :ch_admin_passwd,     algo: :pbkdf2_sha256

    # ---------------------------------------------------------- jails

    jail :pg do
      ip4 "10.17.89.20/24"
      release "15.0-RELEASE"
      packages ["postgresql16-server"]
      dataset "data/pg", mount_in_jail: "/var/db/postgres"
      service :postgresql, env: %{
        "PGDATA" => "/var/db/postgres/16/data"
      }
    end

    jail :ch do
      ip4 "10.17.89.21/24"
      release "15.0-RELEASE"
      packages ["clickhouse"]
      dataset "data/ch", mount_in_jail: "/var/lib/clickhouse"
      service :clickhouse_server
    end

    jail :zedweb do
      ip4 "10.17.89.10/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      app :zedweb do
        release_tarball "../zed/_build/prod/rel/zedweb"
        cookie @cluster_cookie
        env %{
          "ZED_ROLE" => "web",
          "ZED_WEB_BIND" => "10.17.89.10",
          "ZED_WEB_PORT" => "4040",
          "ZED_OPS_SOCKET" => "/host_run_zed/ops.sock"
        }
        nullfs_mount "/var/run/zed", into: "/host_run_zed", mode: :ro
        health :http, url: "http://10.17.89.10:4040/health", expect: 200
      end
    end

    jail :craftplan do
      ip4 "10.17.89.11/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      depends_on :pg
      app :craftplan do
        release_tarball "../craftplan/_build/prod/rel/craftplan"
        cookie @cluster_cookie
        env %{
          "DATABASE_URL" => "postgres://craftplan:secret@10.17.89.20/craftplan",
          "PHX_HOST" => "10.17.89.11",
          "PORT" => "4000"
        }
        health :http, url: "http://10.17.89.11:4000/health", expect: 200
      end
    end

    jail :plausible do
      ip4 "10.17.89.12/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      depends_on [:pg, :ch]
      app :plausible do
        release_tarball "../plausible/_build/prod/rel/plausible"
        cookie @cluster_cookie
        env %{
          "DATABASE_URL" => "postgres://plausible:secret@10.17.89.20/plausible_db",
          "CLICKHOUSE_DATABASE_URL" => "http://plausible:secret@10.17.89.21:8123/plausible_events_db",
          "BASE_URL" => "http://10.17.89.12:8000"
        }
        health :http, url: "http://10.17.89.12:8000/api/health", expect: 200
      end
    end

    jail :livebook do
      ip4 "10.17.89.13/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      app :livebook do
        release_tarball "../livebook/_build/prod/rel/livebook"
        cookie @cluster_cookie
        env %{
          "LIVEBOOK_IP" => "10.17.89.13",
          "LIVEBOOK_PORT" => "8080",
          "LIVEBOOK_PASSWORD" => {:secret, :livebook_passwd, :value}
        }
        health :http, url: "http://10.17.89.13:8080/", expect: 200
      end
    end

    jail :exmc do
      ip4 "10.17.89.14/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      app :exmc do
        release_tarball "../pymc/exmc/_build/prod/rel/exmc"
        cookie @cluster_cookie
        env %{
          "EXMC_COMPILER" => "binary_backend",
          "ALPACA_API_KEY_ID" => {:secret, :alpaca_key, :id},
          "ALPACA_SECRET_KEY" => {:secret, :alpaca_key, :secret}
        }
        health :beam_ping, timeout: 5_000
      end
    end

    # ---------------------------------------------------------- cluster

    cluster :demo do
      strategy :static_topology
      members [
        {:zedweb,    "zedweb@10.17.89.10"},
        {:craftplan, "craftplan@10.17.89.11"},
        {:plausible, "plausible@10.17.89.12"},
        {:livebook,  "livebook@10.17.89.13"},
        {:exmc,      "exmc@10.17.89.14"}
      ]
      cookie @cluster_cookie
    end

    # ---------------------------------------------------------- network

    pf_rdr ext_if: "ue0" do
      forward 443  -> "10.17.89.10:4040"
      forward 8080 -> "10.17.89.13:8080"
      # everything else is private
    end

    # ---------------------------------------------------------- snapshots

    snapshots do
      before_deploy true
      keep 10
    end
  end
end
```

**Note**: `jail` with `dataset mount_in_jail:`, `nullfs_mount`,
`packages`, `service`, `cluster`, and `pf_rdr` verbs are **not yet
in the DSL.** They're sketched in `iteration-plan.md` Layer A5+ and
are part of the demo work. See "Effort" section below.

---

## Cluster formation

Each app's release config (`config/runtime.exs`) sets:

```elixir
config :libcluster,
  topologies: [
    demo: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [
          :"zedweb@10.17.89.10",
          :"craftplan@10.17.89.11",
          :"plausible@10.17.89.12",
          :"livebook@10.17.89.13",
          :"exmc@10.17.89.14"
        ]
      ]
    ]
  ]
```

Boot order doesn't matter; libcluster polls every 5 s and connects
when peers come up. After convergence, any node should report:

```elixir
:erlang.nodes()
# => [:"craftplan@10.17.89.11", :"plausible@10.17.89.12",
#     :"livebook@10.17.89.13",  :"exmc@10.17.89.14"]   # 4 peers
```

`:global` registration works across all five nodes. A demo trick:
register `Zed.Demo.ClusterMonitor` on one node, `:global.whereis_name`
from any other node returns the same PID.

---

## Bring-up order (host)

```sh
# 0. Pre-reqs
doas zfs allow io create,destroy,mount,snapshot,rollback,userprop,canmount,mountpoint,encryption,keyformat,keylocation zroot_mac/zed-test
doas pkg install -y bastille
doas bastille bootstrap 15.0-RELEASE update

# 1. Build the host's zedops + zedweb releases
cd ~/zed
MIX_ENV=prod mix release zedops --overwrite
MIX_ENV=prod mix release zedweb --overwrite

# 2. Build the per-app releases
cd ~/craftplan && MIX_ENV=prod mix release --overwrite
cd ~/plausible && MIX_ENV=prod mix release --overwrite
cd ~/livebook  && MIX_ENV=prod mix release --overwrite
cd ~/pymc/exmc && MIX_ENV=prod mix release --overwrite

# 3. Start zedops on the host
ZED_ROLE=ops doas /usr/local/zed/zedops/bin/zedops daemon

# 4. Bootstrap secrets (one-time)
ZED_TEST_DATASET=zroot_mac doas mix run -e 'Zed.Bootstrap.init("zroot_mac",
  passphrase: System.get_env("PASSPHRASE"),
  mountpoint: "/var/db/zed/secrets")'

# 5. Converge the demo deployment
mix run -e 'MyInfra.Demo.converge()'
```

`converge/0` does, in order: dataset creation → jail create+start →
package install in each jail → release tarball unpack → DB schema
init (postgres, clickhouse) → app start → cluster formation → health
checks. Each phase snapshots the affected datasets before mutating;
if any step fails, the entire plan rolls back via `zfs rollback`.

---

## Demo deliverable

### What the recording shows

1. **Empty box** — `bastille list` shows zero jails, `zfs list -H -o name | grep jails` shows nothing.
2. **One command** — `mix run -e 'MyInfra.Demo.converge()'`. ~3 minutes elapsed.
3. **The cluster forms** — open a remsh into any jail, `:erlang.nodes()` returns the other 4. `Cluster.Strategy.Epmd` log lines show the connections.
4. **The browsers** —
   - `https://<host>:443/` → zedweb dashboard, "Cluster" panel showing 5 nodes green.
   - `http://<host>:8080/` → Livebook landing page; create a notebook, run `Node.list()`, see the cluster.
   - From the Livebook notebook: `:rpc.call(:"plausible@10.17.89.12", Plausible.Stats, :something, [])` returns real Plausible data.
5. **One command teardown** — `mix run -e 'MyInfra.Demo.rollback("@pre-converge")'`. ~10 seconds. Box is empty again.

### Blog post

Companion piece to "What Zed Is, Now": **"Five Apps, One Box."**
~2,500 words. Picks up where "Now" leaves off and demonstrates the
single-host posture. Intended for the dataalienist.com index.

### Replay script

`specs/demo-replay.sh` — checked in; takes the host through steps
0–5 above. Idempotent enough that re-running after a partial failure
is safe.

---

## Effort

This demo requires several DSL verbs that don't exist yet. Honest
sizing per piece:

| Piece | Effort | Notes |
|---|---|---|
| **DSL: `jail` enriched verbs** (`packages`, `service`, `dataset mount_in_jail:`, `nullfs_mount`, `depends_on`, `app` block) | 1.5 d | Mostly new IR fields + Bastille adapter calls; the adapter primitives exist. |
| **DSL: `cluster` verb** | 0.5 d | Compile to libcluster config in each app's runtime.exs; or render a `cluster.config` file the apps consume. |
| **DSL: `pf_rdr` verb** | 0.5 d | EEx-render Bastille's rdr.conf format. |
| **`zed bootstrap` for non-zed app secrets** | 0.5 d | Catalog needs to support per-deploy slots (alpaca_key, livebook_passwd, demo_cluster_cookie, pg/ch admin passwds). |
| **Per-app release prep** | 2.5 d | One day for craftplan + Livebook (Phoenix-flavoured, well-known release shape); 1.5 days for Plausible (Docker-first project, may need release tweaking) + exmc (Nx/EXLA → BinaryBackend swap, GPU disabled). |
| **DB jails** | 1 d | postgres + clickhouse package install + initdb + user/db creation; pg is straightforward, clickhouse on FreeBSD may need linux-compat or pkgsrc — verify before starting. |
| **Cluster formation + libcluster wiring per app** | 0.5 d | Each app's runtime.exs gets the topology block. |
| **Demo recording + replay script + blog post** | 1.5 d | Recording is the easy part; the blog is the longer pole. |
| **Total** | **~8 d** | ≈ 1.5–2 person-weeks. |

### Risks

1. **ClickHouse on FreeBSD** — official packages are Linux-only. Options: use the `freebsd-clickhouse` port (community), use Linux compat layer, or substitute Plausible's ClickHouse with a sample-data fixture for the demo. Validate first.
2. **Plausible release** — heavily Docker-oriented; may need surgery to produce a clean `mix release`. If too painful, swap for a different recognizable Phoenix app (Realworld, Phoenix Storybook).
3. **GPU + jail incompatibility** — confirmed; demo runs exmc with BinaryBackend. Document in the blog as "the cluster pattern, not the high-perf trading pattern."
4. **`zed serve` running INSIDE the zedweb jail talking to zedops on host** — bastille0 nullfs of `/var/run/zed` into the jail is the path. Confirm Bastille supports nullfs mounts via `fstab` rules or the `bastille mount` verb.
5. **Phoenix LiveView WebSocket through pf rdr** — straightforward but worth testing; Phoenix's LongPoll fallback handles the edge case.

### What this demo is NOT

- Not a multi-host story. The cluster is on one box. The next demo (Layer M) is multi-host with `zfs send | ssh zfs receive` of the same datasets to a second box.
- Not a high-availability story. One host crashes, the demo dies. HA is post-Layer-M.
- Not a security review. The demo runs with the relaxed bring-up posture; the strict zedops-only doas rules ship later.
- Not a benchmark. exmc on BinaryBackend is dramatically slower than EXLA; the demo proves topology, not throughput.

---

## Order of operations

| Step | Deliverable | Effort | Depends on |
|---|---|---|---|
| 1 | Validate ClickHouse on FreeBSD (port? compat? fixture?) | 0.5 d | — |
| 2 | DSL verbs: `app` block, `packages`, `service`, `dataset mount_in_jail`, `nullfs_mount`, `depends_on` | 1.5 d | — |
| 3 | DSL verb: `cluster` (libcluster config rendering) | 0.5 d | step 2 |
| 4 | DSL verb: `pf_rdr` (rdr.conf rendering) | 0.5 d | — |
| 5 | Per-app secrets in `Catalog` | 0.5 d | — |
| 6 | Per-app releases (5 apps, parallel) | 2.5 d | — |
| 7 | DB jails (pg + ch) | 1 d | step 1 |
| 8 | Cluster wiring in each app's runtime.exs | 0.5 d | step 6 |
| 9 | End-to-end converge against the Mac Pro | 0.5 d | all above |
| 10 | Recording + replay script + blog post | 1.5 d | step 9 green |

Critical path: 1 → 2 → 6 → 9 → 10 = ~6 days with parallel work on
3, 4, 5, 7, 8.

---

## Open questions

1. **Which Mac Pro** — `free-macpro-gpu` (current) or `free-macpro-nvidia`? The demo doesn't need the GPU, so either. `free-macpro-gpu` is the warm one.
2. **Release the host's external IP publicly?** If yes, we get a public demo URL; if no, demo is local-network only. Public exposure means TLS via Let's Encrypt or self-signed with a trust hop.
3. **Plausible substitute?** If Plausible's release is too painful: Realworld backend, Phoenix Storybook, or an internally-built tracker. Decide before step 6.
4. **Cluster scope** — does zedweb participate in the libcluster topology, or stay isolated? The blog argues both ways. Lean: zedweb participates so the dashboard can `:rpc.call` into the other nodes for live status.
5. **Should `zed converge` block until all health checks pass, or return as soon as the converge is dispatched?** Lean: block; the demo is more impressive if `mix run -e 'MyInfra.Demo.converge()'` returns when the cluster is fully green.

---

## Cross-references

- [iteration-plan.md](iteration-plan.md) — the layer roadmap; this demo is built on layers A0 through A5a.
- [a5-bastille-plan.md](a5-bastille-plan.md) — the jail backend used by every jail.
- [a5a-privilege-boundary.md](a5a-privilege-boundary.md) — the zedweb/zedops split that the zedweb jail consumes.
- The future "Layer M" multi-host plan does not exist yet; this demo is the forcing function for writing it.
