# A5a — Privilege boundary, audit log, and step-up auth

**Status:** speculative; companion to `a5-bastille-plan.md`. No code yet.
**Effort:** ~3.5 pm across A5a / A5b / A5c.
**Why now:** the iteration so far has assumed a single-user, fully-trusted host with passwordless escalation and the BEAM running as root-equivalent. That posture is fine for laptop dev and lab smoke tests; it is **not** acceptable in any deployment a security review will touch. This document names every shortcut we've taken, defines the production-tolerable shape that replaces it, and orders the work that gets us there.

---

## Decisions locked 2026-04-25

| # | Decision | Value |
|---|---|---|
| 12 | Privilege boundary | **Two-user split.** `zedweb` runs the Phoenix endpoint with no privileged capabilities. `zedops` runs the converge engine with narrowly-scoped capabilities. They communicate over a Unix-domain socket with `SO_PEERCRED` checks. |
| 13 | Capability scope | **Per-verb, per-target doas rules**, not `cmd bastille`. Rules cover create / start / stop / cmd; destroy / rotate / factory-reset require a separate, password-gated rule that is invoked only after step-up auth. |
| 14 | Step-up auth for destructive operations | LiveView session alone is **insufficient** for destroy / rotate / factory-reset / delete-paired-device. Requires fresh re-auth (password, passkey, or YubiKey touch) within the last 60 s. |
| 15 | Secrets channel | **Never via env vars.** Bootstrap passphrase, `secret_key_base`, etc. accept `--*-fd <N>` or `--*-file <path>` and prefer the file form. The env-var path is retained for tests only. |
| 16 | Audit log | Append-only journal at `<base>/zed/audit.log`, mode 0400, owned by `zedops`. Daily ZFS snapshot of `<base>/zed` makes it tamper-evident. Streams to syslog when configured. |
| 17 | Host setup | Idempotent `scripts/host-bring-up.sh` covers `bastille0`, pf rc.d wiring, `kld_list`, sysrc flags. No "remember to set X" steps in operator runbook. |
| 18 | Tests stop escalating | Integration tests run **as `zedops`**, which holds the narrowly scoped rules. `Zed.Platform.Bastille.privilege_prefix` config (introduced in A5.1) is removed in A5a. No test ever prepends `doas`. |

---

## Threat model — what we are now defending against

| Threat | Today's posture | After A5a |
|---|---|---|
| LiveView controller bug → command injection | Attacker gets root + can `bastille destroy <anything>` | Attacker gets `zedweb`'s read-only view of secrets metadata; cannot escalate without a fresh credential |
| Malicious or compromised browser session | Same web token can destroy a TM-backup dataset | Destructive ops require step-up; stale cookie cannot trigger them |
| Operator's `~/.zsh_history` retention | `ZED_BOOTSTRAP_PASSPHRASE=...` lands in history + ps | Passphrase via fd or 0400 file; nothing on the command line |
| One operator's account compromised on a multi-admin box | Single shared admin password = all-or-nothing | Per-actor identities + audit log isolate the blast radius and produce evidence |
| Forensic / regulatory review | "Whatever Phoenix logged to stdout, plus your shell history" | Append-only journal with ZFS snapshot continuity |
| `cron` script with shell access on the host | Can `doas bastille destroy` silently | doas rules are user- and verb-scoped; cron job must be running as `zedops`-or-broader user, and destroy isn't on the no-prompt list |

This isn't aiming for SOC-2-Type-2-out-of-the-box. It's aiming for "the design itself does not require an apologetic README section."

---

## The privilege boundary

### Two Unix users

| User | Privileges | Owns |
|---|---|---|
| `zedweb` | None beyond reading specific secrets dataset paths and writing the audit log via `zedops` | Phoenix listener socket, session cookies, OTT ETS, paired-device pubkeys |
| `zedops` | Narrowly-scoped doas rules for bastille / zfs / pf verbs. Never login-shell; service account. | Converge engine, the doas/sudoers entries, `<base>/zed/audit.log` (0400 owned by `zedops`) |

Both BEAM (`zedweb`) and a separate BEAM (`zedops`) can be one OTP application started under different users via separate `rc.d` scripts, or a single application with explicit user-switching at startup. **Recommendation: two separate BEAM nodes.** Failure modes in one don't take the other down; the privilege boundary is a process boundary.

### Communication: Unix-domain socket with peer credential check

`zedops` listens on `/var/run/zed/ops.sock`, mode 0660, owner `zedops:zedweb`. `zedweb` connects, sends a length-prefixed binary-encoded request, reads a length-prefixed reply.

