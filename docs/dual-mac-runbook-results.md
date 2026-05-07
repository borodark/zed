# Dual-Mac Runbook Results (2026-05-07)

## Phase R1 — Bootstrap ✓

| Mac | Pool | Fingerprint snapshot | Status |
|-----|------|---------------------|--------|
| mac-248 (GT 750M) | mac_zroot/zed-test | `bootstrap-20260507T163247` | ✓ secrets generated |
| mac-247 (GT 650M) | zroot/zed-test | `bootstrap-20260507T163442` | ✓ secrets generated |

Both encrypted `zed/secrets` datasets created with AES-256-GCM.
Slots generated: admin_passwd, beam_cookie, ssh_host_ed25519,
tls_selfsigned, ch_admin_passwd, demo_cluster_cookie, livebook_passwd,
pg_admin_passwd.

### ZFS permission notes

Required `doas` for:
- Creating encrypted child datasets (`encryption` property needs root)
- Setting `mountpoint` on encrypted children (root-owned mount paths)
- Granting `compression,mountpoint` permissions to `io` user

Recommended: `doas zfs allow io create,destroy,snapshot,rollback,mount,send,receive,userprop,compression,mountpoint <pool>/zed-test`

## Phase R2 — Distributed Erlang ✓

| From | To | Method | Result | Round-trip |
|------|----|--------|--------|-----------|
| zed-controller@192.168.0.248 | zed-agent@192.168.0.247 | `--name` (long) | **connect: true** | **16ms** |

Short names (`--sname`) failed despite `/etc/hosts` entries — likely
hostname format mismatch (`free-macpro-nvidia` vs `mac`). Long names
with IPs work reliably. Pinned ports 9100-9200.

## Phase R3 — Single-host converge ✓

| Operation | Result |
|-----------|--------|
| `diff()` | Non-empty (dataset create pending) |
| `converge()` | `{:ok, [{"dataset:set:trivial-app:mountpoint", :ok}]}` |
| `status()` | `trivial-app: exists=true, mountpoint=none` |
| ZFS snapshot | `zed-deploy-unknown-20260507T181717` |

### Bug found: converger doesn't pass `-o mountpoint=none` during `zfs create`

The converger creates the dataset with default mountpoint, then tries
to set `mountpoint=none` as a separate property. The `zfs create`
succeeds but the mount fails (permission denied on root-owned dir).
Workaround: grant `mountpoint` permission to the user. Fix: converger
should pass `-o mountpoint=none` as a create option.

## Phase R4 — Two-host coordinated converge (partial)

Cluster connects successfully (R2 proven). The `host` DSL verb is
not yet shipped. `Zed.Cluster.converge_coordinated/2` exists but
requires a proper Zed IR (not a raw map). R4 needs the DSL verb or
manual IR construction to complete.

Status: **blocked on `host` verb implementation**. The cluster
infrastructure works; the DSL gap is the remaining blocker.

## Phase R5 — Chaos test

Blocked on R4.

## Summary

| Phase | Status | Notes |
|-------|--------|-------|
| R1 Bootstrap | ✓ | Both Macs, encrypted secrets |
| R2 Distribution | ✓ | 16ms RPC, long names with IPs |
| R3 Single-host | ✓ | converge + snapshot + status |
| R4 Two-host | blocked | needs `host` verb or manual IR |
| R5 Chaos | blocked | needs R4 |
