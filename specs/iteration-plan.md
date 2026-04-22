# Iteration Plan — zed secrets, QR admin, and the NAS-shaped horizon

**Status:** draft, April 2026. Derived from Secret Plans I + II design memos.
**Scope:** incremental path from current `zed` (declarative ZFS+BEAM deploy, 34 tests on FreeBSD) to a hypothetical SMB+TM NAS built on the same spine. S3 descoped. Layers C and D are "probably not" — unshelve only on explicit decision.

---

## Decisions locked 2026-04-19

| # | Decision | Value |
|---|---|---|
| 1 | S3 service | **Descoped.** Neither in spec nor plan. |
| 2 | zed-web LiveView exists today | **No.** A2 must stand up the foundation. |
| 3 | Mobile companion app | **Fork probnik → `zedz`.** Repo split vs inline still open; defaults to separate repo (matches probnik/probnik_qr pattern). |
| 4 | Plan file location | `~/projects/learn_erl/zed/specs/iteration-plan.md` (this file). |
| 5 | `storage:` field validation | **Parse-time.** IR validator rejects unknown storage values at compile time. Legal values evolve as layers land. |

## Decisions locked 2026-04-21

| # | Decision | Value |
|---|---|---|
| 6 | "Use my existing key on device" auth | **Split into A3 (passkey/WebAuthn) + A4 (SSH pubkey challenge).** Rejected: bundling ed25519-for-SSH on the mobile device. Reason: the platform already provides the right primitive (passkeys), key lives in secure enclave, no private-key parsing in zedz. SSH-key path kept as a laptop-friendly bonus that doesn't need the mobile app at all. |
| 7 | Order: finish B0 Step 5 vs A3/A4 first | **A3/A4 next, then B0 Step 5.** Step 5 is an integration-test pass; A3 opens the most-used path (browser passwordless) and benefits from the infrastructure B0 already exercised. |

---

## Layer rollup (effort after descope)

| Layer | Effort | Commitment |
|---|---|---|
| **A — Retrofits** (valuable regardless of NAS) | **3.1 pm** | Commit now |
| **A3 — Passkey (WebAuthn) admin auth** | 1.5 pm | Added 2026-04-21; orthogonal to NAS; browser-only, no mobile dep |
| **A4 — SSH-key challenge admin auth** | 1.0 pm | Added 2026-04-21; ssh-keygen client only, no hex deps |
| **B — Mobile** (companion app `zedz`) | 1.0 pm | Commit when A2 lands |
| **C — NAS-adjacent** (SMB + TM + LiveView) | 4.0 pm | Probably not |
| **D — Advanced** (Probnik Vault + Shamir + installer) | 5.5 pm | Only if C ships |
| **Total to hypothetical MVP + passwordless auth** | **16.1 pm** | |

---

## Layer A — Retrofits

Valuable for `zed` proper regardless of whether NAS ever materialises. This is the layer that actually ships.

### A0 — `storage:` slot field on secret refs

**Scope:** DSL accepts secret references with a `storage:` mode; IR validator checks the mode at parse time.

**Deliverable:**
- DSL syntax: `{:secret, slot, field, storage: :local_file}`; default storage is `:local_file` when omitted.
- `Zed.IR.Validate.check_storage_values/1` — rejects unknown modes at compile time.
- Legal modes in this iteration: `:local_file` only. Future modes (`:probnik_vault_pair`, `:shamir_k_of_n`) fail parse-time until their layer ships.
- Slot catalog lives in `Zed.Secrets.Catalog` — every slot name referenced in IR must exist there.

**Effort:** 0.1 pm.
**Depends on:** — (current DSL infra is sufficient).
**Acceptance:**
- [ ] `use Zed.DSL` + reference to unknown slot fails at compile time with a readable error.
- [ ] `storage: :probnik_vault` in MVP fails with "not yet implemented, pending Layer D."
- [ ] `storage: :local_file` (or omitted) compiles.
- [ ] Validator test covers all legal + all currently-illegal values.

---

### A1 — `Zed.Bootstrap` module

**Scope:** install-time generation of zed's own secrets, three-tier storage (encrypted dataset + fingerprint properties + archive).