Every accept call gets the peer's `getpeereid()` (FreeBSD) and rejects if `uid != zedweb_uid`. No TLS — local socket peer-cred is the auth.

Wire format: Erlang external term (efficient, type-safe, language-binding-free given both ends are BEAM).

```elixir
# Request
{:zedops, :v1, request_id, action, payload, signature}
# action ∈ {:create, :start, :stop, :destroy, :rotate, ...}
# signature ∈ binary() — see "Step-up auth" below

# Reply
{:zedops_reply, request_id, :ok | {:ok, term()} | {:error, term()}}
```

`zedops` verifies the signature *if* the action is on the destructive list, irrespective of who connected — i.e. a compromised `zedweb` cannot forge a destructive request because the signature comes from a fresh re-auth, not from session state.

### Read paths

Most read operations (`bootstrap status`, `list paired devices`, `list audit log tail`) don't need the boundary — `zedweb` reads the JSON files / ZFS properties directly. Anything that mutates state goes through `zedops`.

---

## Capability-scoped doas/sudoers rules

Replace the current `permit nopass :wheel as root cmd bastille` with verb-and-arg-scoped rules. Example for `zedops`:

```
# /usr/local/etc/doas.conf — production posture

# Default: nobody else escalates without password (never use :wheel here).
permit persist root

# zedops: no-prompt for read-only / non-destructive bastille verbs.
permit nopass zedops as root cmd bastille args create
permit nopass zedops as root cmd bastille args start
permit nopass zedops as root cmd bastille args stop
permit nopass zedops as root cmd bastille args restart
permit nopass zedops as root cmd bastille args cmd
permit nopass zedops as root cmd bastille args list
permit nopass zedops as root cmd bastille args rdr
permit nopass zedops as root cmd bastille args network

# zedops: destructive ops require fresh password — UI sends operator's
# password through the signed-request envelope; zedops re-supplies it
# to doas via stdin. Removes the "passwordless destroy" attack vector.
permit zedops as root cmd bastille args destroy
permit zedops as root cmd bastille args export
permit zedops as root cmd bastille args migrate

# zfs / pf: same pattern. Read-only inheritable; mutating verbs gated.
permit nopass zedops as root cmd zfs args list
permit nopass zedops as root cmd zfs args get
permit nopass zedops as root cmd zfs args set
permit zedops as root cmd zfs args destroy
permit zedops as root cmd zfs args rollback

permit nopass zedops as root cmd pfctl args -s
permit zedops as root cmd pfctl args -F
```

`doas` doesn't have full glob matching on args, so for verbs like `bastille args destroy <name>` we either:
- Loosen to `cmd bastille args destroy` (any name) and rely on `zedops` validating the name *before* it shells out, or
- Wrap in a small setuid C helper or a per-action shell script that verifies the name pattern, called via `cmd /usr/local/libexec/zed/destroy-jail`.

**Recommendation:** loosen-with-application-validation for now; revisit if a shim becomes warranted.

### Why not single-user-with-password?

The simpler "run zed as root, demand password for sensitive ops" model fails because:
- A LiveView controller bug that lets an attacker run *any* function in the BEAM still has root.
- Process boundary makes the design auditable: "did the request go through the socket?" is binary; "did Phoenix call the right helper?" requires reading code.

---

## Step-up auth for destructive operations

A logged-in admin session is **necessary** but **insufficient** to destroy datasets or rotate root keys. The user must prove fresh control — within the last 60 s — of one of:

- Password (re-typed in a modal)
- Registered passkey (WebAuthn `get` with `userVerification: "required"`)
- YubiKey / hardware token (touch)

### Protocol sketch

