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

## What's next

- **S7**: Recording + blog post with the 3-node cluster as the demo.
- **Post-demo**: Wire the converge engine to handle the shell script's
  responsibilities natively (specs/converge-jail-executor.md).
- **craftplan/plausible**: Separate iteration after converge engine
  handles `env` and `setup` blocks.
