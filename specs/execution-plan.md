# Execution Plan — host split, branches, round-trip

**Companion to** [`iteration-plan.md`](iteration-plan.md). The iteration plan says *what*; this file says *where* and *how*.

**Status:** draft, April 2026.

---

## Host split

| Host | Role | Path |
|---|---|---|
| **Jail `plausible` @ 192.168.0.33** (FreeBSD, delegated `jeff/zed-test`) | All ZFS runtime work, Samba/mDNS, Phoenix LiveView server during integration tests | `/home/io/zed/` in jail |
| **Dev host (here, Linux)** | Spec edits, pure-Elixir modules (Shamir, DSL validator), Android build for `zedz`, all git orchestration | `/home/io/projects/learn_erl/zed/` here; `/home/io/projects/learn_erl/zedz/` for companion fork |
| **iOS build** | Deferred — requires Mac. Not in this plan. | — |

**Git remote (shared):** `git@192.168.0.33:/mnt/jeff/home/git/repos/zed.git` — both hosts push/pull to it. Jail operates on the same bare repo it hosts (local path), dev host over SSH.

---

## Branch strategy

One feature branch per iteration. Merge to `main` only after jail-side tests pass (where applicable).

| Iteration | Branch name | Primary host | Why |
|---|---|---|---|
| A0 | `feat/a0-storage-field` | Dev host | Pure DSL/validator; no ZFS needed |
| A1 | `feat/a1-bootstrap` | **Jail** | Real encrypted ZFS dataset + property stamping |
| A2a | `feat/a2a-zed-web` | Dev host, deploy-test in jail | Phoenix plumbing authored locally, run against jail for auth test |
| A2b | `feat/a2b-qr-login` | **Jail** | OTT table + QR-in-shell needs running node |
| B0 | `feat/b0-zedz-android` (in `zedz` repo) | Dev host | Android build + gradle; targets jail's zed-web for integration |
| C3 | `feat/c3-smb-tm` | **Jail** | FreeBSD Samba + mDNSResponder + real Mac client |
| C5 | `feat/c5-liveview-admin` | Dev host, deploy-test in jail | Phoenix LiveView authoring + live data from jail |
| D6 | `feat/d6-vault-modes-1-2` | **Jail** (server) + dev host (zedz) | Sub-channel protocol + mobile handler |
| D7 | `feat/d7-shamir` | Dev host | Pure math, trivially testable anywhere |
| D8 | `feat/d8-installer` | **Jail** | `bsdinstall` + `bectl` are FreeBSD-only |

**Merge rule:** no merge to `main` without tests green on the branch's primary host. For jail-primary branches that also compile here, run `mix compile --warnings-as-errors` on dev host too (catches typos before round-trip).

---

## Round-trip cheat sheet

### From dev host to jail
```
# here: commit + push
git checkout -b feat/a1-bootstrap
# ... edit ...
git commit -m "A1: encrypted dataset creation"
git push -u origin feat/a1-bootstrap

# in jail (via ssh io@192.168.0.33): pull + test
ssh io@192.168.0.33
cd /home/io/zed
git fetch
git checkout feat/a1-bootstrap
mix deps.get              # if new deps
mix test                  # unit tests
sudo mix test --include zfs_live   # ZFS integration, needs root
```

### From jail to dev host
```
# in jail: commit + push
cd /home/io/zed
git add -A
git commit -m "A1: fix dataset cleanup on failure"
git push

# here: pull
git fetch
git pull --rebase
```

**Dev host is source of truth for specs + Android code.**
**Jail is source of truth for anything with a `:zfs_live` test tag.**

---

## Per-iteration execution notes

### A0 — `feat/a0-storage-field` (dev host)
- Edit `lib/zed/ir/validate.ex`: add `check_storage_values/1`.
- Edit `lib/zed/dsl.ex`: parse `storage:` key in secret ref tuple.
- Edit `test/zed/dsl/validate_test.exs`: cover legal + illegal storage values.
- No jail round-trip needed. `mix test` locally.
- Merge: dev host passes → push → merge to main.

