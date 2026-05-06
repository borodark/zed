# S4: ClickHouse on FreeBSD — Findings

**Date:** 2026-04-25
**Branch:** feat/demo-cluster
**Status:** research complete — **path (a): native pkg is clean, use it.**

---

## 1. Native FreeBSD package

**Available.** `databases/clickhouse` is in the quarterly pkg repo for
FreeBSD 15 amd64.

```
clickhouse-25.11.1.558
Origin:    databases/clickhouse
Built:     2026-04-15 (poudriere)
Size:      391 MiB installed, 74.4 MiB pkg
License:   Apache-2.0
Deps:      python311, bash (runtime only — no heavy chains)
Maintainer: pi@FreeBSD.org
```

Install is one command:

```sh
pkg install -y clickhouse
```

The package ships `clickhouse-server`, `clickhouse-client`, and the
single-binary multi-tool (`clickhouse local`, etc.) — same layout as
the upstream Linux release.

### rc.d service

The port installs `/usr/local/etc/rc.d/clickhouse`. Standard
`sysrc clickhouse_enable=YES && service clickhouse start`. Config
lives under `/usr/local/etc/clickhouse-server/`.

### Data directory

Default: `/var/lib/clickhouse` (same as Linux upstream and the
Docker image). This maps cleanly to the demo plan's
`<pool>/data/ch → /var/lib/clickhouse` jail mount.

---

## 2. Linux-compat layer

**Not needed.** Since a native package exists, there is no reason to
use the Linuxulator. Documenting for completeness:

- ClickHouse's static Linux x86_64 binary *does* run under FreeBSD's
  `linux64` compat on amd64 hosts, but requires `linprocfs` and
  `linsysfs` mounted inside the jail, plus `allow.mount.linprocfs`
  in jail.conf. ClickHouse reads `/proc/meminfo`,
  `/proc/stat`, and `/sys/devices/system/node/` at startup.
- Performance overhead of the compat layer is negligible for I/O-bound
  OLAP, but the added jail configuration complexity is unnecessary
  when a native package exists.

**Verdict:** skip.

---

## 3. Container-on-jail (Linux jail / osrelease)

**Not applicable.** FreeBSD 13+ `osrelease=Linux` jails are for
running Linux userlands under the Linuxulator. Since we have a native
FreeBSD binary, this adds complexity for zero benefit. The Docker
`clickhouse/clickhouse-server:24.12-alpine` image cannot run directly
inside a FreeBSD jail regardless — it needs a Linux kernel ABI.

**Verdict:** skip.

---

## 4. Plausible's actual ClickHouse requirements

From `plausible/community-edition` `compose.yml` (checked out at
`~/community-edition`):

```yaml
plausible_events_db:
  image: clickhouse/clickhouse-server:24.12-alpine
```

**Plausible pins ClickHouse 24.12.** The FreeBSD package is **25.11**.
This is a major-version jump, but ClickHouse maintains strong backward
compatibility for the HTTP interface (port 8123) and the native
protocol (port 9000). Plausible talks to ClickHouse via the HTTP
interface (`CLICKHOUSE_DATABASE_URL=http://...:8123/...`), which has
been stable across majors.

### Risk assessment: 24.12 → 25.11

| Concern | Risk | Notes |
|---|---|---|
| Wire protocol (HTTP 8123) | **None** | Stable across all recent majors |
| SQL dialect | **Low** | Plausible uses standard ClickHouse SQL (MergeTree, ReplacingMergeTree); no removed syntax between 24→25 |
| System tables schema | **Low** | Plausible doesn't query system tables at runtime |
| Migration compatibility | **Low** | Plausible's `db createdb` and `db migrate` use standard DDL |

**Verdict:** 25.11 will work. If we hit an edge case, the FreeBSD
ports tree carries the build infrastructure to compile an older
version, but this is unlikely to be needed.

### Config files to replicate

Plausible ships four ClickHouse config overrides. All are small XML
snippets that apply to any ClickHouse version:

| File | Purpose | Jail equivalent |
|---|---|---|
| `logs.xml` | Warning-level logging, query_log TTL 30d | `/usr/local/etc/clickhouse-server/config.d/logs.xml` |
| `ipv4-only.xml` | `<listen_host>0.0.0.0</listen_host>` | Same path; needed so CH listens on the jail's bastille0 IP |
| `low-resources.xml` | `mark_cache_size` 500 MB | Same path; good for demo (Mac Pro has plenty of RAM but no reason to waste it) |
| `default-profile-low-resources-overrides.xml` | Single-threaded profile | `/usr/local/etc/clickhouse-server/users.d/...` |

All four can be dropped into the jail's config dirs via Bastille
`cp` or a `nullfs_mount` of a host-side config directory.

### Health check

Plausible's compose uses:

```sh
wget --no-verbose --tries=1 -O - http://127.0.0.1:8123/ping
```

The jail equivalent for the Zed health check:

```elixir
health :http, url: "http://10.17.89.21:8123/ping", expect: 200
```

---

## 5. Recommendation

**Path (a): native pkg is clean — use it.**

The `databases/clickhouse` FreeBSD port is:
- Recent (25.11, built two weeks ago)
- Well-maintained (`pi@FreeBSD.org`)
- Zero exotic dependencies
- rc.d service included
- Data dir matches Docker convention (`/var/lib/clickhouse`)
- Compatible with Plausible's CH requirements (HTTP interface, standard SQL)

No linux-compat layer needed. No container-on-jail gymnastics. The
demo plan's `jail :ch` block works as-written in the spec:

```elixir
jail :ch do
  ip4 "10.17.89.21/24"
  release "15.0-RELEASE"
  packages ["clickhouse"]
  dataset "data/ch", mount_in_jail: "/var/lib/clickhouse"
  service :clickhouse_server
end
```

The only addition needed: a config-file provisioning step that drops
the four Plausible XML snippets into the jail's
`/usr/local/etc/clickhouse-server/config.d/` and `users.d/` before
first start. This can be a `bastille cp` in the converge plan or a
future `config_files` DSL verb.

### What this unblocks

- **S5** can proceed — Plausible release prep can target ClickHouse
  on FreeBSD without substitution.
- **S7 (DB jails)** — `pkg install clickhouse` + config drop + `sysrc`
  + `service start` is the full ritual. Straightforward.
- **No need for path (c)** — Plausible stays in the demo.
