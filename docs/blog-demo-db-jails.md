# Two Real Databases From One Function Call

*The Path B follow-through: what closing the last 200 lines of shell
against a real Postgres and ClickHouse cost in bugs.*

---

## The gap Path B left open

Path B closed every executor stub in Zed's jail pipeline. That was a
real milestone: on a single scratch jail, `Zed.Examples.SmokePathB.converge()`
brought up packages, mounts, `jail_param`, `jail_file`, a `setup do`
block, and a service, all idempotently. Green in tests, green on the
metal, green on re-run.

But the S6 demo bring-up — the actual purpose of Zed — needed more
than one scratch jail. It needed a stateful Postgres jail with its
data volume on a separate ZFS dataset, `initdb` run exactly once,
`pg_hba.conf` and `postgresql.conf` edited for cluster access, and a
ClickHouse jail with four XML config overlays applied, plus proof
that both accepted connections. Under S6, that had been ~200 lines of
shell across `demo-pg-bootstrap.sh` (113) and `demo-ch-bootstrap.sh`
(87) — scripts running alongside the Elixir converge module, filling
in what the executor couldn't yet do.

Path B was the primitives; the demo module was the load test.

## What DemoDbJails looks like

The whole target is 177 lines of Elixir, most of it comments and
inlined XML content:

```elixir
jail :pg do
  dataset "jails/pg"
  ip4 "10.17.89.20/24"
  release "15.0-RELEASE"

  packages ["postgresql16-server"]
  jail_param "allow.sysvipc", true
  dataset "data/pg", mount_in_jail: "/var/db/postgres"

  setup do
    cmd "sysrc -f /etc/rc.conf.d/postgresql postgresql_data=/var/db/postgres/16/data"
    cmd "chown postgres:postgres /var/db/postgres"
    cmd "test -f /var/db/postgres/16/data/PG_VERSION || service postgresql oneinitdb"
    cmd "grep -qxF 'host all all 10.17.89.0/24 scram-sha-256' /var/db/postgres/16/data/pg_hba.conf || echo 'host all all 10.17.89.0/24 scram-sha-256' >> /var/db/postgres/16/data/pg_hba.conf"
    cmd "grep -qxF \"listen_addresses = '0.0.0.0'\" /var/db/postgres/16/data/postgresql.conf || echo \"listen_addresses = '0.0.0.0'\" >> /var/db/postgres/16/data/postgresql.conf"
  end

  service :postgresql
end
```

The ClickHouse jail is the same shape with `allow.raw_sockets`, four
`jail_file` overlays reading from `@ch_logs`, `@ch_ipv4` etc.
(read from disk at module compile time), and a smaller setup block
that activates the pkg's sample config.

One `converge()` call. 19 steps. Rollback via `zfs rollback`. The
output on a fresh run:

```
{"jail:svc:ch:clickhouse", {:jail_svc_started, "ch", "clickhouse"}},
{"jail:svc:pg:postgresql", {:jail_svc_started, "pg", "postgresql"}},
{"jail:setup:ch",          {:jail_setup_ran, "ch", 2}},
{"jail:setup:pg",          {:jail_setup_ran, "pg", 5}},
{"jail:file:ch:0",         {:jail_file_created, "ch", ...logs.xml}},
{"jail:file:ch:1",         ...ipv4-only.xml},
{"jail:file:ch:2",         ...low-resources.xml},
{"jail:file:ch:3",         ...users.d/...overrides.xml},
{"jail:datamount:ch:0",    {:jail_mount_created, "ch", "/mac_zroot/data/ch",
                                                        "/var/lib/clickhouse"}},
{"jail:datamount:pg:0",    {:jail_mount_created, "pg", "/mac_zroot/data/pg",
                                                        "/var/db/postgres"}},
{"jail:pkg:ch",            {:jail_pkg_installed, "ch", ["clickhouse"]}},
{"jail:pkg:pg",            {:jail_pkg_installed, "pg", ["postgresql16-server"]}},
{"jail:create:ch", :jail_created},
{"jail:create:pg", :jail_created},
{"jail:install:ch", :ok},
{"jail:install:pg", :ok},
{"dataset:create:data/ch",   :ok},
{"dataset:create:jails/ch",  :ok},
{"dataset:create:jails/pg",  :ok}
```

Second run — all seventeen tuples turn `_already_current`,
`_already_present`, `_already_running`. Verify against the running
host state — 17 invariants including `psql -c "SELECT version()"`
returning `PostgreSQL 16.x on ...` and `curl http://127.0.0.1:8123/ping`
returning `Ok`. That's `verify: PASS`.

