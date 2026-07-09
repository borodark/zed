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

> New to Zed? Read [**Zed in 10 Minutes**](docs/zed_10min.md) — a
> single-host walkthrough (define → diff → converge → bump version →
> rollback) aimed at Elixir devs who haven't done much ops.
> Livebook source: [`notebooks/intro_10min.livemd`](notebooks/intro_10min.livemd).
>
> Have a real Elixir release and want to deploy it? Read
> [**Packaging an Elixir App for Zed Deploy**](docs/packaging_elixir_with_zed.md) —
> takes you from `mix release` to a running, health-gated, atomically-
> rollbackable trader on FreeBSD + ZFS, in ~7 steps. Concrete example
> is the eXMC trader. Livebook source: [`notebooks/packaging_elixir_with_zed.livemd`](notebooks/packaging_elixir_with_zed.livemd).

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

## GPU node abstraction — current progress

**tl;dr:** the Nx/Vulkan runtime side shipped in the `nx_vulkan` repo
(May 2026); Zed's deploy-side `deploy :gpu_cluster` DSL below is on the
roadmap and hasn't been implemented yet.

The vision below is intact. The infrastructure for the *runtime side*
(driving the GPU from BEAM) shipped in May 2026 in the sibling
[`nx_vulkan`](https://github.com/borodark/nx_vulkan) repository; the *deploy side* (zed's
declarative DSL for GPU clusters) is still on the roadmap — see "Road
to Production" below.

### What shipped (in `nx_vulkan@main`, May 2026)

| Capability | Where | Status |
|---|---|---|
| Vulkan compute backend (no CUDA, no Metal) | `nx_vulkan/lib/nx_vulkan/native.ex` + spirit | ✅ Cross-platform validated on Linux RTX 3060 Ti + FreeBSD GT 750M + GT 650M (178/178 tests) |
| Long-lived per-machine GPU node GenServer | `Nx.Vulkan.Node` + `with_node/2` | ✅ |
| Persistent `vkPipelineCache` (disk, header-validated) | `Nx.Vulkan.PipelineCache` | ✅ 4× cold-start speedup |
| Runtime shader synthesis from per-family spec | `Nx.Vulkan.Synthesis` + `ShaderTemplate` | ✅ <200 ms cold path; 6 hand-written + 3 synthesized chain shader families |
| MCMC integration (NUTS leapfrog, persistent buffers, EXLA fallback) | `pymc/exmc@main` `Exmc.NUTS.Vulkan.*` | ✅ |
| Per-shader suspect tracking (W6 Phase 1) | `Exmc.NUTS.Vulkan.SuspectTracker` | ✅ Eviction policy + cross-shader sliding window |

### What zed needs to add (deploy side)

The runtime substrate exists. Turning it into the declarative
`deploy :gpu_cluster` block below requires zed-specific work that
hasn't started yet:

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

The mapping from `nx_vulkan`'s capabilities into a zed deploy spec is:

| Vision DSL block | What zed must build | Estimated effort |
|---|---|---|
| `node :workstation do gpu ... end` | Inventory primitive that calls `nvidia-smi` / `pciconf` to enumerate GPU(s); reflect into ZFS properties (`com.zed:gpu.vendor`, `com.zed:gpu.vram_mb`) on the host. | 1 week |
| `model :llama70b do requires vram: 48 end` | Scheduler that matches model VRAM requirements against host `com.zed:gpu.vram_mb`. Refuses to deploy if no host has enough VRAM. Pure Elixir, no new infrastructure. | 1 week |
| `model do dataset "models/..." end` | Already covered by zed's existing dataset primitive — model files are just ZFS datasets. Zero new code. | 0 |
| `job :finetune do checkpoint_every "1 epoch" end` | Hooks into a training loop callback. Triggers `zfs snapshot dataset@epoch-N`. Probably a behavior the user-app implements; zed provides the snapshot primitive (already exists). | 1 week |
| GPU node lifecycle (start `Nx.Vulkan.Node` under app supervisor, restart on driver crash, persist cache on shutdown) | Agent verb that reads `com.zed:gpu.driver` and starts the right OTP application. Standard zed agent pattern. | 1 week |
| mDNS service discovery (`_exmc_gpu._tcp.local`) | Coordinate with `nx_vulkan` Phase 3 work — both projects plan to use `mdns_lite`. Need a service-name convention. | 2-3 weeks (joint with nx_vulkan) |

```
Model versioning?    zfs snapshot
Model distribution?  zfs send/receive
Experiment tracking? ZFS properties (com.zed:loss=0.0023)
Checkpoint/resume?   Snapshots travel to any node
Rollback bad run?    zfs rollback (O(1))
GPU dispatch?        Nx.Vulkan.Node.with_node/2  ← shipped
Per-host inventory?  zed agent reads PCIe + /dev/nvidia*  ← TODO
```

