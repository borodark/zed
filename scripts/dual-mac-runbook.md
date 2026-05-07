# Dual-Mac end-to-end zed runbook

Goal: drive a full zed deploy across **mac-248** (FreeBSD 15.0,
GT 750M, the controller) and **mac-247** (FreeBSD, GT 650M,
SSH-reachable from 248) — exercising the convergence engine,
multi-host coordination, and rollback under partial failure on a
real prod-shaped target.

This runbook is the live-execution complement to today's "Road to
Production" P0 entry in [`README.md`](../README.md) ("End-to-end
converge on a real deploy"). All five phases run on mac-248; phases
R4 and R5 fan out to mac-247 over distributed Erlang.

**Do NOT** start any phase mid-way without completing the prereqs
above it. Each phase assumes the previous phase's invariants. State
in zed lives in ZFS properties; a partial run can leave stale
properties behind that confuse the next phase. The phases are
designed so that re-running them is idempotent, but only if the
prior phase reached its declared end-state.

## Prereqs (one-time, per Mac)

Both Macs need the same baseline. mac-248 ran `host-bring-up.sh` in
the A5a.5 work; if you've drifted since (driver upgrade, OTP bump,
`/usr/local/etc/doas.conf` edits), re-run it.

```sh
# On each Mac:
cd ~/projects/zed
git fetch origin
git checkout main
git pull --ff-only
mix deps.get
mix compile          # builds priv/peer_cred.so via elixir_make
```

If `mix compile` fails on the NIF: `cc` must be in `$PATH` and
`priv/` must exist at the project root.

### Cookie agreement

Both Macs need the same Erlang cookie for distributed Erlang. The
sane default lives in `~/.erlang.cookie` and rolls forward from the
A5.1 era; if mac-247 doesn't have one yet:

```sh
# On mac-247 (via ssh from mac-248):
ssh mac-247 'cp ~/.erlang.cookie.bak ~/.erlang.cookie || \
             scp mac-248:~/.erlang.cookie ~/.erlang.cookie'
ssh mac-247 'chmod 400 ~/.erlang.cookie'
```

### ZFS pool delegation

Both Macs need a delegated ZFS subtree for zed to manage. Pick a
test pool (the runbook assumes `tank/zed-test`):

```sh
# On each Mac, as root:
zfs create tank/zed-test || true
zfs allow $USER create,destroy,snapshot,rollback,mount,send,receive,userprop tank/zed-test
```

The user-prop permit is critical — zed's state-store IS user
properties. Without it the converger silently fails to stamp version
metadata.

---

## Phase R1 — Bootstrap each Mac (A1)

Run on **each** Mac, sequentially. The bootstrap creates an
encrypted `<base>/zed/secrets` dataset and stamps fingerprint
properties on the parent. Idempotent: re-running on an already-
bootstrapped host is a no-op.

```sh
# On mac-248:
cd ~/projects/zed
ZED_BASE=tank/zed-test mix run -e 'Zed.Bootstrap.init([])'
ZED_BASE=tank/zed-test mix run -e 'IO.inspect(Zed.Bootstrap.status())'

# Repeat on mac-247 (over ssh):
ssh mac-247 'cd ~/projects/zed && ZED_BASE=tank/zed-test mix run -e "Zed.Bootstrap.init([])"'
ssh mac-247 'cd ~/projects/zed && ZED_BASE=tank/zed-test mix run -e "IO.inspect(Zed.Bootstrap.status())"'
```

### R1 success criteria

- `Zed.Bootstrap.status()` on each Mac returns `:ok` with a
  fingerprint hash.
- `zfs list -t all -r tank/zed-test/zed` shows a `secrets` dataset
  with `mountpoint=none` and an encryption keystatus of `available`.
- `zfs get -r com.zed:fingerprint tank/zed-test/zed` shows a stamped
  hash matching what `Zed.Bootstrap.status()` reported.

If any of those is wrong, **stop**. Don't proceed to R2 until
bootstrap is clean on both Macs. A drifted fingerprint will cause
multi-host convergence to refuse the deploy in R4.

### R1 failure modes worth knowing

