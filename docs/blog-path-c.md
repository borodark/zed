# Five Slices to a Real BEAM Cluster

*Path C — what it took to turn "a jail with a package installed"
into "a five-node distributed BEAM cluster answering
`Node.list()`". All shipped and metal-verified in one week.*

---

## The gap Path B and DemoDbJails left open

Path B closed the primitives — install a jail, install a package
inside it, mount a directory, run a `setup do` block once, start a
service. `DemoDbJails` then applied the primitives to two real
databases: Postgres and ClickHouse, both accepting connections from
one `converge()` call, replacing ~200 lines of shell.

Neither of those milestones deployed a BEAM app. A `service :cron`
inside a jail is fine; `service :cron` doesn't have a distributed
node name, doesn't need a cookie, doesn't cluster with anything.
The S6 demo — the whole reason Zed exists — wanted five BEAM
nodes, each running a real mix release, each seeing the other four
in `Node.list()`, all clustered over `bastille0`. That gap is what
Path C closed.

Five slices, in order:

| Slice | Milestone | Steps in the smoke | What it proves |
|---|---|---|---|
| **C1** | Jail-contained app deployment (shell stub) | 6 | Executor routing + rc.d template |
| **C2** | Health probes (`:tcp`, `:http`) with retry | 7 | Post-start reachability signal |
| **C3** | Real mix release + disterl over bastille0 | 8 | A distributed BEAM node inside a jail |
| **C4** | Two-node cluster via `PEER_NODE` | 16 | Two nodes seeing each other |
| **C5** | Five-node cluster via libcluster + Zed artifact | 46 | Full mesh, `Node.list()` returns 4 peers |

Every slice ended with a green smoke on mac-248 — a FreeBSD 15 box
with Bastille jails, ZFS pool `mac_zroot`, and (after the second
smoke of the week) `permit nopass io as root` in `doas.conf` so
SSH-driven converges from my workstation could drive the whole
loop without an interactive `iex`. That doas-line was worth two
paragraphs of memory-file to write down — being able to run
`ssh 192.168.0.248 'doas mix run -e "..."'` collapsed the
iterate-fix cycle from "type at your keyboard" to "one command
per attempt".

## C1 — Jail-contained app deployment

Before C1, the executor's `:app :create` step deployed a release
tarball to a *host* mountpoint. `:service :install` wrote an
rc.d script to `/usr/local/etc/rc.d/` on the *host*. Great for a
host-native app; wrong for anything with `contains :app_id` set on
a jail — the demo wanted apps to run *inside* jails, not next to
them.

C1 added a plan-level routing: at plan-build time, iterate every
jail diff, build an `app_id → jail_id` map from `config[:contains]`,
then during `:app` expansion route contained apps to jail-side
steps instead of host-side ones. Three new step types:

```
:jail_app :deploy       → tar-extract into <jails_dir>/<jail>/root<mount_in_jail>
:jail_service :install  → write rc.d into the jail's rootfs
:jail_svc :start        → reuse Path B (sysrc + service start via bastille cmd)
```

`Release.deploy/3` picked up a relative-symlink fix — the `current`
symlink now points at `releases/0.1.0` instead of the absolute host
path, so the same symlink resolves from both the host's perspective
(under `<jails_dir>/<jail>/root/`) and the jail's chroot.

The smoke was a shell stub: `bin/hello` was a shell script that
backgrounded a `sleep` loop and wrote a pidfile. That surfaced two
non-obvious bugs the mocks couldn't:

**The daemon that never returned.** My first stub did
`(while :; do sleep 60; done) &` and moved on. When rc.subr ran
`service hello start`, it inherited stdin/stdout/stderr from
`bastille cmd`; the backgrounded subshell kept those FDs open;
`bastille cmd`'s `wait()` sat forever. The fix was `daemon -f`,
FreeBSD's proper double-fork detacher.

