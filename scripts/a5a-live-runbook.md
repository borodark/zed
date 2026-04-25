# A5a.5 live runbook — FreeBSD Mac Pro

Goal: green run of `bastille_handler_live_test.exs` on a real
FreeBSD 15.0 Mac Pro against bastille 1.4.1, exercising the full
privilege boundary (`OpsClient → Socket → Handler → Runner.System →
doas bastille`).

**Do NOT run `host-bring-up.sh`** in this pass — it would replace
the existing `/usr/local/etc/doas.conf` and tighten the wheel rule,
risking lock-out before A5a.6 has shipped the relaxed-mode shim.
A5a.5 only needs the existing wheel-doas rule that A5.1 already
relied on.

## Prereqs (one-time, per Mac Pro)

```sh
doas pkg install -y elixir gmake
# Verify
elixir --version
make --version 2>&1 | head -1   # BSD make is fine; we don't need gmake
```

## Per-run

```sh
cd ~/projects/zed                 # adjust to wherever you cloned
git fetch origin
git checkout feat/a5a-privilege-boundary
git pull --ff-only

mix deps.get
mix compile                       # builds priv/peer_cred.so via elixir_make
```

If `mix compile` fails on the NIF: confirm `cc` is in `$PATH` and
that `priv/` exists at the project root (the `_build/.../priv`
symlink target). `ls -la priv` — empty dir is fine; missing dir
will fail.

## doas persist (only matters if your rule lacks `nopass`)

The new `Runner.System` always shells `doas bastille ...`. If your
existing /usr/local/etc/doas.conf has the A5.1-era catch-all rule:

```
permit nopass :wheel as :root cmd bastille
```

then no warm-up is needed — `nopass` runs without prompting forever.

If your rule uses `persist` instead (e.g. `permit persist :wheel as
root`), seed the persist timestamp with a no-op as root:

```sh
doas /usr/bin/true
```

(FreeBSD's doas port has no `-v` verify-only flag; that's an
OpenBSD-only convenience. Run any trivial command as root to seed
the timestamp file in /var/db/doas.)

## Run

Existing A5.1 live tests (verifies the rename to `escalation`
didn't break anything):

```sh
mix test --only bastille_live test/zed/platform/bastille_integration_test.exs
```

Expected: `5 tests, 0 failures`.

A5a.5 acceptance — full boundary path against real bastille:

```sh
mix test --only bastille_live test/zed/ops/bastille_handler_live_test.exs
```

Expected: `2 tests, 0 failures`. The first test creates a jail
named `zed-test-bh-<rand>` on `10.17.89.<100-199>/24`, runs `uname
-s` inside it, stops, destroys, and verifies absence — all through
the Unix socket. The second test exercises destroy on a non-existent
jail across the boundary.

## What "green" proves

1. `peer_cred.so` builds and loads on FreeBSD; `getpeereid(2)`
   returns the correct uid for the local connection.
2. `:gen_tcp` Unix-socket listener with `packet: 4` framing works
   on FreeBSD (path-bind, accept, recv, send).
3. Wire envelope `{:zedops, :v1, request_id, :bastille_run, ...}`
   round-trips intact via term-to-binary/safe binary-to-term.
4. The web-side `Runner.OpsClient` reshapes the reply into the
   `{output, exit_code}` contract `Zed.Platform.Bastille` expects,
   indistinguishable from in-process `Runner.System`.
5. The destroy post-condition check (the "lie at exit zero" guard)
   survives the boundary: bastille's silent no-op against a stale
   stub still produces `{:error, {:destroy_did_nothing, _}}`.

## If a test fails

Capture the failure and paste it back. Likely failure modes:

- **NIF not loaded** — `priv/peer_cred.so` missing or wrong arch.
  `file priv/peer_cred.so` should report a FreeBSD ELF.
- **Socket bind permission denied** — `/tmp` not writable by the
  test user. Should not happen.
- **doas prompts for password mid-test** — persist expired; re-run
  `doas -v` and the test.
- **Bastille destroy "exit 0 but jail still alive"** — this is the
  case A5.1 caught originally; the new test asserts the boundary
  preserves that protection. If it surfaces, the bug is in the
  reshape, not in bastille.
