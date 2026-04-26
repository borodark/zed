# S5b Status: Three Easy Releases + Two DB Jails

**Date:** 2026-04-26
**Branch:** feat/demo-cluster
**Machine:** mac-248 (192.168.0.248, FreeBSD 15.0)

---

## Completed

### 1. zedweb release — verified

- Builds clean on system OTP 26 + Elixir 1.17.3
- Artifact: `~/zed/_build/prod/rel/zedweb`
- No source changes needed; release target already existed in mix.exs

### 2. livebook release — built

- Cloned from GitHub, tag `v0.19.7`
- Required OTP 27 + Elixir 1.18 (system Elixir 1.17 too old)
- Installed via kerl + kiex: OTP 27.3.4.11, Elixir 1.18.4
- Artifact: `~/livebook/_build/prod/rel/livebook`
- No source changes to livebook needed — it reads `LIVEBOOK_NODE`,
  `LIVEBOOK_COOKIE`, `LIVEBOOK_IP`, `LIVEBOOK_PORT`, `LIVEBOOK_PASSWORD`
  from env vars natively. Demo sets these in the jail's rc.conf.d.
- Livebook uses `DNSCluster`, not libcluster. The other four apps
  connect to it via libcluster Epmd — Livebook just needs to be a
  named, cookie'd node.

### 3. exmc release — built, uncommitted

- Cloned from `https://github.com/borodark/eXMC.git`
- Required OTP 27 + Elixir 1.18 (same kerl/kiex install as livebook)
- Artifact: `~/exmc/_build/prod/rel/exmc`
- **Four files changed, uncommitted in ~/exmc/:**
  - `mix.exs` — added `releases:` block, `mod: {Exmc.Application, []}`,
    moved EXLA/EMLX to `only: [:dev, :test]` (jails can't GPU)
  - `lib/exmc/application.ex` — new minimal Application module
  - `config/runtime.exs` — `:binary_backend` config, Alpaca creds from env
  - `rel/env.sh.eex` — reads cookie from `/var/db/zed/secrets/demo_cluster_cookie`,
    sets `RELEASE_NODE=exmc@10.17.89.14`

### 4. pg bootstrap script — committed + pushed

- Commit `ceb3071` on feat/demo-cluster
- `scripts/demo-pg-bootstrap.sh` — idempotent: creates jail, installs
  postgresql16-server, initdb, creates craftplan + plausible_db
  databases/users, configures pg_hba.conf for bastille0 subnet

### 5. ch bootstrap script — committed + pushed

- Commit `db30bf9` on feat/demo-cluster
- `scripts/demo-ch-bootstrap.sh` + `scripts/clickhouse-config/` (4 XML files)
- Idempotent: creates jail, installs native clickhouse pkg, deploys
  Plausible config overrides, creates plausible_events_db database

---

## Toolchain installed on mac-248

| Tool | Version | Path | Activate |
|---|---|---|---|
| kerl | 4.4.0 | `~/bin/kerl` | (always available) |
| OTP | 27.3.4.11 | `~/.kerl/installs/27.3.4.11/` | `. ~/.kerl/installs/27.3.4.11/activate` |
| kiex | latest | `~/.kiex/` | `. ~/.kiex/scripts/kiex` |
| Elixir | 1.18.4 | `~/.kiex/elixirs/elixir-1.18.4-27.env` | `. ~/.kiex/elixirs/elixir-1.18.4-27.env` |
| rust | 1.94.0 | pkg | (system-wide) |
| cmake | pkg | pkg | (system-wide) |

**To activate the full OTP 27 + Elixir 1.18 stack:**

```sh
. ~/.kerl/installs/27.3.4.11/activate && . ~/.kiex/elixirs/elixir-1.18.4-27.env
```

**Note:** zedweb builds on system OTP 26 + Elixir 1.17. Livebook and
exmc require the kerl/kiex stack. The jails use `erlang-runtime27` pkg.

---

## What's next

- **mac-247** is working on Plausible + craftplan releases (S5a)
- **Linux session** is on cluster-config plan-step wiring
- After all S5 work lands → **S6: end-to-end converge** against this Mac Pro
