# Six Slices, One Green Smoke: Closing Zed's Jail-Executor Gap

*A converge-tool that declared what to do but couldn't actually
do the last mile — until it could.*

---

## The gap

Zed is a small deployment tool: an Elixir DSL that compiles into a
converge plan against FreeBSD jails and ZFS. In April, on mac-248,
we brought up a three-node BEAM cluster across three Bastille jails
plus a Postgres jail plus a ClickHouse jail. The result was the S6
milestone — three nodes clustering over `bastille0` with a shared
cookie read from an encrypted ZFS dataset. Green.

But not green for the reason we wanted.

The converge engine wrote a jail.conf, stamped some ZFS properties,
and stopped. Everything else — installing packages inside the
jails, mounting nullfs paths, enabling and starting services,
setting `allow.sysvipc` so Postgres would start, initdb-ing
Postgres, editing pg_hba.conf — was ~40 lines of shell script per
jail sitting next to the Elixir converge module. The DSL declared
those things (`packages [...]`, `service :postgresql`,
`nullfs_mount ...`), the Plan produced steps for them, and the
Executor returned `{:ok, :pending}`. Stubs.

That gap was the point of Path B. Six slices later, the smoke jail
comes up clean from a single `Zed.Examples.SmokePathB.converge()`
call — no shell scripts. And the second call is a no-op that
proves it.

## The slices

| Slice | Commit | What it does |
|---|---|---|
| 1 | `d80cf55` | Replace three executor stubs with real `Bastille.cmd` calls |
| 2 | `2f13968` | `jail_param` DSL verb → jail.conf.d passthrough |
| 3 | `8d3a380` | `depends_on` honored via topological-depth Plan sort |
| 4 | `c475b84` | Native `jail(8)` → Bastille jail lifecycle |
| 5 | `584ca22` | `jail_file` DSL verb — write files inside a jail's rootfs |
| 6 | `e62f3a4` | `setup do` block with SHA-256 content-hash idempotency |

Plus three follow-on commits found on the metal: `Bastille.mount`
argv needed six columns (fstab format), the mount presence probe
had to read the host mount table (the jail's own `mount(8)`
doesn't see nullfs), and compile warnings piled up as the platform
layer refactored around Bastille.

Each slice ended with a `git commit` and the test suite growing:
279 → 284 → 287 → 290 → 293 → 299 tests, zero failures the entire
way. Each slice began with reading `specs/converge-jail-executor.md`
— a gap analysis written in April 2026 that laid out three paths
(A: everything in the engine; B: engine plus a setup block; C:
Bastille templates as adapter) and made the case for B. That
document was the map. Path B is what the map described.

## The metal moment

The unit tests pass with `Bastille.Runner.Mock`. That mock proves
we build the argv correctly. It does not prove Bastille accepts it.
For that you drive a real jail on a real FreeBSD box.

The smoke module (`lib/zed/examples/smoke_path_b.ex`) declares two
jails on the `10.17.89.0/24` subnet: `smoke_up` with packages, a
nullfs mount, a jail_param, a jail_file, a setup block, and a
service; `smoke_down` with a `depends_on :smoke_up` and nothing
else. The verify script (`scripts/smoke-path-b.sh`) asserts nine
post-converge invariants against the running host state.

The mac-248 run found three bugs the mocks couldn't have found:

**ZFS delegation.** The BEAM ran as user `io`. `zfs create` failed
`permission denied`. Fix: `zfs allow io ... mac_zroot/jails`.
Zed's stance is "run as a regular user with delegated ZFS
permissions"; the smoke test docs now say so explicitly.

**bastille0 missing.** `bastille create` failed with `bastille0
interface does not exist`. Between S6 in April and the smoke in
July the loopback clone had been destroyed and `cloned_interfaces`
in `/etc/rc.conf` had never been set. Fix: `ifconfig lo1 create
name bastille0` and `sysrc cloned_interfaces+=bastille0`. Also
what `host-bring-up.sh` does, if you remember to run it.

**Bastille wants six-column fstab.** `Bastille.mount/4` passed
`[jail, host_path, jail_path, fstype, mode]` — five columns. Bastille
took one look and rejected: "Detected invalid fstab options in
FSTAB. Format: /host/path /jail/path nullfs ro 0 0. Read: /tmp
/host_tmp nullfs ro". The trailing `0 0` are the fstab dump/pass
columns, useless at runtime, mandatory to Bastille's validator. One
character fix per column; the test updated to match.

None of those were code bugs I'd written wrong. Two were host prep,
one was Bastille speaking a stricter dialect than the man page
suggests. All three found in ~ten minutes of iex + shell round-trip
against a real host. The mocks would never have found them.

## The mount probe

The one bug the metal *did* surface, and I fixed it wrong twice
before getting it right:

The `:jail_mount :create` executor is meant to be idempotent — on
re-converge, if the mount is already present, return
`{:jail_mount_already_present, ...}` and skip the `bastille mount`
call. My first version probed via `bastille cmd smoke_up mount`
and grepped for the target path. On the metal, second-run tuple
came back `{:jail_mount_created, ...}` — my probe returned false
even though the mount was there.

I inspected the actual output:

```
iex> Zed.Platform.Bastille.cmd("smoke_up", ["mount"])
{:ok, "\n[smoke_up]:\nmac_zroot/bastille/jails/smoke_up/root on / (zfs, local, ...)\n"}
```

Only the jail's rootfs. The nullfs mount didn't appear because
`bastille cmd` runs `mount(8)` inside the jail via `jexec`, and the
jail's mount table view is filtered — nullfs sources point back
into the host namespace, and the jail's `mount(8)` doesn't
enumerate them.

Bastille nullfs-mounts the host path onto
`<jails_dir>/<jail>/root<jail_path>` from the host's mount
namespace. To detect the mount from Zed, run `mount` on the host
and grep for that exact mountpoint. Rewrite:

```elixir
defp jail_mount_present?(jail, jail_path) do
  host_mountpoint = "#{Bastille.jails_dir()}/#{jail}/root#{jail_path}"
  case System.cmd("mount", [], stderr_to_stdout: true) do
    {output, 0} -> String.contains?(output, " on " <> host_mountpoint <> " (")
    _ -> false
  end
end
```

Third-run smoke output:

```
{"jail:mount:smoke_up:0",
 {:jail_mount_already_present, "smoke_up", "/host_tmp"}}
```

Right label, right behavior, right layer of the stack to be
looking at. This is the class of bug where the code is
"technically working" (the mount is present, the state is
correct) but the tool is lying to you about *why*. Lying tools
compound.

## The setup block

Slice 6 was the one that felt worth writing up on its own. The
argument in the spec is that even after every DSL verb has a real
executor, there's a long tail of platform-specific imperative init
— initdb, pg_hba.conf edits, ClickHouse config XML — that doesn't
warrant its own DSL verb. Every database product would need one.
The pragmatic move is a `setup do ... end` block that runs
arbitrary shell inside the jail and file writes into its rootfs,
tracked by a content hash so re-converge is a no-op unless the
block changes.

The DSL is small:

```elixir
setup do
  cmd "sysrc postgresql_enable=YES"
  cmd "service postgresql initdb"
  file "/var/db/postgres/16/data/pg_hba.conf",
    append: "host all all 10.17.89.0/24 scram-sha-256"
end
```

`cmd "..."` runs as `bastille cmd <jail> sh -c "..."` — full shell
semantics: pipes, redirects, quoting, whatever the operator wants.
`file "path", append:` reads and rewrites from the host side at
`<jails_dir>/<jail>/root<path>` with grep-before-append, so
declaring the same append twice does nothing the second time.

The idempotency mechanic is a hash of the ops list:

```elixir
:crypto.hash(:sha256, :erlang.term_to_binary(ops))
|> Base.encode16(case: :lower)
```

Stored at `<jails_dir>/<jail>/zed-setup.hash`. On converge, read
the file; if it matches, return `{:jail_setup_already_current,
jail}` and skip everything. If it doesn't (or the file doesn't
exist), run the ops sequentially, then write the new hash.
Changing a single character of a `cmd` string changes the hash,
which invalidates the skip, which re-runs everything.

