# QR Pairing Schema — `zed_admin`

**Purpose:** wire format for QR-delivered admin-session login between
the zed-web server and a companion mobile scanner. Frozen at A2b merge
so B0 (companion app, `zedz` Android/iOS) can parse against a stable
shape.

**Provenance:** derived from the `probnik_pair` term convention in
`probnik_qr`; same `io_lib:format("~p", [Term])` serialisation so a
single regex-based Erlang-term parser on the mobile side handles both
flows.

---

## Payload term

```erlang
{zed_admin,
  Node           :: atom(),                                     % e.g. 'zed@plausible'
  Host           :: {0..255, 0..255, 0..255, 0..255},           % IPv4 tuple
  Port           :: pos_integer(),                              % e.g. 4040
  CertFingerprint :: binary(),                                  % "sha256:<64-lowercase-hex>"
  OTT            :: binary(),                                   % 43-char base64url, no padding (256-bit entropy)
  ExpiresAt      :: integer()}                                  % unix seconds (UTC)
```

Wire example (what `io_lib:format("~p", [Term])` produces and the QR
encodes):

```
{zed_admin,'zed@plausible',{192,168,0,33},4040,"sha256:3f8a1bcc...",
"oEzKJ9v7Rm...","1713546000"}
```

Note: `~p` prints the IP tuple with braces + commas (no spaces on
FreeBSD OTP 26), and prints the unix timestamp as an integer. Strings
are printed with double quotes. Atoms single-quoted if non-trivial.

---

## Consumer contract (mobile companion app)

1. **Parse the term.** Regex-dispatch on first tag atom. `zed_admin`
   routes to `AdminLoginActivity` (equivalent on iOS). Any other
   first-tag falls through to probnik's existing handlers
   (`probnik_pair`, `probnikoff_net`) or to an unrecognised-QR error.

2. **Validate locally before network:**
   - `ExpiresAt` vs local clock. Reject if `now() > ExpiresAt + 10`
     (10s slack for clock skew).
   - Well-formedness of the tuple. Any missing/extra element → reject.
   - `CertFingerprint` matches `sha256:[0-9a-f]{64}`.

3. **Biometric confirm.** Prompt user: "Log in to <Node> at
   <Host>:<Port> as admin?" Face ID / fingerprint gate.

4. **Open WebView with cert pinning.**
   - iOS: `URLSession` + `URLSessionDelegate`. Compute SHA-256 of DER
     leaf cert from `serverTrust`; accept only on equality with
     `CertFingerprint`.
   - Android: `OkHttpClient` with `CertificatePinner` for API calls,
     `WebViewClient.onReceivedSslError` for the WebView itself.

5. **POST the OTT.** `POST https://<Host>:<Port>/admin/qr-login`
   with JSON body `{"ott": "<OTT>"}`.

6. **On success** (`200 {"ok": true, "redirect": "/admin"}`): follow
   redirect in WebView; session cookie is set by the server.

7. **On failure** (`401 {"ok": false, "error": "<reason>"}`): show
   error; offer "Request new QR" path.

---

## Server contract

- **Issue:** `Zed.Admin.OTT.issue/1` returns
  `{:ok, %{ott: binary, expires_at: int}}`. TTL defaults to 120s;
  `zed serve` startup uses 300s; bootstrap-time use (future) gets
  600s.
- **Payload build:** `Zed.QR.admin_payload/5` — accepts
  `(host_ip, port, cert_fp, ott, expires_at)` and stamps `Node.self()`.
- **Render:** `Zed.QR.show/1` prints ANSI; `Zed.QR.render/1` returns
  `{:ok, iodata}` for embedding.
- **Redeem:** `POST /admin/qr-login` → `ZedWeb.AdminQRController.redeem/2`.
  Rate limited 10/min per IP. Atomic single-use via `Zed.Admin.OTT.consume/1`.

### Error strings (stable)

| HTTP | `error` field     | Cause                                       |
|-----:|-------------------|---------------------------------------------|
| 401  | `invalid_token`   | OTT not in the ledger                       |
| 401  | `token_used`      | OTT already consumed                        |
| 401  | `token_expired`   | OTT past `expires_at`                       |
| 401  | `ott_required`    | POST body missing `ott` param               |
| 429  | `rate_limited`    | >10 requests / 60s from same IP             |

Error strings are contract. Don't rename without a companion app bump.

---

## Versioning

The tuple's first element acts as the version tag. Breaking changes
→ new tag (e.g. `zed_admin_v2`). Additions at the end of the tuple
are also breaking for strict-arity parsers; prefer a new tag.

Proper's `~p` format is stable across OTP 24+; do not rely on
whitespace or atom-quoting heuristics on the mobile side beyond what
the existing probnik regex already handles.

---

## Sync point

**S1 (closes at A2b merge):** this file is the frozen contract between
the server (Layer A) and mobile (Layer B). Any change here is a
coordinated both-sides change.
