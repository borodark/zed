# The Last Environment Variable

*Path C6 — how to make a shared cookie stop existing in the
operator's shell. Four bugs, one of which was Erlang silently
misparsing its own command-line arguments.*

---

## The last `SMOKE_COOKIE`

The Path C smokes all had a line at the top:

```sh
export SMOKE_COOKIE=abc123def
```

Then somewhere: `doas env SMOKE_COOKIE=$SMOKE_COOKIE mix run -e "..."`.
The releases inside the jails read `RELEASE_COOKIE` from an env
file that Zed's `:jail_app :deploy` executor wrote with the
resolved value. Both nodes shared the cookie via the env file, not
via the shell directly — but the shell was still the source of
truth, and every operator running the smoke needed to know the
value.

Path C6 makes that line go away. Cookie generated once by
`Zed.Bootstrap.init`. Stored on an aes-256-gcm-encrypted ZFS
dataset. Discovered at converge via a stamped ZFS property.
Written into the jail's env file. The operator never sees it.
`SMOKE_COOKIE` doesn't exist anywhere in the C6 smoke's shell
environment.

That is the entire story. What made it interesting was that Zed's
secrets machinery was almost entirely done before Path C6 started
— and the "almost" hid four bugs that only surface once the whole
chain actually runs against a real Erlang release with a real
generated cookie.

## What Zed already had

Before Path C6:

- `Zed.Bootstrap.init/2` created two ZFS datasets under a base
  pool: `<pool>/zed` (metadata, unencrypted, carries all
  `com.zed:*` properties) and `<pool>/zed/secrets` (encrypted,
  passphrase-locked, holds the actual bytes). Idempotent — a second
  invocation with the same passphrase skips already-generated
  slots.
- `Zed.Secrets.Store.write_value/3` and `read_value/1` handled the
  file I/O.
- `Zed.Secrets.Catalog` declared eight slots including
  `:beam_cookie` (algo `:random_256_b64`, single-value).
- `Zed.Secrets.Generate.random_256_b64/0` produced 32 bytes of
  `:crypto.strong_rand_bytes` base64-url-encoded.
- `Zed.IR.Validate.check_secret_refs/1` validated `{:secret, :slot,
  :field}` DSL references against the Catalog at IR compile time.
- `Zed.Cluster.Config.read_cookie!/1` resolved `{:env, ...}` and
  `{:file, ...}` cookie shapes for cluster config artifacts — but
  explicitly did NOT resolve `{:secret, ...}` and said the converge
  engine must do that first.

The pipeline had one hole: `Zed.Beam.Env.resolve_cookie/1`, added
in Path C3, returned `{:error, {:secret_ref_not_yet_supported,
slot}}` for `{:secret, ...}` references. C6's whole job was to
replace that clause with a real resolver and thread the necessary
context — the metadata dataset name — through the plan and
executor.

That's about 40 lines of Elixir plus the smoke fixture.

## The wiring

Five files changed.

### `lib/zed/secrets/resolve.ex` — new module

Forty lines. `resolve(dataset, slot, field)` fetches
`Zed.ZFS.Property.get_all(dataset)`, looks up the appropriate
property key (`secret.<slot>.path` for single-value, `pub_path`
for `.pub`, `cert_path` for `.cert`), and reads via
`Zed.Secrets.Store.read_value/1`. A `resolve_from_props/3` helper
takes an already-fetched properties map so unit tests don't need a
live ZFS dataset. All error paths fail closed:
`:slot_property_missing`, `:read_failed`, `:unknown_field`.

### `lib/zed/beam/env.ex` — extend to 2-arity

`resolve_cookie/1` becomes `resolve_cookie/2` accepting an optional
`opts` keyword. The `{:env, ...}`, `{:file, ...}`, and binary
clauses ignore `opts`. `{:secret, slot, field}` reads
`opts[:dataset]` and calls `Zed.Secrets.Resolve.resolve/3`. If the
dataset opt is missing, fail closed with
`:secret_dataset_not_provided`. Trim trailing newline like
`{:file, ...}` already does.

### `lib/zed/converge/plan.ex` — thread the dataset