`:erlang.term_to_binary` is deterministic for the set of terms the
DSL allows here (atoms, binaries, maps with atom keys) — same
input, same bytes, same hash. That's the invariant the mechanism
leans on.

The unit tests cover: hash write, hash-match skip, op-change
re-run, file-append idempotency (line already present → no-op),
and cmd failure abort. On the metal, second-run output:

```
{"jail:setup:smoke_up", {:jail_setup_already_current, "smoke_up"}}
```

First run runs two ops. Second run reads a 64-character hex string
from a file, compares to a fresh computation, matches, does
nothing. That's the whole slice.

## What it is and isn't

Zed is not Kubernetes. It doesn't need to be. It runs on the boxes
under my desk. The claim is narrower: given a small FreeBSD host
with Bastille and a ZFS pool, you declare what you want in a few
dozen lines of Elixir and one converge call brings it there,
idempotently. Rollback is `zfs rollback`. State is ZFS
user-properties plus a couple of files in the jail directory. The
tool itself is written in Elixir, runs on the BEAM, and its
transport between hosts is `:rpc.call` with an Erlang cookie for
auth.

Path B is what it took to make the DSL's promises true past the
easy layers (write a jail.conf) into the sticky ones (install a
package inside the jail, mount a directory into it, start a
service, run initdb once and don't run it again next month). Every
`{:ok, :pending}` stub in the executor is gone. Every declared
DSL construct has a real executor path. The smoke module proves
it, twice, on a real FreeBSD host.

The next verification target is running the S6 demo topology
(`Zed.Examples.DemoOffCompose`) with the shell scripts deleted —
five jails, three BEAM nodes clustering, Postgres and ClickHouse
running, all from one converge call. That's the write-up
worth reading. This one was the yak-shave that unlocks it.

## What's under `main`

```
Path B ledger (chronological, git log --oneline):

  e62f3a4 setup do block + SHA-256 content-hash idempotency
  6e80d6f resolve remaining compile warnings
  b085412 clean up warnings from Path B slice 4
  584ca22 jail_file DSL verb + executor writes into bastille jail rootfs
  f7ee5b8 probe host mount table; distinguish svc already-running tuple
  e895999 Bastille.mount passes six-column fstab argv
  c475b84 route Platform.FreeBSD jail lifecycle through Bastille
  f3df771 SmokePathB example + smoke-path-b.sh for mac-248 verification
  8d3a380 honor jail depends_on in plan step ordering
  2f13968 jail_param DSL verb + jail.conf.d passthrough
  d80cf55 wire jail_pkg/jail_mount/jail_svc executor stubs via Bastille
```

Suite: 299 tests, 0 failures. Live on mac-248, verified 2026-07-05.

The gap analysis document (`specs/converge-jail-executor.md`) is
still worth reading — it's the map, and the reason each slice is
the shape it is. If you want to build a similarly narrow
declarative tool for infrastructure you actually operate, that
document is a better model than any of the megatools it explicitly
declines to be.
