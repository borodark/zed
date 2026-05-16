# Zed Rotation SOP — Spec

**Status:** draft, 2026-05-16. Triggered by the s6-milestone passphrase
leak audit during the M-I.5 pre-tag review.

**Scope:** a coherent, TLA+-verifiable feature in zed that handles
three distinct key-rotation levels (slot, passphrase, master) with a
clear separation of **leaked**, **lost**, and **scheduled**
triggers. Audit + blast-radius + step-up auth woven through.

---

## Why this is a real feature, not a script

`zfs change-key` is one command. A *rotation SOP* is the entire
pipeline around it: scope assessment, blast-radius lookup, audit
record-before-and-after, consumer restart, post-rotation verify,
and (if leaked) attacker-usage audit. Doing those by hand at 3 AM,
on a compromised host, with adrenaline running, is when mistakes
get made. zed should encode the SOP so the operator only has to
make one decision: which trigger applies.

The 2026 industry constant: automated scanners pick up newly
leaked secrets within seconds; credential abuse starts before
humans notice. The leak ⇒ rotation latency is the critical metric.
([safeguard.sh][1], [GitGuardian SRE playbook][2])

---

## What zed already has

| Primitive | Location | Status |
|---|---|---|
| `Zed.Bootstrap.rotate/3` | `lib/zed/bootstrap.ex:163` | Implemented; slot-level only (beam_cookie, admin_passwd, ssh_host_ed25519). Snapshots pre/post, archives old value, stamps `secret.<slot>.last_rotated_at`. |
| CLI stub `zed bootstrap rotate` | `lib/zed/cli.ex:138` | **Not wired** — prints "not yet implemented in A1." |
| Consumer-restart catalog | `lib/zed/secrets/catalog.ex:6` | Slots declare services that must restart on rotation. |
| Step-up auth for destructive ops | `specs/a5a-privilege-boundary.md:14,60,129` | Speced (60-second fresh re-auth window) — not built. |
| Per-verb doas rules incl. `rotate` action | `specs/a5a-privilege-boundary.md:60,178` | Speced — `cmd rotate` partitioned from `cmd start`. |

What's **missing**:
- Passphrase rotation (the encryption-root wrapping key).
- Master-key rotation (the destructive re-encryption path).
- Unified `zed rotate …` CLI verb.
- TLA+ spec for the rotation state machine.
- Audit log structure.
- Blast-radius enumeration on rotate.

---

## Three levels of rotation

The ZFS encryption architecture has two key layers; zed's secret
slots add a third on top. They have different rotation cost,
different triggers, and different SOPs.

| Level | What rotates | Cost | When to use |
|---|---|---|---|
| **1. Slot** | One value inside the encrypted secrets dataset (a BEAM cookie, an admin password hash, an SSH host key). | Cheap: `zed bootstrap rotate <slot>`; restart that slot's consumers. | A specific service's credential leaked. The dataset's encryption is fine. |
| **2. Passphrase** | The wrapping key (the human-readable passphrase) that decrypts the master key. `zfs change-key`. | Cheap: O(1); no data re-encryption. Re-wraps the master key with a new wrapping key. | Passphrase was leaked but the dataset's bytes weren't exfiltrated. Re-wrapping is effective. |
| **3. Master key** | The data-encryption key itself. Requires `zfs send` to a fresh encryption root + destroy old. | Expensive: O(dataset size) + downtime. | Master key was compromised (attacker had memory dump or full root + bytes-on-disk). Per OpenZFS docs, `zfs change-key` alone is **insufficient** here — old wrapped master key remains on disk and is forensically recoverable, so newly-written data is still encrypted under the compromised key. ([OpenZFS change-key docs][3]) |

**Critical doc-honesty rule for zed:** never let `zed rotate
passphrase` claim to remediate a master-key compromise. The SOP
must surface the distinction at decision time, not bury it.

---

## Three triggers

| Trigger | Definition | Default scope | Audit shape |
|---|---|---|---|
| **leaked** | Operator believes attacker has the value but the system hasn't been observed misusing it yet. | Rotate immediately. Scan logs for the value's use during exposure window. | Incident record with exposure-window timestamps + post-rotation consumer-use audit. |
| **lost** | No human knows the value anymore. Dataset is permanently locked (passphrase) or service can't authenticate (slot). | Passphrase: recovery via Shamir share reassembly (D7) or pre-stashed offline backup. Slot: regenerate from scratch. | Recovery-pathway record. No exposure-window concern — there's no attacker. |
| **scheduled** | Time-based hygiene per policy (e.g., passphrase rotated annually). | Same mechanics as `leaked` but no urgency, no incident record. | Routine-rotation record stamped to `secret.<slot>.next_due_at`. |

