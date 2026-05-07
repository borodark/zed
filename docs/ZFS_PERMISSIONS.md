# ZFS Permissions for Zed

Zed runs as a regular user (not root). All ZFS operations are
delegated via `zfs allow`. This document lists every permission
needed, why, and the exact commands to grant them.

## TL;DR — One Command Per Pool

Grant all permissions Zed needs in one shot:

```sh
# Replace <pool>/zed with your actual dataset path.
# Replace <user> with the user running zed (e.g., io).

doas zfs allow <user> \
  create,destroy,snapshot,rollback,mount,mountpoint,\
compression,quota,reservation,recordsize,\
send,receive,userprop \
  <pool>/zed

# If using encrypted secrets (Bootstrap):
doas zfs allow <user> \
  create,destroy,snapshot,rollback,mount,mountpoint,\
send,receive,userprop \
  <pool>/zed/zed
```

### Example for the dual-Mac demo

```sh
# mac-248 (pool: mac_zroot):
doas zfs create mac_zroot/zed-test
doas zfs allow io create,destroy,snapshot,rollback,mount,mountpoint,compression,quota,reservation,recordsize,send,receive,userprop mac_zroot/zed-test

# mac-247 (pool: zroot):
doas zfs create zroot/zed-test
doas zfs allow io create,destroy,snapshot,rollback,mount,mountpoint,compression,quota,reservation,recordsize,send,receive,userprop zroot/zed-test
```

---

## Permission Reference

### Core dataset operations

| Permission | ZFS operation | Zed module | When used |
|------------|---------------|------------|-----------|
| `create` | `zfs create` | `Zed.ZFS.Dataset.create/2` | Creating datasets declared in DSL |
| `destroy` | `zfs destroy` | `Zed.ZFS.Snapshot.destroy/1` | Pruning old snapshots (keep N policy) |
| `snapshot` | `zfs snapshot` | `Zed.ZFS.Snapshot.create/2` | Pre-deploy snapshots |
| `rollback` | `zfs rollback` | `Zed.ZFS.Snapshot.rollback/1` | Reverting failed deploys |
| `mount` | `zfs mount` | `Zed.Bootstrap` | Mounting secrets dataset at boot |
| `mountpoint` | `zfs set mountpoint=...` | `Zed.Converge.Executor` | Setting dataset mountpoints |

### Dataset properties

| Permission | ZFS operation | Zed module | When used |
|------------|---------------|------------|-----------|
| `compression` | `zfs set compression=...` | `Zed.Converge.Executor` | DSL `compression :lz4` etc. |
| `quota` | `zfs set quota=...` | `Zed.Converge.Executor` | DSL `quota "10G"` |
| `reservation` | `zfs set reservation=...` | `Zed.Converge.Executor` | DSL `reservation "5G"` |
| `recordsize` | `zfs set recordsize=...` | `Zed.Converge.Executor` | DSL `recordsize "128K"` |

### User properties (state store)

| Permission | ZFS operation | Zed module | When used |
|------------|---------------|------------|-----------|
| `userprop` | `zfs set com.zed:*=...` | `Zed.ZFS.Property` | ALL state: versions, fingerprints, secret metadata, deploy timestamps |

This is the most critical permission. Without it, Zed cannot
stamp version metadata, secret fingerprints, or deploy state.
ZFS user properties (`com.zed:*`) are Zed's state store — they
travel with snapshots and `zfs send/receive`.

### Replication (optional — multi-host sync)

| Permission | ZFS operation | Zed module | When used |
|------------|---------------|------------|-----------|
| `send` | `zfs send` | `Zed.ZFS.Replicate` | Sending snapshots to remote hosts |
| `receive` | `zfs receive` | `Zed.ZFS.Replicate` | Receiving snapshots from remote hosts |

Only needed for `Zed.ZFS.Replicate` operations. Not required for
basic single-host or RPC-based multi-host deploys.

