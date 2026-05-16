# Zed Linux + CUDA Platform Backend — Spec

**Status:** draft, 2026-05-16. Triggered by the Mission-I-on-mac-247
result (Vulkan covers FreeBSD-with-old-GPU, but the trader's real
production target is Linux + modern CUDA hardware).

**Scope:** add a `Zed.Platform.Linux` backend so zed can deploy
GPU-compute Elixir releases against Linux hosts, with a coherent
provisioning abstraction that doesn't pick winners between Nix /
Talos / plain-apt.

---

## Why this matters

zed today is FreeBSD-first via `Zed.Platform.Bastille` (A5.1 +
Mission I). That covers FreeBSD hosts using Vulkan (per
`docs/mission-i-trader.md`, the trader runs on mac-247's GT 650M
via `nx_vulkan`). For real throughput, the trader wants modern
CUDA hardware — RTX 30/40 series, A6000-class — which is
**Linux territory**. CUDA is the dominant deployment substrate
for production BEAM-GPU workloads, and EXLA's mainstream path is
CUDA on Linux.

The complete picture:

| Substrate | OS path | Compute path | zed coverage |
|---|---|---|---|
| FreeBSD + old NVIDIA | Bastille jail | `nx_vulkan` (Vulkan ICD) | ✓ Mission I |
| FreeBSD + AMD | Bastille jail | `nx_vulkan` (RADV) | ✓ same path |
| Linux + modern NVIDIA | new backend | EXLA-CUDA | **gap** |
| Linux + AMD | new backend | EXLA-ROCm or `nx_vulkan` | **gap** |
| macOS + Apple Silicon | n/a (dev only) | EMLX | out of scope |

This spec covers the Linux backend. ROCm is mentioned but not
prioritised — the immediate audience is NVIDIA CUDA.

---

## The provisioning question

A `Zed.Platform.Linux` impl could deploy onto *any* Linux host
that has SSH + ZFS + (optionally) CUDA. The interesting question
is **how the host got into that state** — provisioning. Three
real options in 2026, with very different shapes:

| Path | Reproducibility | CUDA story | Operator complexity | Match for zed |
|---|---|---|---|---|
| **Nix / NixOS** | declarative, deterministic | excellent — `cache.nixos-cuda.org` (moved Nov 2025 from cachix); the [Nixpkgs CUDA team][1] maintains the stack | high upfront, low operational | strongest fit philosophically (zed is also declarative); friction: most operators don't run NixOS today |
| **Talos Linux** | immutable, declarative | excellent — [NVIDIA GPU Operator on Talos][2]; GPU drivers matched to kernel version automatically | medium; requires K8s | strong fit for fleet management; pulls a K8s control plane along with it, contradicting zed's "replace K8s" stance |
| **Plain Ubuntu/Debian + apt** | imperative, drift-prone | familiar — `apt install cuda-12-X libcudnn9-cuda-12 libnccl2`; need libdevice symlink + `XLA_FLAGS` (per the dev-host setup in MEMORY.md #34) | low upfront, high operational | weak fit philosophically but matches what most operators have today |

**Recommendation:** do not pick one. Provisioning is **the operator's
choice**, not zed's. zed declares what a node MUST have (CUDA
12.x, cuDNN 9.x, NCCL 2.x, glibc 2.31+, ZFS, sshd-with-key); zed
**verifies** the node has those at converge time; if anything is
missing, zed emits a precise "you need to install X" report. zed
does not own the package-manager-level provisioning.

This is the same pattern as `Zed.Converge.Health` for runtime: a
behaviour with a default checker; operators can plug in their own.

---

## The contract: `Zed.Platform.Linux.Capabilities`

A node-attestation step that runs at converge time and gates the
deploy. The output is a structured report:

```elixir
%Zed.Platform.Linux.Capabilities{
  os: %{distro: "ubuntu", version: "24.04", kernel: "6.8.0-110-generic"},
  glibc: "2.39",
  zfs: %{version: "2.4.1", arc_max_bytes: ...},
  cuda: %{
    runtime: "12.6",                   # nvcc --version
    driver: "560.35.03",               # nvidia-smi
    devices: [
      %{name: "NVIDIA GeForce RTX 3060 Ti", uuid: "GPU-...", memory_mb: 8192}
    ],
    cudnn: "9.5.0",
    nccl: "2.21.5"
  },
  beam: %{otp: "27", elixir: "1.18.4"},
  systemd: %{version: "255"}
}
```

zed converge against a Linux host runs the capability probe BEFORE
Phase 1 prepare. If required capabilities are missing, fails the
whole converge with a Linux-specific error that names the
provisioning command per detected distro / per supported
provisioning path.

Example failure message:
```
zed: Linux capabilities check failed on rtx-1.lan:
  - missing: libcudnn9-cuda-12 (required by exmc release for EXLA-CUDA)
  - missing: libnccl2 (required by EXLA-CUDA multi-GPU)

Repair:
  Ubuntu/Debian:   doas apt install -y libcudnn9-cuda-12 libnccl2
  Nix (declarative): add `cudaPackages.cudnn` `cudaPackages.nccl` to your flake
  Talos:           apply the gpu-operator profile per
                   docs.talos.dev/v1.x/talos-guides/configuration/gpu-operator/

Once fixed, retry: zed converge -m Mission.IIRtx
```

---

## EXLA-CUDA gotchas zed must encode