**The daemon that didn't own its name.** `daemon(8)` execs `sh -c
'while ...'` by default, which means argv[0] is `sh`. rc.subr's
`check_process` compares argv[0] against the `command=` line
verbatim; the shell name didn't match `/opt/hello/current/bin/hello`,
so `service hello status` returned non-zero. Fix: `daemon -f -p
$PIDFILE "$0" _run` — exec the script itself with a new subcommand
so argv[0] matches. Real mix releases don't hit this because
`bin/<app>` is a compiled thing whose argv[0] naturally matches.

C1's own verify checked pidfile + `kill -0` instead of `service
status` — the pidfile is what "running" means; rc.subr's status
check is a shell-stub concern, not a Zed concern.

## C2 — Health probes

C1 declared a service running when its pidfile was alive. That's
process liveness. It doesn't answer whether the service is actually
answering.

C2 added a `:jail_health :probe` step, emitted after `:jail_svc
:start`. Two probe types shipped:

```elixir
health :tcp,  host: "10.17.89.92", port: 4001, timeout: 3000, attempts: 15, interval: 1000
health :http, url: "http://10.17.89.92:4000/health", expect: 200
```

Each retries `attempts` times with `interval` ms between them, and
surfaces `{:error, :jail_health_failed, jail, app, type, remaining_attempts, last_reason}`
on failure. The retry count in the error tuple is the actionable
part: a failure with `remaining_attempts: 0` and reason
`{:tcp_connect_failed, :econnrefused}` means "your service never
opened the port"; `remaining_attempts: 0` with
`{:http_status_mismatch, expect: 200, got: 502}` means "your
service is up but sick." Different problems, different diagnoses.

The smoke stub needed a TCP listener to probe against, so I gave
it a background `nc -k -l 4001` inside the same daemon mode.
That listener is why the C2 smoke has one more `[OK]` than C1: the
verify script separately dials `10.17.89.92:4001` from the host
via `nc -z` to prove reachability, catching the case where the
probe would return `:jail_health_ok` but a firewall would block
outside traffic.

## C3 — A real mix release

C1 and C2 proved the pipeline against a shell stub. That leaves the
question every plumbing-tests-fine engineer eventually asks: does
it work with the real thing?

The C3 smoke replaced the shell stub with `hello_beam/` — a tiny
mix release with `include_erts: true`, a `HelloBeam.Application`
with one supervised `Heartbeat` GenServer, and a `runtime.exs` that
`System.fetch_env!/1`s on `RELEASE_NODE` and `RELEASE_COOKIE` at
prod boot. Six MB tarball; boots to a distributed node named
`hello_beam@10.17.89.93` inside the jail.

C3 needed three plumbing pieces on the Zed side:

**Cookie resolution.** The DSL already validated `cookie {:env,
"VAR"}`, `{:file, path}`, and `{:secret, slot}` at IR compile time,
but no executor clause ever turned those references into actual
bytes. New `Zed.Beam.Env` module: `resolve_cookie/1` handles
`{:env, "VAR"}` via `System.get_env`, `{:file, path}` via
`File.read + trim_trailing`, and `{:secret, slot}` via an explicit
`:secret_ref_not_yet_supported` — deferred until an app needs it.

**Env file writing.** `:jail_app :deploy` was extended to write an
env file at `<jails_dir>/<jail>/root/var/db/zed/<app>.env`, mode
`0400`, containing exported `RELEASE_DISTRIBUTION`, `RELEASE_NODE`,
`RELEASE_COOKIE`. The rc.d template (unchanged from C1) already
sourced `env_file` with `set -a; . file; set +a` — belt-and-
suspenders so any env file (Zed's own or third-party) auto-exports.

**`:beam_ping` probe.** Third probe type: `Node.set_cookie/2`,
`:net_adm.ping/1`, expect `:pong`. Auto-starts distribution on the
probing side when needed, and — crucially — matches the target
node's *name mode*. If the target atom's hostname has a dot (IP
address or FQDN), start with `:longnames`; otherwise `:shortnames`.
Erlang refuses to ping across the boundary, so this detection has
to happen at probe time.

Five bugs surfaced during the C3 metal verification. All five were
mocks-couldn't-have-caught:

1. **`. env_file` doesn't export.** Sourcing the file set the
   variables in the sourcing shell only; the child `bin/hello_beam`
   didn't inherit them. Mix release fell back to auto-generating
   `-sname hello_beam` (short name) and a random cookie
   `Z2337FPYHRMVFUFBU7LL2UIZVUVCURACICILKTY5HSIXU5WC326A====`. Fix:
   `export` prefix in `compose_env_file` and `set -a; . file; set
   +a` in the rc.d.

2. **`ensure_distribution_started/0` was hard-coded shortnames.**
   Probing a target with an IP hostname bombed with `** Hostname
   10.17.89.93 is illegal **`. Fix: detect target name mode at
   probe time.

3. **Mix release needs `RELEASE_DISTRIBUTION`.** Setting
   `RELEASE_NODE` alone left mix release starting in a
   half-initialized distribution mode; `net_kernel` crashed with
   `{'EXIT', nodistribution}`. Fix: `compose_env_file` now emits a
   third exported var, `RELEASE_DISTRIBUTION=name` (or `sname`).

4. **Verify script's `erts-*` glob.** `bastille cmd <jail> /opt/
   <app>/current/erts-*/bin/epmd -names` — bastille passes argv
   verbatim, so the glob was literal, epmd wasn't found. Fix: wrap
   in `sh -c "..."` so the jailed shell expands.

5. **Verify script's pidfile assumption.** Mix release's `daemon`
   runner via `run_erl` doesn't write `/var/run/<app>.pid`. Fix:
   probe jailed epmd for the registered node instead. That's the
   authoritative disterl liveness signal anyway.

C3 verify passed at nine `[OK]` lines — the last being
`epmd on 10.17.89.93:4369 reachable`, meaning the release booted,
started distribution correctly, registered with its local epmd,
and the host could reach that epmd across `bastille0`.

## C4 — Two nodes seeing each other

C3 gave us one distributed BEAM node in one jail. C4 gave us two
seeing each other.

The naive way — libcluster in `hello_beam`, a topology config,
`Cluster.Supervisor` running the whole show — is the *right* way,
but not the smallest step forward. The smallest step is: read an
env var, spawn a `Node.connect/1` retry loop, exit on success.
That's what `HelloBeam.Peer` does. Fifty lines of GenServer,
`restart: :transient` (essential — more on that in a minute), one
`PEER_NODE` env var per app.

Zed side: the DSL already supported `env %{...}` inside `service`
verbs (Path B). Now `env %{...}` also works inside `app` blocks —
threaded through as `config[:env]`, passed into the plan step as
`extra_env`, and merged after the `RELEASE_*` baseline in
`Zed.Beam.Env.compose_env_file/3`. Extra env keys are sorted for
deterministic output so idempotency's content-match short-circuit
doesn't misfire.

The two-node smoke declares symmetric `env %{"PEER_NODE" => ...}`
on each app, pointing at the other. Each release boots, reads
its env file, connects to its peer, and `HelloBeam.Peer` exits
`:normal`. Erlang's distribution layer keeps the link alive.

**The restart-mode footgun.** My first `HelloBeam.Peer` used the
default `:permanent` restart mode. It stopped `:normal` after
connecting; supervisor treated the stop as a crash and restarted
it; Peer reconnected (no-op, already connected); stopped
`:normal`; supervisor restarted; three restarts in five seconds
exhausted the max_restarts budget; the whole `hello_beam`
application terminated. The `erlang.log` told the story:

```
22:38:39.345 hello_beam peer: connected to hello_beam@10.17.89.94 after 1 attempts
22:38:39.345 hello_beam peer: will retry Node.connect
22:38:40.346 connected
22:38:40.346 will retry
...
22:38:42.348 Application hello_beam exited: shutdown
```

Fix: `use GenServer, restart: :transient`. `:transient` doesn't
restart on `:normal` stop. Peer connects once, exits, stays gone.

**The verify script's `iex -e` misfire.** My cluster-proof step
invoked `iex --name X --cookie Y -S mix -e "code"`. The `-e` went
to `mix`, which only accepts `--help` and `--version`. The script
silently ran nothing; `$peers` came back empty; `[FAIL]`. Fix:
`elixir --erl "-name X -setcookie Y" -S mix run -e "code"`.
`elixir` accepts `--erl` for BEAM args; `mix run` accepts its own
`-e`. Boilerplate for driving disterl from a shell script.

C4 verify passed at eleven `[OK]`, ending with:

> `[OK] node A sees node B in Node.list ([:"hello_beam@10.17.89.94", :"verify@127.0.0.1"])`

The verify BEAM connected to node A over disterl, RPC'd `Node.list()`
on A, saw B (the boot-time peer link) and itself. Two nodes really
were talking.

## C5 — Five nodes via libcluster

C4's `HelloBeam.Peer` pattern is a fixture. Five nodes each
connecting to N-1 peers via a `PEER_NODES` env var would scale
mechanically but it's ugly, and it doesn't touch Zed's actual
cluster support — which already existed.

Zed had a `cluster :name do cookie ...; members [...] end` verb
since Path B. It emitted a `:cluster_config :create` step. That
step wrote `/var/db/zed/cluster/<cluster_id>.config` — a plain-text
artifact, one node atom per line, atomic tmp+rename. There was even
a `Zed.Cluster.Config.topology!/1` helper that returned a
libcluster-shaped `[strategy: Cluster.Strategy.Epmd, config:
[hosts: hosts]]` map from that file. What was missing was any
release *consuming* it.

C5 wired the consumer:

**Add libcluster to `hello_beam`.** One line in `mix.exs` deps.
Extra 100 KB in the tarball. The whole point of `include_erts:
true` is that adding a dep like this doesn't require new pkg
installs inside the jail.

**Read the artifact at boot.** `hello_beam/config/runtime.exs`
gained a `:prod`-only stanza:

```elixir
cluster_config_path = "/var/db/zed/cluster/demo.config"

