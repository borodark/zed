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

## Hardware as inventoried 2026-05-09

| Device | Model | Form / location | Role |
|---|---|---|---|
| **ada0** | Kingston SA400S37120G (s/n `50026B76822C9F86`) | 2.5" SATA, **bay 1** | boot-pool leg 1 |
| **ada1** | Seagate ST4000VN006 (s/n `ZW635XY3`) | 3.5" SATA, jeff data | jeff |
| **ada2** | WD WD6001F4PZ (s/n `WD-WXA1D6542DPN`) | 3.5" SATA, jeff data | jeff |
| **ada3** | SanDisk X400 M.2 2280 128G (s/n `163960427178`) | **M.2 on aftermarket adapter** (NOT in a sled bay) | boot-pool leg 2 |
| **ada4** | Kingston SUV500120G (s/n `50026B778216D2B7`) | 2.5" SATA, currently in **bay 4** | **FreeBSD 15 install target** |
| da0–da3 | (4 × ~3.6T on PCIe SAS HBA) | not in front bays | jeff |

**Critical sled identification** — two 120G Kingston 2.5" SSDs in the
chassis. Distinguish by the model number printed on the drive label:

| Sled to PULL (ada0) | Sled to MOVE (ada4) |
|---|---|
| Model: **SA400S37120G** | Model: **SUV500120G** |
| Serial: 50026B76822C9F86 | Serial: 50026B778216D2B7 |
| Family: A400 | Family: UV400/500 |

Migration writes only to ada4 during install. The boot-pool legs (ada0
+ ada3) are intentionally rendered non-bootable for Phase 2 and
remain available for rollback (ada0 set aside, ada3 ESP wiped with a
backup we can restore).

## Migration scope (after user decisions, revised 2026-05-09)

| Bucket | Size | Action |
|---|---|---|
| `jeff/home` | 622G | preserve |
| `jeff/video` | 312G | preserve |
| `jeff/timemachines/*` | 566G | **preserve** (decision reversed; keep TM) |
| `jeff/iocage/*` | 8.16G | **preserve** (decision reversed; install py39-iocage on FreeBSD 15) |
| `jeff/octanix_git`, `jeff/S3`, `jeff/agent1`, `jeff/zed-test`, `jeff/zed-dev` | <30M | preserve |
| `jeff/.system/samba4/{private,registry.tdb,*.tdb}` | 1.49M | **extract before drop** (SIDs + share defs) |
| `jeff/.system/*` (other) | ~211M | drop (TrueNAS middleware artifacts) |

**Total preserve: ~1.50 TB.** No bucket destroyed pre-migration.

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

### 0.4 Verify timemachines + iocage state

Per scope decision (2026-05-09): **both stay**. This step confirms
they're present and identifies running jails so Phase 4 knows what to
re-discover.

```sh
zfs list -r jeff/timemachines 2>/dev/null
zfs list -r jeff/iocage 2>/dev/null
iocage list 2>/dev/null   # NOTE: may return empty; iocage state DB drift
jls                       # authoritative — kernel view of running jails
```

**TrueNAS quirk:** `iocage list` (Python wrapper) often returns empty
even when jails are running because the WebUI starts jails through
`service ix-iocage` rather than `iocage start`, and the Python state
DB doesn't sync. Use `jls` for ground truth.

Expected on rango (verified 2026-05-09):

| Jail | JID | Path |
|---|---|---|
| `plausible` | 3 | `/mnt/jeff/iocage/jails/plausible/root` |
| `zed-agent-1` | 5 | `/mnt/jeff/iocage/jails/zed-agent-1/root` |

Phase 4 will install `py39-iocage` on FreeBSD 15 and re-discover both.

### 0.5 Locate Samba state directory

```sh
ls -la /var/db/system/samba4/private/ 2>/dev/null
ls -la /var/db/system/samba4/ 2>/dev/null
sqlite3 -header -column /data/freenas-v1.db \
  "SELECT cifs_name, cifs_path, cifs_purpose, cifs_browsable, cifs_ro, cifs_timemachine, cifs_enabled FROM sharing_cifs_share;" \
  2>/dev/null
```

**TrueNAS uses `/var/db/system/samba4/`** (not the upstream Samba
default `/var/db/samba4/`). Critical files:

| File | Purpose |
|---|---|
| `private/passdb.tdb` | NT password hashes + per-user SIDs |
| `private/secrets.tdb` | machine SID + LDAP secrets |
| `private/netlogon_creds_cli.tdb` | netlogon |
| `registry.tdb` | share definitions (registry-shares mode) |
| `account_policy.tdb` | password policy |
| `group_mapping.tdb` | NT group → Unix group mapping |
| `share_info.tdb` | per-share NT permissions |
| `winbindd_idmap.tdb` | UID ↔ SID mapping |

**TrueNAS architecture caveat:** `testparm`, `net`, `pdbedit`, and
`midclt` binaries are unlinked after the daemons launch (NanoBSD-style
overlay design). They're NOT available in any non-interactive shell.
Use the **middleware DB** (`/data/freenas-v1.db`, sqlite) as the
source of truth for share definitions instead — it has clean,
human-readable rows in `sharing_cifs_share`.

Expected share rows on rango (verified 2026-05-09):

| Share | Path | TrueNAS preset | TM? |
|---|---|---|---|
| `home` | `/mnt/jeff/home` | PRIVATE_DATASETS | no |
| `video` | `/mnt/jeff/video` | MULTI_PROTOCOL_NFS | no |
| `timemachines` | `/mnt/jeff/timemachines` | ENHANCED_TIMEMACHINE | yes |

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

### 1.4 Extract Samba state directory (CRITICAL — preserves SIDs)

TrueNAS path: `/var/db/system/samba4/` (verified Phase 0.5).

```sh
mkdir -p /mnt/jeff/migration-2026-05/samba-state

# Copy preserving permissions, timestamps, ownership
cp -a /var/db/system/samba4/. /mnt/jeff/migration-2026-05/samba-state/

# Verify the critical tdbs are present
ls -la /mnt/jeff/migration-2026-05/samba-state/private/ | grep -E "passdb|secrets|netlogon"
ls -la /mnt/jeff/migration-2026-05/samba-state/registry.tdb
ls -la /mnt/jeff/migration-2026-05/samba-state/group_mapping.tdb \
       /mnt/jeff/migration-2026-05/samba-state/account_policy.tdb \
       /mnt/jeff/migration-2026-05/samba-state/share_info.tdb
```

**Expect:** `private/passdb.tdb`, `private/secrets.tdb`, plus
`registry.tdb`, `group_mapping.tdb`, `account_policy.tdb`,
`share_info.tdb` at the top level of `samba-state/`.

`passdb.tdb` + `secrets.tdb` carry the machine SID and NT password
hashes — Phase 4 imports them verbatim into the new system's
`/var/db/samba4/private/`. `registry.tdb` is reference-only on the new
system (we hand-write `smb4.conf` instead — Phase 4.6).

### 1.5 Document share definitions (from middleware DB)

`testparm`, `net`, `pdbedit`, and `midclt` binaries are unlinked under
TrueNAS's NanoBSD overlay (verified Phase 0.5) — we cannot invoke
them. The middleware DB is the authoritative source for share defs:

```sh
sqlite3 -header -column /data/freenas-v1.db \
  "SELECT cifs_name, cifs_path, cifs_purpose, cifs_browsable, cifs_ro, cifs_timemachine, cifs_enabled FROM sharing_cifs_share;" \
  > /mnt/jeff/migration-2026-05/smb-shares-truth.txt

# Also dump any TrueNAS-specific SMB options (auxsmbconf) per share:
sqlite3 -header /data/freenas-v1.db \
  "SELECT cifs_name, cifs_auxsmbconf FROM sharing_cifs_share WHERE cifs_auxsmbconf != '';" \
  >> /mnt/jeff/migration-2026-05/smb-shares-truth.txt

# Snapshot the full middleware DB for offline reference
cp /data/freenas-v1.db /mnt/jeff/migration-2026-05/truenas-middleware-db.sqlite

# Snapshot the running smb4.conf even though it's mostly auto-generated
cp /usr/local/etc/smb4.conf /mnt/jeff/migration-2026-05/smb4.conf.truenas-generated
```

This is the source-of-truth for Phase 4.6, which hand-writes a new
`smb4.conf` with explicit `[home]`, `[video]`, `[timemachines]`
sections (no `include = registry`).

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

