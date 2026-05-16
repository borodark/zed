# Mission I — exmc Trader Deployed to mac-247

**Goal:** zed-style declarative deploy of the exmc multi-instrument
trading trial to a real FreeBSD host, GPU-backed via `nx_vulkan`,
packaged via `tarfs(5)`.

**Why mac-247:** FreeBSD 15.0, ZFS, Bastille available, Vulkan-capable
GPU (NVIDIA GT 650M). Validates the FreeBSD path the zed deploy tool
was always designed for.

**Packaging choice:** uncompressed POSIX tar mounted via `tarfs(5)`
(kernel module, FreeBSD 14+) at `/opt/exmc`. Read-only by
construction, atomic remount on upgrade, snapshot/rollback via ZFS
on the artifact dataset.

---

## Background — how this generalises to mainstream Elixir CI/CD

| Aspect | Mainstream Elixir (2026) | Mission I |
|---|---|---|
| Build artifact | `mix release` tarball / Burrito single-binary / Docker image | `mix release` tar (uncompressed, tarfs-friendly) |
| Distribution | `docker push` / S3 / GitHub release | `scp` / `zfs send` |
| Runtime substrate | K8s pod / Fly machine / systemd | tarfs(5) mount + rc.d unit |
| Config | 12-factor env vars | env file in ZFS-managed dataset |
| State store | etcd / ConfigMaps / Fly state | ZFS user properties (`com.zed:*`) |
| Rollback | image-tag + `kubectl rollout undo` | `zfs rollback` (constant-time) |
| Coordination | K8s controller / Helm | `zed converge` (TLA+-verified 2-phase + Phase 2.5 health) |
| Health checks | k8s liveness / readiness | `Zed.Converge.Health` (TCP / `:beam_ping`) |

The 12-factor model carries through. The release artifact is the
same shape mainstream produces. What's distinct: **tarfs mount + ZFS
rollback** as a substitute for Docker overlay + image-tag rollback.
Burrito is the comparable "self-extracting single artifact" idea
but extracts on first run rather than mounting — adds a step that
can fail (partial extract, disk-full, permissions). Tarfs has zero
runtime extraction, fails loud at mount time if at all.

---

## M-I.0 — Pre-flight: nx_vulkan works on mac-247

| Check | Result |
|---|---|
| OTP 27 + Elixir 1.18.4 on mac-247 | ✓ (after `kiex install 1.18.4` repair — prior install was a skeleton, no `.beam` files) |
| nx_vulkan natively compiles | ✓ (NIF `libnx_vulkan_native.so` already present) |
| `mix test` in nx_vulkan | **171 / 178 pass.** Seven failures all in `Synthesis` + `PipelineCache` paths that call `:crypto.hash/2`; environmental load issue, not GPU |
| Vulkan device selected | **NVIDIA GeForce GT 650M** (driver: NVIDIA, Vulkan 1.2.175) |
| `f64` support | true |

**Toolchain note:** Elixir 1.18.4 install via kiex was broken on
mac-247 (directory skeleton, no compiled beams). Repair was one
`kiex install 1.18.4` call.

---

## M-I.1 — Build the release on mac-248

**Branch:** `feat/gpu-node @ 65cf9e486` (W7 Stage 2.5 follow-up).
**Output:** 36 MB release tree → 52 MB POSIX tar at
`/tmp/exmc-mi1.tar`. Uncompressed (tarfs needs random-access).

