# Rango Migration Runbook — TrueNAS CORE 13 → FreeBSD 15

**Target host:** `rango.local` / `192.168.0.33`
**From:** TrueNAS-13.0-U6.8 (FreeBSD 13.1-RELEASE-p9 TRUENAS kernel)
**To:** FreeBSD 15.0-RELEASE (GENERIC kernel)
**Author:** drafted by super-io Claude, executed by rango Claude
**Date prepared:** 2026-05-09

## Audience and operating mode

This runbook is written for **the Claude instance running on rango**. Each
phase has explicit verification commands (read-only, safe at any time) and
explicit action commands (destructive or state-changing).

**MANDATORY OPERATING RULES for the executing Claude:**

1. Run all verification commands at the start of every phase. Confirm
   expected output matches before any action.
2. Never run destructive action commands without explicit user approval
   in the same chat turn. Each action block in this runbook is gated.
3. If verification fails, halt the phase and report what diverged.
   Do not improvise — report and wait.
4. Phases 2 and 3 require physical user action (BIOS boot order, install
   media). Hand off to the user; do not pretend to perform them.
5. Each ZFS destroy is a one-way door. Read what you are about to
   destroy aloud before destroying it.

## Hardware as inventoried 2026-05-08

| Device | Size | Role |
|---|---|---|
| ada0 | 112G SSD | boot-pool mirror leg 1 — **DO NOT TOUCH** |
| ada3 | 119G SSD | boot-pool mirror leg 2 — **DO NOT TOUCH** |
| **ada4** | **120G Kingston SUV500** | **FreeBSD 15 install target** |
| ada1, ada2 | 3.6T, 5.5T | jeff pool — preserve |
| da0, da1, da2, da3 | 3.6T each | jeff pool — preserve |

Migration target writes only to **ada4**. Both boot-mirror disks remain
untouched, preserving a working TrueNAS install as the rollback path.

## Migration scope (after user decisions)

| Bucket | Size | Action |
|---|---|---|
| `jeff/home` | 622G | preserve |
| `jeff/video` | 312G | preserve |
| `jeff/octanix_git`, `jeff/S3`, `jeff/agent1`, `jeff/zed-test`, `jeff/zed-dev` | <30M | preserve |
| `jeff/.system/samba4` | 1.49M | **extract before drop** (SID + tdbs) |
| `jeff/.system/*` (other) | ~211M | drop (TrueNAS middleware) |
| `jeff/timemachines/*` | 566G | **destroy pre-migration** (user decision) |
| `jeff/iocage/*` | 8.16G | **destroy pre-migration** (user decision) |

## Identity to preserve

| User | UID | GID | Home | Shell | SMB? |
|---|---|---|---|---|---|
| io | 1000 | 1000 | `/jeff/home/io` | bash | yes |
| jo | 1001 | 1001 | `/jeff/home/jo` | bash | yes |
| po | 1002 | 1003 (ostens) | `/jeff/home/po` | bash | yes |
| vo | 1003 | 1003 (ostens) | `/jeff/home/vo` | bash | yes |
| git | 1004 | 1005 | `/jeff/home/git` | bash | no (SSH only) |

| Group | GID | Members |
|---|---|---|
| io | 1000 | — |
| jo | 1001 | — |
| po | 1002 | — (placeholder) |
| ostens | 1003 | io, jo (po+vo via primary GID) |
| engineers | 1004 | io, jo |
| git | 1005 | — |
| media | 8675309 | — |

**Mountpoint policy:** new system uses `/jeff/...` (not `/mnt/jeff/...`).
Update DSL/code references after migration; symlink `/mnt/jeff -> /jeff`
during Phase 4 if any client config still hardcodes `/mnt/jeff`.

**SMB Machine SID (preserve via tdb import):**
`S-1-5-21-1802559556-342626866-2594444652`

**NetBIOS name:** `MR_RANGO`

---

## Phase 0 — Preflight (verify only, no changes)

**Goal:** confirm system state matches what this runbook was written
against. Halt if anything diverges.