## Phase 2 — Install FreeBSD 15 onto ada4 (in-place, no install media)

**Constraint that drives this phase:** rango is a Mac Pro 2008 with
**no GPU installed**. Apple EFI's interactive boot picker (Option key)
is invisible. `bsdinstall`'s TUI cannot run without a display. So we
do *not* boot from a USB install stick. Instead we install FreeBSD 15
**from the running TrueNAS shell**, mounting the FreeBSD 15 ISO
locally and pointing `bsdinstall script` at it.

The disk swap is the only step that requires hands on the chassis.

### 2.0 Verify ISO present and integrity

```sh
ls -la /mnt/jeff/home/io/installs/FreeBSD-15.0-RELEASE-amd64-dvd1.iso
sha256 /mnt/jeff/home/io/installs/FreeBSD-15.0-RELEASE-amd64-dvd1.iso
# Expect: 8cf8e03d8df16401fd5a507480a3270091aa30b59ecf79a9989f102338e359aa
```

### 2.1 Pre-shutdown software prep — neutralise ada3 boot path

Apple EFI scans every disk for a bootable ESP. To guarantee EFI picks
ada4 after the bay swap, ada3's ESP is wiped before we shut down.
Backed up first so rollback is one `dd` away.

```sh
# Back up ada3's ESP (260M, plenty of room)
sudo dd if=/dev/ada3p1 of=/mnt/jeff/migration-2026-05/ada3-esp-backup.img bs=1M
ls -la /mnt/jeff/migration-2026-05/ada3-esp-backup.img

# Detach ada3 from boot-pool so wiping its ESP doesn't trigger pool errors
sudo zpool detach boot-pool ada3p2

# Verify boot-pool is now ONLINE-degraded with only ada0p2
sudo zpool status boot-pool

# Wipe ada3's ESP — first 2 MiB is enough to invalidate the FAT header
sudo dd if=/dev/zero of=/dev/ada3p1 bs=1M count=2

# Confirm: gpart still shows the partition layout but the ESP is empty
sudo gpart show ada3
```

### 2.2 Mount the FreeBSD 15 ISO

```sh
sudo mdconfig -a -t vnode -f /mnt/jeff/home/io/installs/FreeBSD-15.0-RELEASE-amd64-dvd1.iso -u 0
sudo mkdir -p /mnt/iso
sudo mount -t cd9660 -o ro /dev/md0 /mnt/iso

# Confirm
ls /mnt/iso/usr/freebsd-dist/ | head
# Expect: base.txz, kernel.txz, MANIFEST, src.txz (we only need base + kernel)
```

### 2.3 Wipe ada4 to a known state

```sh
# If ada4 has any partitioning (it had a stale Linux MBR), clear it
sudo gpart destroy -F /dev/ada4 2>/dev/null
sudo dd if=/dev/zero of=/dev/ada4 bs=1M count=2

# Verify clean
sudo gpart show ada4 2>&1
# Expect: "gpart: No such geom: ada4."
```

### 2.4 Run bsdinstall in script mode targeting ada4 with GPT labels

Drop the install spec to a file. Note the `PARTITIONS` line uses GPT
**labels** (third field per partition: `rango-esp`, `rango-swap`,
`rango-zfs`) so all subsequent references are device-name-independent.