1. User clicks "Destroy dataset X".
2. LiveView shows a modal: "Re-authenticate to confirm."
3. On successful re-auth, LiveView gets back a short-lived **operation token** (signed by `zedops` against the request payload, valid for 60 s, single-use).
4. LiveView pushes the request + token to `zedops` over the Unix socket.
5. `zedops` verifies the token, the timestamp, and the request's fingerprint against the token's payload binding.
6. `zedops` shells out via doas (passing the operator's password to the doas-with-password rule via stdin if doas needs it).
7. `zedops` appends the action to the audit log.

The token's signing key is rotated daily and stored in `<base>/zed/secrets/zedops_step_up.key`, mode 0400 owned by `zedops`. `zedweb` cannot read it. A compromised `zedweb` cannot forge tokens.

---

## Audit log

### Format

JSON-Lines at `<base>/zed/audit.log`. One event per line:

```json
{
  "ts": "2026-04-25T12:34:56.123Z",
  "actor": "admin@operator-pubkey-fingerprint",
  "session": "<session-id-prefix>",
  "action": "destroy",
  "target": "jail/web-1",
  "request_id": "<uuid>",
  "step_up": "passkey:<credential-id>",
  "result": "ok",
  "details": {"snapshot_before": "jeff/zed/web-1@pre-destroy-..."}
}
```

### Tamper-resistance

- File mode 0400, owned by `zedops`. Only `zedops` writes.
- ZFS snapshot of `<base>/zed` taken daily at midnight (zfs auto-snap or by `zedops` itself). Snapshots are immutable; the log's history is anchored.
- Optional: stream events to syslog/SIEM via `Logger.MetaBackend` or direct `:gen_udp` to a syslog server. Configurable per host.

### What goes in

Every mutating operation. Including:
- bastille create / start / stop / destroy / rotate / migrate
- zfs create / destroy / rollback / set on `com.zed:secret.*`
- Admin login (success + failure)
- Passkey register / forget
- Step-up auth attempt (success + failure)
- Secret rotation (which slot, by whom)

Read operations are not logged by default. Optional `audit_reads: true` config for high-paranoia deployments.

---

## Secrets-via-fd / file

### Bootstrap CLI

Today:

```sh
ZED_BOOTSTRAP_PASSPHRASE=<plaintext> zed bootstrap init --base jeff
```

After A5b:

```sh
# Preferred: file (mode 0400, ephemeral)
zed bootstrap init --base jeff --passphrase-file /run/zed-bootstrap-passphrase
shred -u /run/zed-bootstrap-passphrase

# fd form, useful in shell pipelines
echo -n "$pass" | zed bootstrap init --base jeff --passphrase-fd 0

# Env var: still works, with a deprecation warning at startup
ZED_BOOTSTRAP_PASSPHRASE=... zed bootstrap init --base jeff
```

The plaintext does not appear on the command line, doesn't appear in `ps -ef`, and doesn't land in shell history if the operator uses the file form correctly.

### Phoenix `secret_key_base`

Today: `ZED_SECRET_KEY_BASE` env var.

After A5b: `<base>/zed/secrets/secret_key_base` file, generated at bootstrap, mode 0400 owned by `zedweb`. Phoenix reads it at startup. Rotated only on explicit operator command (`zed admin rotate session-key`), all sessions invalidated.

### What stays as env

Only non-secret tunables (port, bind address, log level, profiles).

---

## Multi-admin

### Slot evolution

`admin_passwd` → `admin_users.json`:

```json
{
  "users": [
    {
      "name": "io",
      "argon2": "$pbkdf2-sha256$i=600000$...",
      "role": "owner",
      "passkeys": ["<credential-id-1>", "<credential-id-2>"],
      "ssh_keys": ["sha256:<fingerprint>"],
      "created_at": "2026-04-25T..."
    },
    {
      "name": "alice",
      "argon2": null,
      "role": "operator",
      "passkeys": ["<credential-id-3>"],
      "ssh_keys": [],
      "created_at": "2026-05-..."
    }
  ]
}
```

### Roles

- `owner` — can do anything including manage other users.
- `operator` — can perform converge, snapshot, rotate non-critical slots; cannot destroy datasets containing user data; cannot manage other users.
- `viewer` — read-only audit + status; can register a passkey for self.

### First-boot flow

`zed bootstrap init` creates one `owner` user with the operator-supplied or auto-generated password. Subsequent users registered through the existing owner's session.

### Or: passkeys-only

Skip the password story entirely. First boot generates a one-time enrollment QR; first scan registers the operator as `owner` with a passkey. No password ever exists. Tighter security posture, slightly more friction on first-boot. Recommend this is the *default* mode and password is a fallback enabled by `--allow-password-auth` at bootstrap time.

---

## Host setup as code

Every assumption that today reads like "and then you run this command" becomes a line in `scripts/host-bring-up.sh`:

```sh
#!/bin/sh
# scripts/host-bring-up.sh — idempotent FreeBSD host preparation for a zed deploy.
# Run once as root before zed bootstrap. Self-checks; safe to re-run.
set -eu

# 1. Users
pw groupshow zedweb >/dev/null 2>&1 || pw groupadd zedweb -g 8501
pw groupshow zedops >/dev/null 2>&1 || pw groupadd zedops -g 8502
pw usershow zedweb >/dev/null 2>&1 || pw useradd zedweb -u 8501 -g zedweb -G zedweb -s /sbin/nologin -d /var/db/zed/web -m
pw usershow zedops >/dev/null 2>&1 || pw useradd zedops -u 8502 -g zedops -G zedweb -s /sbin/nologin -d /var/db/zed/ops -m

# 2. Network: bastille0 + cloned_interfaces persist
sysrc cloned_interfaces+=bastille0 >/dev/null
ifconfig bastille0 >/dev/null 2>&1 || ifconfig lo1 create name bastille0

# 3. pf
sysrc kld_list+=pf >/dev/null
sysrc pf_enable=YES pflog_enable=YES pf_load=YES >/dev/null
kldstat -q -n pf.ko || kldload pf
[ -f /etc/pf.conf ] || install -m 0644 docs/pf.conf /etc/pf.conf
service pf start >/dev/null 2>&1 || true

# 4. IPv4 forwarding
sysrc gateway_enable=YES >/dev/null
sysctl net.inet.ip.forwarding=1 >/dev/null

# 5. doas rules
install -m 0600 -o root -g wheel docs/doas.conf.zedops /usr/local/etc/doas.conf
doas -C /usr/local/etc/doas.conf

# 6. Bastille
pkg query %n bastille >/dev/null 2>&1 || pkg install -y bastille
sysrc bastille_enable=YES bastille_zfs_enable=YES bastille_zfs_zpool="${ZED_BASTILLE_ZPOOL:-zroot}" >/dev/null

# 7. Audit log dir
install -d -o zedops -g zedops -m 0700 /var/db/zed
install -d -o zedops -g zedops -m 0700 /var/db/zed/audit

echo "host bring-up complete. zed bootstrap init now runs without further host config."
```

The verify script (`scripts/verify-bastille-host.sh`) becomes "did `host-bring-up.sh` run successfully?" — pass/warn/fail per assertion the bring-up script makes.

---

## Migration from current code

A1, A2a, A2b, A3 already shipped. Refactoring them to fit the new boundary is non-trivial but bounded.

### What changes

- `Zed.Bootstrap.init/2` writes secrets owned by `zedops` (not `root` invoking on behalf of nobody-in-particular).
- `ZedWeb.Endpoint` runs as `zedweb`. Its session cookies and OTT ETS are accessible only to `zedweb`.
- `Zed.Admin.OTT.consume/1` and `Zed.Admin.Passkeys.add/2` are pure read-and-update operations on files / ETS owned by `zedweb` — no privilege escalation needed.
- `Zed.Platform.Bastille` no longer calls `bastille` directly. It builds a `{:create, args}` envelope, sends it over the Unix socket to `zedops`, awaits reply.
- New `Zed.Ops` application — the `zedops` BEAM. Hosts the Unix socket listener, handles bastille / zfs / pf shellouts, owns the audit log writer.

### Backward-compat for the Mac dev boxes

The dev-host `Mac Pro` setups can run `zedops` as the `io` user with the relaxed `permit nopass :wheel as root cmd bastille` rule we already have — A5a's prod posture is opt-in via `ZED_PRIVILEGE_BOUNDARY=enforced` env. Default during development = single-process, no boundary. Production deploy = boundary enforced.

This makes A5a non-blocking for ongoing iteration on the Macs while still landing the architecture for production.

---

## Iteration breakdown

| Sub-step | Scope | Effort |
|---|---|---|
| **A5a.1** | Two-process supervisor split: `Zed.Web` (zedweb) and `Zed.Ops` (zedops) as distinct OTP applications. Single repo, separate releases. | 4 h |
| **A5a.2** | Unix-domain socket protocol: `Zed.Ops.Socket` server + `Zed.Web.OpsClient` client. Erlang term wire format with peer-cred check. | 4 h |
| **A5a.3** | Capability-scoped doas.conf template + `host-bring-up.sh` lays it down idempotently. | 2 h |
| **A5a.4** | `Zed.Platform.Bastille` rewired: production code paths go through OpsClient; tests still use Mock runner unchanged. | 3 h |
| **A5a.5** | Integration test runs as `zedops`, not via `doas`-prefixed adapter. `privilege_prefix` config removed. | 2 h |
| **A5a.6** | Backward-compat shim for dev hosts (`ZED_PRIVILEGE_BOUNDARY=relaxed` keeps single-process behavior). | 2 h |
| **A5b.1** | `--passphrase-fd` + `--passphrase-file` options on `zed bootstrap init`. Env-var path emits deprecation warning. | 2 h |
| **A5b.2** | `secret_key_base` slot; Phoenix endpoint reads from file at startup. | 2 h |
| **A5b.3** | Audit log JSON-Lines writer in `Zed.Ops`. Daily zfs auto-snap of `<base>/zed/audit/`. | 4 h |
| **A5c.1** | LiveView step-up modal component. Re-auth via password / passkey / YubiKey. Issues operation token. | 4 h |
| **A5c.2** | `Zed.Ops` token verification: signed by per-day rotation key, payload-bound, single-use. | 3 h |
| **A5c.3** | `bastille destroy` and slot-rotation flows wired through the step-up path end-to-end. | 3 h |

Total: **~35 h ≈ 2.0 pm of solid work**, broken into three coherent iterations.

---

## What we are deferring (intentionally, with a pointer)

- **Multi-host orchestration** — A5a is single-host. Cluster view is a separate iteration once two zed hosts exist.
- **HSM / TPM-backed signing keys** — operation token signing key lives on disk, mode 0400. Adequate for now; HSM is a phase-2 hardening if anyone cares.
- **Mandatory access control** — no SELinux / Capsicum integration. FreeBSD's MAC framework + Capsicum could box `zedops` further, but the cost-benefit doesn't pencil for first-pass.
- **Replication-aware audit log** — the audit on host A doesn't replicate to host B. When clustering ships, audit replication becomes a property of the cluster protocol.
- **Compliance frameworks** — design supports them; no specific framework gets explicit treatment here.

---

## Acceptance criteria (across A5a / A5b / A5c)

- [ ] `ps -ef` on a live host shows `zedweb` and `zedops` as separate processes owned by separate users.
- [ ] `id zedweb` shows no privileged groups; `doas -C /usr/local/etc/doas.conf` shows zero `permit nopass` rules for `zedweb`.
- [ ] A LiveView controller modified to call `System.cmd("bastille", ["destroy", ...])` directly fails with "permission denied" — proves the boundary holds.
- [ ] `pgrep -f beam.smp | xargs -I{} ps -ouser= {}` shows two distinct users.
- [ ] `zed bootstrap init --base ... --passphrase-fd 0 < passphrase-file` works; `ZED_BOOTSTRAP_PASSPHRASE=... zed bootstrap init` works AND prints a deprecation warning to stderr.
- [ ] `cat <base>/zed/audit.log` shows JSON-Lines, mode 0400 owned by zedops.
- [ ] Destroying a dataset from the LiveView UI requires a re-auth modal; operating with a stale cookie fails closed.
- [ ] Replay of a captured operation token after >60 s fails with `token_expired`.
- [ ] Replay of a consumed token fails with `token_used`.
- [ ] Integration tests run with no `doas` invocations from inside test bodies. `mix test --only bastille_live` runs as `zedops` user.
- [ ] `scripts/host-bring-up.sh` is idempotent: running it twice produces no diffs in `sysrc`, `pw show`, `ifconfig`, or `pf`.

---

## Open questions

1. **Single BEAM with user-switching at startup, or two BEAMs?** Two is cleaner architecturally; one is simpler to deploy. Lean: two, distributed-Erlang between them on a single host (no public ports).
2. **Operation token: per-action or per-session?** Per-action is safer (one token, one destroy, expires). Per-session shorter-window is more usable. Lean: per-action, 60s TTL, single-use.
3. **YubiKey support — first-class or future?** WebAuthn covers it; FIDO2 hardware key registers as a passkey. No separate code path needed. Already covered.
4. **Backwards compat shim — how long?** `ZED_PRIVILEGE_BOUNDARY=relaxed` for at least 6 months after A5a ships, with deprecation warnings escalating in the last 60 days.
5. **Audit log rotation.** Daily snapshot is the tamper-evidence story, but the live file grows unbounded. Truncate / rotate strategy: weekly, tied to snapshot continuity. Detail in A5b.3.

---

## Cross-references

- [a5-bastille-plan.md](a5-bastille-plan.md) — original Bastille adapter plan; A5a hardens its execution layer without changing the adapter's external contract.
- [iteration-plan.md](iteration-plan.md) — to be updated with A5a/A5b/A5c rows after this draft is reviewed.
- [probably_not_secret_plan_i.md / ii.md](../../../.claude/projects/.../probably_not_secret_plan_i.md) — A5a aligns with Plan II's three-tier secret model and tightens the access controls around the slots.