---

## Bootstrap (encrypted secrets)

The Bootstrap creates an encrypted child dataset for secrets.
Encrypted dataset creation requires root because:

1. `encryption`, `keylocation`, `keyformat` are root-only properties
2. The mountpoint directory (`/var/db/zed/secrets`) is root-owned

### Root commands (run once per host)

```sh
# Create the encrypted secrets dataset (root required):
doas zfs create -o encryption=aes-256-gcm \
  -o keylocation=prompt -o keyformat=passphrase \
  <pool>/zed-test/zed

# Create the secrets child and set mountpoint:
doas zfs create <pool>/zed-test/zed/secrets
doas mkdir -p /var/db/zed/secrets
doas chown <user> /var/db/zed/secrets
doas zfs set mountpoint=/var/db/zed/secrets <pool>/zed-test/zed/secrets

# Delegate permissions on the encrypted subtree:
doas zfs allow <user> create,destroy,snapshot,rollback,mount,\
mountpoint,send,receive,userprop \
  <pool>/zed-test/zed
```

After these root commands, `Zed.Bootstrap.init/2` runs as the
regular user:

```elixir
Zed.Bootstrap.init("mac_zroot/zed-test", passphrase: "your-passphrase")
```

---

## Common Errors and Fixes

### `cannot create '...': permission denied`

Missing `create` permission on the parent dataset.

```sh
doas zfs allow <user> create <parent-dataset>
```

### `cannot set property for '...': permission denied`

Missing the specific property permission.

```sh
# For compression:
doas zfs allow <user> compression <dataset>

# For mountpoint:
doas zfs allow <user> mountpoint <dataset>

# For user properties (com.zed:*):
doas zfs allow <user> userprop <dataset>
```

### `cannot mount '...': failed to create mountpoint: Permission denied`

The mountpoint directory doesn't exist or is root-owned.

```sh
doas mkdir -p /path/to/mountpoint
doas chown <user> /path/to/mountpoint
```

Or set `mountpoint=none` if the dataset doesn't need to be mounted:

```sh
doas zfs set mountpoint=none <dataset>
```

### `cannot create '...secrets': permission denied` (Bootstrap)

Encrypted dataset creation requires root. See the Bootstrap
section above for the one-time root commands.

### `filesystem successfully created, but not mounted`

The dataset was created but the mountpoint directory is root-owned.
Not an error if `mountpoint :none` is intended — the converger
should pass `-o mountpoint=none` during create (known bug, see
`docs/dual-mac-runbook-results.md` R3).

---

## Verifying Permissions

```sh
# Show all delegated permissions on a dataset:
zfs allow <dataset>

# Example output:
# ---- Permissions on mac_zroot/zed-test ----
# Local+Descendent permissions:
#   user io compression,create,destroy,mount,mountpoint,
#        receive,rollback,send,snapshot,userprop

# Verify a specific user can create:
su -l <user> -c 'zfs create <dataset>/test-child && zfs destroy <dataset>/test-child && echo OK'
```

---

## Security Notes

1. **`userprop` is the minimum viable permission.** Without it,
   Zed is a no-op — it can't store or read any state. Grant this
   first; add others as needed.

2. **`destroy` allows deleting ANY child dataset.** Only grant on
   the Zed-managed subtree, not on the pool root.

3. **`send`/`receive` enable data exfiltration/injection.** Only
   grant if you actually use `Zed.ZFS.Replicate`. For RPC-based
   multi-host (the demo pattern), `send`/`receive` are not needed.

4. **Encrypted dataset keys are prompted at create time.** Zed
   doesn't store passphrases — they're entered once during
   Bootstrap and the key stays loaded in ZFS until unmount or
   reboot.

5. **Permissions inherit via `Local+Descendent`.** Granting
   `create` on `pool/zed-test` also grants it on all children.
   This is intentional — Zed creates nested datasets freely.