**Deliverable:**
- `Zed.Bootstrap.init/2` — accepts `--base <dataset>` (not `--pool`); creates `<base>/zed` and `<base>/zed/secrets` (encrypted, `canmount=noauto`), generates missing slots, stamps fingerprints, snapshots. Production default: `--base <pool>` (e.g. `jeff`); tests pass `--base jeff/zed-test/<uuid>`.
- `Zed.Bootstrap.status/1` — list slots with fingerprint, age, file-present check.
- `Zed.Bootstrap.rotate/2` — regenerate a single slot, archive old value, update consumers.
- `Zed.Bootstrap.verify/1` — recompute fingerprints, detect drift, surface silent fatals.
- CLI: `zed bootstrap {init | status | rotate | verify | export-pubkey} --base <dataset>`.
- Slot catalog for A1 (zed's own secrets, not NAS-specific):
  - `beam_cookie` (random-256)
  - `admin_passwd` (argon2id hash; plaintext shown once)
  - `ssh_host_ed25519` (keypair; pubkey exportable)

**Why `--base`, not `--pool`:** the jail delegation (`jeff/zed-test` only) cannot create siblings at `jeff/*`, so tests cannot use a real pool root. Parametrising on an arbitrary parent dataset makes tests trivially isolatable (every test gets its own UUID subtree) and keeps the production path identical — production simply passes the pool name as the base. See A1 prep notes in `execution-plan.md`.

**Effort:** 1.0 pm.
**Depends on:** A0.
**Acceptance:**
- [ ] First `bootstrap init` generates all three slots, prints banner once.
- [ ] Second `bootstrap init` is a no-op (idempotent).
- [ ] `bootstrap rotate beam_cookie` archives old value, stamps new fingerprint, emits restart-plan for consumers.
- [ ] `bootstrap verify` detects deliberately-corrupted file (fingerprint mismatch) and reports operator action.
- [ ] All tests run against FreeBSD jail with real ZFS.
- [ ] ZFS properties readable via `zfs get` show only fingerprints, never values.

---

### A2a — zed-web LiveView foundation

**Scope:** Phoenix LiveView application, auth plumbing, basic admin route skeleton. Required because zed-web does not exist today.

**Deliverable:**
- Phoenix 1.7+ + LiveView project under `apps/zed_web/` (umbrella) or `lib/zed_web/` (flat).
- Auth: password login against `admin_passwd` slot (Argon2 verify).
- Session: 8h rolling, secure cookie.
- Routes: `/admin/login`, `/admin`, `/admin/logout`.
- Single LiveView page at `/admin` showing `Zed.Bootstrap.status/1` output (proves the plumbing).

**Effort:** 1.0 pm.
**Depends on:** A1.
**Acceptance:**
- [ ] Password login works against bootstrap-generated admin_passwd.
- [ ] Session persists; logout clears.
- [ ] `/admin` renders bootstrap slot status live (ETS subscription or per-request read).
- [ ] TLS with bootstrap-generated self-signed cert; cert fingerprint exposed via a config accessor.

---

### A2b — QR admin first-login

**Scope:** `Zed.QR` rendering + `Zed.Admin.OTT` GenServer + `/admin/qr-login` redeem endpoint.

**Deliverable:**
- `Zed.QR.show_admin_session/1` — renders ANSI QR with `{zed_admin, Node, Host, Port, CertFP, OTT, Expires}` payload.
- `Zed.Admin.OTT` — GenServer with ETS backing, atomic single-use consume, configurable TTL.
- `/admin/qr-login` POST endpoint, rate-limited 10/min/IP.
- `bootstrap init` summary prints QR with 10-min TTL OTT.
- `/admin` "Generate pairing QR" button issues 2-min TTL OTT and renders inline.

**Effort:** 1.0 pm.
**Depends on:** A2a.
**Acceptance:**
- [ ] OTT issued at bootstrap is consumable exactly once.
- [ ] Expired OTT returns `{error: :expired}`.
- [ ] Already-used OTT returns `{error: :used}`.
- [ ] Rate limiter fires after 10 failed redeems in 60s.
- [ ] Concurrent redeem of same OTT: one succeeds, other gets `{error: :used}`.
- [ ] Audit log records every issue + consume with OTT prefix (not full).

---

### A3 — Admin passkey (WebAuthn) auth

**Scope:** let any modern browser register a passkey against an authenticated admin session, then use that passkey for subsequent logins — no password, no QR, no mobile app. Key lives in the OS secure enclave; biometric-gated on use. Works on laptop browsers, phone browsers, and iPads; orthogonal to the zedz Android app.

**Deliverable:**
- New slot on `<base>/zed`: `admin_passkeys` — list of registered credentials (one entry per device). Structure per credential: `credential_id`, `public_key_cose`, `sign_count`, `aaguid`, `device_label`, `created_at`, `last_used_at`.
- Phoenix routes (JSON):
  - `POST /admin/passkey/register-options` → challenge + relying-party info (requires authenticated admin session)
  - `POST /admin/passkey/register` → store attestation, assign `device_label`
  - `POST /admin/passkey/auth-options` → challenge (unauthenticated; by handle or userless)
  - `POST /admin/passkey/auth` → verify assertion, issue session cookie
- `ZedWeb.AdminController.new_session/2` gains a "Sign in with a passkey" button driving `navigator.credentials.get(...)` in the browser.
- LV dashboard gains a "Passkeys" card: "Register this device", list of registered devices with labels + last-used, forget per-row.
- Dep: `{:wax_, "~> 0.6"}` — pure-Elixir WebAuthn verifier, no NIF.

**Effort:** 1.5 pm.
**Depends on:** A2a (session + password fallback already work).
**Acceptance:**
- [ ] Log in with password or QR, hit "Register this device" → browser fires biometric prompt, credential appears in the Passkeys list.
- [ ] Log out, click "Sign in with a passkey" → biometric → logged in, no password typed.
- [ ] Register a second device (another browser), both appear in the list, either works for login.
- [ ] Forget a device → its passkey no longer authenticates.
- [ ] Replay of a captured assertion is rejected (sign-count monotonicity enforced).
- [ ] Tested on at least: Chrome desktop, Safari iOS, Chrome Android.

---

### A4 — Admin SSH-key challenge auth

**Scope:** operators who already carry `~/.ssh/id_ed25519` paste their **public** key into zed-web once; subsequent logins sign a server-issued challenge with their private key. Catches the audience that has SSH muscle memory but no passkey, and enables trivial programmatic auth for scripts.

**Deliverable:**
- New slot: `admin_authorized_keys` — stored as an `authorized_keys`-format file so it's auditable with standard tools. One line per key: `ssh-ed25519 AAAAC3Nz… alice@laptop`.
- Routes:
  - `POST /admin/ssh/challenge` with `{"fingerprint": "SHA256:<base64>"}` → `{"nonce": "...", "challenge_b64": "..."}`. Server stores `(nonce, fingerprint, expires_at)` with 120s TTL.
  - `POST /admin/ssh/response` with `{"nonce": "...", "sig_b64": "..."}` → server looks up the nonce's fingerprint, finds the pubkey, verifies the signature on `challenge_b64`, issues session cookie.
- CLI: `zed admin add-key <authorized_keys_line>` / `zed admin list-keys` / `zed admin remove-key <fingerprint>`.
- LV dashboard: Keys card with add / label / remove.
- Client helper: `scripts/zed-web-login.sh` — reads `~/.ssh/id_ed25519`, computes fingerprint, POSTs the two endpoints using `ssh-keygen -Y sign`, deposits the session cookie into a file the caller can hand to `curl --cookie`.
- Elixir side uses `:public_key.verify/4` — OTP built-in, no dep.
- Optional: zedz mobile gets an "Add my SSH pubkey" button that forwards the pubkey line from an SSH-manager app via Intent, no private-key handling on the phone.

**Effort:** 1.0 pm.
**Depends on:** A2a (authenticated session needed to add keys initially).
**Acceptance:**
- [ ] Add a pubkey via CLI or UI while logged in.
- [ ] `scripts/zed-web-login.sh https://host:port` produces a valid session cookie; `curl --cookie` can hit `/admin`.
- [ ] Wrong-key signature rejected.
- [ ] Replay of `(nonce, sig)` rejected (nonce consumed after first successful response).
- [ ] Unknown fingerprint rejected.
- [ ] Key format variants covered: unencrypted OpenSSH ed25519 and rsa-4096.

---

## Layer B — Mobile companion

Forked from probnik. Working name: **zedz**. Repo decision (separate vs inline in zed) deferred; separate repo is the default (mirrors probnik/probnik_qr split and keeps gradle/xcode out of mix).

### B0 — `zedz` companion app with `zed_admin` handler

**Scope:** fork probnik's Android + iOS scanner code, rename to zedz, add a handler for the `zed_admin` term shape.

**Deliverable:**
- Android: new `AdminLoginActivity` — WebView with pinned cert, auto-POST of OTT to `/admin/qr-login`.
- iOS: equivalent with `URLSession` cert pinning.
- Parser: extend probnik's Erlang term regex to dispatch on tag (`probnik_pair` → existing flow, `zed_admin` → new flow).
- Persistence: `zedz_nodes` preferences store with last-used host + cert FP.
- Repo: new GitHub repo `zedz` (fork of probnik, rename, strip probnik-specific term handlers or keep both — decide at fork time).

**Effort:** 1.0 pm (Android + iOS).
**Depends on:** A2b server-side schema locked.
**Acceptance:**
- [ ] Scan QR rendered by `bootstrap init` → phone opens WebView at correct host:port with pinned cert.
- [ ] Wrong-cert MITM attempt rejected by pin (test against a local proxy).
- [ ] Expired QR: phone rejects locally before attempting connection.
- [ ] Used OTT: phone shows server error ("token already consumed") and offers "Request new QR" path.

---

## Layer C — NAS-adjacent (probably not)

Only begins if Layers A and B have landed and an explicit unshelve decision is made.

### C3 — SMB + Time Machine share DSL + Samba rendering + mDNS

**Scope:** DSL verbs for SMB/TM shares; EEx-based `smb4.conf` rendering; mDNS advertisement via mDNSResponder or avahi.

**Deliverable:**
- DSL: `share "music" do type :smb, path: "tank/music", quota: "500G", users: [:alice, :bob] end`.
- DSL: `share "alice-tm" do type :smb, time_machine: true, path: "tank/tm/alice", quota: "1T", user: :alice end`.
- Samba config generation: `vfs objects = catia fruit streams_xattr`, `fruit:time machine = yes`, `fruit:metadata = stream`, share-scoped ACL.
- ZFS dataset auto-created per share with quota as dataset quota (not Samba fruit:max_size alone).
- mDNS advertisement: `_smb._tcp` + `_adisk._tcp` with `dk0=adVN=...` TXT records.
- Local-user admin via `Zed.Users` module — NT hash stored per-user in `<pool>/zed/users/<uid>` (mode 0400 root:wheel).

**Effort:** 2.0 pm.
**Depends on:** A1 (secret storage for NT hashes).
**Acceptance:**
- [ ] Create share via DSL; Samba restart succeeds; Mac sees share in Finder.
- [ ] Time Machine share completes a 10GB backup + incremental + restore.
- [ ] Quota enforcement: TM share filling past quota gets ZFS-level `ENOSPC`, not silent corruption.
- [ ] mDNS discovery: Mac's Finder sidebar shows server without manually typing `smb://`.
- [ ] Tested against macOS 13 / 14 / 15.

---

### C5 — LiveView admin UI for pools, shares, alerts

**Scope:** Phoenix LiveView dashboards — builds on A2a foundation.

**Deliverable:**
- Pool health dashboard: vdev tree, capacity, scrub/resilver progress (live PubSub).
- Share management: list / create / delete SMB + TM shares, with TM-specific status (last backup, band count, quota used).
- User management: local users + group membership.
- Alert stream: live-pushed alerts from `Zed.Alerts` module (to be built as part of C5).
- Wizard flows: pool creation, TM share setup.

**Effort:** 2.0 pm.
**Depends on:** A2a, C3.
**Acceptance:**
- [ ] All UI operations round-trip through IR → converge (no direct mutation of ZFS state from UI).
- [ ] Scrub progress updates live without page reload.
- [ ] TM per-Mac status shows last backup timestamp and size, matches what macOS Time Machine prefs reports.
- [ ] Alert stream persists last 500 alerts; browser scrollback survives disconnect/reconnect.

---

## Layer D — Advanced (phase 2+)

### D6 — Probnik Vault: sub-channel + Mode 1 + Mode 2

**Scope:** second encrypted sub-channel (not reusing rendering channel); unlock-at-boot (Mode 1); approval for destructive ops (Mode 2).

**Deliverable:**
- Sub-channel protocol: ECDH-per-session over separate TCP listener or ALPN-discriminated on same TLS endpoint.
- `Zed.Vault` module: `pair/1`, `list_devices/0`, `revoke/1`, `put/3`, `get/2`, `approve/3`.
- `zedz` companion app: new keystore bucket `zed_vault`, per-key biometric gate, operation queue screen.
- New QR term shapes: `zed_vault_pair`, `zed_vault_request`, `zed_vault_approve`.
- New slot catalog entries: `secrets_ds_passphrase` (storage: `:probnik_vault_pair`).
- Unlock-at-boot flow: server emits vault request, phone prompts, phone releases passphrase over sub-channel, server unlocks.
- Approval flow: LiveView "Destroy dataset X" pushes to phone, phone prompts biometric, phone signs challenge, server verifies.

**Effort:** 2.0 pm (server + mobile).
**Depends on:** A1, B0.
**Acceptance:**
- [ ] Unlock-at-boot works: paired phone releases secrets-dataset passphrase; server unlocks without operator typing.
- [ ] Revoked device cannot release secrets even if paired previously.
- [ ] Approval-required operation blocked when phone denies; permitted when phone confirms.
- [ ] Sub-channel crypto material is independent of rendering channel (verified by revoking rendering pairing while vault still works).
- [ ] Re-pairing a rendering-paired device for vault role generates fresh crypto material (decision II in Plan II).

---

### D7 — Shamir in-tree: Mode 3

**Scope:** GF(2⁸) Shamir Secret Sharing implemented from scratch in Elixir (no hex dep for sharing layer).

**Deliverable:**
- `Zed.Crypto.Shamir.split(secret, k, n)` returning N shares.
- `Zed.Crypto.Shamir.reconstruct(shares)` requiring at least K.
- GF(2⁸) lookup tables for mul/inv; Lagrange interpolation.
- Test vectors matching a reference implementation (e.g. `vault-shamir` cross-check).
- `Zed.Vault.shamir_put/4` + `Zed.Vault.shamir_get/2`.
- New legal storage values: `:shamir_k_of_n` with k ∈ [2, n−1] enforced at parse time.
- New slot catalog entries: `pool_encryption_key` (storage: `:shamir_k_of_n`).

**Effort:** 1.5 pm.
**Depends on:** D6.
**Acceptance:**
- [ ] Split → reconstruct round-trips for k-of-n with k ∈ [2,5], n ∈ [3,7].
- [ ] Reconstruction with fewer than K shares returns `{error, :insufficient_shares}`.
- [ ] Cross-check: shares split by `Zed.Crypto.Shamir` reconstructible by reference implementation.
- [ ] Test vectors from NIST or Vault's Shamir spec pass.
- [ ] IR validator rejects k=n configurations at parse time (footgun prevention per Recovery semantics).
- [ ] Audit log records every split/reconstruct with share prefix (not full share).

---

### D8 — Installer ISO + boot-environment updates + docs

**Scope:** make the thing installable on bare metal, updatable via boot environments, documented for operators.

**Deliverable:**
- `bsdinstall`-based ISO with post-install script that runs `zed bootstrap init`.
- `bectl`-based update flow: `zed update` creates a new BE, `pkg upgrade` into it, activate on reboot; rollback via `bectl activate` of prior BE.
- Operator quickstart docs: first-boot walkthrough, creating a TM share, pairing a phone, rotating secrets, recovering from phone loss (references Recovery semantics).
- Release signing: detached signatures on update manifests, signature verification in `zed update`.

**Effort:** 2.0 pm.
**Depends on:** C5.
**Acceptance:**
- [ ] Fresh hardware boots from ISO, completes install wizard, lands at first-login QR.
- [ ] `zed update` installs a new BE; reboot into new BE succeeds; rollback to prior BE succeeds.
- [ ] Update signature verification rejects tampered manifest.
- [ ] Quickstart docs walk from zero to a working TM backup in under 15 minutes.

---

## Open decisions not yet closed

1. **zedz repo layout** — separate repo (default, matches probnik pattern) or inline under `zed/zedz/` (single repo, gradle/xcode noise in mix tree). Revisit when starting B0.
2. **Phoenix umbrella vs flat** for zed-web. Flat is simpler for a small admin UI; umbrella preserves boundary if zed-web grows. Revisit at A2a kickoff.
3. **MinIO replacement for descoped S3** — if S3 is ever re-scoped, Garage is the FreeBSD-first alternative worth revisiting. Out of plan for now.
4. **Mass rollback** — if A1's `bootstrap verify` detects drift, is automatic rollback via `zfs rollback @bootstrap-*` the right action, or does it require operator confirmation? Lean: confirmation, because rollback destroys any stamped-but-unsnapshotted work.

---

## Cross-references

- Secret Plan I (threat model + 3-tier storage + slot catalog): `~/.claude/projects/-home-io-projects-learn-erl-pymc/memory/probably_not_secret_plan_i.md`
- Secret Plan II (Probnik Vault + recovery semantics + Hypothecide pun): `~/.claude/projects/-home-io-projects-learn-erl-pymc/memory/probably_not_secret_plan_ii.md`
- Book-pun candidates: `~/.claude/projects/-home-io-projects-learn-erl-pymc/memory/book_punz.md`
- Blog post (public-facing): `~/projects/learn_erl/pymc/www.dataalienist.com/blog-probably-not-a-nas.html`

---

## Next action

A0, A1, A2a, A2b all merged. B0 Steps 1–4 merged on the zedz repo.

Next per decision #7: **A3 (admin passkey / WebAuthn)**. Unblocks laptop passwordless login for any modern browser, no mobile app required. Start with the slot + `wax_` dep + the two registration endpoints, then the LV card, then the login button. B0 Step 5 integration matrix follows after.
