# Zed — ZFS + Elixir Deploy

Declarative BEAM application deployment on FreeBSD and illumos, using ZFS as the state store and rollback mechanism.

## The Idea

ZFS user properties (`com.zed:version=1.4.2`) are a built-in, replicated key-value store that travels with snapshots and `zfs send/receive`. No external state store required — **the deployment state IS the filesystem metadata.**

## Why

**~85% of companies with servers run ≤50 nodes.** They don't need Kubernetes. They need something that works.

| Traditional Stack | Zed |
|-------------------|-----|
| etcd/consul cluster (3-5 nodes) | ZFS properties (zero infra) |
| Terraform state in S3 | State IS the filesystem |
| Ansible/Chef/Puppet | Elixir DSL, compile-time validated |
| Container runtime + orchestrator | FreeBSD jails (kernel feature) |
| 10+ tools to learn | One tool, ~2000 lines |

```
Rollback with K8s:        Rollback with Zed:
  kubectl rollout undo      zfs rollback tank/app@v1
  (hope state matches)      (data + state, atomic, O(1))
```

Zed trades global coordination for local simplicity. Each host is authoritative for its own state. That's a feature when your failure domain is per-host anyway.

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

## Future: GPU Cluster

ZFS + Erlang distribution = distributed ML without MLflow/DVC/K8s.

```elixir
deploy :gpu_cluster, pool: "tank" do
  node :workstation do
    gpu "RTX 4090", vram: 24
  end

  model :llama70b do
    dataset "models/llama-70b"
    requires vram: 48
  end

  job :finetune do
    model :llama70b
    checkpoint_every "1 epoch"  # checkpoint = zfs snapshot
  end
end
```

```
Model versioning?    zfs snapshot
Model distribution?  zfs send/receive
Experiment tracking? ZFS properties (com.zed:loss=0.0023)
Checkpoint/resume?   Snapshots travel to any node
Rollback bad run?    zfs rollback (O(1))
```

See [docs/gpu-cluster.md](docs/gpu-cluster.md) for the full vision.

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

- [CONTRIBUTING.md](CONTRIBUTING.md) — How to contribute
- [CLAUDE.md](CLAUDE.md) — Project context and architecture
- [docs/MULTI_HOST_TEST.md](docs/MULTI_HOST_TEST.md) — Multi-host test setup
- [docs/gpu-cluster.md](docs/gpu-cluster.md) — GPU cluster vision
- [docs/pitches.md](docs/pitches.md) — Why ZFS properties replace etcd
- [docs/market.md](docs/market.md) — Market analysis
- [docs/BLOG_ZED_MANIFESTO.md](docs/BLOG_ZED_MANIFESTO.md) — The manifesto

## Architecture

```
DSL (macros) → IR (validated) → Converge (diff→plan→execute) → ZFS
                                       ↓
                              Agent ←──:rpc.call──→ Cluster
```

## Contributing

**PRs are welcome!** See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Roadmap

| Phase | Status | What's Needed |
|-------|--------|---------------|
| 5 | Next | `cluster` verb, secrets, Burrito builds |
| 6 | Planned | illumos parity (SMF, zones) |
| 7 | Vision | GPU cluster: `node`, `model`, `job` verbs |
| 8 | Ideas | mDNS discovery, web dashboard, metrics |

### Good First Issues
- Add more health check types (TCP, HTTP)
- Improve error messages
- More examples in `lib/zed/examples/`
- Documentation improvements

## License

Apache License 2.0 — see [LICENSE](LICENSE)
