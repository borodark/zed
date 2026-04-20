# B0 — `zedz` companion app (Android first)

**Status:** plan, not started. Unblocked by A2b merge + `specs/qr-schema.md`.

**Goal:** minimum-viable mobile scanner that consumes the `{zed_admin,
…}` QR from `zed serve`, cert-pins against the fingerprint in the
payload, POSTs the OTT to `/admin/qr-login`, and opens the admin
LiveView WebView already logged in. Password + cert-warning-click
paths stay as the fallback.

**Effort:** ~1.0 pm (Android only — iOS deferred until we have a Mac
in the loop). Repo-decision: **separate repo at
`~/projects/learn_erl/zedz/`**, fork of `probnik`, origin hosted on
`git@192.168.0.33:/mnt/jeff/home/git/repos/zedz.git`. Mirrors the
probnik / probnik_qr split so the gradle/xcode toolchain stays out of
the zed mix tree.

**Dev host:** Linux box at `/home/io/projects/learn_erl/`. Android SDK,
ML Kit, Java — already present from probnik builds.

## What's being reused

`probnik` already ships 99% of what we need:

- `CameraX` + ML Kit barcode scanner (`QrScannerActivity.java`)
- Erlang-term regex parser dispatching on first tag atom
  (`NodePreferences.parseQrPayload`)
- `PairingActivity` — list of previously paired nodes, "scan QR" button
- `HostActivity` — native-side BEAM bootstrap
- SharedPreferences persistence of paired nodes

The changes are small and localized: new term tag, new activity for
admin login, persistent cert-fingerprint store, OkHttp + WebView cert
pinning.

## Out of scope for B0

- iOS (deferred; requires Mac)
- Vault modes from Layer D (unlock-at-boot, approval, Shamir). The
  companion app only handles `:zed_admin` in this iteration.
- HTML-rendered QR in the zed-web admin dashboard (operator copies the
  payload string for now; still works manually)
- Device identity key + signed challenges. `zed_admin` uses OTT
  single-use redemption; device identity kicks in at D6.

## Incremental plan

### Step 1 — Repo fork (~1 hr)

```sh
# on dev host
cp -r ~/projects/learn_erl/probnik ~/projects/learn_erl/zedz
cd ~/projects/learn_erl/zedz
rm -rf .git _build deps _install .DS_Store
git init
git add -A
git commit -m "Fork from probnik at <sha>"

# bare repo on 192.168.0.33
ssh io@192.168.0.33 'git init --bare /mnt/jeff/home/git/repos/zedz.git'
git remote add origin git@192.168.0.33:/mnt/jeff/home/git/repos/zedz.git
git push -u origin main
```

Rename Android `applicationId` (`probnik.net` → `io.octanix.zedz`) in
`android/app/build.gradle` so the app installs alongside probnik on the
same phone without collision. Update package declarations in Java
sources via IDE refactor.

Acceptance: `./rebuild-android-host.sh` produces an APK with the new
id; APK installs on a test device; launcher icon launches the
PairingActivity identically to probnik.

### Step 2 — Erlang term parser extension (~2 hrs)

In `NodePreferences.java` (or equivalent parser in Kotlin if the
rewrite happened), extend the regex dispatch:

```java
// probnik regex already handles {probnik_pair, ...} and
// {probnikoff_net, ...}. Add a third:
// {zed_admin, Node, {A,B,C,D}, Port, "sha256:...", "ott", Expires}
```

Output a `ZedAdminPayload` model with typed fields:

```java
class ZedAdminPayload {
  String node;           // 'zed@plausible' (strip single quotes)
  byte[] hostIp;         // 4-element
  int port;              // e.g. 4040
  String certFingerprint; // "sha256:<64 hex>"
  String ott;             // base64url, 43 chars
  long expiresAt;         // unix seconds
}
```

Validate at parse time per `specs/qr-schema.md` §2:
- `certFingerprint` matches `sha256:[0-9a-f]{64}`
- `ott` matches `[A-Za-z0-9_-]{43}`
- `expiresAt` is in the future minus 10s slack
- host IP components all in `0..255`
- port in `1..65535`

Unit tests against fixture payloads.

Acceptance: parser returns a valid `ZedAdminPayload` for a live
`zed serve` QR; rejects expired, malformed, or wrong-tag payloads
with distinct error codes.

### Step 3 — AdminLoginActivity with cert-pinned WebView (~3 hrs)

New activity launched when the parser returns `ZedAdminPayload`.

Flow:
1. Show confirmation card: "Log in to `<node>` at `<host>:<port>` as
   admin?" with BiometricPrompt gate.
2. On confirm: build `OkHttpClient` with
   `CertificatePinner.Builder().add(host, "sha256/" + base64(der))`.
   The fingerprint from the QR is hex; convert to the base64 format
   OkHttp expects.