The trigger is **the only decision** the operator should have to
make. Everything else is policy-driven from `Zed.Rotation.Policy`.

---

## Proposed module shape

```
lib/zed/
  rotation.ex                       — orchestrator + trigger dispatch
  rotation/
    slot.ex                         — wraps Bootstrap.rotate, adds audit
    passphrase.ex                   — zfs change-key wrapper, audit
    master_key.ex                   — zfs send | recv pipeline; destructive
    policy.ex                       — rotation cadence, allowed-trigger rules
    audit.ex                        — append-only audit log (ZFS-backed,
                                      one file per rotation event)
    blast_radius.ex                 — given a slot/passphrase, list affected
                                      services + restart strategy
    consumer.ex                     — graceful service restart helpers
specs/
  Rotation.tla                      — state-machine spec, invariants below
  Rotation.cfg
```

CLI surface:
```
zed rotate slot <name>       --trigger leaked|lost|scheduled --base <ds>
zed rotate passphrase                                         --base <ds>
zed rotate master            --trigger leaked|scheduled       --base <ds>
zed rotation status                                           --base <ds>
zed rotation history         [--slot <name>]                  --base <ds>
zed rotation policy show
```

---

## TLA+ invariants the spec must prove

The rotation state machine should have these as `INVARIANTS` (and
one liveness property):