### 0.0 Verify CPU and RAM meet FreeBSD 15 requirements

**FreeBSD 15.0's amd64 baseline is x86-64-v1 (SSE2 only)** — verified
2026-05-09 against the [FreeBSD 15.0 Hardware
Notes](https://www.freebsd.org/releases/15.0R/hardware/) ("Release
media is expected to work on all x86-64 machines with at least 256
MiB of RAM"). The 15.0 release notes mention no CPU baseline change.
Practical consequence: any 64-bit Intel or AMD CPU since ~2003 boots
FreeBSD 15. The mandatory check is just `amd64`.

Rango (X5482, Penryn 2008) sits well above the baseline but lacks
several performance accelerators that newer Samba/ZFS code paths
expect. We record those gaps so the install isn't surprising.

```sh
# Architecture and basic CPU
uname -m                              # MUST be amd64
sysctl hw.model
sysctl hw.machine
sysctl hw.ncpu
sysctl hw.clockrate

# CPU feature flags — look for SSE4.2, POPCNT, AES, AVX, RDRAND
sysctl machdep.cpu_features
sysctl machdep.cpu_features2 2>/dev/null
sysctl machdep.cpu_stdext_features 2>/dev/null
sysctl machdep.cpu_stdext_features2 2>/dev/null

# RAM
sysctl hw.physmem | awk '{ printf "physical: %.1f GB\n", $2 / 1073741824 }'
sysctl hw.usermem | awk '{ printf "usermem: %.1f GB\n", $2 / 1073741824 }'

# Boot mode (UEFI vs legacy)
sysctl machdep.bootmethod

# Boot dmesg has the authoritative feature list (sysctl can come up empty
# under TRUENAS kernel)
cat /var/run/dmesg.boot | grep -iE "CPU:|Origin|Features|VT-x" | head -10
```

**HALT if missing:**

| Requirement | Why |
|---|---|
| `uname -m` = `amd64` | FreeBSD 15.0 is amd64-only (i386 dropped) |
| ≥ 4 GB physmem | ZFS won't be happy below this for raidz3 of any size |

**Strongly recommended for performance (record absence, do not halt):**

| Feature | Penalty if missing |
|---|---|
| `SSE4.2` + `POPCNT` (x86-64-v2) | ZFS Edon-R checksum path unavailable; some Samba accelerated paths fall back |
| `AESNI` | SMB3 encryption is software-only (~100 MB/s ceiling instead of line rate) |
| `RDRAND` | Slower entropy seeding at boot |
| `AVX` / `AVX2` | Some openssl/Samba code paths slower |
| ≥ 16 GB physmem | Larger ZFS ARC = better hit rate on `jeff/home` |
| VT-x enabled in BIOS | Required only if running bhyve later (not needed for this NAS migration) |

**Process:** record the actual `hw.model` string and the cpu_features
flags into `/mnt/jeff/migration-2026-05/preflight/cpu-info.txt` so the
final FreeBSD 15 install can be cross-checked against the same
hardware.

```sh
mkdir -p /mnt/jeff/migration-2026-05/preflight
{
  echo "=== Architecture ==="
  uname -a
  sysctl hw.model hw.machine hw.ncpu hw.clockrate
  echo
  echo "=== CPU features (sysctl) ==="
  sysctl machdep.cpu_features machdep.cpu_features2 \
         machdep.cpu_stdext_features machdep.cpu_stdext_features2 2>/dev/null
  echo
  echo "=== CPU features (boot dmesg, authoritative) ==="
  cat /var/run/dmesg.boot | grep -iE "CPU:|Origin|Features|VT-x" | head -10
  echo
  echo "=== Memory ==="
  sysctl hw.physmem hw.usermem hw.realmem
  echo
  echo "=== Boot ==="
  sysctl machdep.bootmethod 2>/dev/null
} > /mnt/jeff/migration-2026-05/preflight/cpu-info.txt

cat /mnt/jeff/migration-2026-05/preflight/cpu-info.txt
```

**Confirmed for rango (verified 2026-05-09 over SSH):**

| Check | Value | Verdict |
|---|---|---|
| Architecture | amd64 | ✓ HALT condition cleared |
| CPU | Intel Xeon X5482 @ 3.20 GHz (Penryn 2008, 4 cores) | will boot FreeBSD 15 |
| RAM | 64 GiB | ✓ generous |
| Boot | UEFI | ✓ |
| SSE2 / SSE3 / SSSE3 / SSE4.1 | yes | baseline + extras |
| **SSE4.2 / POPCNT** | **no** | x86-64-v1 only — perf-only impact |
| **AES-NI** | **no** (`aesni0: No AES or SHA support`) | SMB3 encryption software-bound |
| AVX / AVX2 / RDRAND | no | minor perf impact |
| VT-x | disabled in BIOS | irrelevant (bhyve not in scope) |

Rango is **cleared to install FreeBSD 15.0** with the noted performance
caveats. None are blockers for a household NAS workload.

### 0.1 Verify ada4 is unclaimed

```sh
gpart show ada4 2>/dev/null
zpool status | grep -i ada4
```

**Expect:** `gpart show ada4` returns nothing (no GPT) OR shows partitions
the user explicitly knows about. `zpool status | grep ada4` returns
nothing. If ada4 has unexpected partitions or is part of any pool,
**halt.**

### 0.2 Verify boot mirror is healthy

```sh
zpool status boot-pool
```

**Expect:** `state: ONLINE`, both `ada0p2` and `ada3p2` ONLINE, no errors.
If degraded or any disk faulted, **halt** and report.

### 0.3 Verify jeff is healthy

```sh
zpool status jeff
zpool list jeff
```

**Expect:** `state: ONLINE`, raidz3-0 ONLINE, six leaves ONLINE.
Last scrub date should be recent (within months).

### 0.4 Verify scope-removal candidates still present

```sh
zfs list -r jeff/timemachines 2>/dev/null
zfs list -r jeff/iocage 2>/dev/null
iocage list 2>/dev/null
```

These tell us whether the user has already destroyed the TM and iocage
trees per the standalone instructions. Either state is fine; the
runbook adapts in Phase 1.

### 0.5 Verify Samba private dir location

```sh
testparm -s 2>/dev/null | grep -iE "private dir|state directory|cache directory"
ls -la /var/db/samba4/private/ 2>/dev/null | head -20
ls -la /var/db/system/samba4/private/ 2>/dev/null | head -20
```

**Record:** exact path that contains `passdb.tdb`, `secrets.tdb`. This
is the path Phase 1 backs up and Phase 4 imports from.

### 0.6 Verify free space for snapshot retention

```sh
zpool list jeff
df -h /mnt/jeff
```

**Expect:** at least 50G free on jeff (snapshots will hold differentials
for the lifetime of the migration). If under 50G, surface to user.

### 0.7 Capture inventory artifacts

```sh
mkdir -p /mnt/jeff/migration-2026-05/preflight
cd /mnt/jeff/migration-2026-05/preflight

zpool status > zpool-status.txt
zpool list -v > zpool-list.txt
zfs list -t all -o name,used,refer,mountpoint,compression > zfs-list-all.txt
gpart show > gpart-show.txt
getent passwd > etc-passwd-osview.txt
getent group > etc-group-osview.txt
pdbedit -L -v > pdbedit-list.txt 2>/dev/null
testparm -s > smb-config-effective.txt 2>/dev/null
cp /usr/local/etc/smb4.conf smb4.conf.copy 2>/dev/null
cp /etc/rc.conf rc.conf.copy 2>/dev/null
cp /etc/hosts hosts.copy
ifconfig > ifconfig.txt
sysctl -a > sysctl-a.txt 2>/dev/null

ls -la
```

**Halt and report to user before proceeding to Phase 1.**

---

## Phase 1 — Backup (snapshots + config export)

**Goal:** capture a complete restorable state of jeff before any
destructive action elsewhere. **Read-only with respect to data;**
creates new snapshots and copies.

**Gate:** Phase 0 must have completed cleanly. User has approved
proceeding.

### 1.1 If timemachines and iocage still present, drop per user decision

If `zfs list jeff/timemachines` returned datasets in 0.4 AND user has
confirmed their disposal, run the standalone destruction sequence
(see "Pre-migration cleanup" appendix below) BEFORE 1.2. Otherwise
skip to 1.2.

### 1.2 Recursive snapshot of jeff

```sh
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP="jeff@pre-migration-${TS}"
echo "Creating recursive snapshot: ${SNAP}"
zfs snapshot -r "${SNAP}"
zfs list -t snapshot -r jeff -o name,used,refer | head -30
```

**Expect:** every dataset under `jeff` now has a snapshot named
`@pre-migration-<timestamp>`. The snapshot uses 0B initially (CoW).

### 1.3 Export TrueNAS config bundle

The TrueNAS UI → System → General → Save Config produces a tar with
the SQLite middleware DB. The CLI equivalent:

```sh
mkdir -p /mnt/jeff/migration-2026-05/truenas-config
cd /mnt/jeff/migration-2026-05/truenas-config

# SQLite database (middleware config)
cp /data/freenas-v1.db ./
cp /data/pwenc_secret ./ 2>/dev/null

# SSH host keys (so connecting clients don't see a fresh fingerprint
# on the new system unless we want them to)
cp -a /etc/ssh ./etc-ssh
cp -a /usr/local/etc/ssh ./local-etc-ssh 2>/dev/null

ls -la
```

### 1.4 Extract Samba private directory (CRITICAL — preserves SIDs)

Replace `<SAMBA_PRIVATE_DIR>` below with the path discovered in 0.5.

```sh
SAMBA_DIR="<SAMBA_PRIVATE_DIR>"  # e.g. /var/db/samba4/private
mkdir -p /mnt/jeff/migration-2026-05/samba-private

# Copy preserving permissions, timestamps, ownership
cp -a "${SAMBA_DIR}"/. /mnt/jeff/migration-2026-05/samba-private/

# Verify the critical tdbs are present
ls -la /mnt/jeff/migration-2026-05/samba-private/ | grep -E "passdb|secrets|account_policy"
```

**Expect:** at minimum `passdb.tdb` and `secrets.tdb`. These carry the
machine SID and SMB password hashes. Phase 4 imports them verbatim.

### 1.5 Document share definitions

```sh
testparm -s > /mnt/jeff/migration-2026-05/smb-config-final.txt 2>/dev/null
# also TrueNAS-generated extras:
ls -la /usr/local/etc/smb4.conf.d/ 2>/dev/null
cp -a /usr/local/etc/smb4.conf.d /mnt/jeff/migration-2026-05/smb4-conf-d 2>/dev/null
```

This is the source-of-truth for what shares exist and their options.
Phase 4 hand-writes a new `smb4.conf` referencing these.

### 1.6 Snapshot `jeff/migration-2026-05` itself

```sh
zfs snapshot jeff/migration-2026-05@captured-${TS} 2>/dev/null \
  || echo "migration-2026-05 is a directory, not a dataset — that's fine"
```

(The migration directory is just a directory under `jeff`, not a
dataset, so this snapshot is unnecessary; the recursive snapshot from
1.2 covered it.)

### 1.7 Confirm Phase 1 completion

```sh
zfs list -t snapshot -r jeff | grep "pre-migration-${TS}"
ls -la /mnt/jeff/migration-2026-05/
du -sh /mnt/jeff/migration-2026-05/
```

**Halt and report to user. User must approve Phase 2 (which involves
shutdown).**

---

## Phase 2 — Install FreeBSD 15 onto ada4 (USER ACTION)

**The executing Claude on rango cannot perform this phase.** Hand off
to the user with these instructions:

### 2.1 Power off rango

```sh
shutdown -p now
```

### 2.2 Boot from FreeBSD 15.0-RELEASE install media

User must:

1. Insert FreeBSD 15.0-RELEASE install USB.
2. Power on, enter BIOS/UEFI boot menu.
3. Select the install USB.

### 2.3 Run bsdinstall against ada4 ONLY

User selects in `bsdinstall`:

- **Hostname:** `rango`
- **Distribution:** kernel-dbg, lib32 (default selection is fine)
- **Network:** DHCP from rango's existing NIC
- **Partitioning:** Auto (ZFS)
  - **Pool type:** stripe (single disk)
  - **Pool name:** `zroot`
  - **Disk selection:** `ada4` ONLY. **Do not select ada0, ada3, ada1, ada2,
    da0, da1, da2, da3.**
  - **Encryption:** user choice (recommend GELI off for now to keep boot
    simple; can add later)
  - **Swap:** 4G
- **Root password:** set strong, save securely
- **Time zone:** America/Detroit (or current)
- **System hardening:** all defaults
- **Add user:** create `io` with UID 1000 (others added in Phase 4)

### 2.4 First boot from ada4

After install completes:

1. Remove install USB.
2. Reboot.
3. Enter BIOS/UEFI boot menu, select **ada4** as boot device.
4. FreeBSD 15 boots. Verify hostname is `rango`, `uname -a` shows
   15.0-RELEASE.

**Rollback at this point:** boot menu select ada0 → TrueNAS comes
back, jeff intact, no harm done.

User confirms Phase 2 success → Claude resumes from Phase 3.

---

## Phase 3 — Import jeff and reconstruct mountpoints

**Gate:** rango is now running FreeBSD 15.0-RELEASE from ada4. The
executing Claude is now a *new* instance on the new system. ada0+ada3
boot-pool is still intact but unused.

### 3.1 Verify FreeBSD 15

```sh
uname -a
hostname
zpool list
```

**Expect:** `15.0-RELEASE`, hostname `rango`, only `zroot` pool listed
(jeff not yet imported).

### 3.2 Import jeff

```sh
zpool import
zpool import jeff
zpool status jeff
```

**Expect:** `zpool import` lists `jeff` as importable. `zpool import
jeff` succeeds. Status shows ONLINE raidz3-0 with all six leaves.

If status shows missing devices, **halt** — the new kernel may have
renamed devices (e.g., da0 → ada5). Use `zpool import -d /dev` to scan
explicitly.

### 3.3 Adjust mountpoints

The TrueNAS-era mountpoints used `/mnt/jeff/...`. New system uses
`/jeff/...` for cleanliness:

```sh
# Verify current mountpoints
zfs list -o name,mountpoint -r jeff | head

# Set new root mountpoint
zfs set mountpoint=/jeff jeff

# Children inherit by default; correct the explicit ones
zfs list -o name,mountpoint -r jeff | grep "/mnt/"
# For each row showing /mnt/..., reset:
# zfs set mountpoint=/jeff/<rest> <dataset>

# Fix the known typo
zfs set mountpoint=/jeff/zed-dev jeff/zed-dev   # was /mnt/mnt/zed-dev

# .system datasets stay legacy (TrueNAS used them; we will destroy)
```

### 3.4 Mount and verify

```sh
zfs mount -a
ls /jeff
ls /jeff/home
df -h /jeff/home /jeff/video
```

**Expect:** `io jo po vo git projects sb` visible under `/jeff/home`.
File sizes match what was on TrueNAS.

### 3.5 Destroy TrueNAS leftovers on jeff

```sh
zfs destroy -r jeff/.system   # TrueNAS middleware artifacts
```

**Confirmation read-aloud:** this destroys 213M of TrueNAS config
artifacts. The Samba private dir contents are already preserved in
`/jeff/migration-2026-05/samba-private/`.

### 3.6 Snapshot post-import state

```sh
TS=$(date -u +%Y%m%dT%H%M%SZ)
zfs snapshot -r "jeff@imported-${TS}"
```

This is a checkpoint for Phase 4 rollback (if Samba misconfiguration
breaks ACLs).

**Halt and report. User must approve Phase 4.**

---

## Phase 4 — Reconstruct services (users, Samba, SSH)

**Gate:** Phase 3 complete, jeff mounted at `/jeff`, TrueNAS leftovers
gone, snapshot taken.

### 4.1 Install required packages

```sh
pkg update
pkg install -y bash zsh sudo doas samba422 vim git
```

(Substitute the current Samba 4.x version as available in pkg. As of
2026-05, samba422 is current.)

### 4.2 Recreate groups

Order matters: groups before users with primary-GID dependency.

```sh
pw groupadd ostens     -g 1003
pw groupadd engineers  -g 1004
pw groupadd git        -g 1005
pw groupadd media      -g 8675309
pw groupadd po         -g 1002   # placeholder for ACL parity
```

### 4.3 Recreate users with exact UID/GID match

Skip `io` if Phase 2.3 created it; verify UID matches:

```sh
id io   # should show uid=1000(io) gid=1000(io)
# If different, fix:
# pw usermod io -u 1000 -g 1000 -G ostens,engineers
```

```sh
pw useradd io  -u 1000 -g 1000 -G ostens,engineers -d /jeff/home/io  -s /usr/local/bin/bash -c "IO" -m -k /dev/null
pw useradd jo  -u 1001 -g 1001 -G ostens,engineers -d /jeff/home/jo  -s /usr/local/bin/bash -c "JO" -m -k /dev/null
pw useradd po  -u 1002 -g 1003                     -d /jeff/home/po  -s /usr/local/bin/bash -c "PO" -m -k /dev/null
pw useradd vo  -u 1003 -g 1003                     -d /jeff/home/vo  -s /usr/local/bin/bash -c "VO" -m -k /dev/null
pw useradd git -u 1004 -g 1005                     -d /jeff/home/git -s /usr/local/bin/bash -c "git" -m -k /dev/null
```

The `-m -k /dev/null` flags create-and-empty an existing home dir; they
should NO-OP because home dirs already exist on jeff. Verify:

```sh
for u in io jo po vo git; do
  ls -la /jeff/home/$u | head -3
  stat -f '%Su:%Sg' /jeff/home/$u
done
```

**Expect:** ownership shows `<user>:<primary-group>` matching the table
in the runbook header.

### 4.4 Import Unix passwords from preserved hashes

The original `/etc/master.passwd` had SHA512 ($6$) hashes. On the new
system, edit `/etc/master.passwd` via `vipw`:

```sh
vipw
```

For each user (io, jo, po, vo, git), find the line on the new system
and replace the second field (the password hash) with the original
hash from `/jeff/migration-2026-05/preflight/etc-passwd-osview.txt`.

**Do not paste hashes into chat or logs.** Use the file directly.

After saving, `pwd_mkdb` runs automatically. Verify:

```sh
su - io -c whoami   # should not prompt for password if you authed already
# or test SSH login with old password from a different machine
```

### 4.5 Import Samba private DB (preserves SMB SIDs and hashes)

```sh
# Stop Samba if it auto-started
service samba_server stop 2>/dev/null

# Locate FreeBSD 15 Samba's private dir
testparm -s 2>/dev/null | grep -i "private dir" || true
# Default for Samba 4.22 on FreeBSD: /var/db/samba4/private

# Restore from backup
mkdir -p /var/db/samba4/private
cp -a /jeff/migration-2026-05/samba-private/. /var/db/samba4/private/

# Verify tdbs landed
ls -la /var/db/samba4/private/passdb.tdb /var/db/samba4/private/secrets.tdb

# Permissions
chown -R root:wheel /var/db/samba4/private
chmod 600 /var/db/samba4/private/*.tdb
chmod 700 /var/db/samba4/private
```

### 4.6 Hand-write smb4.conf

Reference: `/jeff/migration-2026-05/smb-config-final.txt` and the
copied `smb4-conf-d/`.

Create `/usr/local/etc/smb4.conf`:

```ini
[global]
    workgroup = MR_RANGO
    netbios name = MR_RANGO
    server string = rango
    server role = standalone server

    # Use the imported passdb.tdb (carries SIDs)
    passdb backend = tdbsam
    private dir = /var/db/samba4/private

    # ZFS NFSv4 ACLs — required for permissions to come over correctly
    vfs objects = zfsacl
    nfs4:mode = special
    nfs4:acedup = merge
    nfs4:chown = yes

    # Logging
    log file = /var/log/samba4/log.%m
    max log size = 1000
    log level = 1

    # SMB protocol
    server min protocol = SMB2
    server signing = auto
    smb encrypt = desired

    # Performance
    socket options = TCP_NODELAY IPTOS_LOWDELAY
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384

[homes]
    comment = User home
    browseable = no
    read only = no
    inherit acls = yes
    inherit owner = yes
    valid users = %S

# Add other shares per the original smb-config-final.txt — examples below.
# Read the captured testparm output and translate share-by-share.

# Example projects share (verify against captured config):
# [projects]
#     path = /jeff/home/projects
#     browseable = yes
#     read only = no
#     valid users = @ostens, @engineers
#     inherit acls = yes

# Example media share for jeff/video (if shared):
# [video]
#     path = /jeff/video
#     browseable = yes
#     read only = yes
#     valid users = @ostens, @media
#     inherit acls = yes
```

Test the config:

```sh
testparm -s
```

**Expect:** no errors, no warnings about unknown parameters, share list
matches what you wrote.

### 4.7 Enable services in rc.conf

```sh
sysrc samba_server_enable=YES
sysrc sshd_enable=YES   # likely already YES from install
sysrc hostname=rango

# Mount jeff at boot (zpool cachefile handles this; verify):
sysrc zfs_enable=YES
```

### 4.8 Start Samba

```sh
service samba_server start
service samba_server status
```

**Expect:** `samba_server is running`. Logs in `/var/log/samba4/`
should show no errors. If there are errors, the most likely causes are:

- Wrong path in `private dir` (check 4.5 step)
- ACL mode mismatch (`nfs4:mode = special` vs `simple`)
- Missing tdb permissions

### 4.9 Verify SMB user list survives import

```sh
pdbedit -L
```

**Expect:** four users (io, jo, po, vo) with the same SIDs as the
original `pdbedit -L` output captured in 0.7. If SIDs differ, the tdb
import did not take effect — re-check 4.5.

**Halt and report. User must verify a Mac client can connect before
Phase 5.**

---

## Phase 5 — Verify

### 5.1 SMB connectivity from a Mac

User runs from a Mac client:

```
# Finder → Go → Connect to Server → smb://rango.local/io
# enter io's SMB password
```

**Expect:** mount succeeds, files visible, ownership intact when viewed
via Terminal `ls -le` on the Mac.

### 5.2 SSH from a workstation

```
ssh io@rango.local
```

**Expect:** login succeeds with the preserved Unix password.

### 5.3 File ownership audit

On rango:

```sh
find /jeff/home -maxdepth 2 -uid 0 ! -path "*/migration-2026-05/*" 2>/dev/null
find /jeff/home -maxdepth 2 -uid -1 ! -path "*/migration-2026-05/*" 2>/dev/null
```

**Expect:** no output (nothing owned by root or by missing UIDs in user
homes). If anything turns up, UIDs are misaligned.

### 5.4 ACL spot-check

```sh
ls -le /jeff/home/io | head
ls -le /jeff/home/projects | head 2>/dev/null
```

**Expect:** ACLs reference users by name (resolved via UID lookup), not
numeric. If you see numeric UIDs in ACL listings, the user accounts
weren't created with the right UIDs in Phase 4.3.

**Halt and report. User must declare success before Phase 6.**

---

## Phase 6 — Cleanup and harden

**Gate:** Phase 5 verification passed. Migration is functionally
complete.

### 6.1 Reclaim the old TrueNAS boot mirror

After at least 24 hours of confirmed stable operation:

```sh
# Confirm boot-pool is still importable (sanity check)
zpool import   # should list boot-pool

# Destroy it
zpool import -f boot-pool
zpool destroy boot-pool

# Wipe partition tables on ada0 and ada3
gpart destroy -F ada0
gpart destroy -F ada3
```

### 6.2 Add ada0 + ada3 as mirror legs to zroot

This restores boot-disk redundancy:

```sh
# Partition ada0 to match ada4's boot layout
gpart create -s gpt ada0
# (mirror the partitioning of ada4 — see `gpart show ada4`)
# This is delicate; the user should review or do this step themselves.
```

(This subphase is not safe for autonomous execution. Hand off to user.)

### 6.3 Schedule auto-snapshots

```sh
# Install zfs-auto-snapshot or write a periodic-style cron equivalent
pkg install -y zfs-snapshot-mgmt   # or similar
```

Set retention: hourly × 24, daily × 30, monthly × 12 on `jeff/home` and
`jeff/octanix_git`. Skip `jeff/video` (large + low-change).

### 6.4 Migration directory cleanup

After 30 days of stable operation:

```sh
# All Phase 1 artifacts can go
rm -rf /jeff/migration-2026-05
zfs destroy jeff@pre-migration-*
zfs destroy jeff@imported-*
```

### 6.5 Update zed and other downstream code

- `zed/specs/execution-plan.md` — replace `/mnt/jeff/...` with `/jeff/...`
- iteration plan decision #9 ("drop iocage after pilot migration of
  plausible") — mark as completed
- Any client config (Mac mounts, etc.) referencing
  `\\MR_RANGO\<share>` continues to work — no client-side changes.

---

## Appendix A — Pre-migration cleanup (standalone, BEFORE Phase 1)

If user has not already run these, they may be run as part of
preflight cleanup. Each is destructive.

### A.1 Drop all iocage jails

```sh
iocage list                        # confirm what's there
iocage stop -a                     # stop all running
iocage destroy -f plausible
iocage destroy -f zed-agent-1
zfs list -r jeff/iocage            # what's still there?
zfs destroy -r jeff/iocage         # destroy all iocage datasets
```

### A.2 Drop all time machines

```sh
# In TrueNAS UI: Sharing → SMB → delete every share under
# /mnt/jeff/timemachines/* — OR:
service samba_server stop
zfs destroy -r jeff/timemachines
service samba_server start
```

---

## Appendix B — Rollback paths by phase

| Phase reached | If something goes wrong | Recovery |
|---|---|---|
| 0 | nothing destructive run | n/a |
| 1 | snapshots created, no destruction | discard snapshots if desired |
| 2 | install in progress | abort install; reboot from ada0 → TrueNAS |
| 2 (post-install) | FreeBSD 15 installed but not booted | BIOS boot ada0 → TrueNAS |
| 3 (pool imported) | jeff visible on FreeBSD 15 | export jeff, shutdown, boot ada0, jeff comes up under TrueNAS |
| 4 (Samba misconfig) | SMB broken, Unix files fine | rollback to `jeff@imported-<ts>` snapshot, re-do Phase 4 |
| 5 (verification fails) | clients can't connect | export jeff, boot ada0, debug from TrueNAS side |
| 6 (boot mirror destroyed) | last-resort fallback gone | full restore from offsite (or none if no offsite) |

The phase-2-through-5 rollback path **never touches jeff destructively**.
Only Phase 6.1 (boot-pool destroy) is irreversible w.r.t. the rollback.

---

## Appendix C — What this runbook deliberately does NOT do

- Configure WebUI / management interface (TrueNAS replacement)
- Set up auto-snapshots in WebUI form (Phase 6.3 handles via cron)
- Replicate to remote (no offsite was specified)
- Configure email alerts
- Set up monitoring / Grafana / Prometheus
- Reconstruct iocage jails on the new system (decision: dropped)
- Reconstruct Time Machine SMB shares (decision: dropped)

If any of these are needed later, they are post-migration enhancements,
not blockers.