```sh
sudo tee /tmp/install.sh > /dev/null <<'INSTALL_SCRIPT'
DISTRIBUTIONS="kernel.txz base.txz"
PARTITIONS="ada4 GPT { 200M efi rango-esp, 4G freebsd-swap rango-swap, auto freebsd-zfs rango-zfs }"
HOSTNAME="rango"

#!/bin/sh
# This second part runs in the chroot of the new system, post-extract.

# Identity + network
sysrc hostname="rango"
sysrc ifconfig_DEFAULT="DHCP"
sysrc sshd_enable="YES"
sysrc zfs_enable="YES"

# fstab uses GPT labels (stable across device renaming)
cat > /etc/fstab <<FSTAB
# Device              Mountpoint    FStype    Options       Dump  Pass#
/dev/gpt/rango-esp    /boot/efi     msdosfs   rw,noatime    0     0
/dev/gpt/rango-swap   none          swap      sw            0     0
FSTAB

# Root password — console-rescue only; SSH is key-only (see below)
echo '1010' | pw usermod root -h 0

# SSH key authorization for root (the migration controller's pubkey)
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<KEYS
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKRlRm8ztYu9FC7ooGVKGgF2H/Uo/CG54TyMb1hYj0j7 igor@octanix.com
KEYS
chmod 600 /root/.ssh/authorized_keys

# sshd: key-only for root (1010 is too weak for password SSH)
sed -i '' -e 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i '' -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Bootstrap pkg so we can install Samba + iocage in Phase 4 over SSH
env ASSUME_ALWAYS_YES=yes pkg bootstrap

# Note: do NOT pre-create user io here. Phase 4.3 creates io/jo/po/vo/git
# with their correct home dirs under /jeff/home/<user>, which can only be
# done after Phase 3 imports jeff. SSH key on root is the path in until then.
INSTALL_SCRIPT

# Run it
sudo env BSDINSTALL_DISTDIR=/mnt/iso/usr/freebsd-dist \
         bsdinstall script /tmp/install.sh
```

`bsdinstall script`:
1. Creates GPT on ada4 with three labelled partitions
2. Formats ESP as FAT32, freebsd-zfs partition as ZFS (`zroot` pool, single-device stripe)
3. Extracts `base.txz` + `kernel.txz` from `/mnt/iso/usr/freebsd-dist/`
4. Mounts ESP, copies `loader.efi` → `/EFI/FreeBSD/loader.efi` AND `/EFI/BOOT/BOOTX64.EFI` (the EFI-spec fallback path Apple EFI honors)
5. Runs the embedded post-install shell block in the chroot
6. Unmounts and exports zroot

### 2.5 Verify the install

```sh
# Pool was exported by bsdinstall — re-import RO to inspect, then export again
sudo zpool import -o readonly=on -R /tmp/check zroot
sudo zfs list -o name,used,mountpoint -r zroot

# Critical EFI files
ls -la /tmp/check/boot/efi/EFI/BOOT/BOOTX64.EFI       # the Apple-EFI-honored fallback
ls -la /tmp/check/boot/efi/EFI/FreeBSD/loader.efi      # FreeBSD's own path

# Network + SSH config landed
grep -E "hostname|ifconfig|sshd" /tmp/check/etc/rc.conf
grep -E "PermitRootLogin|PasswordAuthentication" /tmp/check/etc/ssh/sshd_config

# SSH key authorization
cat /tmp/check/root/.ssh/authorized_keys
ls -la /tmp/check/root/.ssh/

# fstab uses GPT labels (the whole point of this exercise)
cat /tmp/check/etc/fstab

# Export cleanly so Phase 2.7 can boot from this disk
sudo zpool export zroot
sudo umount /mnt/iso
sudo mdconfig -d -u 0
```

If any check fails, **do not shut down** — fix from TrueNAS first.

### 2.6 Shutdown rango

```sh
ssh root@192.168.0.33 'shutdown -p now'
```

The SSH session disconnects when the network goes down (~5 sec before
poweroff). Wait 30 seconds for the front power LED to go fully dark.

### 2.7 Physical bay swap (case open, rango fully off)

Mac Pro 2008 internal SATA bays — front, behind side panel:

| Bay | Currently holds | After swap |
|---|---|---|
| 1 | ada0 (Kingston SA400 — TrueNAS boot) | **ada4 (Kingston SUV500 — FreeBSD)** |
| 2 | ada1 (Seagate ST4000 — jeff) | unchanged |
| 3 | ada2 (WD WD6001 — jeff) | unchanged |
| 4 | ada4 (Kingston SUV500 — install target) | empty |

Ops:

1. Open side panel (lever on back of chassis).
2. **Pull the bay 1 sled** (Kingston SA400, model `SA400S37120G`,
   serial `50026B76822C9F86`). Label "**ada0 — TrueNAS rollback —
   was bay 1**" with masking tape. Set aside.
3. **Pull the bay 4 sled** (Kingston SUV500, model `SUV500120G`,
   serial `50026B778216D2B7`). This is ada4 with the FreeBSD install
   we just did.
