# Secrets Design

How Zed resolves credentials and sensitive configuration from DSL declarations to the running BEAM.

## Scope

This document covers Phase 5 secrets support. It is a design proposal — no code has been written yet.

The motivating example is a common shape: a BEAM app that integrates with multiple external services under a single deployment — several broker-account credential pairs, a license key, a Phoenix `secret_key_base`, a distribution cookie. Today those live as a mix of plaintext config files and shell-exported environment variables. The design has to make that deploy no worse than it is today, and ideally much better.

## Non-Goals

- Hourly-rotating credentials. That is Vault-class infrastructure, out of scope.
- Defense against a root compromise on the target host. If an attacker is root, the BEAM runtime user's secrets are readable regardless — this is a problem no deploy tool solves.
- A GUI or web dashboard for secrets. Zed is Elixir in, Elixir out.

## DSL Shape

Secrets live in a nested block inside `app`. Each secret binds a name (atom) to a source expression.

```elixir
app :broker_bot do
  dataset "apps/broker_bot"
  version "1.5.0"
  cookie {:env, "BEAM_COOKIE"}

  secrets do
    broker_a_key    {:env, "BROKER_A_API_KEY"}
    broker_a_secret {:env, "BROKER_A_API_SECRET"}
    broker_b_token  {:file, "/var/run/secrets/broker_b.token"}
    license_key     {:env, "LICENSE_KEY"}
    secret_key_base {:env, "SECRET_KEY_BASE"}
    accounts_config {:file, "secrets/accounts.config.age", mode: :age}
  end

  health :beam_ping, timeout: 5_000
end
```

### Source expressions

| Source | Meaning | MVP? |
|--------|---------|------|
| `{:env, "VAR"}` | Read from target-host process environment at converge time | ✅ MVP |
| `{:file, path}` | Read plaintext file on target, trim trailing newline | ✅ MVP |
| `{:file, path, mode: :age}` | Read age-encrypted file, decrypt with keyfile | Phase 5.1 |
| `{:zfs_prop, "com.zed:name"}` | Read from ZFS user property (non-secret config only) | Phase 5.1 |
| `{:op, "op://Vault/Item/field"}` | 1Password CLI lookup | Post-5.1 |

Secrets are compile-time validated: the right-hand side must match one of the allowed patterns, or `mix compile` fails with a source location.

## Three-Layer Pipeline

```
DSL                           IR                             Target host
───                           ──                             ───────────
secrets do              ▶     %{secrets: [                   1. Resolver reads each source
  broker_a_key             ▶      {:broker_a_key,      ▶       ({:env, ...} → System.get_env/1
  {:env, "BROKER_..."}          {:env, "BROKER_..."}}          {:file, ...} → File.read/1)
end                           ]}                             2. Abort if any source missing
                                                             3. Write /opt/<app>/env, mode 0600
                                                             4. rc.d/SMF loads env file at boot
                                                             5. BEAM reads via System.get_env/1
```

### Layer 1 — source

Source expressions are stored in the IR as inert tuples. The compiler validates syntax and shape; it does **not** read any value. This keeps the controller free of plaintext — only the target ever sees resolved secrets.

### Layer 2 — resolver

`Zed.Secret.resolve/1` runs on the target during `converge`, before the app's service is (re)started. Each source is resolved in turn:

- `{:env, var}` → `System.get_env(var) || {:error, {:missing_env, var}}`
- `{:file, path}` → `File.read(path)` with trim, `{:error, {:missing_file, path}}` on failure
- `{:file, path, mode: :age}` → shell-out to `age -d -i <keyfile>`, error on non-zero exit

**Fails closed.** Any missing secret aborts the converge. No half-started service with garbage env.

### Layer 3 — sink

Resolved secrets are written to a single file per app:

```
/opt/<app>/env          (mode 0600, owned by runtime user)
```

Format: `KEY=value` lines, values shell-escaped. The rc.d/SMF service definition loads this file before starting the BEAM.

- **FreeBSD rc.d:** `daemon -e /opt/<app>/env` or `. /opt/<app>/env` in the rc script
- **illumos SMF:** `envvar` properties in the manifest, or `. /opt/<app>/env` in the exec_method
- **Linux systemd (dev):** `EnvironmentFile=/opt/<app>/env` in the unit

The BEAM reads values via `System.get_env/1` in `runtime.exs`, which is how most existing Elixir releases already do it. **Zero application code changes.**

## Why This Shape

