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
mix compile          # builds priv/peer_cred.so via elixir_make

# Run tests
mix test                                       # 216 unit/integration tests
ZED_TEST_DATASET=<pool>/zed-test \
  doas mix test --include zfs_live             # + 24 ZFS-on-FreeBSD tests
mix test --include bastille_live               # + 7 Bastille-on-FreeBSD tests
```

## Requirements

- FreeBSD or illumos (Linux for dev/test only)
- ZFS pool with a delegated test subtree (any name; pass via `ZED_TEST_DATASET`)
- Erlang/OTP 26+, Elixir 1.17+
- C compiler for the `peer_cred` NIF (`cc` from FreeBSD base; `gcc`/`clang` on Linux)

## Iteration Arc

The roadmap lives in [`specs/iteration-plan.md`](specs/iteration-plan.md); each `A*` layer has a per-iteration spec under [`specs/`](specs/). Headline status:

| # | Layer | Status | Notes |
|---|-------|--------|-------|
| A0 | DSL slot validation | ✅ Done | Compile-time `storage:` mode check |
| A1 | `Zed.Bootstrap` (init / status / **rotate** / verify / export-pubkey) | ✅ Done | Encrypted `<base>/zed/secrets`, fingerprint-stamped ZFS properties, archived rotation history |
| A2a | Phoenix LiveView admin foundation | ✅ Done | Password login + 8h session + dashboard |
| A2b | QR admin first-login | ✅ Done | `Zed.QR` + `Zed.Admin.OTT` (single-use, rate-limited, audit-logged) |
| A3 | Passkey (WebAuthn) auth | ✅ Done | `wax_`-backed; Chrome desktop + Safari iOS + Chrome Android |
| A4 | SSH-key challenge auth | ✅ Done | `ssh-keygen -Y sign` flow + login script |
| A5.1 | Bastille jail adapter | ✅ Done | 540 LOC; live-verified after seven real-world bugs ([blog](http://www.dataalienist.com/blog-lie-at-exit-zero.html)) |
| A5a | **Privilege boundary** (zedweb / zedops split) | ✅ Done | Two `mix release` targets, Unix-socket transport, `getpeereid(2)` NIF, capability-scoped doas, `host-bring-up.sh` |
| B0 | `zedz` mobile QR scanner | Planned | Fork of probnik with `zed_admin` payload handler |

Layers C (NAS-adjacent: SMB + Time Machine) and D (Probnik Vault + Shamir) are shelved per the iteration plan; unshelve only on explicit decision.

## Architecture

```
DSL (macros) → IR (validated) → Converge (diff→plan→execute) → ZFS
                                       ↓
                              Agent ←──:rpc.call──→ Cluster

After A5a:
   zedweb (no privilege)         zedops (capability-scoped doas)
   ────────                      ────────
   Phoenix endpoint              Zed.Ops.Socket   ── Unix socket
   OpsClient.Pool ──────►        (peer-cred check on accept)
                                 Zed.Ops.Bastille.Handler
                                 Runner.System  ──► doas bastille …
```

## Documentation

**Specs (the plan)**
- [specs/iteration-plan.md](specs/iteration-plan.md) — full roadmap, decisions log, layer rollup
- [specs/a5-bastille-plan.md](specs/a5-bastille-plan.md) — Bastille adapter design (A5)
- [specs/a5a-privilege-boundary.md](specs/a5a-privilege-boundary.md) — privilege boundary spec (A5a)
- [specs/b0-zedz-plan.md](specs/b0-zedz-plan.md) — mobile companion (B0)
- [specs/qr-schema.md](specs/qr-schema.md) — QR payload term shapes

**Operational**
- [docs/doas.conf.zedops](docs/doas.conf.zedops) — production doas template (capability-scoped)
- [docs/SECRETS_DESIGN.md](docs/SECRETS_DESIGN.md) — secrets pipeline design
- [docs/MULTI_HOST_TEST.md](docs/MULTI_HOST_TEST.md) — multi-host test setup
- [scripts/host-bring-up.sh](scripts/host-bring-up.sh) — idempotent FreeBSD setup
- [scripts/verify-bastille-host.sh](scripts/verify-bastille-host.sh) — readiness checker
- [scripts/a5a-live-runbook.md](scripts/a5a-live-runbook.md) — Mac Pro live-test runbook

**Background**
- [docs/BLOG_ZED_MANIFESTO.md](docs/BLOG_ZED_MANIFESTO.md) — the manifesto
- [docs/gpu-cluster.md](docs/gpu-cluster.md) — GPU cluster vision
- [docs/pitches.md](docs/pitches.md) — why ZFS properties replace etcd
- [docs/market.md](docs/market.md) — market analysis
- [docs/elixirforum-update-1.md](docs/elixirforum-update-1.md) — community progress note

**Project meta**
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute
- [CLAUDE.md](CLAUDE.md) — project context and architecture

## Status

Pre-1.0, design-iterating, single-maintainer. The iteration plan is being walked one layer at a time with live FreeBSD verification after each landed merge. Issues / PRs are welcome but expect short discussion before sizable changes — the design surface is still being negotiated.

## License

Apache License 2.0 — see [LICENSE](LICENSE)