4. **Insert the SUV500 sled into bay 1.** Same drive, new bay.
5. Bay 4 left empty (rollback could put ada0 back here, but standard
   rollback puts ada0 back in bay 1).
6. Confirm jeff data disks (bay 2 and 3, the heavy 3.5") and the M.2
   ada3 (NOT in any sled bay — on its aftermarket adapter) are
   undisturbed.
7. Close case.

**Why move ada4 to bay 1:** Apple EFI scans the motherboard SATA
controller in port-number order. Bay 1 is port 0 — first thing EFI
sees. With ada4 in bay 1 and ada3's ESP wiped, **ada4 is unambiguously
the first (and only) bootable ESP**. No reliance on EFI's behavior
when scanning past empty/non-bootable bays.

### 2.8 Power on and verify

Press the front power button.

What you cannot see (no GPU): Apple EFI POST → finds ada4 in bay 1
→ loads `/EFI/BOOT/BOOTX64.EFI` → FreeBSD's loader runs → kernel boots
→ DHCP → sshd.

From your laptop, watch for ping then SSH:

```sh
# Should land within 60-90 sec
while ! ping -c 1 -W 2 192.168.0.33 > /dev/null 2>&1; do
  echo "$(date) — no response yet, waiting..."
  sleep 10
done
echo "ping OK at $(date)"

while ! nc -z -w 2 192.168.0.33 22 > /dev/null 2>&1; do
  echo "$(date) — port 22 not open yet"
  sleep 5
done
echo "SSH ready at $(date)"

# Clear stale TrueNAS host key, reconnect
ssh-keygen -R 192.168.0.33
ssh root@192.168.0.33 'uname -a; hostname; zpool list; gpart show'
```

Expected first SSH:
- `uname -a` → `FreeBSD rango 15.0-RELEASE`
- `zpool list` → only `zroot` (jeff is Phase 3)
- `gpart show` → ada4 (or whatever it numbers as now) shows the
  three labelled partitions

### 2.9 Failure modes and rollback

| Symptom | Diagnosis | Recovery |
|---|---|---|
| No ping after 5 min | Apple EFI didn't find a bootable ESP, or FreeBSD bootloader hung at early boot | Long-press front power 10 sec to force off; pull the SUV500 sled from bay 1; re-seat ada0 in bay 1 (and put SUV500 back in bay 4 if you want); from TrueNAS shell after it boots: `dd if=/mnt/jeff/migration-2026-05/ada3-esp-backup.img of=/dev/ada3p1 bs=1M` then `zpool attach boot-pool ada0p2 ada3p2` |
| Ping responds but no SSH after 5 min | sshd didn't start, or wrong NIC came up | Same rollback (no easy diagnosis without console) |
| Wrong IP responds | DHCP gave a different lease | `nmap -sn 192.168.0.0/24` from your laptop, or check router's lease table |
| SSH responds with old host key warning | Expected — rango has a fresh host key | `ssh-keygen -R 192.168.0.33` then re-SSH |

The phase-2 rollback **never touches jeff destructively**. ada0
preserved as the SA400 sled, ada3 ESP preserved as a 260M dd image on
jeff. Restoring both is two commands plus a sled re-seat.

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
artifacts. The Samba state is already preserved in
`/jeff/migration-2026-05/samba-state/`.

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
pkg install -y bash zsh sudo doas samba422 vim git py39-iocage avahi-app netatalk3
```

Notes:
- **samba422**: substitute the current Samba 4.x version as available in
  pkg (2026-05: samba422 is current).
- **py39-iocage**: required for jail re-discovery in 4.10. The legacy
  iocage-managed datasets under `jeff/iocage` will be re-imported as
  Bastille adoption is the long-term path (see iteration plan #9), but
  for migration parity we keep iocage running on FreeBSD 15.
- **avahi-app**: needed for SMB/AFP mDNS advertising (so Macs see
  `rango._smb._tcp.local`).
- **netatalk3**: only if AFP shares are needed alongside SMB. Drop if
  no AFP clients exist (likely the case — Apple deprecated AFP in
  macOS 11). Skip unless verified needed.

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

### 4.5 Import Samba state (preserves SMB SIDs and hashes)

Source on backup: `/jeff/migration-2026-05/samba-state/` (TrueNAS used
`/var/db/system/samba4/` — non-default path).

Destination on FreeBSD 15: `/var/db/samba4/` (Samba 4.22 default).

```sh
# Stop Samba if it auto-started after pkg install
service samba_server stop 2>/dev/null

# Confirm destination Samba's expected private dir
testparm -s 2>/dev/null | grep -i "private dir" || echo "default: /var/db/samba4/private"

# Restore the private dir (passdb, secrets, netlogon)
mkdir -p /var/db/samba4/private
cp -a /jeff/migration-2026-05/samba-state/private/. /var/db/samba4/private/

# Restore the top-level state tdbs (group_mapping, account_policy,
# share_info, winbindd_idmap). Skip registry.tdb — Phase 4.6 writes
# shares as flat sections instead.
for tdb in group_mapping.tdb account_policy.tdb share_info.tdb winbindd_idmap.tdb; do
  cp -a "/jeff/migration-2026-05/samba-state/${tdb}" "/var/db/samba4/${tdb}" 2>/dev/null
done

# Verify the SID-bearing tdbs landed
ls -la /var/db/samba4/private/passdb.tdb /var/db/samba4/private/secrets.tdb

# Permissions (Samba refuses to start if these are wrong)
chown -R root:wheel /var/db/samba4/private
chmod 600 /var/db/samba4/private/*.tdb
chmod 700 /var/db/samba4/private
chmod 600 /var/db/samba4/*.tdb 2>/dev/null
```

### 4.6 Hand-write smb4.conf with flat share sections

Reference: `/jeff/migration-2026-05/smb-shares-truth.txt` (middleware
DB extract) and `/jeff/migration-2026-05/smb4.conf.truenas-generated`.

**Decision (2026-05-09):** explicit flat sections, NOT
`include = registry`. Reasons: auditable in git, diffable, no binary
tdb dependency for share definitions. The imported `registry.tdb` from
4.5 is reference-only.

**NetBIOS naming:** TrueNAS used `workgroup = LOCAL` and
`netbios name = mr_rango` (lowercase). Existing client mounts are
written against `\\MR_RANGO\<share>` — Samba is case-insensitive on
NetBIOS so either case works. Keep `mr_rango` for continuity.

Create `/usr/local/etc/smb4.conf`:

```ini
[global]
    workgroup = LOCAL
    netbios name = mr_rango
    netbios aliases = MR_RANGO
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
    max log size = 2048
    log level = 1
    logging = syslog@1 file

    # SMB protocol — match TrueNAS hardening
    server min protocol = SMB2
    max protocol = SMB3
    server signing = mandatory
    smb encrypt = required

    # Performance
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536
    use sendfile = yes
    min receivefile size = 16384
    aio read size = 16384
    aio write size = 16384
    large readwrite = yes
    deadtime = 15

    # Locking — TrueNAS settings
    oplocks = yes
    kernel oplocks = yes
    posix locking = no
    strict allocate = yes
    sync always = yes

    # Disable NFS-style ACE conversion under fruit (TrueNAS default)
    fruit:nfs_aces = no

    # Username map (carry over from TrueNAS — empty file is fine)
    username map = /usr/local/etc/smbusername.map

    # Misc
    load printers = no
    printing = bsd
    disable spoolss = yes
    dns proxy = no
    restrict anonymous = 2
    obey pam restrictions = yes
    unix extensions = no
    bind interfaces only = yes
    interfaces = lo0 igb0   # adjust if NIC name differs after install

# ----- home: PRIVATE_DATASETS preset -----
# Per-user subdirectories. Each user sees only their own /jeff/home/<user>.
[home]
    path = /jeff/home/%U
    browseable = yes
    read only = no
    valid users = io, jo, po, vo, git, @ostens
    inherit acls = yes
    inherit owner = yes
    create mask = 0664
    directory mask = 0775

# ----- video: MULTI_PROTOCOL_NFS preset -----
# Coexists with NFS access; avoids Apple-only attributes.
[video]
    path = /jeff/video
    browseable = yes
    read only = no
    valid users = @ostens, @engineers, @media
    inherit acls = yes
    inherit owner = yes
    # No fruit module — keeps NFS clients happy.

# ----- timemachines: ENHANCED_TIMEMACHINE preset -----
# Apple Time Machine over SMB. Per-user subdirectories under
# /jeff/timemachines/<user>/. Apple's TM client expects the share root
# to contain the per-user dir.
[timemachines]
    path = /jeff/timemachines/%U
    browseable = yes
    read only = no
    valid users = io, jo, po, vo
    inherit acls = yes
    inherit owner = yes
    # Apple-specific VFS modules
    vfs objects = zfsacl fruit streams_xattr
    fruit:time machine = yes
    fruit:time machine max size = 1T
    fruit:metadata = stream
    fruit:resource = stream
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    # TM requires durable handles + posix locking off
    durable handles = yes
    kernel oplocks = no
    posix locking = no
    strict locking = no
    # Required by macOS for stable TM operation
    ea support = yes
```

Test the config (Samba 4.22 has `testparm` in `/usr/local/bin/`):

```sh
testparm -s
```

**Expect:** no errors, no warnings about unknown parameters, share list
shows `home`, `video`, `timemachines`. If `testparm` complains about
`interfaces = ... igb0`, list actual interfaces with `ifconfig` and
substitute.

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
captured baseline (`/jeff/migration-2026-05/preflight/` notes from
Phase 0.5: `S-1-5-21-1802559556-342626866-2594444652-{1001,1002,1004,1012}`
for io, jo, po, vo respectively). If SIDs differ, the tdb import did
not take effect — re-check 4.5.

### 4.10 Re-discover iocage jails

```sh
# iocage scans the existing jeff/iocage/* datasets and rebuilds its DB
iocage activate jeff
iocage list
```

**Expect:** `plausible` and `zed-agent-1` listed as STOPPED. Start
each:

```sh
iocage start plausible
iocage start zed-agent-1
iocage list   # both should show RUNNING with their JIDs
jls
```

If a jail's RELEASE base (e.g. `13.5-RELEASE`) is incompatible with
FreeBSD 15's host kernel ABI, the jail will fail to start. FreeBSD 15
generally maintains backward jail-ABI for one major version (so 14.x
jails work; 13.x jails *may* need `compat10x`/`compat11x`/`compat12x`/
`compat13x` packages or a release upgrade inside the jail). For
rango's jails:

| Jail | Base RELEASE | Action if start fails |
|---|---|---|
| `plausible` | check `iocage list -l` | `pkg install -y compat13x compat12x` on host |
| `zed-agent-1` | 13.5-RELEASE | install compat libs, or upgrade inside jail to 14.x |

If a jail won't start cleanly, mark it as a follow-up rather than a
Phase 4 blocker. The jail's data on jeff is intact; it can be revived
later or migrated to Bastille (per iteration plan #9).

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

## Appendix A — Optional teardown (NOT part of the migration plan)

The current scope (revised 2026-05-09) **preserves** both
`jeff/timemachines/*` and `jeff/iocage/*`. These commands are kept
here for reference only — run them only if a future cleanup decides
to drop one or both.

### A.1 Drop all iocage jails

iocage state DB on TrueNAS is often out of sync with `jls` (the
Python wrapper doesn't see jails started via WebUI middleware). Use
`jail -r <jid>` for stop, then ZFS for cleanup:

```sh
jls   # find JIDs of running jails (see Phase 0.4 for current values)
jail -r 3   # plausible (use actual JID from jls)
jail -r 5   # zed-agent-1
jls         # confirm both gone

# ZFS-level cleanup — handles everything iocage did or didn't manage
umount /mnt/jeff/iocage/jails/plausible/root 2>/dev/null
umount /mnt/jeff/iocage/jails/zed-agent-1/root 2>/dev/null
zfs destroy -r jeff/iocage
```

### A.2 Drop all time machines

The TrueNAS WebUI cleanly: Sharing → SMB → delete every share under
`/mnt/jeff/timemachines/*`, then in shell:

```sh
zfs destroy -r jeff/timemachines
```

Or CLI-only (skips WebUI; disconnects any in-flight TM clients):

```sh
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
- Migrate iocage jails to Bastille (long-term plan per iteration plan
  decision #9 — for migration parity, jails stay on iocage)

If any of these are needed later, they are post-migration enhancements,
not blockers.
