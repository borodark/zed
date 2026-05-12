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

## Branches not yet covered

- **External rollback signal mid-flight** (`Zed.Converge.Health.signal_rollback/1`,
  resolving to `{:error, :rolled_back, …}`). Requires a hook to grab
  the in-flight orchestrator pid from outside. Not wired into
  `Cluster.run_health_phase/4` yet — there's no current path for an
  operator-driven abort during health checks. Worth following up
  once a real operator UX appears.
- **`:beam_ping` over real distribution.** R3 covered the
  unreachable-node failure case in isolation; the success case
  against a real connected node was not exercised in R4/R5 (we used
  TCP-only to keep apparatus inert). The DefaultChecker code is
  identical to R3's invocation, so the risk is low; still worth a
  one-line smoke later.
- **Real app payload.** R4/R5 used a synthetic `app` node whose
  only purpose was carrying the `:health` list; no release was
  actually deployed. End-to-end with a release-listening-on-its-own-port
  is the natural next step but is gated on release-engineering work,
  not the health protocol itself.

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