3. POST `https://<host>:<port>/admin/qr-login` with
   `{"ott": "<ott>"}` and `Content-Type: application/json`.
4. On 200: server returned `{"ok": true, "redirect": "/admin"}`. Copy
   the session cookie from the response into a `CookieManager` tied
   to the WebView, then load `https://<host>:<port>/admin` in a
   full-screen WebView.
5. WebView's `WebViewClient.onReceivedSslError` checks the leaf cert
   fingerprint against the stored pin; proceed only on match.

Cert-fingerprint conversion:

```java
// From "sha256:<hex>" to OkHttp's "sha256/<base64>":
byte[] der = hexToBytes(fpHex);
String b64 = Base64.encodeToString(der, Base64.NO_WRAP);
String pin = "sha256/" + b64;
```

Error mapping (per `qr-schema.md` §4):
- 401 `invalid_token` → "This QR is no longer valid. Request a new one."
- 401 `token_used` → "QR already used. Request a new one."
- 401 `token_expired` → same as invalid.
- 429 `rate_limited` → "Too many attempts. Try again in a minute."
- SSL pin mismatch → "Server certificate changed. Abort."
- Network timeout → "Cannot reach `<host>:<port>`."

Acceptance: end-to-end smoke test against jail's `zed serve` —
scan → biometric → WebView opens at `/admin` with session. No
cert-warning page shown.

### Step 4 — Pairing persistence (~2 hrs)

Extend the SharedPreferences store with a new namespace
`zedz_admin_sessions`:

```
node@host          string
cert_fingerprint   string
port               int
last_login_at      long
```

One entry per paired `zed-web` server. Enables "re-open admin" without
rescanning, subject to session cookie validity.

Acceptance: scan a QR once, kill the app, reopen. The node appears in
a "recent" list at the top of PairingActivity. Tapping it opens the
WebView at `/admin`. If the session cookie is expired, WebView lands
at `/admin/login` and falls back to password.

### Step 5 — Integration test matrix (~3 hrs)

Run against jail `zed serve`:
- Fresh paired device, no stored cookie → full QR flow. Golden path.
- Paired device, valid cookie → "recent" tap opens admin. Fast path.
- Paired device, expired cookie → login redirect. Recovery path.
- Paired device, server cert rotated (new `zed bootstrap rotate
  tls_selfsigned` when that ships) → pin mismatch. Error path.
- Replay of a consumed OTT → `token_used` error.
- Expired OTT (wait past TTL) → `token_expired` error.
- Rate limit: 11 rapid redeems → 11th gets the error card.
- Offline network → timeout error.

Each path documented with a screenshot in `docs/B0_TESTING.md`.

## Acceptance criteria (B0 merge)

- [ ] `zedz` repo exists on `192.168.0.33` and on dev host
- [ ] APK installs alongside probnik on a test phone (different bundle id)
- [ ] Parser recognises `:zed_admin` tag and produces a typed payload
- [ ] AdminLoginActivity opens the LiveView admin after a successful scan + biometric
- [ ] Cert pinning fails-closed on fingerprint mismatch
- [ ] All 8 error paths from Step 5 produce distinct, user-readable errors
- [ ] Re-open of a paired node without rescanning works
- [ ] `specs/qr-schema.md` unchanged (contract frozen at S1)

## Dependencies

- `zed serve` running on jail (Layer A complete ✓)
- `specs/qr-schema.md` contract frozen (done ✓)
- Android dev host with SDK + existing probnik build infrastructure
- Test phone with camera and biometric

## Sync points

**S1 — qr-schema frozen:** closed at A2b merge. Any change to the
tuple shape is a coordinated both-sides commit.

**S2 — reachability check:** at B0 Step 5 kickoff, confirm the test
phone can reach the jail (`ping 192.168.0.116` from the phone's
browser or a network tool). DHCP drift risk — the phone may need a
fresh scan after an IP change.

## Risks

| Risk | Mitigation |
|---|---|
| macOS dev unavailable → no iOS port | Android-only for B0; iOS deferred to its own iteration |
| Jail IP changes between scan and redeem (DHCP drift) | Mitigated by 5-min OTT TTL; worst case user rescans |
| OkHttp cert-pinning spec incompatible with self-signed certs that change subject CN | `tls_selfsigned` always uses `/CN=zed-web`; if that changes, bump qr-schema spec and re-pair devices |
| `ProbnikQR.payload_term/1` output differs slightly across OTP versions (`~p` format stability) | Mobile parser is regex-based and tolerant of whitespace; tested against OTP 26 output |
| Java/Kotlin rewrite drift vs probnik's current state | Fork at a specific probnik commit sha; don't chase upstream churn during B0 |