Contents:
- ERTS 15.2.7.8 (16 MB)
- All deps + apps (19 MB)
- `libnx_vulkan_native.so` ✓
- `libexmc_tree.so` (Rust tree-builder NIF) ✓
- `crypto.so` ✓ (release startup includes `:crypto` automatically;
  resolves M-I.0's environmental concern)

### Mission-I-specific config (`config/runtime.exs`, new)
```elixir
config :exmc, :compiler,
  case System.get_env("EXMC_COMPILER", "vulkan") do
    "vulkan" -> :vulkan
    "binary" -> :none
    "exla"   -> :exla
    "emlx"   -> :emlx
  end

if accounts = System.get_env("ACCOUNTS_CONFIG") do
  config :exmc, :accounts_config, accounts
end
```

### Local mac-248 change preserved
`exmc/mix.exs` has `{:exla, ...}` commented out — EXLA's prebuilt NIF
requires AVX2 which the Xeon X5482 doesn't have. Without commenting
out, `mix deps.compile` fails. Doesn't affect the artifact's runtime
behaviour; Vulkan is the live compiler anyway.

---

## M-I.2 — Hand-deploy on mac-247

### Setup script (`/tmp/mi-2-setup.sh`)
Single doas-prompt; idempotent on re-run. Steps:

1. `kldload tarfs` + persist `tarfs_load=YES` in `/boot/loader.conf`
2. Create ZFS datasets:
   - `zroot/zed/exmc-trial` (mountpoint=none)
   - `zroot/zed/exmc-trial/artifacts` → `/var/zed/exmc/artifacts` (compression=off)
   - `zroot/zed/exmc-trial/state` → `/var/db/exmc-trial` (compression=lz4, quota=20G)
3. `chown io:io` artifact + state dirs
4. Move `/tmp/exmc-mi1.tar` → artifact dataset
5. `mount -t tarfs <tar> /opt/exmc`
6. Write `${STATE}/env` with cookie, node, paths, `EXMC_COMPILER=vulkan`
7. Write `accounts.config` (single alpaca paper account, slim instruments)
8. Write `instruments.txt` (SPY, GLD, XOM)

### Two unblocks discovered
- **OpenSSL ABI mismatch.** OTP's `crypto.so` from mac-248 linked
  against `/usr/local/lib/libcrypto.so.12` (ports openssl). mac-247
  only had base FreeBSD `/lib/libcrypto.so.35`. Fix: `doas pkg
  install -y openssl` on mac-247 (resolves to openssl-3.0.19,1 in
  ports, which provides `libcrypto.so.12` despite the 3.x version
  number — FreeBSD's `.so.12` is an ABI suffix, not the OpenSSL
  major).
- **`RELEASE_DISTRIBUTION=sname` needed.** mix release defaults to
  long names → FQDN resolution. Single-host deploy uses sname mode
  to match the dev-host `iex --sname trial` convention; remsh works
  the same way.

### Smoke result (boot)
```
17:13:44.065 [Trading.Supervisor] start_link called
17:13:44.065 [Trading.Supervisor] Multi-account: [:alpaca_6k]
17:13:44.279 [ComputePool] gpu=3 cpu=4 workers
17:13:44.286 Running Exmc.Trading.Web.Endpoint with Bandit at 0.0.0.0:4000
[GLD] Restored checkpoint (7080 prices, saved 2026-03-03T19:20:23Z)
[SPY] Restored checkpoint (6823 prices, saved 2026-03-03T18:42:08Z)
[XOM] Restored checkpoint (200  prices, saved 2026-05-15T16:48:20Z)
17:13:49.466 [RiskManager:alpaca_6k] Synced equity: $6850.54
spirit-vulkan: NVIDIA GeForce GT 650M (f64=yes)
17:14:44.327 [RiskManager:alpaca_6k] Synced equity: $6850.81
17:15:14.395 [RiskManager:alpaca_6k] Synced equity: $6847.13
```

### Probe via `bin/exmc rpc`
```elixir
Exmc.JIT.detect_compiler()  →  Nx.Vulkan
Exmc.JIT.backend()          →  Nx.Vulkan.Backend
Exmc.JIT.precision()        →  :f32
Nx.Vulkan.Native.device_name()  →  "NVIDIA GeForce GT 650M"
```

### Gaps surfaced (not Mission-I blockers, but worth filing)

1. ~~**`Nx.Vulkan.Node` not in `Exmc.Application` supervision tree.**~~
   **CLOSED (2026-05-16, phd@a59def26c).** Live discovery during
   Mission II investigation showed the trial had been running 9 h
   in this broken state — `compiler=Nx.Vulkan` and
   `default_backend=Nx.Vulkan.Backend` were both set, but
   `Process.whereis(Nx.Vulkan.Node) == nil`, so every NUTS call
   into the backend hung and the 300 s HealthCheck watchdog reset
   stuck instruments. Patch adds a `gpu_children/0` function in
   `Exmc.Application.start/2` that returns `[Nx.Vulkan.Node]` when
   `Exmc.JIT.detect_compiler() == Nx.Vulkan`, else `[]`. ABI-safe
   on EXLA/EMLX/BinaryBackend (no-op there). Verified on mac-247:
   after rebuild + tar swap, `Process.whereis(Nx.Vulkan.Node)` is a
   live pid; a manual round-trip
   `Nx.Vulkan.Node.with_node(fn -> Nx.sum(Nx.add(Nx.iota({1024}),
   1.0)) end)` returns 524_800.0 in ~1.1 ms.
2. **Checkpoint path is CWD-relative** (`trial/checkpoints/<acct>`).
   Works because we start with `cd /var/db/exmc-trial`. A future
   pass should accept `EXMC_CHECKPOINT_ROOT` to drop the implicit
   CWD coupling.
3. **`alarm_handler: disk_almost_full /opt/exmc`** — tarfs reports
   zero free space (RO mount). Cosmetic alarm; reframe as expected
   in any tarfs-mounted release.

### Take-down
```sh
cd /var/db/exmc-trial && set -a && . ./env && set +a && /opt/exmc/bin/exmc stop
```
Clean exit; `epmd -names` shows only `zed-agent` after.

---

## M-I.3 — Promote bash to zed DSL verbs

**New verbs:**
- `tarfs name do … end` — declares a `tarfs(5)` mount of a tar
  artifact. Config keys: `tar_path`, `mount`. Idempotent; the
  executor parses live `mount` output and skips if the requested
  source already covers the mountpoint.
- `file path do … end` — declares a managed text file with optional
  `mode`, `owner`, `group`, and inline `content`. Content-comparing
  rewrite — no-op when on-disk matches, atomic write otherwise.

**IR + executor changes:** `lib/zed/ir.ex` gets `tarfs_mounts:` and
`files:` fields; `Diff` emits unconditional `:create` entries (the
executor enforces idempotency); `Plan` slots tarfs at priority 2
(after datasets) and file at priority 6 (after apps); `Step`'s
typespec extended with `:tarfs|:file` types and `:mount|:write`
actions.

**Mission.I example module** at `lib/zed/examples/mission_i.ex`
composes 4 datasets + 1 tarfs mount + 1 env file under one
`host :mac_247` block. The same artifact + state layout the M-I.2
bash script produces, expressed declaratively.

**Latent bug surfaced & fixed.** The compiler had been warning
about `Cluster.do_coordinated_converge/2`'s catch-all `{:error, _}`
clause being unreachable because `prepare_all/1` returns a 3-tuple
`{:error, :prepare_failed, failures}`. M-I.3's first live converge
triggered that exact path (ZFS-permission-denied snapshot), so the
clause shape was corrected. Pattern: 3-tuple match.

**ZFS delegation needed.** Datasets created via `doas zfs create`
in M-I.2 weren't `zfs allow`-ed for `io`, so the agent couldn't
snapshot them during prepare. Added a one-doas script
(`/tmp/mi3-delegate-zfs.sh`) granting create/destroy/snapshot/
mount/rollback/userprop/etc. on `zroot/zed`. After delegation, the
agent runs zfs operations natively without per-call doas.

### Live result, first pass
```
== run: converge_coordinated ==
phase 1 (prepare): 1 hosts ready
phase 2 (converge): all 1 hosts succeeded
result: {:ok, %{mac_247: {:ok, [
  {"file:write:/var/db/exmc-trial/env",
   {:file_written, "/var/db/exmc-trial/env"}},
  {"tarfs:mount:exmc_release",
   {:tarfs_already_mounted, "/opt/exmc"}},
  {"dataset:set:zed:mountpoint", :ok},
  {"dataset:set:zed/exmc-trial:mountpoint", :ok}
]}}}
```

### Second pass — full idempotency
```
{"file:write:/var/db/exmc-trial/env",
 {:file_already_current, "/var/db/exmc-trial/env"}},
{"tarfs:mount:exmc_release",
 {:tarfs_already_mounted, "/opt/exmc"}},
…
```

### Cosmetic over-eagerness
Two `dataset:set:*:mountpoint` ops fire every pass because the diff
compares the IR's atom `:none` against ZFS's string `"none"` and
sees mismatch. Zero-cost ZFS property write to the same value;
worth tightening in the diff layer (cast atom→string before compare)
but not blocking.

---

## M-I.4 — Health + service start under one converge

Sliced into three:

### M-I.4a — `app` block + `:health` probes
Mission.I gains an `app :exmc_trial do … end` carrying:
```elixir
node_name :"trial@mac"
cookie {:env, "RELEASE_COOKIE"}
env_file "/var/db/exmc-trial/env"
health :tcp, host: "192.168.0.247", port: 4000
```
`:beam_ping` was considered and **omitted** — the trader uses
sname (`trial@mac`) but the controller uses long names; EPMD
doesn't bridge those, and the F3 finding from the health-check
smoke (`docs/dual-mac-health-smoke.md`) means probes run on the
controller, so the loopback target you'd otherwise type is
meaningless. LAN-IP TCP probe is the right shape.

Live result: trader manually started, converge fired Phase 2.5,
`all hosts healthy` in 16 ms.

### M-I.4b — `:service_run` verb (declarative service start)

Sixth Mission-I verb. Declares a daemon command launched during
converge with idempotency via `alive_check`:
```elixir
service_run :exmc_trial do
  command "/opt/exmc/bin/exmc"
  args ["daemon"]
  cd "/var/db/exmc-trial"
  env_file "/var/db/exmc-trial/env"
  alive_check {:epmd, "trial"}
end
```
The executor parses the env file at run-time and threads it through
`System.cmd/3`'s `:env` keyword — no shell wrapping. `alive_check
{:epmd, "trial"}` greps `epmd -names`; if the named node is
registered, the start step short-circuits to
`:service_already_running`.

### Live result — single-call deploy
```
== run: converge_coordinated ==
phase 1 (prepare): 1 hosts ready
phase 2 (converge): all 1 hosts succeeded
phase 2.5 (health): all hosts healthy
result: {:ok, %{mac_247: {:ok, [
  {"service_run:start:exmc_trial",       {:service_already_running, :exmc_trial}},
  {"file:write:/var/db/exmc-trial/env",  {:file_already_current, "/var/db/exmc-trial/env"}},
  {"tarfs:mount:exmc_release",           {:tarfs_already_mounted, "/opt/exmc"}},
  {"dataset:set:zed:mountpoint",         :ok},
  {"dataset:set:zed/exmc-trial:mountpoint", :ok}
]}}}
```
Five idempotent steps + one Phase-2.5 probe.  ~931 ms wall (most of
which is the prepare-snapshot pass and converge step.create on
already-existing datasets).

### M-I.4c — rollback drill (verified)

Driven from a one-off script that takes Mission.I's compiled IR and
substitutes the health probe port (4000 → 1 closed). Phase 2 still
succeeds (everything idempotent), Phase 2.5 probe fails, full
rollback chain fires.

```
broken: probe @ port 1 (closed)
  phase 1 (prepare): 4 snapshots taken (all :modify)
  phase 2 (converge): all 1 hosts succeeded
  phase 2.5 (health): health_failed
  rollback mac_247: zfs rollback zroot/zed/exmc-trial/state@zed-…
  rollback mac_247: zfs rollback zroot/zed/exmc-trial/artifacts@…
  rollback mac_247: zfs rollback zroot/zed/exmc-trial@…
  rollback mac_247: zfs rollback zroot/zed@…
  result: {:error, :health_failed,
           %{health_outcomes: %{mac_247: :failed},
             rolled_back: %{mac_247: [ok: "", ok: "", ok: "", ok: ""]}}}

recovery: probe @ port 4000 (good)
  phase 2.5 (health): all hosts healthy
  result: {:ok, …}
```

Visible state on disk is unchanged — Phase 1 snapshots matched
pre-converge state, so rollback is a no-op in content terms. What's
proven is the **chain**: prepare snapshots ⇒ Phase 2.5 trigger ⇒
rollback executes against the snapshots ⇒ orchestrator returns
`:health_failed` with rolled_back receipts. The trader's BEAM
stayed up throughout (rollback is dataset-level; doesn't restart
services).

Latent bug fixed in passing: `app` DSL macro wasn't tagging
config with `__host__` like the other verbs (dataset/tarfs/file/
service_run). Mission.I.converge_coordinated/1 worked by accident
because the per-host IR builder didn't override `apps`. The drill
script that built host_irs by hand exposed the gap.

---

## What's left for Mission I

| Phase | Scope |
|---|---|
| **M-I.5** | Doc + commit + **β tag**. |

---

## Artifact provenance

| Item | Path |
|---|---|
| Source branch | `feat/gpu-node @ 65cf9e486` (mac-248:~/exmc) |
| Release tar | mac-247:`/var/zed/exmc/artifacts/exmc-mi1.tar` (52 MB) |
| tarfs mount | mac-247:`/opt/exmc` |
| State dataset | mac-247:`zroot/zed/exmc-trial/state` → `/var/db/exmc-trial` |
| Setup script | mac-247:`/tmp/mi-2-setup.sh` |
| Env file | mac-247:`/var/db/exmc-trial/env` |
| Account creds | mac-247:`/var/db/exmc-trial/accounts.config` (paper, alpaca_6k entry) |