- **One 0600 file per app.** Easy to audit (`ls -la /opt/*/env`), easy to rotate (write new file atomically), easy to destroy on rollback (the ZFS dataset holding it gets snapshotted and rolled with everything else).
- **Resolution on target, not controller.** Plaintext never crosses the wire. The controller ships `{:env, "X"}` tuples and source file paths, not values.
- **Env-var sink.** Matches existing Elixir release convention (`runtime.exs`, `System.get_env/1`). No new library, no new pattern to learn.
- **Fails closed.** A missing secret is a deploy abort, not a service that starts and then 500s on the first external API call.

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| Secret in git repo | `{:env, ...}` or `{:file, ...}` only — inline strings rejected at compile |
| Secret in shell history | Env vars set by operator or CI, not typed into interactive shells |
| Secret readable by other users on target | `/opt/<app>/env` is mode 0600, owned by runtime user |
| Secret in ZFS property | `{:zfs_prop, ...}` is flagged as non-secret only; compiler rejects it for `secrets` block |
| Secret in logs | `Zed.Secret.resolve/1` result is `%Zed.Secret{value: ..., source: ...}` with custom `Inspect` impl that prints `"#Zed.Secret<redacted>"` |
| Secret survives rollback | Each deploy writes a new `/opt/<app>/env`; `zfs rollback` restores the previous version atomically |
| Plaintext on the wire | Resolution happens on target; controller never holds values |

Out of scope: root compromise, kernel exploits, memory scraping, side-channel attacks, state-actor adversaries.

## Structured Multi-Account Config Files

A common pattern: an app that holds several broker-account credential pairs (one record per account, each with its own API key and secret) in a single structured Elixir config file. Treating each field as a separate DSL secret would explode the config surface and couple Zed's DSL to the app's internal account model. Better to keep the config as one opaque blob.

Two options for handling it:

**Option A (MVP):** Keep the file on the target, reference it as a single secret:

```elixir
secrets do
  accounts_config {:file, "/opt/broker_bot/secrets/accounts.config"}
end
```

The file is deployed via a separate out-of-band process (operator SCPs it once, or a bootstrap script seeds it from a password manager). Zed doesn't ship the contents — it only references the path.

**Option B (Phase 5.1):** Age-encrypt in-repo and decrypt on target:

```elixir
secrets do
  accounts_config {:file, "secrets/accounts.config.age", mode: :age}
end
```

Keyfile location is a per-target convention (`/root/.zed/age.key`, mode 0400). Rotation = re-encrypt with a new public key, commit, redeploy.

MVP ships Option A. Option B is an additive change once age integration is in.

## Decisions Deferred

1. **`:age` as a first-class mode.** Need to pick: shell-out to `age` binary, or vendor the Rust `age` crate via Rustler. Shell-out is simpler; Rustler is more portable. Decide when we actually get to Phase 5.1.
2. **`{:zfs_prop, ...}` for secrets.** Rejected. ZFS user-property values show up in `zfs get all` which is readable by any user with dataset access. The property channel is fine for non-secret config (node_name, version) but not secrets. Keep it off the secrets source list.
3. **Secret rotation verb.** `zed secrets rotate <app>` would re-resolve and atomically swap the env file. Design once we have a user asking for it.
4. **Per-account secrets for multi-broker apps.** An app with several broker accounts could either expose per-account names in the DSL (`secrets do account_primary_key ... account_backup_key ... end`) or ship a single opaque `accounts_config` file. MVP: opaque file. If Zed grows a multi-account-aware `app` verb later, revisit.

## Module Shape

```
lib/zed/secret.ex              # resolver: resolve/1, resolve_all/1
lib/zed/secret/source.ex       # source validation + pattern types
lib/zed/secret/sink/env_file.ex # writes /opt/<app>/env
lib/zed/secret/inspect.ex      # redacted Inspect impl for resolved values
test/secret_test.exs           # unit: resolver + sink, no real env
test/secret_live_test.exs      # integration: real env vars, real file on test ZFS dataset
```

Wire-up points in existing code:

- `lib/zed/dsl.ex` — add `secrets do ... end` macro, emit `{:secrets, [...]}` into IR
- `lib/zed/ir/validate.ex` — extend `check_no_inline_secrets/1` to validate source tuples inside the secrets block
- `lib/zed/converge/executor.ex` — after `Release.deploy/3`, call `Secret.resolve_all/1` and write env file before starting the service
- `lib/zed/platform/*.ex` — each platform backend emits service definition that loads the env file

## Open Questions for the Reviewer

1. Do you want age encryption in the MVP, or deferred to 5.1?
2. For a structured multi-account config file: Option A (opaque file on target, path-only reference) or Option B (age-encrypted in repo)?
3. Is `/opt/<app>/env` the right path, or should it live inside the ZFS dataset (`<pool>/<dataset>/env`)? ZFS-resident means it rolls back with the app, which is probably what we want.