if File.exists?(cluster_config_path) do
  hosts = cluster_config_path
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.starts_with?(&1, "#"))
          |> Enum.map(&String.to_atom/1)

  config :libcluster,
    topologies: [demo: [strategy: Cluster.Strategy.Epmd,
                        config: [hosts: hosts]]]
end
```

Note the `File.exists?/1` guard: the C4 smoke doesn't nullfs-mount
the cluster artifact, so its jails see no file, libcluster gets no
topology, and `HelloBeam.Application` falls back to the
`HelloBeam.Peer` path. One release, two clustering strategies,
depending on whether the mount is there.

**Supervise `Cluster.Supervisor` conditionally.**
`HelloBeam.Application.start/2` checks `Application.get_env(:libcluster,
:topologies, [])` — if non-empty, supervise `Cluster.Supervisor`;
if empty, fall back to `HelloBeam.Peer`. Both are `:one_for_one`
children of the same supervision tree.

**Nullfs-mount the artifact.** Zero new Zed code. Each jail
declares `nullfs_mount "/var/db/zed/cluster", into: "/var/db/zed/
cluster", mode: :ro`. Path B's `nullfs_mount` primitive handles the
rest. Sort priority already correct: `cluster_config` is priority
2, `jail_mount` is 5, so Zed writes the artifact before bastille
mounts it.

