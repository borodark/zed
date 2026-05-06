# Converge Jail Executor — DSL-to-Bastille gap analysis + setup block proposal

**Status:** proposal, April 2026.
**Context:** S6 demo converge exposed the gap between what the DSL
declares and what the converge engine actually executes.  Many jail
verbs compile into IR and produce Plan steps, but the executor returns
`{:ok, :pending}` stubs.  Shell scripts fill the gap manually.
Platform-specific init (initdb, pg_hba.conf, ClickHouse config) is
not in the DSL at all.

Cross-references:
- [demo-cluster-plan.md](demo-cluster-plan.md) — the five-app demo topology
- [iteration-plan.md](iteration-plan.md) — layer roadmap (A5+)
- [a5-bastille-plan.md](a5-bastille-plan.md) — Bastille adapter primitives

---

## 1. Current state

### DSL verb coverage

| DSL verb | Compiles to IR | Plan generates Step | Executor handles | What actually runs |
|---|---|---|---|---|
| `dataset "path"` | yes | `dataset:create`, `dataset:update` | real ZFS ops | `zfs create`, `zfs set` |
| `app :name` | yes | `app:deploy`, `service:install`, `service:restart` | real deploy + rc.d | `Release.deploy`, `platform.service_install` |
| `jail :name` (basic) | yes | `jail:install`, `jail:create` | real `platform.jail_install/create` | `bastille create`, ZFS property stamp |
| `packages [...]` | yes | `jail_pkg:install` | **stub** `{:ok, :pending}` | manual `bastille pkg` |
| `service :name` (in jail) | yes | `jail_svc:start` | **stub** `{:ok, :pending}` | manual `bastille service` |
| `nullfs_mount` | yes | `jail_mount:create` | **stub** `{:ok, :pending}` | manual `bastille mount` |
| `dataset "d", mount_in_jail:` | yes (parsed) | no dedicated step | no | manual fstab + `bastille mount` |
| `depends_on :jail` | yes (parsed) | no ordering step | no | manual boot order |
| `cookie` | yes (parsed) | no step | no | manual file write |
| `env %{...}` | yes (parsed) | no step | no | manual env file |
| `cluster :name` | yes | `cluster_config:create` | real file write | `Cluster.Config.write!/3` |
| `jail_param "k", v` | **not in DSL** | n/a | n/a | manual `sysrc`/jail.conf edit |
| `setup do...end` | **not in DSL** | n/a | n/a | manual shell commands |

### What scripts do today (S6 bring-up)

The demo-cluster bring-up required roughly 40 lines of shell per jail
for operations the DSL intended to express declaratively:

1. `bastille pkg <jail> install -y <packages>` — for every jail
2. `bastille cmd <jail> sysrc <service>_enable=YES` — service enablement
3. `bastille cmd <jail> service <service> start` — service start
4. `bastille mount <jail> <host> <jail_path> nullfs ro` — nullfs mounts
5. `bastille cmd pg service postgresql initdb` — one-time DB init
6. `bastille cmd pg su -m postgres -c "createdb ..."` — DB/user creation
7. Manual `pg_hba.conf` edit for network auth
8. Manual `jail.conf.d` edit for `allow.sysvipc` (Postgres requirement)
9. ClickHouse `config.xml.sample` copy and edit

Categories 1-4 are things the DSL already declares but the executor
stubs out.  Categories 5-9 are platform-specific imperative init that
the DSL has no verb for.

---

## 2. Three paths evaluated

### Path A: Full converge engine

Every DSL verb produces a converge step with a real executor clause.
`jail_pkg:install` calls `Bastille.cmd(jail, ["pkg", "install", "-y" | pkgs])`.
`jail_svc:start` calls `Bastille.cmd(jail, ["sysrc", ...])` then
`Bastille.cmd(jail, ["service", svc, "start"])`.  And so on for
mounts, env files, cookie files, depends_on ordering.

**Pros:** Single source of truth.  `converge()` is the only command.
Rollback covers everything.

**Cons:** Largest scope.  Platform-specific init (initdb, pg_hba.conf,
allow.sysvipc, ClickHouse config) still has no verb — every database
product needs custom logic.  Scope creep toward a configuration
management tool (Ansible/Chef territory).

**Effort:** ~3 days for the executor wiring; open-ended for
platform-specific init.

### Path B: Converge + hooks (lifecycle hooks for platform-specific init)

Wire the existing stubs to real Bastille calls (same as Path A for
the known verbs), but add a `setup` block for one-time imperative
init.  The setup block runs arbitrary commands inside the jail after
packages are installed but before services start.  A ZFS user
property (`com.zed:setup_done=<sha256>`) tracks whether the block has
already executed; re-converge skips it unless the block's content
hash changes.

**Pros:** Covers the 80% case (packages, services, mounts) with
proper converge steps.  Handles the 20% long tail (initdb,
pg_hba.conf, allow.sysvipc) without inventing a verb for every
database product.  Content-hash tracking means the setup block is
idempotent and auditable.

**Cons:** Setup block is imperative — not diffable, not individually
rollbackable.  Operator must think about idempotency inside the
block.

**Effort:** ~2 days for executor wiring + ~1 day for setup block DSL
and tracking.

### Path C: Bastille templates as adapter

Bastille ships a template system (`bastille template`) that can
install packages, copy files, run commands, and enable services from
a Templatefile.  Zed could render a Bastille Templatefile from IR
and apply it via `bastille template <jail> <path>`.

**Pros:** Leverages existing Bastille machinery.  Template files are
inspectable artifacts.

**Cons:** Bastille templates are not idempotent — re-applying
reinstalls packages and re-runs commands.  Template error handling is
opaque (exit codes only, no structured output).  Zed loses
per-step visibility and rollback granularity.  Couples tightly to
Bastille's template format, which has changed across versions.