From the existing dev-host setup (MEMORY.md #34, #52) + 2026
EXLA/CUDA practice:

| Concern | Resolution | Stamped in capabilities probe? |
|---|---|---|
| libcudnn version match (XLA cuda12 needs cuDNN 9.x) | apt: `libcudnn9-cuda-12`; Nix: `cudaPackages.cudnn` | ✓ |
| libnccl for multi-GPU (EXLA 0.10+) | apt: `libnccl2`; Nix: `cudaPackages.nccl` | ✓ |
| libdevice symlink (`/usr/lib/nvidia-cuda-toolkit/nvvm/libdevice → /usr/lib/nvidia-cuda-toolkit/libdevice`) | shipped per distro patch or set via XLA_FLAGS | ✓ (presence of `nvvm/libdevice`) |
| `XLA_FLAGS=--xla_gpu_cuda_data_dir=/usr/lib/nvidia-cuda-toolkit` | runtime env in env file | written into the release's env_file via existing zed `file` verb |
| `ELIXIR_ERL_OPTIONS="+sssdio 128"` (XLA child-process stack) | same | same |
| **BEAM must not run as PID 1** (XLA shells out, BEAM-as-init would inherit child mgmt) | systemd `Type=simple` + `ExecStart` invokes a small wrapper that exec's `bin/exmc daemon` — not the release directly. In Docker, `tini` or similar. | not in capabilities; encoded in `Zed.Platform.Linux.Service` unit template |
| glibc ≥ 2.31 (XLA precompiled requirement) | distro version check | ✓ |

---

## Platform backend module shape

```
lib/zed/platform/
  linux.ex                      — @behaviour impl: service install/start/stop,
                                    package check (not install), boot env wrapping
  linux/
    capabilities.ex             — probe + struct definition
    service.ex                  — systemd unit template + sysctl-equivalent
                                    (sysrc lives in Bastille; here it's
                                    systemctl + `systemctl edit` overrides)
    cuda.ex                     — CUDA + cuDNN + NCCL version detection +
                                    XLA_FLAGS / LD_LIBRARY_PATH builder
    package.ex                  — apt / pacman / nix-shell detection +
                                    install-suggestion emitter
    boot_env.ex                 — equivalent of FreeBSD bectl —
                                    on Linux this is "snapshot the dataset
                                    holding /etc + /var/db/zed; rollback via
                                    zfs rollback". No GRUB integration.
```

Mirrors the existing `lib/zed/platform/freebsd.ex` shape. The
`@behaviour Zed.Platform` contract already exists; the Linux impl
fills in `service_start/stop/restart/status/install`, `container_*`
(no-op or Docker-aware), `package_install/installed?`,
`boot_env_create/activate/list`.

---

## Three deploy strategies for Linux nodes

Operators pick one per host class:

### Strategy A — "Native + systemd" (recommended baseline)

Like Mission I on FreeBSD, but Linux-native:
- ZFS dataset hosts the release tar
- **tarfs equivalent:** Linux 6.7+ ships `tarfs` (was Microsoft's, now upstream) — same kernel-mount-of-tar semantics. Fallback for older kernels: extract to dataset (`tar xf`); lose atomicity but everything else works.
- systemd unit at `/etc/systemd/system/<app>.service` written via the existing `:file` verb
- `systemctl daemon-reload && systemctl enable --now <app>.service` via a `:service_run` extension (or a new `:systemd_service` verb)
- env file at `/etc/<app>/env` (mode 0640, owner+group from DSL)
- **BEAM-not-PID-1 guard:** the unit `ExecStart` is `/usr/local/lib/<app>/bin-wrapper.sh start`; the wrapper exec's the release binary so the BEAM is a child of systemd, not the init shim itself

This is the **shape that matches Mission I one-for-one**. Same DSL,
different `Zed.Platform` backend. Promotes the existing `:tarfs`,
`:file`, `:service_run` verbs without changing them.

### Strategy B — "Nix flake reference"

The deploy artifact is a Nix flake URL/SHA rather than a tar:
- DSL gains `nix_flake "github:user/repo#package"` verb (or an `artifact :nix, …` form)
- Executor: `nix build` on the host, `nix-copy-closure` for cross-host, symlink current → store path
- Service unit references the Nix-built binary directly
- Rollback: switch the symlink + `nix-collect-garbage` on the old generation

Pros: deterministic; CUDA versions tied to the flake's nixpkgs pin.
Cons: requires Nix daemon; substantial first-build cost; not a
fit for hosts that aren't Nix.

### Strategy C — "Docker / OCI image" (least zed-y)

Pulls in cluster orchestration concerns we deliberately pushed
away in α. Listed for completeness; not a recommended zed path.
Mention in docs as "if you want this, use K8s; zed isn't the tool."

---

## Tarfs on Linux: status check

Per Linux kernel 6.7+ commits, `tarfs` is upstream (originally
Microsoft contribution for OCI image layering). Verification step
during Linux platform R1: run `modprobe tarfs` on Ubuntu 24.04
kernel 6.8+; if it loads, the FreeBSD-style mount-the-tar model
works identically. If not (kernel too old / module not built),
fall back to `tar xf` into the dataset and symlink swap.

The `:tarfs` verb already in zed is **portable as-is** if the
Linux executor learns to invoke `mount -t tarfs` and the underlying
kernel supports it. Otherwise, add a `:tarball_extract` verb as a
fallback (extract once into the dataset; trade kernel-level
atomicity for distro portability).

---

## Discovery / agent registration on Linux

mDNS for agent discovery (per `zed_project.md`) works identically
on Linux via `avahi-daemon` instead of `mdnsResponder`. mdns_lite
(the Elixir dep) handles both. No backend-specific code needed for
discovery.

---

## Phasing

| Phase | Scope | Effort |
|---|---|---|
| **L1** | `Zed.Platform.Linux.Capabilities` probe — distro/kernel/glibc/zfs/cuda/cudnn/nccl/beam detect via `System.cmd` shellouts. Pure read; safe to ship first. | 1 day |
| **L2** | `Zed.Platform.Linux` behaviour impl: service install/start/stop/status via systemd, package_installed? via dpkg / pacman / rpm / `nix-env`. install_package returns `{:error, :manual_required, hint}` (zed doesn't run apt itself). | 2 days |
| **L3** | systemd unit template + BEAM-not-PID-1 wrapper. Replace Mission I's `service_run` with `systemd_service` on Linux while keeping the FreeBSD path unchanged. | 1 day |
| **L4** | Linux tarfs check + fallback to `tarball_extract`. Verb already exists; just route through the platform abstraction. | half day |
| **L5** | Smoke: deploy exmc trader to super-io (this dev host) via Mission II DSL — same shape as Mission I but Platform = Linux, Compute = CUDA. Health probes against the deployed endpoint. | 1 day |
| **L6** | Doc + integration of EXLA-CUDA gotcha list into `Zed.Platform.Linux.CUDA` env emitter. Verify `XLA_FLAGS` + `+sssdio 128` survive the release env_file path. | half day |
| **L7** | Optional: Nix flake artifact strategy (Strategy B). Defer if no consumer asks. | 2–3 days |

Total **~5–6 days** for L1–L6 (Strategy A). L7 (Nix) is opt-in.

---

## Why "no opinionated provisioning"

The 2026 GPU-Linux ecosystem has two declarative options
(NixOS, Talos) and a long tail of imperative ones (Ubuntu + apt,
RHEL + dnf, Arch + pacman, Debian + apt). zed's value is *the
post-provisioning declarative deploy*, not the bootstrap. The
capability probe is the right boundary: zed says "I need CUDA
12.6+; here's how I detect it; here's a per-distro hint if it's
absent." The operator picks their bootstrap.

This is the same trade as A5.1 with Bastille: zed didn't reimplement
jails — it adapted to the existing FreeBSD jail manager. On Linux,
"the existing manager" is whichever path the operator already runs.

---

## What this unlocks

- **Mission II** — deploy the trader to a CUDA-capable Linux host
  (super-io itself, in the first instance, since it already has
  RTX 3060 Ti + all the dependencies per MEMORY.md #34). Same DSL
  as Mission I, different platform.
- **Mixed fleets** — a single `host :foo, platform: :freebsd` /
  `host :bar, platform: :linux` declaration across hosts in one
  deploy module. Coordinated converge already handles per-host
  variation; the platform field just routes to the right backend.
- **GPU compute as a zed primitive** — `gpu_compute :name, cuda: …`
  or `gpu_compute :name, vulkan: …` verb that bundles the
  per-platform GPU env wiring (XLA_FLAGS on Linux, NX_VULKAN_DEVICE_ID
  on FreeBSD).

---

## Sources

- [How to Install NVIDIA GPU Drivers on Talos Linux][3] — Talos GPU pattern; immutable + matched-to-kernel.
- [NVIDIA GPU Operator on Talos Linux][2] — fleet GPU management.
- [CUDA — NixOS Wiki][4] / [Nixpkgs CUDA team][1] — declarative CUDA via Nix.
- [Flox + CUDA on Nix guide][5] — Nix-but-easier path.
- [elixir-nx/xla README][6] — XLA precompiled binaries (glibc 2.31+, CUDA + cuDNN).
- [EXLA on CUDA — Elixir Forum][7] — common config gotchas.
- [EXLA hexdocs][8] — runtime + env requirements; BEAM-not-root note for Docker.

[1]: https://nixos.org/community/teams/cuda/
[2]: https://oneuptime.com/blog/post/2026-03-03-deploy-nvidia-gpu-operator-on-talos-linux/view
[3]: https://oneuptime.com/blog/post/2026-03-03-install-nvidia-gpu-drivers-on-talos-linux/view
[4]: https://wiki.nixos.org/wiki/CUDA
[5]: https://flox.dev/blog/the-flox-catalog-now-contains-nvidia-cuda/
[6]: https://github.com/elixir-nx/xla
[7]: https://elixirforum.com/t/help-getting-exla-using-cuda-exla-not-identifying-cuda-as-supported-platform/67033
[8]: https://hexdocs.pm/exla/EXLA.html