That's the target. This is what it cost.

## The five bugs Path B mocks couldn't have caught

**1. Elixir compiles modules in two passes.**

The DemoDbJails module needs to embed four XML overlay files as
strings inside `jail_file` declarations. Reading them via a helper
function inside the DSL block failed silently — the function call
was captured as AST and never evaluated. First attempt to fix: move
to module attributes.

```elixir
@ch_logs File.read!(Path.join(@ch_config_dir, "logs.xml"))
...
jail_file "/usr/local/etc/clickhouse-server/config.d/logs.xml",
  content: @ch_logs
```

Still failed. `Module.get_attribute` inside my DSL macro returned
`nil` even after `@ch_logs "..."` executed above.

The trace, shown to my surprise:

```
[EXPAND A]
[EXPAND B]
[BODY 1]
[RUN A]
[BODY 2]
[RUN B]
[BODY 3]
```

Elixir expands every macro top-to-bottom in one pass, then executes
the module body in a second pass. During expansion, no `@` attribute
writes have happened yet — they're side effects that run in the
second pass. `Module.get_attribute` reads a table that's still empty
at macro-expand time.

The real fix uses `Macro.escape/2`'s `unquote: true` option.
`normalize_value/1` in the DSL now wraps unresolvable AST — `@attr`
references and bare function calls — in `{:unquote, [], [ast]}`
sentinels. The escape option preserves those as raw AST that
evaluates in the *second* pass, when attributes are set. Every DSL
macro now calls `Macro.escape(config, unquote: true)` instead of the
bare escape. Two lines of change plus one new `normalize_value`
clause; 302 tests, zero regressions.

That was the biggest yak in the shave. It also means users of the DSL
can now write `content: @some_attr` or `content: read_config("x.toml")`
directly inside jail blocks and both resolve to strings at execution
time. The bug and the fix are both worth the ride.

**2. `bastille cmd <jail> <cmd>` exits 0 on a stopped jail.**

Bastille prints `Jail is not running. Use [-a|--auto] to auto-start
the jail.` to stdout and returns exit 0. Every jail-internal check in
my verify script — `bastille cmd pg service postgresql status`,
`bastille cmd pg test -f /var/db/postgres/16/data/PG_VERSION`, etc.
— was treating exit 0 as success. Five `[OK]` lines were false
positives during a run where both jails had actually been stopped
mid-converge.

Fix: `jls -j <name> -q jid` at the kernel level as a precondition
for every bastille-cmd check. `jls` is the FreeBSD tool that
enumerates *actually running* jails from the kernel's jail table,
which bastille cannot lie about. Verify script now guards each check
with a `jail_running $j &&` prefix; every "OK" now means the jail
is up *and* the check passed. Lying tools compound; measuring at a
level below the layer that lies is the cure.

**3. `service postgresql initdb` needs `postgresql_enable=YES`. Or bypass.**

FreeBSD's rc.d framework refuses to run subcommands (including
`initdb`) unless `<service>_enable=YES` in rc.conf. The `initdb`
subcommand told me so directly:

```
Cannot 'initdb' postgresql. Set postgresql_enable to YES in /etc/rc.conf
or use 'oneinitdb' instead of 'initdb'.
```

The standard rc(8) escape hatch is the `one` prefix — `oneinitdb`,
`onestart`, `onestop`. It bypasses the enable check and runs the
subcommand as an explicit one-off. That's the exact right fit here:
during setup we want the one-shot init without touching service-enable
state. `jail_svc:start` will set enable later.

Direct-path invocation (`/usr/local/etc/rc.d/postgresql initdb`) was
also tried and failed: it doesn't source `/etc/rc.conf.d/`, so my
`postgresql_data` setting was invisible and initdb defaulted somewhere
useless. The `service` verb sources `rc.conf.d/`; the `one` prefix
bypasses the enable check; together they do exactly what's needed.

**4. `chown postgres:postgres /var/db/postgres` before initdb.**

Nullfs mounts inherit the underlying dataset's ownership. `zfs create
mac_zroot/data/pg` created that dataset as root:wheel. Mounted at
`/var/db/postgres` inside the jail, that mount root was still
root-owned. `initdb` runs as the `postgres` user (via `su -m`
inside the rc.d script), and postgres can't create subdirectories
under a root-owned parent:

```
initdb: error: could not create directory "/var/db/postgres/16":
  Permission denied
