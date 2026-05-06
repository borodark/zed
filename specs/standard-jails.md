# Standard Jails: PostgreSQL, ClickHouse, Cube.dev, RabbitMQ

**Date:** 2026-04-27
**Status:** plan, informed by S6 experience

---

## The boundary

Zed manages **infrastructure jails** — services that BEAM apps consume.
Zed does NOT manage app-internal configuration (env vars, migrations,
business logic secrets, license keys).

The contract:

```
Zed's responsibility          App's responsibility
─────────────────────         ────────────────────
jail create + start           runtime.exs
package install               DATABASE_URL construction
jail params (sysvipc, etc.)   migrations (mix ecto.migrate)
config file generation        business secrets (CLOAK_KEY, etc.)
service enable + start        connection pooling config
database/vhost creation       schema ownership
health check endpoint         query patterns
expose: {ip, port, creds}     consume: {ip, port, creds}
```

The output of a standard jail is a **connection tuple** that consuming
apps reference in their `env` block:

```elixir
jail :pg do
  # ... Zed handles everything below
end

jail :myapp do
  app :myapp do
    env %{
      "DATABASE_URL" => {:pg, :url, db: "myapp"}  # Zed resolves this
    }
  end
end
```

---

## What Zed does NOT do (learned from S6)

1. **App-specific env vars.** TOKEN_SIGNING_SECRET, CLOAK_KEY,
   GOOGLE_CLIENT_ID — these are infinite in variety. The operator
   supplies them via the `env` block or secrets catalog. Zed passes
   them through, doesn't generate or validate them.

2. **App migrations.** `mix ecto.migrate` is the app's job. Zed can
   offer a `post_start` hook that runs it, but doesn't own the
   migration content or know if it succeeded semantically.

3. **App health beyond "process is up."** Zed checks the health
   endpoint. Whether the app is *functionally correct* (serving the
   right data, connected to the right upstream) is the app's problem.

4. **Version compatibility between apps and infrastructure.** If
   plausible needs ClickHouse 24.x and we ship 25.x, that's a
   version pin in the DSL (`version: "24.12"`), not magic.

---

## The four standard jails

### 1. PostgreSQL

**Package:** `postgresql16-server` (or `postgresql17-server`)
**Jail params:** `allow.sysvipc = true` (SysV shared memory)
**Config:**
- `pg_hba.conf`: allow `scram-sha-256` from bastille0 subnet
- `postgresql.conf`: `listen_addresses = '0.0.0.0'`
**Init:** `initdb` (one-time, tracked by data dir existence)
**Provisioning:** create databases + users per `consumers` list
**Health:** `pg_isready -h <ip>`
**Exposes:** `{ip: "10.17.89.x", port: 5432, users: [{name, password}], databases: [name]}`

```elixir
jail :pg, standard: :postgresql do
  ip4 "10.17.89.20/24"
  version "16"
  databases [:craftplan, :plausible_db]
  users [
    craftplan: {db: :craftplan, password: {:secret, :pg_craftplan_passwd}},
    plausible: {db: :plausible_db, password: {:secret, :pg_plausible_passwd}}
  ]
end
```

**What this compiles to (converge steps):**
1. `bastille create` with `allow.sysvipc`
2. `bastille pkg install postgresql16-server`
3. Write `pg_hba.conf` + `postgresql.conf` overrides
4. `initdb` (if data dir absent)
5. `service postgresql start`
6. `createuser` + `createdb` per entry (idempotent)
7. `ALTER USER ... PASSWORD` from secrets
8. Health: `pg_isready`

### 2. ClickHouse

**Package:** `clickhouse` (native FreeBSD port, currently 25.11)
**Jail params:** none special
**Config:**
- `config.xml` from sample
- `config.d/ipv4-only.xml`: listen on 0.0.0.0
- `config.d/logs.xml`: warning level, query_log TTL
- `config.d/low-resources.xml`: mark_cache 500MB (optional)
- `users.d/low-resources.xml`: single-threaded profile (optional)
**Init:** none (ClickHouse self-initializes on first start)
**Provisioning:** create databases per `consumers` list
**Health:** `http://<ip>:8123/ping` returns "Ok."
**Exposes:** `{ip: "10.17.89.x", port: 8123, databases: [name]}`

```elixir
jail :ch, standard: :clickhouse do
  ip4 "10.17.89.21/24"
  profile :low_resources  # optional tuning preset
  databases [:plausible_events_db]
end
```

**What this compiles to:**
1. `bastille create`
2. `bastille pkg install clickhouse`
3. Copy `config.xml.sample` → `config.xml`
4. Write config.d/ and users.d/ snippets (based on profile)
5. `service clickhouse start`
6. `clickhouse-client --query "CREATE DATABASE IF NOT EXISTS ..."`
7. Health: fetch `http://127.0.0.1:8123/ping`

### 3. Cube.dev