### A1 — `feat/a1-bootstrap` (jail)
- Author on dev host for IDE comfort, push, develop iteratively in jail.
- New: `lib/zed/bootstrap.ex`, `lib/zed/secrets/catalog.ex`, `lib/zed/secrets/generate.ex`.
- New CLI verb in `lib/zed/cli.ex`: `bootstrap {init|status|rotate|verify|export-pubkey}`.
- Tests: `test/zed/bootstrap/integration_test.exs` tagged `:zfs_live`.
- **Jail prep:** ensure `jeff/zed-bootstrap-test` dataset exists and is deletable; tests clean up via `zfs destroy -r`.
- **Required ZFS features:** `keyformat=passphrase` needs pool feature `encryption`. Verify on jail: `zpool get feature@encryption jeff`.
- Merge: jail tests green → push → merge.

### A2a — `feat/a2a-zed-web` (dev host, deploy-test in jail)
- Author Phoenix 1.7 project under `lib/zed_web/` (flat, not umbrella — decision from iteration plan #2).
- Deps: `phoenix`, `phoenix_live_view`, `argon2_elixir`, `bandit`.
- Auth: password login reads `admin_passwd` file via `Zed.Secrets.Read.read_file/1` (comes with A1).
- Test locally with a fake admin_passwd fixture.
- Deploy to jail once, run end-to-end: bootstrap + login + session.
- Merge after both local unit tests and one successful jail round-trip login.

### A2b — `feat/a2b-qr-login` (jail)
- New deps: `{:probnik_qr, git: "..."}` — may need path rewrite or fork since probnik_qr currently lives in a separate repo.
- New: `lib/zed/qr.ex`, `lib/zed/admin/ott.ex` (GenServer), `lib/zed_web/controllers/admin_qr_controller.ex`.
- Tests: OTT consume atomicity, expiry, rate limit. `:zfs_live` not required (ETS only).
- **Integration test from jail:** `iex -S mix`, call `Zed.QR.show_admin_session()`, scan from phone (requires B0 or manual OTT redeem via `curl`).
- **Schema lock point:** the term shape `{zed_admin, Node, Host, Port, CertFP, OTT, Expires}` must be frozen before starting B0. Commit a schema doc in `specs/qr-schema.md` at merge time.

### B0 — `feat/b0-zedz-android` (dev host, in `zedz` repo)
- **Fork probnik:**
  - Option 1 (default): new repo. `cp -r /home/io/projects/learn_erl/probnik /home/io/projects/learn_erl/zedz`, strip `.git`, `git init`, `git remote add origin git@192.168.0.33:/mnt/jeff/home/git/repos/zedz.git` (needs bare repo on 192.168.0.33 first).
  - Option 2 (deferred): inline in zed. Not recommended — mixes gradle/xcode with mix.
- Rename app id: `zedz.net` → `zedz.io` or `io.octanix.zedz`. Update `android/app/build.gradle` applicationId.
- Parser extension: Java regex dispatches on first tag atom. Add `zed_admin` branch → `AdminLoginActivity`.
- New activity: `AdminLoginActivity.java` — WebView with `CertificatePinner` (OkHttp for API calls) and `WebViewClient.onReceivedSslError` fingerprint check for the page load.
- Android build: `./rebuild-android-host.sh` from zedz root.
- **Integration target:** jail's running zed-web from A2b. QR scanned on phone → WebView opens `https://192.168.0.33:<port>/admin` → session cookie obtained.
- Merge after one successful end-to-end scan-to-admin.

### C3 — `feat/c3-smb-tm` (jail)
- Jail needs: `samba413` or `samba416` (`pkg install samba416`), `avahi-app` or `mDNSResponder` (`pkg install mdnsresponder`).
- DSL: `lib/zed/dsl/share.ex`.
- Config rendering: `lib/zed/platform/freebsd/samba.ex` (EEx templates for smb4.conf per-share fragments).
- mDNS registrar: spawn `mdnsd` announcements from an OTP worker, or write the config the FreeBSD `mDNSResponder` service reads.
- NT hash storage: `<pool>/zed/users/<uid>` file mode 0400, fingerprint in `com.zed:user.<uid>.nt_fingerprint`.
- **Real Mac required for acceptance:** test 10GB TM backup + incremental + restore against macOS 13/14/15.
- Merge after Mac integration pass.

### C5 — `feat/c5-liveview-admin` (dev host, deploy-test in jail)
- LiveView pages under `lib/zed_web/live/`.
- Depends on A2a scaffold + C3 service layer.
- PubSub topics: `zed:pool_health`, `zed:scrub`, `zed:alerts`.
- No jail-local runtime changes beyond what A1/C3 already installed.
- Merge after both unit LiveView tests and jail deploy-test.

### D6 — `feat/d6-vault-modes-1-2` (jail server + dev host zedz)
- Server side (jail):
  - `lib/zed/vault.ex`, `lib/zed/vault/channel.ex` (second TLS listener, ECDH-per-session).
  - New QR terms: `zed_vault_pair`, `zed_vault_request`, `zed_vault_approve`.
  - Slot catalog adds `secrets_ds_passphrase` with `storage: :probnik_vault_pair`.
- Mobile side (dev host, zedz):
  - New keystore bucket `zed_vault`.
  - Vault-operations screen: paired nodes, stored keys, pending approvals.
  - New activities for each term shape.
- **Integration test:** paired phone releases passphrase → jail boots encrypted dataset without operator keyboard input.
- **Cannot merge until both sides green on same end-to-end test.**

### D7 — `feat/d7-shamir` (dev host)
- Pure Elixir. No ZFS, no jail.
- `lib/zed/crypto/shamir.ex` — GF(2⁸) lookup tables, Lagrange interpolation.
- `test/zed/crypto/shamir_test.exs` — round-trip, insufficient shares, k=n rejection, cross-check vectors.
- **Cross-check source:** pick a reference implementation for test vectors (e.g., Shamir section in Vault's open-source codebase or a NIST test vector set). Decide at branch kickoff.
- Merge when tests green on dev host.

### D8 — `feat/d8-installer` (jail)
- Requires jail to be upgraded to a FreeBSD host with full `bsdinstall` access, or test on a VM. Current `plausible` jail is fine for `bectl` experiments but an ISO build may need a VM.
- Out of immediate sync scope — deferred to project unshelve decision.

---

## Sync points

| Sync | When | What |
|---|---|---|
| **S1: A2b ↔ B0 schema freeze** | End of A2b | Commit `specs/qr-schema.md` with the `zed_admin` term shape + cert-pin contract. B0 reads this as source of truth. |
| **S2: B0 first scan against jail** | During B0 integration | Phone on dev-host network must reach 192.168.0.33:4000. Verify firewall/routing before starting B0. |
| **S3: D6 dual merge** | End of D6 | Server branch in `zed` and mobile branch in `zedz` must merge together. Coordinate with paired PRs or a single coordinated merge day. |
| **S4: D7 test vector agreement** | Before D7 merge | Shamir shares produced by `zed` must reconstruct via reference tool (and vice versa). One explicit test run with recorded output. |

---

## Risks + mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Jail DHCP IP changes (has happened once: .33 → .116) | Breaks pushed hardcoded IPs, QR payloads referencing old IP | Use jail hostname (`plausible.local` via mDNS) in QR payload where possible; document jail IP check in A2b test runbook |
| Lost jail (corruption, reinstall) | Replay of environment setup: OTP/Elixir install, CA certs, SSH keys, git remote | Keep a `scripts/jail-bootstrap.sh` in this repo documenting the exact pkg list + ZFS delegation; tested recovery target: 30 minutes from clean jail |
| Phone cannot reach jail network | Blocks B0 integration | Dev host can serve as jump host; or test B0 via emulator's host networking bridge |
| Samba version mismatch between FreeBSD ports and macOS expectations | TM backups silently fail or corrupt | Pin Samba version in `scripts/jail-bootstrap.sh`; test macOS 13/14/15 before declaring C3 done |
| EXLA/Elixir version drift between dev host and jail | Subtle test failures | `.tool-versions` file committed; enforce `asdf install` in both environments on branch checkout |
| Iteration branches diverge over weeks | Merge conflicts in `lib/zed/cli.ex` (central verb dispatch) | Rebase feature branches on `main` at most every 2 days; keep CLI verb additions in separate files where possible |

---

## Immediate next actions (after plan sign-off)

1. **Commit the two spec files** (`iteration-plan.md`, `execution-plan.md`) to `main` on dev host. Push.
2. **Pull on jail.** Confirm both files visible.
3. **Create `jeff/zed-bootstrap-test` dataset** on jail (for A1 integration tests). Verify `zfs get feature@encryption jeff` returns enabled.
4. **Start A0 on dev host** (`feat/a0-storage-field` branch, 0.1 pm). No jail involvement.
5. **At A0 merge:** kick off A1 on jail.