The C5 smoke declares five apps and five jails on
`10.17.89.100..104`, all running the same tarball, with one
`cluster :demo do members [all 5 nodes] end` at the top. That's
`Zed.Examples.SmokeContainedReal5`. The plan expands to 46 steps:

```
 5 dataset:create      1 cluster:config:demo    5 jail:install
 5 jail:create         5 jail:mount             5 jail:app:deploy
 5 jail:service:install 5 jail:svc:start        5 jail:health :tcp
 5 jail:health :beam_ping
```

All 46 return `:ok` or `_ok`. Verify script asserts 28 invariants
— jails up, artifact present on host and inside each jail, epmd
reachable on each IP, all five BEAM nodes registered with their
local epmd, and (the money shot) a `Node.list()` on `hello_beam@
10.17.89.100` returns the other four hello_beam nodes.

An unexpected cameo: when the verify script's control BEAM
`net_adm.ping`ed node `.100`, Erlang's own `global` name registry
noticed that the incoming probe would create overlapping
partitions and disconnected the peer nodes to prevent split-brain:

```
'global' at zed_probe_1442@127.0.0.1 requested disconnect from
  hello_beam@10.17.89.101 in order to prevent overlapping partitions
'global' at zed_probe_1442@127.0.0.1 disconnected node
  hello_beam@10.17.89.103 in order to prevent overlapping partitions
```

The kernel loudly noticed all five nodes were clustered when the
probe joined — this warning is the strongest possible cluster-
liveness signal you can get, delivered by Erlang itself.

## The SSH-driven interlude

Somewhere around C3 I stopped typing `doas iex --sname foo -S mix`
into a terminal and started running

```sh
ssh 192.168.0.248 'cd ~/zed && SMOKE_COOKIE=abc doas env SMOKE_COOKIE=abc \
  mix run -e "IO.inspect(SomeModule.converge(), limit: :infinity)"'
```

