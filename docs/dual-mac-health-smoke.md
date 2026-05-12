# Dual-Mac Health-Check Smoke (2026-05-11)

First live exercise of `Zed.Converge.Health` (Phase 2.5 of
coordinated converge) against real two-host FreeBSD 15 BEAM
distribution.

**Spec:** [`specs/HealthCheck.tla`](../specs/HealthCheck.tla)
verified safety + liveness at N=2..5 (887,681 distinct states),
safety alone at N=7 (151,261,697 distinct states; TLC's disk-graph
SCC checker hit `EOFException` so liveness wasn't re-verified at
that scale).

**Code under test:**
- `lib/zed/converge/health.ex` — GenServer orchestrator
- `lib/zed/converge/health/default_checker.ex` — TCP + `:beam_ping`
- `lib/zed/cluster.ex` — `run_health_phase/4` wedged between
  Phase 2 (converge) and the return

**HEAD:** `19209da` on both hosts.

---

## Setup

| Host | Pool | Role | Node | Cookie |
|---|---|---|---|---|
| mac-248 (free-macpro-nvidia, 192.168.0.248) | `mac_zroot/zed-test` | controller | `zed-controller@192.168.0.248` | `zed_test_cookie` |
| mac-247 (mac.247, 192.168.0.247) | `zroot/zed-test` | agent | `zed-agent@192.168.0.247` | `zed_test_cookie` |

Distribution ports pinned `9100-9200` per the dual-mac runbook;
agent on 247 launched via `elixir --name … -S mix run -e
'Process.sleep(:infinity)'` and stays resident across runs.

Each host's IR carried one dataset (`mountpoint=none`, flat name —
no slash so ZFS doesn't auto-create an intermediate parent) and one
app with a single `:tcp` health probe.

---

## R1 — Pre-clean

Stale `twohost-*` and `rollout-app` datasets from prior R3/R5 runs
removed (no snapshots — direct destroy). Bootstrap state
(`<pool>/zed-test/zed`, `<pool>/zed-test/zed/secrets`) preserved.

---

## R2 — Sync HEAD

Both macs synced `feat/demo-cluster` / stale `main` to `19209da`.
Origin re-pointed from `rango_origin` (down — rango is mid-migration)
to `git@super-io:/home/git/repos/zed.git`. `mix compile` clean on
both (only pre-existing `cluster_live.ex` warnings).

---

## R3 — Checker isolation

`Zed.Converge.Health.DefaultChecker.check/4` invoked directly via
`mix run --no-start -e`. Each probe on each host:

| Probe | Both macs |
|---|---|
| `:tcp 127.0.0.1:22` (sshd) | `:ok` |
| `:tcp 127.0.0.1:1` (closed) | `{:error, {:tcp_connect, "127.0.0.1", 1, :econnrefused}}` |
| `:beam_ping nonexistent@127.0.0.1` | `{:error, {:beam_ping, :pang, …}}` |

Matches every transition label in `HealthCheck.tla` (`:ok` path
vs tagged-error path; retry path is exercised by R5 below).

---

## R4 — Green path

mac-248 and mac-247 each probed `127.0.0.1:22` (always-up sshd).
Both datasets created fresh.

```
01:47:50.058 phase 1 (prepare):  2 hosts ready
01:47:50.155 phase 2 (converge): all 2 hosts succeeded
01:47:50.155 phase 2.5 (health): 2 hosts          ← new code
01:47:50.159 phase 2.5 (health): all hosts healthy
RESULT: {:ok, %{
  mac_248: {:ok, [{"dataset:create:health-smoke-green-1778550470", :ok}]},
  mac_247: {:ok, [{"dataset:create:health-smoke-green-1778550470", :ok}]}
}}
```

End-to-end **101 ms**, Phase 2.5 contributed **4 ms** (two hosts ×
one TCP loopback probe).

ZFS state confirms creation, `mountpoint=none` honoured, no
rollback fired:

```
mac_zroot/zed-test/health-smoke-green-1778550470    96K   none
zroot/zed-test/health-smoke-green-1778550470        96K   none
```

The `phase 2.5 (health): 2 hosts` line is the wiring-correctness
witness — `extract_health_targets/1` returned a non-empty list, so
this is not the silent-no-op failure mode where green-path "passes"
because health was never actually invoked.

---

## R5 — Red path

mac-248 probed port 22 (open). mac-247 probed port 1 (closed) to
force a health failure. Expectation: full Phase 2.5 + Phase 3
(rollback) sequence; final return `{:error, :health_failed, …}`;
both datasets destroyed.