- `keystatus=unavailable` → ZFS encryption keys aren't loaded.
  Re-run `mix run -e 'Zed.Bootstrap.init([])'` — the bootstrap will
  re-derive and load.
- `com.zed:fingerprint` missing → user-prop permit is missing on
  the pool. Re-run the `zfs allow ...,userprop` command above.

---

## Phase R2 — Distributed Erlang between the Macs

mac-248 starts a named node, mac-247 starts a named node, the two
ping each other and resolve via short-name hostnames. The cookie
(R1 prereq) gates the connection.

```sh
# On mac-248:
cd ~/projects/zed
iex --sname zed-controller --cookie zed_test_cookie -S mix
```

In the iex shell:

```elixir
iex(zed-controller@mac-248)1> Node.connect(:"zed-agent@mac-247")
true
iex(zed-controller@mac-248)2> Node.list()
[:"zed-agent@mac-247"]
iex(zed-controller@mac-248)3> :rpc.call(:"zed-agent@mac-247", Zed.Bootstrap, :status, [])
:ok
```

In a separate shell on **mac-247** (via ssh):

```sh
ssh -t mac-247 'cd ~/projects/zed && \
  iex --sname zed-agent --cookie zed_test_cookie -S mix'
```

Leave both iex sessions open through R3-R5; closing zed-agent
terminates the cluster.

### R2 success criteria

- `Node.connect/1` returns `true`.
- `Node.list/0` on mac-248 includes `:"zed-agent@mac-247"`.
- `:rpc.call(:"zed-agent@mac-247", Zed.Bootstrap, :status, [])`
  returns `:ok` (proves the agent has booted Bootstrap, not just
  joined the cluster).

### R2 failure modes

- `Node.connect/1` returns `false` → check `~/.erlang.cookie` parity
  on both Macs (`md5 ~/.erlang.cookie` on each).
- Connect succeeds but `:rpc.call` returns `{:badrpc, :nodedown}` →
  EPMD on mac-247 may have died. `epmd -names` on mac-247 should
  list `zed-agent` on a port. If not, kill any stale `iex` and
  restart.
- Hostname resolution fails (`nxdomain`, `not_found`) → either Mac
  doesn't resolve the other's short-name. Add to `/etc/hosts` on
  both, or use `--name zed-controller@<ip>` long names instead.

---

## Phase R3 — Single-host converge on mac-248

Before going multi-host, validate the convergence engine on a
single Mac with a deliberately tiny deploy. This catches DSL,
ZFS, and Bastille issues without the multi-host blast radius.

Create a test deploy module on mac-248:

```elixir
# scripts/dual_mac_test_deploy.exs
defmodule DualMacTest.Trivial do
  use Zed.DSL

  deploy :trivial, pool: "tank/zed-test" do
    dataset "trivial-app" do
      mountpoint :none
      compression :lz4
    end

    snapshots do
      before_deploy true
      keep 3
    end
  end
end
```

In the existing zed-controller iex (on mac-248):

```elixir
iex> c "scripts/dual_mac_test_deploy.exs"
iex> DualMacTest.Trivial.diff()           # show what would change
iex> DualMacTest.Trivial.converge()       # apply
iex> DualMacTest.Trivial.status()         # read state from ZFS
iex> DualMacTest.Trivial.rollback("@latest")  # instant rollback
```

### R3 success criteria

- `diff()` returns a non-empty list on the first run, then an empty
  list after `converge()`.
- `converge()` returns `:ok` and `zfs list tank/zed-test/trivial-app`
  shows the dataset.
- `status()` reports the dataset's properties matching the IR.
- `rollback("@latest")` reverts to the pre-converge snapshot.
- After rollback, `zfs list tank/zed-test/trivial-app` either
  reports the dataset doesn't exist, or shows the dataset reverted
  to its pre-converge state — depending on whether the snapshot
  was taken before or after the dataset existed.

### R3 failure modes

- `diff()` raises a DSL validation error → real bug in the deploy
  module syntax. Fix the module, recompile, retry.
- `converge()` fails with a ZFS permission error → user-prop
  permit missing (R1 prereq); re-run `zfs allow ...,userprop`.