`build_jail_app_deploy_step` gets a `pool` parameter. When
non-nil, `zed_dataset: "#{pool}/zed"` lands in the step args.
That's the convention `Zed.Bootstrap.init` uses too, so both sides
agree on where to look.

### `lib/zed/converge/executor.ex` — pass it through

The `:jail_app :deploy` executor's `write_jail_env_file` builds
`resolve_opts = if is_nil(args[:zed_dataset]), do: [], else:
[dataset: ...]` and passes it into `Zed.Beam.Env.resolve_cookie/2`.
Env/file/binary refs work unchanged; only `{:secret, ...}` picks up
the new context.

### `lib/zed/examples/smoke_contained_real_secrets.ex` — new fixture

Two jails on `10.17.89.95/96`, both `cookie {:secret,
:beam_cookie}`. Every `SMOKE_COOKIE` reference removed. Cluster
verb declares both nodes as members. The `cookie` on the cluster
verb is also `{:secret, :beam_cookie}` — same slot, same bytes,
same shape.

### `scripts/bootstrap-secrets.sh` — one-time helper

Idempotent wrapper around `Zed.Bootstrap.init` that runs once on
the target host. Takes `BOOTSTRAP_PASSPHRASE` from the env. Creates
`mac_zroot/zed` + `mac_zroot/zed/secrets`, generates every catalog
slot, prints what was generated vs. skipped.

`mix test`: 339 passes, 0 failures. Push, `git pull` on mac-248,
run the smoke.

## The four bugs

The above shipped in one commit and *did not work*. The next four
commits are what it actually took.

### Bug 1: Rollback masking the primary error

First converge attempt failed with:

```
** (ArgumentError) all arguments for System.cmd/3 must be binaries
    (elixir 1.17.3) lib/system.ex:1105: System.cmd/3
    (zed 0.1.0) lib/zed/platform/freebsd.ex:31: Zed.Platform.FreeBSD.service_restart/1
    (elixir 1.17.3) lib/enum.ex:987: Enum."-each/2-lists^foreach/1-0-"/2
    (zed 0.1.0) lib/zed/converge.ex:40: Zed.Converge.run/2
```

This is not a C6 error; it's a *rollback* error. The primary
converge failed for a different reason, `Zed.Converge.run/2`
called `rollback_pre_deploy(ir)`, and the rollback path did:

```elixir
defp restart_app_service(app, platform) do
  service = app.config[:service] || to_string(app.id)
  platform.service_restart(service)
end
```

My smoke declared `service :hello_beam` — an atom. `service`
became `:hello_beam`, `platform.service_restart(:hello_beam)`
called `System.cmd("service", [:hello_beam, "restart"], ...)`,
`System.cmd` refused non-binary args, and the actual primary
failure was buried under the rollback's own crash.

Fix: `service = to_string(app.config[:service] || app.id)`. One
character in the right place. The next run surfaced the actual
first bug.

### Bug 2: Health probes missed the dataset threading

C6.c wired `zed_dataset` into `:jail_app :deploy` step args
because that's where the env file gets written. But
`:jail_health :probe :beam_ping` also resolves a cookie — the
DSL says:

```elixir
health :beam_ping,
  node: :"hello_beam@10.17.89.95",
  cookie: {:secret, :beam_cookie},
  ...
```

The probe's `resolve_probe_cookie/1` called
`Zed.Beam.Env.resolve_cookie/1` (1-arity), which triggered my new
`{:secret_dataset_not_provided, :beam_cookie, :value}` error path.
The step failed:

```
{:jail_health_failed, "hello_beam_a95", :hello_beam_a95, :beam_ping, 0,
 {:probe_cookie_resolve_failed,
  {:secret_dataset_not_provided, :beam_cookie, :value}}}
```

Fix: extend `build_jail_health_steps` to also inject `zed_dataset`
into each probe's opts, and have the `:beam_ping` executor read it
and thread through `resolve_probe_cookie`. Two file changes,
mirrored from Slice C6.c.

### Bug 3: `Node.set_cookie/2` didn't affect `:net_adm.ping/1`

With bug 2 fixed, the probe resolved the cookie correctly. Still
returned `:pang`. From the probe's perspective:

```elixir
Node.set_cookie(target_node, cookie_atom)
:net_adm.ping(target_node)
```

