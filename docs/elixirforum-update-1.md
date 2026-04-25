# ElixirForum reply — zed progress update, April 2026

*Drafted 2026-04-25 as a follow-up to the original "secrets design — two forks I'd like opinions on" thread (April 16, 2026). Paste-ready below the horizontal rule.*

---

**Quick update for anyone who followed the original post — and answers to both forks.**

When I asked the forum about the two design forks (age-encrypted files vs ZFS user properties for secret material), the project had ~34 tests on FreeBSD and a half-written `Zed.Bootstrap`. Nine days and a lot of FreeBSD later, here's where things actually landed.

### What shipped

**A0 — DSL slot validation.** Secrets in the DSL now go through `{:secret, slot, field, storage: :local_file}` and the validator rejects unknown storage modes at parse time. Future modes (`:probnik_vault_pair`, `:shamir_k_of_n`) fail compilation until their implementation lands. The slot catalog is a single source of truth — typo a slot name in your DSL, get a compile error with the source location.

**A1 — `Zed.Bootstrap`.** Idempotent install-time generator for zed's own secrets: `beam_cookie`, `admin_passwd` (Argon2id), `ssh_host_ed25519`. All sit on an encrypted dataset (`<base>/zed/secrets`) with `canmount=noauto`. Fingerprints get stamped into ZFS user properties (`com.zed:fingerprint.<slot>`); the values themselves never live there. `zed bootstrap status/rotate/verify/export-pubkey` are wired up. Re-running `init` is a no-op. Drift detection is fingerprint-based — corrupt the file on disk and `verify` tells you which slot drifted.

**A2a — zed-web LiveView.** Phoenix 1.7 + LiveView, password login against `admin_passwd`, 8h rolling session, TLS with the bootstrap-generated self-signed cert. The first useful page is `/admin` showing live `Zed.Bootstrap.status/1` — not flashy, but it proved the round-trip from ZFS state to the browser.

**A2b — QR admin first-login.** `Zed.QR` renders an ANSI QR with a `{zed_admin, …}` Erlang-term payload; `Zed.Admin.OTT` is a GenServer with an ETS-backed atomic single-use consume. `bootstrap init` prints a 10-minute QR; the dashboard has a "Generate pairing QR" button issuing 2-minute OTTs. Rate-limited 10/min/IP. Audit log records the OTT prefix only.

**A3 — Passkey (WebAuthn).** Browser-only; uses `wax_` (pure Elixir, no NIF). Register on an authenticated session, sign in with biometric. Sign-count monotonicity catches replays. Works on Chrome desktop, Safari iOS, Chrome Android. The credential lives in the OS secure enclave — zedweb only ever sees the public COSE key.

**A4 — SSH-key challenge.** For operators who carry `ssh-ed25519` muscle memory but no passkey. Pubkey gets pasted in once (`authorized_keys` format, auditable with stock tools). Login is `POST /admin/ssh/challenge` → sign with `ssh-keygen -Y sign` → `POST /admin/ssh/response` → session cookie. Verification uses `:public_key.verify/4` from OTP — no extra dep. There's a 50-line shell script that does the whole flow and drops a cookie file for `curl --cookie`. Unblocks scripts.

**A5 — Bastille jail backend (this is the one that nearly broke me).** Adapter to FreeBSD's Bastille (1048-star pure-shell jail manager, BSD-licensed). 540 lines of Elixir, 79-line Runner behaviour, 64-line Mock for unit tests. 175 mocked unit tests passed cleanly on the laptop. The first live run on a real FreeBSD 15.0 Mac Pro found seven distinct production bugs in sequence. Long-form retro here: <https://www.dataalienist.com/blog-lie-at-exit-zero.html>.

The summary version: `bastille destroy -f` exits 0 even when it does nothing (running jail, no `-a`). The mock said the destroy worked. The system kept running. Every other failure was a shape of the same lesson — adapters exist precisely to convert soft contracts into hard ones, and the post-condition check is the only thing that catches a tool that lies on the way out. Final state on the Mac Pro: 5/0 live integration tests, merged to main as `daea21a`.

### A5a — privilege boundary (specced, not yet built)

A5.1 ran the BEAM as the same user that ran `doas bastille`. That's a perfectly fine pilot but not a production posture. `specs/a5a-privilege-boundary.md` lays out a two-user split: `zedweb` (network-facing, no doas) and `zedops` (privileged, doas-authorized for the bastille subcommands only). Communication via a small `gen_tcp` line-protocol over a Unix socket with a per-process token. ~1.5 person-months of work. Decisions 12-18 in the spec lock the surface area.

### Answers to the original forks

**Fork 1 — age-encrypted files.** Verdict: **yes, but as a `{:file, path, mode: :age}` source mode in the DSL, not as the bootstrap default.** Bootstrap stays on encrypted ZFS datasets — it's the right primitive for "secrets that travel with `zfs send`." age belongs in the user-supplied secret pipeline (`accounts.config.age` style), not in zed's own bootstrap chain. Implementation is Phase 5.1; the DSL syntax is already validated parse-time so consumers can write the references today and get a "not yet implemented" error at converge time, not a typo six months later.

**Fork 2 — ZFS user properties for secrets.** Verdict: **no, with a clarification.** Properties get *fingerprints* (`com.zed:fingerprint.<slot> = sha256:<hex>`), never values. The reason is a single sentence: ZFS properties are world-readable to any user with `zfs get` rights on the dataset. They're a great metadata backbone — they replicate with snapshots, they survive `send/recv`, they're free — but they are not a secret store. The `{:zfs_prop, "com.zed:name"}` source kind in the DSL is reserved for non-secret configuration only, and the validator will reject it for slots tagged `secret: true`. This was the cleanest answer once I started writing the threat model: properties optimise for visibility, secrets optimise against it.

### What's next

B0 (the `zedz` Android+iOS scanner — fork of `probnik`) is the next thing on the runway. After that, A5a — the privilege boundary that retires "BEAM-runs-as-bastille-user" forever. Layers C and D (NAS-adjacent + Probnik Vault + Shamir) remain shelved unless explicitly unshelved.

Thanks to everyone in the original thread — particularly the people who pushed back on Fork 2. The fingerprint-only compromise came directly out of that pushback.

— Igor

---

*Repo: <https://github.com/octanix/zed> (private during MVP; will open up once A5a lands).*
*Blog: <https://www.dataalienist.com/blog-lie-at-exit-zero.html>.*
*Specs: `specs/iteration-plan.md`, `specs/a5-bastille-plan.md`, `specs/a5a-privilege-boundary.md`, `docs/SECRETS_DESIGN.md`.*