See [docs/gpu-cluster.md](docs/gpu-cluster.md) for the original vision.

## Road to Production

Honest assessment of what's missing before zed should be trusted with
production workloads. Categorized by risk to a deployment, not by
chronological order. Each line is a real deficit, not a polish item.

### P0 — must fix before anyone runs zed in prod

- [ ] **Convergence engine end-to-end on a real deploy.** A1-A5a are
      individual layers; the *combined* `Module.converge()` on a
      multi-host deploy with ZFS + Bastille + cluster has been
      live-tested only on the dev machines, not on a clean prod-shaped
      target. **Effort: 1-2 weeks live-burn.**
- [x] **Health checks wired to convergence.** Phase 2.5 of
      `Zed.Cluster.converge_coordinated` runs `:tcp` / `:beam_ping`
      probes after all hosts converge, retries on failure, and rolls
      back the deploy if any host fails or an external rollback signal
      latches. Behaviour pinned by `specs/HealthCheck.tla` (TLC-checked,
      `NoLatePromotionAfterRollback` covered) and `test/zed/converge/health_test.exs`.
      HTTP probe still needs a custom `:checker` module — `:httpc`
      stays out of the default path to skip the `:inets` startup tax.
- [ ] **Rollback under partial failure.** If a multi-host deploy
      succeeds on hosts A+B and fails on C, `Zed.Cluster.converge_coordinated`
      is supposed to roll all three back. The path exists but hasn't
      been chaos-tested under realistic failure modes (network
      partition during apply, ZFS pool full, jail.conf syntax error
      mid-apply). **Effort: 2 weeks chaos-test + harden.**
- [ ] **Secrets at rest.** A1 produces encrypted `<base>/zed/secrets`
      with fingerprint-stamped properties. The pipeline that gets
      secrets *into* the deploying app's env is partly designed
      ([`docs/SECRETS_DESIGN.md`](docs/SECRETS_DESIGN.md)) but not
      fully shipped — current deploys rely on env files placed by the
      operator. **Effort: 2 weeks to ship the agent-side decrypt path.**
- [ ] **Erlang-distribution security**. Cluster RPC currently uses
      cookie auth + Unix sockets between zedweb/zedops. Production
      deployments need either TLS distribution or a hardened
      `epmd_proxy`. The `getpeereid` NIF covers local IPC; cross-host
      cookies on the open network do not. **Effort: 1 week.**

### P1 — should fix before scaling beyond a single operator

- [ ] **No CI/CD integration.** No GitHub Actions / Forgejo / etc.
      runner that runs `mix test` + `mix test --include zfs_live` on
      every push. Currently the only verification is the operator
      running the live tests by hand. **Effort: 2 days.**
- [ ] **No telemetry / observability beyond log files.** No
      `:telemetry` events on convergence steps, no Prometheus/StatsD
      hooks. `LiveDashboard` is wired in zedweb but the converger
      itself is opaque. **Effort: 1 week.**
- [ ] **No upgrade strategies.** A `Module.converge()` either replaces
      a service entirely or doesn't. No rolling upgrade, no
      blue-green, no canary. For a small fleet (<10 hosts) this is
      fine; beyond that an operator wants finer control. **Effort: 2-3
      weeks for rolling; another 2 for blue-green.**
- [ ] **DSL coverage is shallow.** The DSL handles `dataset`, `app`,
      `jail`, `snapshots`. It doesn't handle: nested deploys,
      conditional resources (`if env == :prod`), resource hooks
      (`before_deploy`, `after_deploy`), depends_on graphs. Current
      workaround is multiple deploy modules. **Effort: 1 week per
      hook, 2-3 weeks for the dependency graph.**
- [ ] **No supported-version policy.** OTP 26+ / Elixir 1.17+ is the
      stated minimum, but the live-test rig pins OTP 27 + Elixir 1.18
      and there's no LTS commitment. Production needs a written
      promise about what zed will and won't break across point
      releases. **Effort: 1 day to write the policy.**

### P2 — nice to have, not blockers for first prod use

- [ ] **mDNS discovery for multi-host deploys.** Currently `Zed.Cluster.connect`
      takes an explicit node name. mDNS would auto-discover. Coordinated
      with `nx_vulkan` Phase 3 (see "GPU node abstraction" above).
      **Effort: 2-3 weeks joint.**
- [ ] **Web UI for non-Erlang operators.** The Phoenix LiveView admin
      foundation (A2a/A2b/A3/A4) ships; the actual *deploy* UI on top
      of it (form for editing `Module.converge` parameters,
      visual diff before apply) doesn't yet. The `zed` command-line is
      the only deploy interface today. **Effort: 3-4 weeks.**