`Node.set_cookie/2` sets a per-target cookie. But
`:net_adm.ping/1` — at least on Erlang/OTP 26 — uses
`Node.get_cookie/0` (the local cookie) when establishing the
connection, not the per-target one. My probe process's local
cookie was still whatever Erlang auto-generated at BEAM startup.

Fix: set BOTH.

```elixir
Node.set_cookie(cookie_atom)          # local
Node.set_cookie(node, cookie_atom)    # per-target
```

Belt-and-suspenders. `set_cookie/1` is the one that fixed the
probe; `set_cookie/2` stays for defense across Erlang versions.

### Bug 4: `-setcookie` and leading dashes

With bugs 1–3 fixed, the probe was doing the right thing. Ping
still returned `:pang`.

I manually verified from a fresh iex — same cookie, same
target — same result. `:pang`. Cookies matched exactly on both
sides:

```
disk cookie: -iQRzpP9bmrie6X6sgjkN_Ehv3IcORHAjBrs-tG-1vs (43 chars)
env cookie:  -iQRzpP9bmrie6X6sgjkN_Ehv3IcORHAjBrs-tG-1vs (43 chars)
```

Same 43 bytes. Same string. So why the mismatch?

The target BEAM was started by mix release via:

```
/opt/hello_beam/current/erts-14.2.5.12/bin/beam.smp -- ...
  -setcookie -iQRzpP9bmrie6X6sgjkN_Ehv3IcORHAjBrs-tG-1vs
  -name hello_beam@10.17.89.95
  ...
```

Two tokens after `-setcookie`. What does Erlang's command-line
parser do with `-setcookie` followed by a value that starts with
`-`?

I ran the smallest possible reproduction:

```sh
erl -noshell -name test@127.0.0.1 \
  -setcookie "-iQRzpP9bmrie6X6sgjkN_Ehv3IcORHAjBrs-tG-1vs" \
  -eval "io:format(\"~p~n\", [erlang:get_cookie()])" \
  -s init stop
```

Output:

```
'OCDFNNAUFCMCOIKGJZGB'
```

Not the intended cookie. Erlang's argument parser saw `-setcookie`
as a flag needing a value, saw the next token started with `-`,
treated it as *another* flag, and fell back to reading
`~/.erlang.cookie` — which for a fresh install is a random
20-character uppercase atom.

Zero warnings. Zero errors. The BEAM started up, its cookie was
`'OCDFNNAUFCMCOIKGJZGB'`, and the probe's cookie was the
disk value. They didn't match; ping returned `:pang`; the probe
correctly reported failure but not for the reason the failure
existed.

The root cause is that `Zed.Secrets.Generate.random_256_b64/0` uses
`Base.url_encode64(padding: false)`. URL-safe base64 uses
`A-Z`/`a-z`/`0-9`/`-`/`_`. Any output has a 2-in-64 chance of
starting with `-` or `_` — the two characters that break both erl's
argument parser (for `-`) and any shell that treats `_` specially
in some context I haven't hit yet.

Fix in `Zed.Secrets.Generate`: reject leading `-` or `_` and
re-roll.

```elixir
def random_256_b64 do
  case :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false) do
    <<"-", _::binary>> -> random_256_b64()
    <<"_", _::binary>> -> random_256_b64()
    good -> good
  end
end
```

Expected retry count is ~1. In pathological cases, ~2. This is a
production-quality fix — no entropy lost, no ergonomic
compromise, just a hard constraint on the acceptable output.

Destroy the encrypted secrets dataset (safe — no real secrets in
it yet), re-run bootstrap, get a fresh `beam_cookie` starting with
`g` this time. Re-run the smoke.

## The verify

Nineteen steps, `{:ok, [...]}`. Then:

```
=== [OK] Zed metadata dataset mac_zroot/zed exists
=== [OK] secrets dataset encrypted (aes-256-gcm)
=== [OK] com.zed:secret.beam_cookie.path stamped (/var/db/zed/secrets/beam_cookie)
=== [OK] cookie file /var/db/zed/secrets/beam_cookie exists, mode 0400
=== [OK] jail hello_beam_a95 exists
=== [OK] jail hello_beam_a95 is running
=== [OK] jail hello_beam_a96 exists
=== [OK] jail hello_beam_a96 is running
=== [OK] both env files contain the same RELEASE_COOKIE value
=== [OK] env file cookie matches on-disk secret
=== [OK] epmd on 10.17.89.95:4369 reachable
=== [OK] epmd on 10.17.89.96:4369 reachable
=== [OK] BEAM node hello_beam registered in hello_beam_a95
=== [OK] BEAM node hello_beam registered in hello_beam_a96
=== [OK] node .95 sees .96 in Node.list ([:"hello_beam@10.17.89.96", :"verify@127.0.0.1"])
=== verify: PASS
```