from my workstation. Non-interactive, no tty, no interactive
`iex`. This was possible because — after the second smoke of the
week — I added `permit nopass io as root` to `/usr/local/etc/doas.
conf` on mac-248. That single line collapsed the observe-fix-retry
cycle from "type at your keyboard" to "one command per attempt."

Two false starts before this worked. First, `doas -E` — FreeBSD's
`doas` doesn't have GNU sudo's `-E` flag. `env VAR=value doas ...`
runs `env` before `doas`, so `doas` starts with a stripped
environment. Correct is `doas env VAR=value command` — `doas`
runs `env`, which builds the environment and execs the target.
Second, `iex --eval "code"` — that runs the code but iex's
interactive shell then dominates stdin; the script prints its
output and hangs. `mix run -e "code" </dev/null` fixes both by
being explicit about no-tty and no-shell.

The smoke stub in C1 was a fixture — not "real" in any meaningful
sense. But the C3 release was real. The C4 two-node cluster was
real. C5 is five real BEAM nodes running a real release, deployed,
started, and clustered by one Zed function call. The pipeline that
does that has been rehearsed on every intermediate slice by
running the smoke, watching the failure, fixing the specific
layer, and re-running. Each of the five sessions ended with a
green `verify: PASS`.

## The receipt

Numbers, week over week:

| Metric | Before Path C | After Path C5 |
|---|---|---|
| Test count | 302 | 328 |
| DemoOffCompose blockers | Path C1 stub, jail-contained app deployment | (unblocked) |
| Path C1 stub, health probes | (unblocked) |
| Cluster verb consumers | Zero — verb existed, no release used it | One (hello_beam via libcluster) |
| Jail-contained apps proven | Zero | Five (all on 10.17.89.100..104) |
| Lines of Elixir added | | ~800 (including hello_beam release, 5 smoke examples, 4 executor helpers) |
| Lines of shell replaced | | ~500 (S6's per-jail bring-up plus release start/stop management) |

Five sessions in one week. Every session ended by pushing to
GitHub, saving a memory file, and updating this repo's iteration
plan.

The demo — five BEAM apps clustered over `bastille0`, verified
end-to-end — is reachable now in one function call. The real
demo (`Zed.Examples.DemoOffCompose`, which S6 originally targeted)
still needs three more things:

1. Cookie resolution against encrypted ZFS (`{:secret, :slot}` —
   design shipped in `docs/SECRETS_DESIGN.md`, no code yet).
2. Migration of one of Igor's real apps to Zed deployment (probably
   `zedweb` first — it's already in `DemoOffCompose` as a target,
   Igor authored it).
3. Actually shipping — a public repo update, a blog post like this
   one, and getting the demo cluster running on the Mac Pro
   somewhere someone can watch it happen.

Path C's job was to make the last one reachable. Now it is.

## What's under `main`

```
639fb54 zed: Path C5 — 5-node hello_beam cluster via libcluster
5f09e26 zed: verify cluster proof uses elixir + mix run -e syntax
110c42c zed: HelloBeam.Peer uses restart: :transient
cfef691 zed: Path C4 — two-node hello_beam cluster over bastille0
3612737 zed: verify epmd probe wraps the erts-* glob in sh -c
e579209 zed: smoke-contained-real-app verify updated for real-release format
8dd7ccd zed: env file includes RELEASE_DISTRIBUTION so mix release enables disterl
3c7cc89 zed: :beam_ping starts disterl with mode matching target node
7f1c983 zed: env file writer prepends `export`; rc.d sources with set -a fallback
668b8fb zed: Path C3 — real mix release deployment for jail-contained apps
2e94660 zed: Release.update_current_symlink uses relative target
1d5f04a zed: Path C1 — jail-contained app deployment
f4d90a2 zed: Path C2 — jail-contained app health probes
d90c105 zed: Path C1 rc.d user directive is opt-in, not defaulted to app_id
```

Fourteen commits, five slices, one week. Suite: 328 tests, 0
failures. Live on mac-248.

Repo: `github.com/borodark/zed`. Smoke fixtures live in
`lib/zed/examples/smoke_contained_*.ex`; each ships with a
matching `scripts/smoke-*.sh` for clean + verify. `hello_beam/`
is a full mix release inside the repo — the on-repo, on-metal
proof that Zed can deploy a real BEAM app to a real FreeBSD jail
in one function call. It's not doing anything useful. That's
the whole point.