- [ ] **No security review.** No external audit; no fuzz testing of
      the DSL parser; no formal threat model for the Bastille adapter
      privilege boundary. The `getpeereid` boundary is small and
      reviewable, but no one outside the dev team has reviewed it.
      **Effort: 1-2 weeks for an internal pen-test sprint; budget
      $5-15K for an external audit.**
- [ ] **Documentation gap for non-FreeBSD users.** README claims
      "FreeBSD or illumos (Linux for dev/test only)". A user wanting to
      try zed on Ubuntu currently has no guidance — the dev-loop docs
      assume FreeBSD primitives (Bastille, ZFS-on-root, doas).
      **Effort: 1 week to write a Linux quickstart.**
- [ ] **Larger test fleet.** Current dev runs on two FreeBSD Macs +
      one Linux box. Production validation needs ≥5 hosts, mixed
      hardware, real network failures. The Spirit project's CI ran on
      a 12-node cluster; zed has nothing comparable yet. **Effort: 1-2
      months including hardware acquisition.**

### What zed *won't* do (deliberate scope discipline)

- ❌ **Linux as a first-class deployment target.** Linux is supported
      for dev/test only. ZFS-on-Linux works but isn't the design center.
- ❌ **Container orchestration.** Kubernetes / Docker / Podman are out
      of scope. Zed deploys mix releases into FreeBSD jails or illumos
      zones. Containers exist; this isn't them.
- ❌ **Single-host high availability.** Zed is per-host authoritative.
      For HA you run multiple hosts and let zed coordinate — but each
      host is its own root of trust. Quorum protocols (Raft, Paxos)
      are not on the roadmap.
- ❌ **Cross-cloud abstraction.** No AWS / GCP / Azure terraform-style
      provider layer. Zed manages BEAM applications on hosts you
      already have. How those hosts came into existence is your
      problem.

## Installation

```sh
git clone <repo>
cd zed
mix deps.get
mix compile          # builds priv/peer_cred.so via elixir_make

# Run tests (328 tests, 0 failures, 52 excluded as of 2026-07-09 / commit 639fb54)
mix test                                       # unit + integration
ZED_TEST_DATASET=<pool>/zed-test \
  doas mix test --include zfs_live             # + ZFS-on-FreeBSD tests
mix test --include bastille_live               # + Bastille-on-FreeBSD tests
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
| Path B | Jail executor (6 slices) | ✅ Done | `jail_pkg`/`jail_mount`/`jail_svc`/`jail_file`/`jail_config`/`jail_setup` wired to real Bastille calls |
| DemoDbJails | Postgres + ClickHouse from one converge | ✅ Done | Live-verified on mac-248 |
| Path C1 | Jail-contained shell-stub app deploy | ✅ Done 2026-07-09 | App verb deploys inside a Bastille jail |
| Path C2 | Health probes wired to converge | ✅ Done 2026-07-09 | `:tcp`, `:http`, `:beam_ping` |
| Path C3 | Real `mix release` + disterl over bastille0 | ✅ Done 2026-07-09 | Full release + Erlang distribution across loopback |
| Path C4 | Two-node `hello_beam` cluster | ✅ Done 2026-07-09 | `PEER_NODE`-driven pairing |
| Path C5 | 5-node `hello_beam` cluster | ✅ Done 2026-07-09 | libcluster + Zed `cluster` artifact (commit 639fb54) |
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

## Integration with `nx_vulkan`

Zed and [`nx_vulkan`](https://github.com/borodark/nx_vulkan) are sibling repos, not coupled at the Mix dependency level. The deployment pattern:

1. Zed orchestrates BEAM nodes (start, supervise, health-check, rollback).
2. Each node's own `mix.exs` lists `nx_vulkan` (and `exmc`, etc.) as Hex deps — zed doesn't import `nx_vulkan` itself.
3. The deployed application's supervisor starts `Nx.Vulkan.Node` (the long-lived GPU-node GenServer) under its own tree.
4. Zed treats it identically to any other OTP application — deploys it, supervises it, doesn't need to know about Vulkan APIs.

Practical compatibility holds today: both pin OTP 27 / Elixir 1.18, share the NAS git server, and have no conflicting global state. See [`specs/nx-vulkan-execution.md`](specs/nx-vulkan-execution.md) for the full integration story (and the historical execution plan).

Open coordination work (Phase 3 of `nx_vulkan/PLAN_GPU_NODE.md`): both projects plan to use `mdns_lite` for service discovery. Once the multi-client GPU node lands, the two need to agree on service-name conventions (`_zed._tcp.local` vs `_exmc_gpu._tcp.local`) so they don't collide on the local-link advertisement bus.

## Status

Pre-1.0, design-iterating, single-maintainer. The iteration plan is being walked one layer at a time with live FreeBSD verification after each landed merge. Issues / PRs are welcome but expect short discussion before sizable changes — the design surface is still being negotiated.

## License

Apache License 2.0 — see [LICENSE](LICENSE)
