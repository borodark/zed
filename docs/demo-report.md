# S6 Demo Technical Report: 3-Node BEAM Cluster on FreeBSD Jails

**Date:** 2026-04-27
**Branch:** feat/demo-cluster
**Host:** free-macpro-nvidia (Mac Pro, FreeBSD 15.0-RELEASE)
**Pool:** mac_zroot

---

## What was built

Seven FreeBSD jails on a single Mac Pro, managed by Bastille, forming
a complete application stack:

| # | Jail | IP | Role |
|---|------|-----|------|
| 1 | zedweb | 10.17.89.10 | Phoenix LiveView admin (Zed's own UI) |
| 2 | livebook | 10.17.89.13 | Livebook (notebook interface, hidden node) |
| 3 | exmc | 10.17.89.14 | NUTS sampler (Nx + Explorer on BinaryBackend) |
| 4 | pg | 10.17.89.20 | PostgreSQL 16 |
| 5 | ch | 10.17.89.21 | ClickHouse 25.11 |
| 6 | craftplan | 10.17.89.11 | Phoenix ERP (deferred — app config) |
| 7 | plausible | 10.17.89.12 | Analytics (deferred — EE license) |

Three BEAM nodes (zedweb, exmc, livebook) form a distributed Erlang
cluster over the bastille0 loopback network, connected via a shared
cookie stored in an encrypted ZFS dataset and nullfs-mounted read-only
into each jail.

The LiveView page at `/cluster` on zedweb displays `Node.list()` in
real time and provides a button that triggers a 4-chain NUTS sampling
run on exmc via `:erpc.call`, displaying results back in the browser.

---

## Architecture diagram

```
                     INTERNET
                        |
                   pf rdr :4000 → 10.17.89.10:4000
                   pf rdr :8080 → 10.17.89.13:8080
                        |
  ┌─────────────────────────────────────────────────────────┐
  │              HOST  (FreeBSD 15.0, mac_zroot)            │
  │                                                         │
  │   zedops (host process, uid 8502)                       │
  │      └── /var/run/zed/ops.sock                          │
  │                                                         │
  │   ┌─── bastille0 (lo1-clone, 10.17.89.0/24) ────────┐  │
  │   │                                                   │  │
  │   │  zedweb ──── distributed erlang ──── exmc         │  │
  │   │     │                                   │         │  │
  │   │     └───────── cluster cookie ──────────┘         │  │
  │   │                     │                             │  │
  │   │                 livebook (hidden node)             │  │
  │   │                                                   │  │
  │   │  pg (PostgreSQL 16)    ch (ClickHouse 25.11)      │  │
  │   └───────────────────────────────────────────────────┘  │
  │                                                         │
  │   ZFS datasets:                                         │
  │     mac_zroot/jails/<name>     (jail roots)             │
  │     mac_zroot/data/<name>      (stateful data)          │
  │     mac_zroot/zed/secrets      (encrypted, passphrase)  │
  │       └── nullfs → /secrets in each BEAM jail (ro)      │
  └─────────────────────────────────────────────────────────┘
```

---

## What worked cleanly

- **Bastille jail creation and networking.** `bastille create` with
  static IPs on bastille0 just works. No bridging complexity.
- **ZFS secrets dataset.** Encrypt once, nullfs mount into N jails.
  Cookie distribution solved with zero file duplication.
- **Distributed Erlang across jails.** EPMD binds to the jail IP,
  distribution ports route over bastille0. No firewall rules needed
  on the internal network.
- **PostgreSQL and ClickHouse in thin jails.** Both installed via
  `bastille pkg`, configured with standard config files, `sysrc` for
  service enable. PostgreSQL needed `allow.sysvipc` in jail params.
- **pf rdr for external access.** Two lines in pf.conf expose exactly
  the ports needed.
- **One-command re-converge.** The `demo-converge.sh` script is
  idempotent — run it again and it skips already-converged state.

---

## What required workarounds

- **Livebook EPMD.** Livebook uses a custom EPMD module
  (`Livebook.EPMD`) that conflicts with standard `epmd`. Solution:
  run as a `--hidden` node with longnames and the shared cookie.
  Appears in `Node.list(:hidden)` only.
- **exmc :crypto missing.** The release didn't include `:crypto` in
  `extra_applications`. Symptom: `** (UndefinedFunctionError)
  :crypto.strong_rand_bytes/1`. Fix: add to release config, rebuild.
- **BinaryBackend overflow.** Nx.BinaryBackend does all math in f64
  without log-space transforms. Wide priors (sigma > ~50) overflow
  during NUTS leapfrog integration. Workaround: keep prior scales
  conservative (sigma 1-10).
- **ERTS PATH in thin jails.** Thin jails don't have `/usr/local/bin`
  in the default PATH. The env.sh must prepend the erlang package path
  explicitly.
- **pkill fallback for release stop.** `bin/app stop` uses
  `:rpc.call` which fails if the node cookie changed or the node is
  wedged. Added `pkill -f` as a fallback before re-staging.
- **CDN JS instead of asset pipeline.** Building esbuild/tailwind
  inside a thin jail is painful (no npm, no Node.js). Used ESM imports
  from jsdelivr for Phoenix LiveView client JS. Works fine.
- **craftplan/plausible deferred.** These apps have complex runtime
  configuration (TOKEN_SIGNING_SECRET, CLOAK_KEY, DB migrations,
  Plausible EE license check). Not an infrastructure problem — the
  converge engine doesn't need to solve "what env vars does your app
  need."

---

## Key learnings

### The boundary between infra and app config

The single most important insight: Zed should own jail lifecycle,
packages, config file generation, service management, and connection
tuple exposure. It should NOT own application-specific secrets,
migration order, or runtime.exs logic. The `specs/standard-jails.md`
document codifies this boundary.

### Livebook EPMD is not optional

Livebook's architecture assumes it controls EPMD. You cannot simply
set `RELEASE_NODE` and have it join a standard cluster. The
`--hidden` flag plus env.sh with explicit longname/cookie is the
minimal viable integration.

### OTP version crossing

All nodes in the cluster must run the same OTP major (27 in our case).
Mix releases pin the ERTS version. If one jail has erlang26 and
another has erlang27, distribution handshake fails silently.

### GPU on FreeBSD: not happening

NVIDIA's FreeBSD driver supports X11/Wayland display output but does
not expose CUDA compute. There is no XLA compiler, no Torchx backend,
no path to EXLA on FreeBSD. The production architecture for
GPU-accelerated inference/training is a multi-host cluster with a
Linux GPU node connected via distributed Erlang. ZFS send/receive
handles dataset replication to the GPU host.

### CDN JS is fine for internal tools

Phoenix LiveView's client JS is ~30KB. Loading it from jsdelivr via
ESM import avoids the entire esbuild/node/npm dependency chain. For
internal admin UIs this is perfectly acceptable.

---

## What's next

### Standard jails behaviour (specs/standard-jails.md)

A `Zed.Jail.Standard` behaviour that encapsulates the
install-configure-enable-healthcheck lifecycle for infrastructure
services. First implementations: PostgreSQL, ClickHouse.

### Converge engine wiring (specs/converge-jail-executor.md)

Replace every `{:ok, :pending}` stub in the executor with real
Bastille operations. Priority: `packages`, `nullfs_mount`,
`jail_svc:start`, `setup` block for platform-specific init.

### Multi-host Layer M

The demo runs on one host. The next phase connects multiple FreeBSD
hosts via distributed Erlang, with ZFS send/receive for state
replication. The GPU-on-Linux path fits here — a Linux node joins
the cluster for compute, FreeBSD nodes handle storage and routing.

---

## How to reproduce

### Prerequisites

- FreeBSD 15.0+ with ZFS
- Bastille installed and bootstrapped (`bastille bootstrap 14.2-RELEASE`)
- bastille0 loopback interface configured on 10.17.89.0/24
- ZFS pool (any name — pass via `POOL` env var)

### Run

```sh
# Clone the repo
git clone <repo-url> zed && cd zed
git checkout feat/demo-cluster

# Generate a passphrase (or reuse)
PASSPHRASE=$(openssl rand -base64 32)

# Converge everything
doas env POOL=mac_zroot PASSPHRASE="$PASSPHRASE" \
  sh scripts/demo-converge.sh
```

The script is idempotent. It will:
1. Create the encrypted secrets dataset (if missing)
2. Bootstrap all 7 jails (create, start, configure networking)
3. Install packages in each jail
4. Deploy BEAM releases (zedweb, exmc, livebook)
5. Write env.sh with node names, cookie path, and longnames
6. Start all services
7. Connect the cluster via `Node.connect/1`

After converge, visit `http://<host-ip>:4000/cluster` to see the
cluster status page and trigger sampling.

### Existing passphrase (for the mac-248 deployment)

```
aaDjeCIRJN0REcVYvFK3VYZbGLgvLEvgYxo35vRULGA=
```

---

## Commit log (selected)

```
fa3d3df demo: 4-chain sampling via :erpc, disable livebook token auth
2869fbe demo: Livebook → eXMC cluster sampling notebook
225a3c7 specs: standard jails — PostgreSQL, ClickHouse, Cube.dev, RabbitMQ
76240b9 docs: S6 milestone — 3-node BEAM cluster across FreeBSD jails
ecb44ff demo S6: 3-node cluster achieved (zedweb + exmc + livebook)
4fb0ad5 demo S6: add TOKEN_SIGNING_SECRET for craftplan
d1b3b89 demo S6: per-app env vars in env.sh
f7fc95c demo S6: add erlang27 to PATH in env.sh + manual cluster connect
94b72bb demo S6: mount secrets dataset separately into BEAM jails
c0324d8 demo S6: unified env.sh for all BEAM jails
6eb8764 demo S6: pkill fallback when release stop fails
b94d61d demo S6: stop running BEAMs before re-staging releases
74e7599 specs: converge jail executor — DSL-to-bastille gap analysis
```