1. **NoStaleAuth** — once `rotate` reaches `committed`, the prior
   value cannot authenticate anywhere in the dependency graph.
   (Verifies that all consumers were restarted *before* the old
   value's archival window expires.)
2. **NoCorruptionDuringRotation** — for the passphrase level: at
   every intermediate state, the encrypted dataset is unlockable
   by EITHER the old or the new passphrase, never neither. (zfs
   change-key has this property; we just need to encode it.)
3. **AuditMarkerPaired** — every rotation operation has exactly
   one `rotation_started_at` and one `rotation_completed_at` (or
   `rotation_aborted_at`) record. No half-events in the audit log.
4. **BlastRadiusVisited** — every service in the slot's catalog
   `consumers` list is either restarted or explicitly marked
   `:skipped` with a reason before commit.
5. **NoLatePromotionAfterAbort** — mirrors the HealthCheck spec's
   `NoLatePromotionAfterRollback`. If the rotation is aborted
   mid-pipeline, any in-flight consumer restarts must not see the
   new value committed.

Liveness: **RotationTerminates** — every started rotation reaches
`committed` | `aborted` | `failed` within `max_rotation_time`.

Verification cadence: same model as the HealthCheck spec — N=2,
N=3 in unit tests; one larger N (5+) before tagging.

---

## SOP per trigger × level (the matrix)

|  | Slot | Passphrase | Master key |
|---|---|---|---|
| **leaked** | (1) Audit log start. (2) `Bootstrap.rotate(slot)` — snapshot pre + post. (3) Restart blast-radius consumers. (4) Scan logs for old-value use during exposure window. (5) Audit log commit. | (1) Step-up auth (60s window). (2) Audit start. (3) `zfs change-key`. (4) `zfs unload-key` + `zfs load-key` with new value to verify old no longer works. (5) Audit commit. Old wrapped key still on disk — flag for `master_key` rotation if data was also exfiltrated. | (1) Step-up auth. (2) Audit start. (3) `zfs snapshot` source. (4) Create fresh encryption root with new master + new passphrase. (5) `zfs send -i` source → new. (6) Cut consumers over (env_file repoint). (7) Verify all consumers healthy on new root. (8) `zfs destroy -r` old root. (9) `zpool trim --secure` if hardware supports, else `zpool initialize`. (10) Audit commit. |
| **lost** | Regenerate from scratch via `Bootstrap.rotate`. No exposure audit. | Reassemble passphrase from Shamir shares (gated on D7) OR restore from offline backup. If neither: data is permanently inaccessible. Record decision. | n/a — losing the master key means the data is gone. Recovery is restore-from-backup. |
| **scheduled** | Same as leaked steps 1–3, 5. Skip log-scan in 4. | Same as leaked, skip the "verify old fails" step (no compromise to confirm). | Same as leaked. Routine — scheduled during maintenance window. |

---

## Audit log structure

Plain JSONL under `<base>/zed/rotation/audit.log` (inherits the
encrypted dataset's protection). One line per event:

```json
{"ts":"2026-05-16T22:14:33Z","event":"rotation_started","level":"passphrase","base":"zroot/zed-test","trigger":"leaked","operator":"io@super-io","step_up_verified_at":"2026-05-16T22:14:01Z","rotation_id":"r-9f3e"}
{"ts":"2026-05-16T22:14:34Z","event":"snapshot","level":"passphrase","snapshot":"zroot/zed-test/zed@rotate-pre-passphrase-20260516T221433","rotation_id":"r-9f3e"}
{"ts":"2026-05-16T22:14:35Z","event":"zfs_change_key_ok","rotation_id":"r-9f3e"}
{"ts":"2026-05-16T22:14:36Z","event":"old_key_unload_verified","rotation_id":"r-9f3e"}
{"ts":"2026-05-16T22:14:36Z","event":"rotation_committed","rotation_id":"r-9f3e","blast_radius":[]}
```

Properties on the dataset get stamped on commit:
```
com.zed:passphrase_rotated_at = 2026-05-16T22:14:36Z
com.zed:passphrase_rotation_id = r-9f3e
com.zed:passphrase_rotation_trigger = leaked
```

---

## Phasing

| Phase | Scope | Effort |
|---|---|---|
| **R1** | Wire the existing `Bootstrap.rotate` into CLI (`zed bootstrap rotate <slot>`) — closes the open stub. | half day |
| **R2** | `Zed.Rotation.Passphrase` + CLI `zed rotate passphrase`. Audit log infrastructure (`Audit` module). | 1–2 days |
| **R3** | Blast-radius integration: `Catalog.consumers/1` → `Consumer.restart_all/1`. Hook into R1/R2. | 1 day |
| **R4** | TLA+ spec `specs/Rotation.tla`. Verify invariants N=2..5. | 1 day |
| **R5** | `Zed.Rotation.MasterKey` — destructive re-encryption. Step-up auth gate (depends on A5a being shipped). | 2–3 days |
| **R6** | `Zed.Rotation.Policy` — cadence config, `zed rotation status` overdue flags. | half day |
| **R7** | Docs + runbook (`docs/rotation-runbook.md`) — the human SOP that complements the code. | half day |

Total **~1 week** for R1–R4 + R6 + R7 (master-key path R5 deferred
until step-up auth lands).

---

## Immediate trigger from this audit

The s6-milestone leak is a **passphrase** issue, **leaked** trigger,
**low** severity (LAN-local + test creds per operator threat model).
Remediation: the manual `zfs change-key` recipe in
`docs/mission-i-trader.md` (M-I tag review thread). Once R2 ships,
the same operation is `zed rotate passphrase --base zroot/zed-test
--trigger leaked`, and the audit record is written without the
operator having to remember to.

---

## Sources

- [zfs-change-key(8) — OpenZFS docs][3] — the wrapping-key vs master-key distinction; the master-key-on-disk forensic-recovery limit.
- [How to Rotate Leaked Secrets With Automation (2026)][1] — emergency rotation pipeline shape; attacker-response-time as the critical metric.
- [Responding to Exposed Secrets — GitGuardian SRE playbook][2] — scope-first, rotate-second principle; exposure-window log audit.
- [aws-customer-playbook-framework: Compromised IAM Credentials][4] — IAM-flavoured but the staging (revoke / replace / audit / postmortem) generalises.
- [DevSecOps School — Secret Rotation Guide (2026)][5] — cadence policy patterns.

[1]: https://safeguard.sh/resources/blog/how-to-rotate-leaked-secrets-automation-2026
[2]: https://blog.gitguardian.com/responding-to-exposed-secrets-an-sres-playbook/
[3]: https://openzfs.github.io/openzfs-docs/man/master/8/zfs-change-key.8.html
[4]: https://github.com/aws-samples/aws-customer-playbook-framework/blob/main/docs/Compromised_IAM_Credentials.md
[5]: https://devsecopsschool.com/blog/secret-rotation/