**Effort:** ~1.5 days, but ongoing maintenance cost from Bastille
template format coupling.

---

## 3. Recommendation

**Path B** is the pragmatic next step.  Path A is the long-term
direction, but the setup block from Path B is a permanent addition
(not throwaway) because platform-specific init is inherently
imperative — there will always be a `createdb` or a config file edit
that doesn't warrant a DSL verb.

### Implementation: `Zed.Converge.Executor.Bastille`

A new module (or extension of the existing executor's jail clauses)
that replaces the three stubs:

```
jail_pkg:install  -> Bastille.cmd(jail, ["pkg", "install", "-y" | packages])
jail_mount:create -> Bastille.cmd(jail, ["mount", host_path, jail_path, "nullfs", mode])
jail_svc:start    -> Bastille.cmd(jail, ["sysrc", "#{svc}_enable=YES"])
                   + Bastille.cmd(jail, ["service", svc, "start"])
```

Additional steps generated from existing IR fields that currently
have no step:

| IR field | New step type | Executor action |
|---|---|---|
| `depends_on` | ordering constraint | topological sort in Plan (no executor step; deps field on existing steps) |
| `cookie` | `jail_file:create` | write cookie file inside jail via `Bastille.cmd` |
| `env %{...}` | `jail_file:create` | write env file inside jail via `Bastille.cmd` |
| `mount_in_jail` | `jail_mount:create` | same as nullfs_mount path |
| `jail_param` | `jail_config:set` | write to jail.conf.d or `bastille config` |

### Implementation: `setup` block DSL verb

A new block inside `jail` that accumulates imperative commands.
Tracked by a ZFS user property containing the SHA-256 of the
block's serialized content.  Converge runs the block only when the
hash differs from the stored property (first run, or block changed).

### Implementation: `jail_param` DSL verb

A new key-value verb inside `jail` that maps to jail.conf parameters.
Needed for `allow.sysvipc`, `allow.raw_sockets`, `enforce_statfs`,
and similar jail-level knobs that packages require.

---

## 4. Proposed DSL shape

```elixir
jail :pg do
  ip4 "10.17.89.20/24"
  release "15.0-RELEASE"
  packages ["postgresql16-server"]
  jail_param "allow.sysvipc", true

  setup do
    cmd "sysrc postgresql_enable=YES"
    cmd "service postgresql initdb"
    cmd ~S|su -m postgres -c "createdb -O craftplan craftplan"|
    cmd ~S|su -m postgres -c "createdb -O plausible plausible_db"|
    file "/var/db/postgres/16/data/pg_hba.conf",
         append: "host all all 10.17.89.0/24 scram-sha-256"
  end

  service :postgresql, env: %{"PGDATA" => "/var/db/postgres/16/data"}
end

jail :ch do
  ip4 "10.17.89.21/24"
  release "15.0-RELEASE"
  packages ["clickhouse"]
  jail_param "allow.raw_sockets", true

  setup do
    cmd "cp /usr/local/etc/clickhouse-server/config.xml.sample " <>
        "/usr/local/etc/clickhouse-server/config.xml"
    file "/usr/local/etc/clickhouse-server/config.xml",
         replace: {"<listen_host>::1</listen_host>",
                   "<listen_host>0.0.0.0</listen_host>"}
  end

  service :clickhouse_server
end
```

### Setup block semantics

- **Runs inside the jail** via `Bastille.cmd/2`.
- **Runs once** unless the block content changes (tracked by
  `com.zed:setup_hash` on the jail's dataset).
- **Runs after** packages are installed but **before** services start.
- **`cmd`** executes a shell command; non-zero exit aborts converge.
- **`file`** with `append:` appends a line if not already present
  (grep-before-append).  With `replace:` does a sed-style
  substitution.  With `content:` writes the full file.
- **Not rollbackable** at the command level.  Rollback restores the
  ZFS snapshot, which includes filesystem state from before the
  setup block ran.

### Plan step ordering with setup

```
dataset:create  ->  jail:install  ->  jail:create  ->  jail_pkg:install
  ->  jail_config:set (jail_param)  ->  jail_setup:run  ->  jail_svc:start
  ->  app:deploy  ->  service:install  ->  service:restart
```

---

## 5. Effort estimate

| Piece | Effort | Notes |
|---|---|---|
| Wire three executor stubs to Bastille | 0.5 d | `jail_pkg`, `jail_mount`, `jail_svc` — adapter calls exist |
| `depends_on` ordering in Plan | 0.25 d | Add deps to existing step builders |
| `cookie` + `env` file write steps | 0.5 d | New `jail_file:create` step type |
| `jail_param` DSL verb + jail.conf.d write | 0.5 d | New verb + executor clause |
| `setup` block DSL parsing | 0.5 d | New AST parser in `parse_jail_block` |
| `setup` executor + hash tracking | 0.5 d | SHA-256 of block, ZFS user property check |
| Tests (unit + live) | 0.5 d | Mock runner for unit; live against test jail |
| **Total** | **~3.25 d** | |

### What this unblocks

- **Demo converge in one command.** Currently requires ~200 lines of
  shell scripts alongside `MyInfra.Demo.converge()`.  After this
  work, the shell scripts reduce to release builds only.
- **Rollback covers jail state.** ZFS snapshot before converge
  captures the jail filesystem; rollback restores packages, config
  files, and DB state atomically.
- **Repeatable demo.** `converge()` followed by `rollback("@pre-converge")`
  is a clean round-trip, provable on stage.
- **Path to multi-host.** `zfs send | zfs receive` of a converged
  jail dataset to a second host brings the full jail state, including
  setup artifacts.  No separate config management channel needed.
