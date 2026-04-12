# Zed — ZFS + Elixir Deploy

Declarative BEAM application deployment on FreeBSD and illumos, using ZFS as the state store and rollback mechanism.

## The Idea

ZFS user properties (`com.zed:version=1.4.2`) are a built-in, replicated key-value store that travels with snapshots and `zfs send/receive`. This replaces etcd, consul, and state files entirely. **The deployment state IS the filesystem metadata.**

## Features

- **DSL** — Elixir macros for declaring infrastructure
- **Convergence** — diff → plan → apply → verify
- **Instant Rollback** — `zfs rollback` is O(1) and atomic
- **Jails** — FreeBSD jail.conf.d generation
- **Multi-Host** — Erlang distribution + `:rpc.call`
- **Replication** — `zfs send/receive` moves state with data

## Quick Example

```elixir
defmodule MyInfra.Prod do
  use Zed.DSL

  deploy :prod, pool: "tank" do
    dataset "apps/myapp" do
      compression :lz4
    end

    app :myapp do
      dataset "apps/myapp"
      version "1.0.0"
      cookie {:env, "RELEASE_COOKIE"}
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end
end

# Use it
MyInfra.Prod.diff()       # Show what would change
MyInfra.Prod.converge()   # Apply changes
MyInfra.Prod.status()     # Read state from ZFS
MyInfra.Prod.rollback("@latest")  # Instant rollback
```

## Multi-Host Deployment

```elixir
# Start agents on each host
Zed.Agent.start_link()

# From controller, connect and deploy
Zed.Cluster.connect(:"zed@host2")
Zed.Cluster.converge_all(ir)

# Coordinated deploy with automatic rollback on failure
Zed.Cluster.converge_coordinated(ir)
```

## Installation

```sh
git clone <repo>
cd zed
mix deps.get
mix compile

# Run tests
mix test                      # 37 unit tests
mix test --include zfs_live   # + 21 ZFS integration tests
```

## Requirements

- FreeBSD or illumos (Linux for dev/test only)
- ZFS pool with delegated dataset
- Erlang/OTP 26+, Elixir 1.17+

## Project Status

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | ✅ Done | DSL, IR, convergence engine, ZFS ops |
| 1b | ✅ Done | Wire DSL to real ZFS |
| 3 | ✅ Done | Jail verb, jail.conf.d generation |
| 4 | ✅ Done | Multi-host via Erlang distribution |
| 5 | Planned | Cluster verb, secrets, Burrito builds |

## Documentation

- [CLAUDE.md](CLAUDE.md) — Project context and architecture
- [docs/MULTI_HOST_TEST.md](docs/MULTI_HOST_TEST.md) — Multi-host test setup
- [docs/BLOG_ZED_MANIFESTO.md](docs/BLOG_ZED_MANIFESTO.md) — Why we built this

## Architecture

```
DSL (macros) → IR (validated) → Converge (diff→plan→execute) → ZFS
                                       ↓
                              Agent ←──:rpc.call──→ Cluster
```

## License

MIT