- `rollback()` reports "no pre-deploy snapshot" → the
  `before_deploy true` snapshots block didn't fire. Inspect
  `zfs list -t snapshot tank/zed-test`. This was a real bug in
  zed pre-A5a; if reproduced, file an issue.

---

## Phase R4 — Two-host coordinated converge

The actual multi-host run. mac-248 is the controller; both Macs
host. This exercises `Zed.Cluster.converge_coordinated`.

Extend the test deploy:

```elixir
# scripts/dual_mac_two_host_deploy.exs
defmodule DualMacTest.TwoHost do
  use Zed.DSL

  deploy :two_host, pool: "tank/zed-test" do
    host :mac_248, node: :"zed-controller@mac-248" do
      dataset "shared-app/mac-248" do
        mountpoint :none
      end
    end

    host :mac_247, node: :"zed-agent@mac-247" do
      dataset "shared-app/mac-247" do
        mountpoint :none
      end
    end

    snapshots do
      before_deploy true
      keep 3
    end
  end
end
```

(If the `host` verb isn't shipped in current main, substitute the
`Zed.Cluster.converge_all/1` API directly with a list of nodes. The
spec doc claims the verb but the implementation surface depends on
where main is the day you run this — check
[`specs/iteration-plan.md`](../specs/iteration-plan.md) for current
state.)

```elixir
iex> c "scripts/dual_mac_two_host_deploy.exs"
iex> DualMacTest.TwoHost.diff()           # both hosts
iex> DualMacTest.TwoHost.converge_coordinated()
iex> DualMacTest.TwoHost.status()
```

### R4 success criteria

- `diff()` shows changes pending on **both** hosts.
- `converge_coordinated()` returns `:ok` with timestamps for both
  hosts; both return success or both rollback.
- `status()` on the controller aggregates both hosts' properties.
- `zfs list -r tank/zed-test/shared-app` on **each** Mac (via ssh
  for mac-247) shows the corresponding dataset.

### R4 failure modes

- One host succeeds, the other fails, and the success **is not**
  rolled back → coordinated rollback is broken. This is the P0
  bug item in today's Road to Production. Capture the failing
  host's logs (`iex --sname zed-agent` console + `journalctl
  --user`-equivalent on FreeBSD: `tail -f /var/log/messages`
  filtered for `zed`) and **stop** before R5. The R5 chaos test
  exists to surface exactly this; if it surfaces in R4, the test
  protocol has caught a real bug in normal operation.
- `:rpc.call` to mac-247 returns `{:badrpc, :nodedown}` after a
  successful R2 → the agent crashed during converge. Inspect the
  zed-agent shell on mac-247 for a stack trace before restarting.
- ZFS pool full on one host → standard error path; the converger
  should report it cleanly. If the converger crashes instead of
  reporting, file a bug.

---

## Phase R5 — Rollback under partial failure (chaos)

This is the explicit test for "rollback under partial failure" —
the second P0 item. Manufacture a deploy that succeeds on one host
and fails on the other, verify both roll back.

The cleanest way to manufacture a guaranteed failure: declare a
dataset on mac-247 with a `quota` smaller than the existing data,
which the converger will reject after mac-248 has already succeeded.

```elixir
# scripts/dual_mac_chaos.exs
defmodule DualMacTest.Chaos do
  use Zed.DSL

  deploy :chaos, pool: "tank/zed-test" do
    host :mac_248, node: :"zed-controller@mac-248" do
      dataset "chaos-good" do
        mountpoint :none
      end
    end

    host :mac_247, node: :"zed-agent@mac-247" do
      dataset "chaos-bad" do
        mountpoint :none
        quota "1K"   # absurdly small; will fail when zed tries to write
      end
    end

    snapshots do
      before_deploy true
      keep 3
    end
  end