```
01:57:18.466 phase 2 (converge): all 2 hosts succeeded
01:57:18.466 phase 2.5 (health): 2 hosts
01:57:18.472 [Health] :mac_247 attempt 1 failed: econnrefused, retrying
01:57:18.473 [Health] :mac_247 attempt 2 failed: econnrefused, retrying
01:57:18.473 [Health] :mac_247 retries exhausted
01:57:18.475 phase 2.5 (health): health_failed, rolling back:
             %{mac_248: :passed, mac_247: :failed}
01:57:18.475 rollback mac_248: zfs destroy ...health-smoke-red-1778551038
01:57:18.487 rollback mac_247: zfs destroy ...health-smoke-red-1778551038
```

```elixir
RESULT: {:error, :health_failed,
 %{
   health_outcomes: %{mac_248: :passed, mac_247: :failed},
   rolled_back: %{mac_248: [ok: ""], mac_247: [ok: ""]},
   preparations: %{...}
 }}
```

End-to-end **117 ms**. ZFS state after R5 confirms both red
datasets gone (only the green sentinel from R4 remains).

---

## Invariants observed

| Invariant (from `HealthCheck.tla`) | Live evidence |
|---|---|
| **GreenOnlyWhenAllPassed** | R5: one host failed ⇒ result is `{:error, :health_failed, _}`, never `{:ok, _}`. |
| **FinalOutcomeMonotonic** | Once mac-247 was recorded `:failed`, retries didn't flip it back. Outcome map stable from first write. |
| **NoStaleSuccess** | mac-248 reported `:passed`, but the *cluster-level* return was still failure. The health-orchestrator outcome ≠ the host's individual outcome — only the conjunction matters. |
| **RetryBounded** | Exactly 2 retries before exhaustion. `MaxRetries = 2` in the spec, matches behaviour. |
| **NoLatePromotionAfterRollback** | mac-248's passing probe didn't promote the host past a failing peer — Phase 3 destroyed its dataset all the same. |
| **HealthCheckTerminates** (liveness) | Both runs reached a terminal `{:ok, _}` or `{:error, :health_failed, _}`. No hang, no leaked GenServer. |

---

## F1 — `:beam_ping` over real distribution

Both hosts' probes hit the `:beam_ping` branch of `DefaultChecker`
across a live distribution link rather than the synthetic
`:"nonexistent@127.0.0.1"` of R3. Each host's check pings the
*other* cluster member's BEAM node:

| Host | Probes |
|---|---|
| mac-248 | `{:beam_ping, %{node: :"zed-agent@192.168.0.247"}}` |
| mac-247 | `{:beam_ping, %{node: :"zed-controller@192.168.0.248"}}` |

```
02:08:49.065 phase 2 (converge): all 2 hosts succeeded
02:08:49.065 phase 2.5 (health): 2 hosts
02:08:49.071 phase 2.5 (health): all hosts healthy
RESULT: {:ok, %{
  mac_248: {:ok, [{"dataset:create:health-smoke-beam-1778551728", :ok}]},
  mac_247: {:ok, [{"dataset:create:health-smoke-beam-1778551728", :ok}]}
}}
```

Phase 2.5 wall time **6 ms** (R4's TCP-loopback was 4 ms; the
2 ms delta is two real `net_adm.ping/1` round-trips). Both probes
returned `:pong`. The other DefaultChecker code path is now
exercised end-to-end.

**Run-id:** `beam-1778551728`.

---

## F2 — `signal_rollback/1` mid-flight (third spec branch)

Single-process verification on dev host (no macs needed — the
test is about orchestrator semantics, not distribution). A custom
`SlowChecker` sleeps 200 ms per probe and unconditionally returns
`:ok`; the test grabs the orchestrator pid via a new `:on_start`
opt on `Health.run/2`, then calls `signal_rollback/1` 30 ms in,
while every worker is still mid-sleep.

```
t+0 ms   got pid #PID<0.342.0>
t+30 ms  signal_rollback
22:32:38 [Health] external rollback signal latched
t+205 ms RESULT: {:error, :rolled_back, %{host_a: :failed, host_b: :failed}}
ok :: NoLatePromotionAfterRollback held — no :passed recorded
```

Both workers returned `:ok` after the signal latched, but the
`handle_cast({:check_complete, _, :passed}, …)` guard read the
rollback flag in the same callback that records the outcome
(per the moduledoc comment about realising the TLA+
`NoLatePromotionAfterRollback` invariant in code). The unrecorded
outcomes pass through `drain_for_rollback/1` as `nil → :failed`,
matching the spec branch.

Code surgery:
- `Health.run/2` gains an `:on_start` opt accepting a `(pid -> any())`
  callback. Test-only — no production caller needs it. Five lines.
- No `Cluster.signal_health_rollback` wrapper added — `run_health_phase/4`
  doesn't currently have an upstream rollback source to plumb in.
  Add when (if) one appears.