Two `[OK]` lines are the point of Path C6:

- `env file cookie matches on-disk secret` — the whole trust chain
  from Bootstrap generation through ZFS property to jail env file
  is bit-exact.
- `node .95 sees .96 in Node.list` — both BEAM nodes authenticated
  their distributed handshake using the resolved secret. `Node.list`
  returned `[:"hello_beam@10.17.89.96", :"verify@127.0.0.1"]`. The
  peer is there. So is the transient verify BEAM the smoke script
  used to test connectivity.

The verify BEAM connected using the same cookie, resolved by the
verify script the same way: `doas cat /var/db/zed/secrets/beam_cookie`
directly, since the verify script runs on the host with root access
to the mounted secrets dataset. In production this would come from
whatever authenticated pathway the operator uses to talk to the
cluster.

## Bugs the mocks couldn't have caught

Every one of the four:

1. **Rollback masking primary errors** requires an actual converge
   failure to trigger. Unit tests don't cascade into rollback paths
   the way live converges do. This bug had been there since Path B
   and only surfaced now because C6's converge happened to hit an
   error path that ran through rollback.

2. **`:beam_ping` dataset threading** looks obvious in retrospect
   but is exactly the class of bug that surfaces only when you
   thread context through one call site and forget the other. Unit
   tests for the executor's health probes pass their own opts map;
   they never exercise the plan → executor threading.

3. **`Node.set_cookie/2` vs `set_cookie/1`** is an Erlang version
   / distribution-mode subtlety. Unit tests against `Node.self()`
   pass because a node pinging itself doesn't do the same handshake
   as two distinct nodes.

4. **Erlang's argument parser silently accepting invalid values**
   is genuinely a lurking bug in Erlang, and it *only* manifests
   when the cookie value happens to start with `-`. In 62 of 64
   randomly generated slots you would never hit it. In production
   over months, one random Bootstrap re-init after key rotation
   would eventually hit it, silently, and the cluster would
   partition. This is the class of bug that convinces you the mock
   isn't enough.

All four made the C6 blog post. Path B was primitives, Path C1-C5
was the release surface, Path C6 was the secrets surface. Every
slice ends with the same kind of "the mock wouldn't have caught
this" list, and every list makes the case for building on the
metal.

## What's under `main`

```
a59e685 zed: random_256_b64 refuses leading dash/underscore
1c7e7c2 zed: set both local + per-target cookie in :beam_ping probe
45ee6c8 zed: thread zed_dataset into :beam_ping probes for {:secret, :slot} resolution
5213756 zed: rollback_pre_deploy service name must be a binary
854bb44 zed: Path C6 — {:secret, :slot} cookie resolution against encrypted ZFS
```

Five commits, one big + four fixes. Suite: 339 tests, 0 failures.
Live on mac-248.

The DemoOffCompose target — five BEAM apps clustered, backed by
Postgres and ClickHouse, cookies from encrypted ZFS — is now
reachable end-to-end. What remains for a full production posture is
mostly around orchestration:

- Rotation as a DSL-level verb (`Bootstrap.rotate/3` exists, no DSL
  wire yet).
- Re-key (change the encryption passphrase).
- Multi-consumer coordination for a slot referenced by several
  apps.
- Audit log of secret access.
- Migration of one of Igor's real apps to Zed deployment.

Path C6 was the biggest hurdle for the demo-worthiness of the
cluster. The remaining paths are polish and specific to the apps
being deployed.

The `SMOKE_COOKIE` line at the top of the smoke scripts is gone.
The operator doesn't type a cookie value anywhere. A distributed
BEAM cluster of two nodes, authenticated by a cookie generated once
and stored encrypted at rest, comes up from one function call. That
was C6.