end
```

```elixir
iex> c "scripts/dual_mac_chaos.exs"
iex> DualMacTest.Chaos.converge_coordinated()
# Expected: returns {:error, %{rolled_back: [:mac_248, :mac_247], ...}}
iex> DualMacTest.Chaos.status()
# Expected: both hosts back to pre-deploy state
```

### R5 success criteria

- `converge_coordinated()` returns `{:error, ...}` (not `:ok`).
- The error map includes `:rolled_back` with **both** host atoms.
- `zfs list tank/zed-test/chaos-good` on mac-248: dataset is GONE
  (rolled back).
- `zfs list tank/zed-test/chaos-bad` on mac-247: dataset is GONE
  (failed; never created).
- `status()` reports both hosts at the pre-converge fingerprint.

### R5 failure modes that we WANT to surface

- `chaos-good` is left behind on mac-248 → coordinated rollback
  is the bug. P0.
- The deploy returns `:ok` despite the quota constraint → the
  converger doesn't actually validate the apply, just submits it.
  P0.
- mac-247's agent crashes silently mid-rollback → the
  rollback path itself doesn't survive a partial-state. P1.

---

## Reporting back

The runbook is an artifact-producing exercise. Each phase emits
specific data:

| Phase | Artifact | Where to put it |
|-------|----------|-----------------|
| R1    | `Zed.Bootstrap.status()` output, fingerprint, ZFS keystatus    | `docs/dual-mac-runbook-results.md` (new file)   |
| R2    | Cookie, EPMD names, `:rpc.call` round-trip wall (`:timer.tc/1`) | same                                            |
| R3    | `diff()` IR, `converge()` wall, `rollback()` wall             | same                                            |
| R4    | Both-host wall, success or coordinated rollback shape          | same                                            |
| R5    | The exact `{:error, ...}` shape, ZFS post-state on each host    | same                                            |

Commit `dual-mac-runbook-results.md` to `feat/dual-mac-runbook` and
push. Each row is a real measurement; do not hand-wave any of them.

If R5 surfaces a P0 bug in coordinated rollback (likely — it has not
been chaos-tested), **stop** and file an issue. Do not proceed to
fix it on the same branch; that's a separate workstream.

## Time budget

| Phase | Expected wall | Notes |
|-------|---------------|-------|
| Prereqs | 30 min | Most likely already done from A5a era; just verify |
| R1 | 15 min | Two Macs, mostly waiting for ZFS |
| R2 | 10 min | Cookie + EPMD; or 60 min debugging hostname resolution if /etc/hosts is stale |
| R3 | 30 min | Single-host loop; the diff/converge/rollback round-trip |
| R4 | 60 min | First multi-host live test ever for this branch |
| R5 | 60 min | Chaos test; expect to find at least one bug |

Total: **3-4 hours** for a clean run; **6-8** if anything in R4 or
R5 surfaces a real issue (which is the whole point of running the
test).

## What this runbook explicitly does NOT cover

- **Health checks** — current zed converger does not wait on
  `health :http` declarations. Today's Road to Production lists this
  as a separate P0 item. The runbook tests dataset and snapshot
  primitives; health-checked applications are out of scope until
  that P0 ships.
- **Bastille jails** — A5.1 covers the Bastille adapter in isolation;
  this runbook tests deploys without jails inside them. A
  jail-bearing two-host deploy is a follow-up runbook that pulls in
  Bastille on top of what this validates.
- **Secrets distribution** — `Zed.Bootstrap` creates the encrypted
  `<base>/zed/secrets` dataset, but this runbook doesn't exercise
  the secrets-into-app-env pipeline (also a P0 in today's Road to
  Production).
- **GPU node lifecycle** — once mac-247 and mac-248 are running zed
  agents reliably, a follow-on runbook can wire `Nx.Vulkan.Node`
  into a deployed app's supervisor tree. See the GPU node section
  in [`README.md`](../README.md).

## Cross-references

- [`specs/iteration-plan.md`](../specs/iteration-plan.md) — full layer
  rollup, useful when checking whether a verb is shipped.
- [`scripts/host-bring-up.sh`](host-bring-up.sh) — the FreeBSD
  bring-up sequence mac-248 ran during A5a.
- [`scripts/a5a-live-runbook.md`](a5a-live-runbook.md) — the A5a
  live-test runbook this one is patterned after.
- [`docs/MULTI_HOST_TEST.md`](../docs/MULTI_HOST_TEST.md) — TrueNAS
  multi-jail test (different topology; useful contrast).
- [`README.md`](../README.md) — Road to Production lists the P0
  items this runbook is the live-execution test for.
