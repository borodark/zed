# Dual-Mac Runbook Results (2026-05-07)

## Phase R1 — Bootstrap ✓

| Mac | Pool | Snapshot | Status |
|-----|------|----------|--------|
| mac-248 (GT 750M) | mac_zroot/zed-test | `bootstrap-20260507T163247` | ✓ secrets generated |
| mac-247 (GT 650M) | zroot/zed-test | `bootstrap-20260507T163442` | ✓ secrets generated |

Encrypted `zed/secrets` datasets (AES-256-GCM). 7 slots generated.

### ZFS permission notes
Required `doas` for: encrypted child creation, mountpoint changes,
compression/mountpoint property delegation.

## Phase R2 — Distributed Erlang ✓

| From | To | Method | Result | Round-trip |
|------|----|--------|--------|-----------|
| zed-controller@192.168.0.248 | zed-agent@192.168.0.247 | `--name` (long) | **true** | **16ms** |

Short names failed (hostname format mismatch). Long names with IPs
and pinned ports 9100-9200 work reliably.

## Phase R3 — Single-host converge ✓

| Operation | Result |
|-----------|--------|
| `diff()` | Non-empty (dataset create pending) |
| `converge()` | `{:ok, [{"dataset:set:trivial-app:mountpoint", :ok}]}` |
| `status()` | `trivial-app: exists=true, mountpoint=none` |
| ZFS snapshot | `zed-deploy-unknown-20260507T181717` |

**False alarm** (corrected 2026-05-07): `Plan.expand_to_steps`
already does `Map.take([:mountpoint, :compression, :quota,
:recordsize])` on the dataset config at `lib/zed/converge/plan.ex:47`
and passes the resulting map to `Dataset.create/2`, which spreads
it into `-o key=value` args during `zfs create`. R3's apparent
"missing mountpoint" was a misread of `zfs get` output — the
mountpoint *was* set to `none` correctly at create time.

## Phase R4 — Two-host coordinated converge ✓

| Host | Dataset | Pool | Result |
|------|---------|------|--------|
| mac-248 | shared-app-248 | mac_zroot/zed-test | ✓ created |
| mac-247 | shared-app-247 | zroot/zed-test | ✓ created via RPC |

Controller on mac-248 drove both local and remote converge.
Remote converge via `:rpc.call` to `Zed.Converge.run/1` on mac-247.

`host` DSL verb implemented during the runbook to unblock R4:
```elixir
host :mac_247, node: :"zed-agent@192.168.0.247", pool: "zroot/zed-test" do
  dataset "shared-app-247" do
    mountpoint :none
  end
end
```

## Phase R5 — Chaos test (P0 bug found)

| Host | Dataset | Expected | Actual |
|------|---------|----------|--------|
| mac-248 | chaos-good | rolled back | **exists (NOT rolled back)** |
| mac-247 | chaos-bad | never created | never created |

**P0 BUG CONFIRMED**: when remote converge fails, local success is
NOT rolled back. The converger runs each host independently; there
is no coordinated rollback protocol. This is exactly the bug the
runbook was designed to surface.

**Impact**: partial deploys leave stale state on successful hosts.
Manual cleanup required after any multi-host failure.

**Fix scope**: `Zed.Cluster.converge_coordinated/2` needs to:
1. Snapshot all hosts before converge
2. Run converge on all hosts
3. If any fails, rollback ALL hosts to pre-converge snapshot
4. Return `{:error, %{rolled_back: [...], failed: [...]}}`

## Summary

| Phase | Status | Key finding |
|-------|--------|-------------|
| R1 | ✓ | Both Macs bootstrapped, encrypted secrets |
| R2 | ✓ | 16ms RPC, long names with IPs |
| R3 | ✓ | Single-host converge + snapshot |
| R4 | ✓ | Two-host converge via RPC |
| R5 | **P0 bug** | No coordinated rollback on partial failure |

## Phase R5 — Re-test (P0 fix confirmed) ✓

After implementing the TLA+-verified 2-phase protocol:

| Host | Dataset | Action | Converge | Rollback | Post-state |
|------|---------|--------|----------|----------|------------|
| mac-248 | chaos-good | **create** | ✓ created | **zfs destroy** | **GONE** ✓ |
| mac-247 | chaos-bad | create | ✗ failed (quota) | skip | never existed |

Protocol trace:
1. Prepare: both datasets absent → marked as `action: :create`
2. Converge: mac-248 succeeds, mac-247 fails (quota 1K)
3. Rollback: mac-248's `chaos-good` destroyed (create rollback)

`NoPartialState` invariant holds: no dataset survives a failed
coordinated converge. The P0 bug from the original R5 is fixed.

TLA+ spec: 172 states, 124 distinct, 0 errors (v2 with create/modify).
