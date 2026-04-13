# Zed — ZFS + Elixir Deploy

Declarative BEAM application deployment on FreeBSD and illumos, using ZFS as the state store and rollback mechanism.

## What This Is

An Elixir DSL that compiles deployment declarations into convergence operations against ZFS. No K8s, no Ansible, no YAML. The tool itself is written in Elixir, runs on BEAM, deploys BEAM apps.

## Key Insight

ZFS user properties (`com.zed:version=1.4.2`) are a built-in, replicated key-value store that travels with snapshots and `zfs send/receive`. No external state store required — the deployment state IS the filesystem metadata.

## Architecture

- **DSL** (`lib/zed/dsl.ex`): Sim.DSL pattern — `__using__/1` + module attribute accumulation + `@before_compile` code generation. Verbs: `dataset`, `app`, `jail`, `zone`, `snapshots`, `cluster`.
- **IR** (`lib/zed/ir.ex`): Intermediate representation. Compile-time validated (`lib/zed/ir/validate.ex`).
- **Convergence** (`lib/zed/converge.ex`): diff → plan → apply → verify. Rollback = `zfs rollback` (instant, atomic).
- **ZFS** (`lib/zed/zfs/`): `System.cmd/3` wrappers. Properties, datasets, snapshots. `com.zed:*` namespace.
- **Platform** (`lib/zed/platform/`): Behaviour with FreeBSD (rc.d/sysrc), Illumos (SMF/svcadm), Linux (dev/test) backends.
- **BEAM** (`lib/zed/beam/`): Release deploy (tarball + symlink), health checks (`:rpc.call`, `:net_adm.ping`, HTTP).

## Development Environment

- **Primary dev**: FreeBSD jail `plausible` on TrueNAS at 192.168.0.33 (DHCP, currently 192.168.0.116)
- **ZFS pool**: `jeff` — test dataset `jeff/zed-test` delegated to jail
- **Erlang**: OTP 26 (pkg), Elixir 1.17.3 (pkg)
- **Work as root** in jail (ZFS operations require root)
- **Git remote**: `git@192.168.0.33:/mnt/jeff/home/git/repos/zed.git`
- **Workstation**: `/home/io/projects/learn_erl/zed/` on Linux (for editing, pushing)

## Test Suites

- `mix test` — 37 unit tests (DSL, IR, plan, jail, agent, cluster). Run anywhere.
- `mix test --include zfs_live` — 21 ZFS integration tests against real `jeff/zed-test`. Requires root + ZFS.
- **Total**: 58 tests, 0 failures on both Linux and FreeBSD.

## DSL Example

```elixir
defmodule MyInfra.Trading do
  use Zed.DSL

  deploy :trading, pool: "jeff" do
    dataset "apps/exmc" do
      mountpoint "/opt/exmc"
      compression :lz4
    end

    app :exmc do
      dataset "apps/exmc"
      version "1.4.2"
      node_name :"trading@plausible"
      cookie {:env, "RELEASE_COOKIE"}

      health :beam_ping, timeout: 5_000
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end
end
```

Working examples in `lib/zed/examples/`:
```elixir
# Basic deploy
Zed.Examples.TestDeploy.diff()
Zed.Examples.TestDeploy.converge()
Zed.Examples.TestDeploy.status()

# Jail deploy (app inside jail)
Zed.Examples.JailDeploy.converge(dry_run: true)
```

## Phased Plan

### Phase 1 — MVP (DONE)
- [x] DSL: dataset, app, health, snapshots verbs
- [x] IR + compile-time validation
- [x] ZFS: dataset, property, snapshot operations
- [x] Convergence engine: diff → plan → executor
- [x] Platform backends: FreeBSD, Illumos, Linux
- [x] CLI: converge, diff, rollback, status
- [x] 34 tests passing on FreeBSD + real ZFS

### Phase 1b — Wire DSL to real ZFS (DONE)
- [x] Run `MyDeploy.converge()` against jeff/zed-test
- [x] FreeBSD rc.d service generation (service_install)
- [x] BEAM release unpack + symlink (wired in executor, needs tarball)
- [x] End-to-end: DSL → converge → ZFS properties stamped
- [x] 38 tests passing (21 unit + 17 ZFS live)

### Phase 2 — illumos parity
- [ ] SMF manifest generation
- [ ] zone verb

### Phase 3 — isolation (IN PROGRESS)
- [x] jail verb: jail.conf.d generation
- [x] jail convergence: install → create steps
- [x] contains directive (app inside jail)
- [ ] zone verb: zonecfg/zoneadm (illumos)

### Phase 4 — multi-host (DONE)
- [x] Agent GenServer (`lib/zed/agent.ex`)
- [x] Cluster module for remote ops (`lib/zed/cluster.ex`)
- [x] zfs send/receive wrapper (`lib/zed/zfs/replicate.ex`)
- [x] Coordinated converge with rollback
- [x] Test setup guide (`docs/MULTI_HOST_TEST.md`)
- [x] Setup script (`scripts/setup-agent-jail.sh`)
- [x] **Tested live**: plausible → zed-agent-1 converge worked!
- [ ] mDNS discovery (manual node list works for now)

### Phase 5 — cluster + polish
- [ ] cluster verb (distributed Erlang)
- [ ] Secret resolution
- [ ] Burrito binary builds

## Design Decisions

- **Sim.DSL pattern over Exmc.DSL**: compile-time validation via `@before_compile` catches broken refs before deploy
- **ZFS properties as state**: replicated by `zfs send/receive`, zero infrastructure
- **`:rpc.call` over REST**: controller and agents are BEAM nodes, cookie IS auth
- **`System.cmd/3` over NIFs**: ZFS CLI is stable and identical on FreeBSD/illumos
- **No database**: ZFS IS the database. Snapshot list IS the audit log.

## Inspiration

- **Project FiFo** (Erlang, SmartOS): per-host agent pattern, CRDT state. Avoided: riak_core complexity, JSON/REST API, 128-repo sprawl.
- **Sim.DSL** (sim_ex): macro DSL architecture — `__using__`, attribute accumulation, `@before_compile`, AST parsing.
