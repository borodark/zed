# S6 Milestone: 3-Node BEAM Cluster Across FreeBSD Jails

**Date:** 2026-04-27
**Branch:** feat/demo-cluster
**Host:** free-macpro-nvidia (mac-248, 192.168.0.248)
**Pool:** mac_zroot

---

## What's running

```
         JAIL  IP             NODE NAME              STATUS
         ────  ──────────     ─────────────────      ──────
         #1    10.17.89.10    zedweb@10.17.89.10     ✓ clustered
         #2    10.17.89.13    livebook@10.17.89.13   ✓ clustered
         #3    10.17.89.14    exmc@10.17.89.14       ✓ clustered
         #4    10.17.89.20    pg (PostgreSQL 16)     ✓ running
         #5    10.17.89.21    ch (ClickHouse 25.11)  ✓ running
         #6    10.17.89.11    craftplan              deferred (app config)
         #7    10.17.89.12    plausible              deferred (EE license)
```

## Cluster verification

```elixir
# From zedweb via rpc:
iex(zedweb@10.17.89.10)> Node.list()
[:"exmc@10.17.89.14", :"livebook@10.17.89.13"]
```

Three BEAM nodes across three FreeBSD jails, connected via shared
cookie over bastille0 loopback. Cookie read from nullfs-mounted
encrypted ZFS secrets dataset.

## What this proves

1. **Distributed Erlang across Bastille jails** — bastille0 loopback
   routes epmd + distribution traffic between jail IPs.
2. **Shared cookie via ZFS secrets** — one encrypted dataset, nullfs
   mounted read-only into each jail. No file duplication.
3. **Converge-to-cluster pipeline** — bootstrap → secrets → jails →
   packages → releases → env.sh → daemon → Node.connect.
4. **ZFS as state store** — secrets, cluster artifact, and bootstrap
   metadata all stored as ZFS datasets + user properties.

## What's deferred (and why)

| App | Issue | Not a Zed problem |
|---|---|---|
| craftplan | Needs TOKEN_SIGNING_SECRET, CLOAK_KEY, DB migration | Production app config complexity |
| plausible | Enterprise Edition license check | Wrong release build (needs CE) |

These are app-level operational prerequisites, not infrastructure
gaps. The converge engine doesn't need to solve "what env vars does
craftplan need" — that's the operator's responsibility via the DSL's
`env` block.

## Lessons for the converge engine

Every shell script workaround we added is a spec for what the engine
needs to handle natively. See `specs/converge-jail-executor.md` for
the full gap analysis. Key items:

- `packages` → `bastille pkg install` (done manually in PHASE 3b)
- `allow.sysvipc` → `bastille config` (done in pg bootstrap)
- nullfs child mounts → separate mount for ZFS child datasets
- env.sh generation → per-app from DSL `env` + `cookie` + `node_name`
- ERTS PATH → system erlang not in default PATH in thin jails
- graceful stop before restage → pkill fallback when rpc fails

## Passphrase (for future runs)

```
aaDjeCIRJN0REcVYvFK3VYZbGLgvLEvgYxo35vRULGA=
```

## Re-run command

```sh
doas env POOL=mac_zroot PASSPHRASE='aaDjeCIRJN0REcVYvFK3VYZbGLgvLEvgYxo35vRULGA=' \
  sh /home/io/zed/scripts/demo-converge.sh
```

## What changed since initial milestone

**LiveView cluster page at /cluster on zedweb.** A Phoenix LiveView
showing `Node.list()` in real time, with a button that triggers NUTS
sampling on exmc via `:rpc.call`. Proves the full loop: browser →
zedweb → distributed Erlang → exmc computation → result back to
LiveView. No asset pipeline — JS loaded via CDN ESM imports from
jsdelivr (Phoenix LiveView client, topbar).

**Livebook EPMD research.** Standalone runtimes (Livebook's default)
cannot join an external BEAM cluster because they use `Livebook.EPMD`
as a custom EPMD module and short names. Solution: configure Livebook
with `--hidden` node and explicit longname + cookie via env.sh. The
node appears in `Node.list(:hidden)` but does not disrupt the main
cluster topology.

**exmc rebuilt with :crypto + :binary_backend JIT fix.** The initial
exmc release was missing `:crypto` in extra_applications and hit JIT
issues with Nx.BinaryBackend on FreeBSD/aarch64. Fixed by adding
`:crypto` to the release and pinning BinaryBackend explicitly.

**BinaryBackend numerical stability issues.** Wide priors (e.g.,
`Normal.new(0, 100)`) cause overflow in BinaryBackend's f64 math
during NUTS adaptation. Workaround: use conservative parameter scales
(sigma ~ 1-10). This is a known Nx limitation — EXLA handles it via
log-space ops, but EXLA requires CUDA (see GPU note below).

**GPU on FreeBSD research: no path forward.** NVIDIA's FreeBSD driver
supports display but not CUDA compute. No EXLA, no Torchx, no XLA
backend. The production path for GPU-accelerated sampling is a
multi-host topology with a Linux GPU node connected via distributed
Erlang. ZFS send/receive can push model/data datasets to the GPU host.

**Standard jails spec written** (`specs/standard-jails.md`). Defines
the boundary between Zed's responsibility (jail lifecycle, packages,
config files, service start, health check, expose connection tuple)
and app responsibility (migrations, business secrets, connection
pooling). Covers PostgreSQL, ClickHouse, Cube.dev, RabbitMQ.

**Converge jail executor spec written** (`specs/converge-jail-executor.md`).
Full gap analysis between what the DSL declares and what the executor
actually handles today. Documents every `{:ok, :pending}` stub and
proposes a `setup` block for platform-specific init (initdb, config
file templates, service enable).

**CDN LiveView JS for zedweb.** Rather than building a full asset
pipeline (esbuild, tailwind, npm), zedweb loads Phoenix LiveView JS
and topbar from jsdelivr via ESM `<script type="module">` imports.
Zero build step, works in thin jails with no Node.js.

**pf rdr working for external access.** Host-level pf rules redirect
external traffic on ports 4000 (zedweb) and 8080 (Livebook) to the
respective jail IPs on bastille0. All other jail traffic stays on the
loopback network.

---

## What's next

- **S7**: Recording + blog post with the 3-node cluster as the demo.
- **Post-demo**: Wire the converge engine to handle the shell script's
  responsibilities natively (specs/converge-jail-executor.md).
- **craftplan/plausible**: Separate iteration after converge engine
  handles `env` and `setup` blocks.