```

The fix is a one-line cmd in the setup block: `chown
postgres:postgres /var/db/postgres` before initdb. Nullfs propagates
the chown through to the ZFS dataset on the host; it's persistent and
survives jail restart. Idempotent — running it again is a no-op.

**5. Jail params only take effect on jail start.**

`Bastille.create` auto-starts the newly created jail with the stock
jail.conf. My `apply_jail_params_overlay` runs *after* create,
appending `allow.sysvipc = true;` to jail.conf. Result: the file
contains the param, but the running kernel jail was started before
that write and doesn't have sysvipc enabled. `initdb`'s bootstrap
tried a `shmget` and got:

```
FATAL: could not create shared memory segment: Function not implemented
```

The fix is to teach `jail_install` to report whether the overlay
actually wrote anything: `apply_jail_params_overlay` now returns
`{:ok, changed?}`. If `changed?` is true and the jail is running,
`jail_install` stops it. The `jail_create` step running next
restarts it fresh with the params active. On re-converge, the overlay
finds all params already present and returns `{:ok, false}`; the
jail is left alone. Idempotent, cheap, correct.

## What the seventeen invariants mean

The verify script asserts everything from "does the jail exist" up
through "is PostgreSQL accepting SQL and returning a version
string." The last two are what make this a real database milestone,
not just an install milestone:

```
[OK] pg accepts psql connections locally
[OK] ch HTTP endpoint returns Ok
```

`psql -c "SELECT version()" | grep -q PostgreSQL` — that's a full
round-trip: TCP connect over the jail's loopback, authenticate as
the postgres superuser, execute a query, parse the response. If
`allow.sysvipc` weren't in effect, if the data volume weren't
mounted, if `pg_hba.conf` didn't authorize the connection, if
`listen_addresses` weren't set — the check fails. It only passes
because every layer is in place.

Same story for ClickHouse's `/ping`: TCP to 8123, HTTP request, look
for "Ok" in the response body. That's proof CH is up and its four XML
overlays didn't break the config, not just proof its rc.d script ran.

## What we did *not* build

Per-app database user creation (`createuser craftplan`), per-app
database creation (`createdb -O craftplan craftplan`), and password
setting from the encrypted secrets dataset. All three are per-app
concerns and belong with the app declarations that use the DB — not
with the DB jail declaration. Same reason a Postgres AMI on AWS
doesn't ship pre-loaded with your schema.

Also not built: any BEAM app running inside a jail. The demo's five
BEAM nodes (zedweb, craftplan, plausible, livebook, exmc) all need
release tarballs delivered into their jails' rootfs, rc.d scripts
written *inside* the jail, and `bastille cmd <jail> service <app>
start` to bring them up. That's Path C — the next slice. Path B gave
us jail-native init; Path C makes it a home for BEAM apps.

## The receipt

377 lines of shell (`demo-pg-bootstrap.sh` + `demo-ch-bootstrap.sh`)
became 177 lines of Elixir, most of them comments and inlined XML.
The Elixir is idempotent by construction, exhibits its plan before
executing, and rolls back through ZFS. The shell scripts were none
of those things.

The bigger receipt is the five bugs the mocks couldn't have caught.
Each was a place where Zed's model of the system disagreed with the
system's actual behavior — Elixir's compile passes, bastille's exit
codes, FreeBSD's rc.d framework, nullfs ownership propagation, kernel
jail param semantics. Fixing each one made the tool ~2% more honest.
Aggregate 2%s until you have a tool that stops surprising you.

The next verification target is Path C: a single BEAM app running
inside a jail, deployed from a release tarball, health-check-verified,
alongside DemoDbJails as its persistence layer. When that lands green
on mac-248, the S6 demo becomes reachable in one function call. When
that in turn lands green, Zed does what it says on the tin.

## What's under `main`

Additional commits since the Path B ledger, chronological:

```
230e8e6 zed: DemoDbJails module + mount_in_jail plan step + smoke script
04ba608 zed: DSL preserves @attribute and function-call AST for exec-time eval
e5160bd zed: demo_db_jails uses `service postgresql oneinitdb` for setup
fcf9229 zed: chown /var/db/postgres to postgres:postgres before initdb
99920be zed: stop jail after jail_params overlay so restart picks them up
```

Suite: 302 tests, 0 failures. Live on mac-248, verified 2026-07-09.

The DemoDbJails module is at `lib/zed/examples/demo_db_jails.ex`; the
smoke verify at `scripts/smoke-db-jails.sh verify` prints its 17
`[OK]` lines against a running host, second-run through second-run,
and calls it a PASS.