**Package:** none in FreeBSD ports — Node.js app, install via npm
**Jail params:** none
**Runtime:** needs `node` (pkg: `node22` or similar)
**Config:**
- `cube.js` or env vars: `CUBEJS_DB_TYPE`, `CUBEJS_DB_HOST`, etc.
- Points at the pg or ch jail for its data source
**Init:** `npm install` in the cube directory (or pre-built tarball)
**Provisioning:** schema files are app-provided, not Zed's job
**Health:** `http://<ip>:4000/readyz`
**Exposes:** `{ip: "10.17.89.x", port: 4000}`

```elixir
jail :cube, standard: :cubejs do
  ip4 "10.17.89.22/24"
  node_version "22"
  source "/path/to/cube-project"  # or tarball
  env %{
    "CUBEJS_DB_TYPE" => "postgres",
    "CUBEJS_DB_HOST" => {:pg, :ip},
    "CUBEJS_DB_PORT" => "5432",
    "CUBEJS_DB_NAME" => "analytics",
    "CUBEJS_DB_USER" => "cube",
    "CUBEJS_DB_PASS" => {:secret, :pg_cube_passwd}
  }
end
```

**What this compiles to:**
1. `bastille create`
2. `bastille pkg install node22 npm-node22`
3. Stage source/tarball into jail
4. `npm install --production` (if from source)
5. Write env file from `env` block
6. Start via rc.d script or `node` directly
7. Health: `http://127.0.0.1:4000/readyz`

### 4. RabbitMQ

**Package:** `rabbitmq` (FreeBSD port, well-maintained)
**Jail params:** none special
**Config:**
- `rabbitmq.conf`: listener bind, default vhost
- `enabled_plugins`: `rabbitmq_management` (optional)
**Init:** none (self-initializes)
**Provisioning:** create vhosts + users per `consumers` list
**Health:** `rabbitmqctl status` or management API
**Exposes:** `{ip: "10.17.89.x", port: 5672, management_port: 15672, vhosts: [name]}`

```elixir
jail :mq, standard: :rabbitmq do
  ip4 "10.17.89.23/24"
  plugins [:management]
  vhosts [:craftplan, :events]
  users [
    craftplan: {vhost: :craftplan, password: {:secret, :mq_craftplan_passwd}},
    plausible: {vhost: :events, password: {:secret, :mq_plausible_passwd}}
  ]
end
```

**What this compiles to:**
1. `bastille create`
2. `bastille pkg install rabbitmq`
3. Write `rabbitmq.conf` (listen on jail IP)
4. `rabbitmq-plugins enable` per plugin
5. `service rabbitmq start`
6. `rabbitmqctl add_vhost` + `add_user` + `set_permissions` (idempotent)
7. Health: `rabbitmqctl status`

---

## Implementation shape

Each standard jail is a **behaviour module** under `Zed.StandardJail.*`:

```elixir
defmodule Zed.StandardJail do
  @callback packages(opts :: map()) :: [String.t()]
  @callback jail_params(opts :: map()) :: [{String.t(), term()}]
  @callback config_files(opts :: map()) :: [{path :: String.t(), content :: String.t()}]
  @callback init_commands(opts :: map()) :: [String.t()]
  @callback provision_commands(opts :: map()) :: [String.t()]
  @callback health_check(opts :: map()) :: Zed.Health.check_spec()
  @callback connection_info(opts :: map()) :: map()
end
```

Implementations: `Zed.StandardJail.PostgreSQL`, `.ClickHouse`,
`.CubeJS`, `.RabbitMQ`.

The DSL's `standard: :postgresql` option selects the behaviour and
delegates the converge steps to it. The operator only specifies what
varies (IP, databases, users, profile). Everything else is the
behaviour's opinion.

---

## What this keeps out of scope

- **MySQL/MariaDB** — not needed by any current app. Add when needed.
- **Redis** — often used as cache; if needed, trivial (pkg + service).
  Add as a 5th standard jail later.
- **Kafka** — too heavy for single-host demo. RabbitMQ covers the
  message broker slot.
- **Elasticsearch/Meilisearch** — search is app-specific. Not standard.
- **nginx/caddy** — reverse proxy is host-level (pf rdr), not a jail.

---

## Effort

| Piece | Effort |
|---|---|
| `Zed.StandardJail` behaviour + DSL integration | 1 d |
| PostgreSQL implementation | 0.5 d |
| ClickHouse implementation | 0.5 d |
| RabbitMQ implementation | 0.5 d |
| Cube.dev implementation | 1 d (Node.js in jail is less charted) |
| Connection tuple resolution in `env` blocks | 0.5 d |
| **Total** | **~4 d** |

This is post-demo work. The demo proved the pattern manually; this
iteration codifies it.

---

## Cross-references

- `specs/converge-jail-executor.md` — the broader executor gap analysis
- `specs/clickhouse-on-freebsd.md` — S4 research (ClickHouse is native pkg)
- `scripts/demo-pg-bootstrap.sh` — the manual version of PostgreSQL standard jail
- `scripts/demo-ch-bootstrap.sh` — the manual version of ClickHouse standard jail