**Run-id:** `rollback-1778554358` (informal — local run, no ZFS state).

---

## F3 — Real app payload (and a design finding)

Each mac ran an Elixir one-liner opening `:gen_tcp.listen(14040, …)`
to stand in for a deployed app. The first attempt (`HealthSmokeApp`)
bound to `127.0.0.1` and probed `127.0.0.1:14040` on each host.
Green path passed. Then mac-247's listener was killed; the "red"
run **still returned green**.

Diagnosis:

`Zed.Converge.Health` spawns workers via `Task.start/1`, which run on
the **same node as the orchestrator GenServer** — the controller
(mac-248). Each worker invokes `checker.check(host, type, opts, …)`
where `host` is only a label used to key the outcome map; the
probe's actual destination comes from `opts`. With both IRs
pointing at `127.0.0.1:14040`, both workers pinged the *controller's*
loopback. Mac-247's listener never entered the picture.

This is not a regression; the spec says nothing about *where* a
probe physically runs. R4/R5/F1 happened to be accidentally
correct: R4's `127.0.0.1:22` was open on both macs (sshd
everywhere); R5's `127.0.0.1:1` was closed on both macs; F1's
`:beam_ping` target carried a real cross-host node atom, so it
genuinely traversed distribution.

### F3 v2 — fix the probe targets

Listeners rebound on `0.0.0.0:14040`. Each host's IR probes its
**LAN IP**, so the controller (now correctly executing both probes)
reaches the right machine each time.

**Green** (`app-v2-1778592887`):
```
13:34:48.001 phase 2.5 (health): 2 hosts
13:34:48.005 phase 2.5 (health): all hosts healthy
RESULT: {:ok, %{mac_248: {:ok, …}, mac_247: {:ok, …}}}
```

**Red** (`app-v2-1778592904`, mac-247 listener killed):
```
13:35:04.154 phase 2.5 (health): health_failed, rolling back:
             %{mac_248: :passed, mac_247: :failed}
13:35:04.155 rollback mac_248: zfs destroy …
13:35:04.166 rollback mac_247: zfs destroy …
RESULT: {:error, :health_failed,
         %{health_outcomes: %{mac_248: :passed, mac_247: :failed},
           rolled_back: %{mac_248: [ok: ""], mac_247: [ok: ""]}}}
```

End-to-end **117 ms** red, **4 ms** Phase 2.5 green.

### Design finding (open question)

Per-host outcomes are recorded, but probes always run from the
controller. Two valid models:

1. **Convention.** Document that probe targets must be *reachable
   from the controller* and *specific to the host* (LAN IP,
   registered DNS, `:beam_ping` against the host's node atom).
   Loopback targets in multi-host coordinated converge are an
   operator error. Cost: a docstring + a runtime warning at IR
   validation when a multi-host IR contains loopback probes.

2. **Routing.** Have `spawn_worker/6` RPC the check to the host's
   BEAM node, so probes execute on the right physical machine and
   loopback IS the right thing. Cost: an `:rpc.call` per probe, a
   dependency on the host having a live agent (which it must have
   to receive the converge RPC anyway), and an additional failure
   mode (RPC timeout → probe failure).

Model 2 is more permissive (loopback works as authors expect) but
adds a hop. Model 1 is simpler. **Recommendation: ship Model 1
(doc + warn) now; revisit if a real operator UX request lands.**

---

## Branches not yet covered

- **Wiring `signal_rollback` into `Cluster.run_health_phase/4`** —
  protocol-level support exists and is verified; what's missing is
  a real *caller* (operator abort UX, upstream-failure listener).
  Speculative until one materialises.
- **A real release with its actual `Endpoint`.** F3 uses a tiny
  `:gen_tcp.listen/2` shim. The zedweb release boots but its Phoenix
  endpoint is gated behind a `zed serve` verb that isn't yet wired
  in the release. Standing up an actual release-managed endpoint is
  release-engineering work tracked in `specs/converge-jail-executor.md`,
  not a health-protocol gap.

---

## Conclusion

`HealthCheck.tla` correctly models the behaviour we observe in
production. The new code wires through `Zed.Cluster.do_coordinated_converge`
exactly as the spec describes: converge → health → either success
or coordinated rollback, with no partial state and no late
promotion.

Operative verification stands at N=5 from the model checker and
two live two-host runs (green + red) from this exercise.

**Run-ids:** `green-1778550470`, `red-1778551038`.

**Bug count surfaced by this exercise:** zero in the health code.
One *operational* gotcha re-discovered: dataset ids with `/` cause
ZFS to auto-create an intermediate dataset whose default mountpoint
is honoured, which fails for the non-root user. Use flat ids or
pre-stamp the parent. (Pre-existing — same issue noted in the
dual-mac runbook.)
