# A5 — Bastille jail backend

**Status:** speculative, not started. Lands the decision to depend on
[Bastille](https://bastille.readthedocs.io/en/latest/) for jail +
network lifecycle, so zed stops reinventing VNET/bridge/epair
plumbing. Keeps zed's ZFS + secret-bootstrap + admin-UI scope fully
in-tree; Bastille is narrow and subordinate.

**Effort:** ~1.0 pm.
**Slots into:** Layer A extensions, between A4 (SSH-key auth) and
Layer B / Layer C work. C3 (SMB + TM) depends on this because Samba
will run in a Bastille-managed jail.

---

## Decision locked 2026-04-24

| # | Decision | Value |
|---|---|---|
| 8 | Jail + network lifecycle | **Depend on Bastille.** Call out to the `bastille` CLI via a typed Elixir adapter. Reason: VNET/bridge/epair is weeks of FreeBSD plumbing we don't need to re-derive; Bastille has done it for seven years, pure shell, BSD-licensed, no runtime deps beyond base FreeBSD. |
| 9 | State-of-truth | **zed remains authoritative via `com.zed:*` ZFS user properties.** Bastille's `${prefix}/jails/<name>/jail.conf`, `zfs.conf`, `rdr.conf`, `fstab` are treated as *cache*, re-rendered on every converge. |
| 10 | `Zed.ZFS` | **Stays in-tree.** Bastille's `bastille zfs` is thinner than zed's encryption + property + rollback surface; swapping would lose features. |
| 11 | iocage | **Drop.** Once plausible is migrated, no residual iocage dependency. The mountpoint-doubling jail path-view quirk from A1/C3 goes away as a side effect. |

---

## What zed keeps doing itself

- ZFS dataset + encryption + snapshot + `com.zed:*` user-property stamping (A1, `Zed.ZFS`, `Zed.Bootstrap`).
- Secret bootstrap: `beam_cookie`, `admin_passwd`, `ssh_host_ed25519`, `tls_selfsigned` with SANs.
- Admin LiveView + QR OTT + passkey + SSH-key auth.
- BEAM release unpacking + cookie wiring + distributed-Erlang friendly networking config emitted *into* Bastille's jail config.

## What Bastille does on zed's behalf

- Jail lifecycle: `create / start / stop / restart / destroy / rename / clone / list`.
- Release bootstrap + update: `bastille bootstrap <release>`, `bastille update`.
- Network: VNET, bridged VNET, alias/shared, NAT with auto `bastille0` lo interface, `rdr` port redirection with pf table auto-management, live `bastille network add/remove`.
- Inside-jail execution: `bastille cmd`, `bastille pkg`, `bastille service`, `bastille sysrc`, `bastille cp`, `bastille edit`.
- Cross-host export/import/migrate (later; not Layer A scope).
- Resource limits via `bastille limits` wrapping `rctl`.

## What neither system does yet (future work)

- Multi-host cluster view. Bastille is single-host; zed will layer this on top when needed (D6 Vault + replication already contemplates two hosts).
- Template registry with provenance. Bastille supports git-bootstrapped community templates; zed will only ship a `zed/*` namespace under Bastille's template store, never auto-execute external templates.

---

## Architecture

```
 DSL (Zed.DSL.jail :web do ... end)
         │
         ▼
 IR node (type: :jail, config: %{...})
         │
         ▼
 Zed.Converge — computes diff vs live state (read via Zed.Platform.Bastille.status/1 + com.zed:* props)
         │
         ▼
 Zed.Platform.Bastille — typed adapter to the `bastille` CLI
         │
         ▼
 bastille {create|start|stop|cmd|rdr|network|template} — shells out
         │
         ▼
 FreeBSD jail(8) / pf / epair / netgraph
```

State flows upward through ZFS user properties that zed stamps on
the jail's dataset; Bastille's on-disk config files are regenerated
by zed's converge each time.

---

## New module: `Zed.Platform.Bastille`

Thin typed adapter. One module, a handful of functions, clear
error returns. Prefer side-effect verification over CLI output
parsing.

```elixir
defmodule Zed.Platform.Bastille do
  @moduledoc """
  Adapter around the `bastille` CLI. Each function shells out,
  captures stdout/stderr, returns {:ok, result} | {:error, reason}.
  No output parsing beyond narrow strings that Bastille documents
  as stable (jail name, state, IP).

  Converge reads current state by inspecting ZFS datasets + jail(8)
  rather than scraping `bastille list` — more reliable across
  Bastille versions.
  """

  @spec create(name :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  @spec start(name :: String.t()) :: :ok | {:error, term()}
  @spec stop(name :: String.t()) :: :ok | {:error, term()}
  @spec destroy(name :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  @spec cmd(name :: String.t(), argv :: [String.t()]) ::
          {:ok, output :: String.t()} | {:error, term()}

  @spec rdr(name :: String.t(), proto :: :tcp | :udp, host_port :: 1..65535,
            jail_port :: 1..65535) :: :ok | {:error, term()}
  @spec rdr_clear(name :: String.t()) :: :ok | {:error, term()}

  @spec apply_template(name :: String.t(), template_path :: String.t()) ::
          :ok | {:error, term()}

  @spec status() :: [%{name: String.t(), state: :running | :stopped, ip: String.t() | nil}]
  @spec ensure_bootstrap(release :: String.t()) :: :ok | {:error, term()}
end
```

Implementation:
- `System.cmd("bastille", [...], stderr_to_stdout: true)` with explicit timeout.
- Detect `bastille` on PATH at module load; raise a clear message on absence.
- Version probe on first call; warn if Bastille is older than the minimum we test against (pin at the cutover version).

## DSL integration

Current DSL:

```elixir
jail :web do
  dataset "jails/web"
  contains :web_app
  ip4 "10.0.1.10/24"
end
```

After A5, the converge pass for a `jail` node:

1. `Zed.ZFS.Dataset.create/2` the backing dataset (unchanged).
2. `Zed.Platform.Bastille.create/2` with a Bastillefile that wires:
   - VNET + bridge config derived from `ip4`/`ip6` DSL opts
   - `pkg` installs from the contained app's deps
   - `sysrc` for services
   - `cp` of the app release tarball into the jail
3. `Zed.Platform.Bastille.start/1`.
4. `Zed.Platform.Bastille.cmd/2` for post-start ops (e.g. `bastille cmd web service myapp start`).
5. Stamp `com.zed:jail.<name>.state` + `com.zed:jail.<name>.image_hash` + `com.zed:jail.<name>.applied_at` on the jail's dataset so subsequent converges can diff.

## Bastillefile emitter

New module `Zed.Platform.Bastille.Template`:

```elixir
def emit(%IR.Node{type: :jail, config: config} = node, app_node) do
  lines = []
  lines ++= ["# Generated by zed — do not edit, rewritten on every converge"]
  lines ++= ["PKG #{Enum.join(app_node.config[:pkg] || [], " ")}"]
  lines ++= ["CP #{app_node.config[:release_tarball]} /opt/#{app_node.id}.tar.gz"]
  lines ++= ["CMD tar -xzf /opt/#{app_node.id}.tar.gz -C /opt"]
  lines ++= ["SYSRC #{app_node.id}_enable=YES"]
  lines ++= ["SERVICE #{app_node.id} start"]
  Enum.join(lines, "\n")
end
```

Write to `${bastille_prefix}/templates/zed/<jail>/Bastillefile`.
Apply via `bastille template <jail> zed/<jail>`.

---

## Pilot — migrate plausible from iocage to Bastille

Sequence run once, manually, to de-iocage the dev environment:

```sh
# on host rango, as root

pkg install -y bastille
sysrc bastille_enable=YES
service bastille start

# Stop plausible in iocage
iocage stop plausible

# Export iocage jail as a zip
iocage export plausible

# Bootstrap a FreeBSD release if not already
bastille bootstrap 14.1-RELEASE

# Import into Bastille (reads the zip from iocage's export path)
bastille import /iocage/images/plausible_<timestamp>.zip

# Re-apply the jeff/zed-test ZFS delegation — Bastille preserves it
# differently; `bastille zfs jail jeff/zed-test plausible` is the
# direct equivalent of `iocage set jail_zfs=on + jail_zfs_dataset=...`
bastille zfs jail jeff/zed-test plausible

# Start and verify
bastille start plausible
bastille console plausible  # shell in; confirm git remote, zfs access

# When happy, nuke the iocage jail
iocage destroy -f plausible
```

One-time operator steps on the host. Zed's Bastille adapter never
performs the initial `bastille bootstrap <release>` — that's a host
install concern, documented in a new `scripts/host-setup-bastille.sh`.

---

## Iteration breakdown

| Sub-step | Scope | Effort |
|---|---|---|
| A5.1 | `Zed.Platform.Bastille` adapter with create/start/stop/destroy/cmd + version probe | 3 h |
| A5.2 | `rdr` + `network` primitives; pf-rule idempotency via Bastille | 2 h |
| A5.3 | `Zed.Platform.Bastille.Template` emitter — PKG/CP/SYSRC/SERVICE/RDR hooks | 3 h |
| A5.4 | DSL `jail` verb backed by Bastille adapter; converge + diff for jails | 4 h |
| A5.5 | ZFS property stamping on jail datasets (`com.zed:jail.<name>.*`) | 1 h |
| A5.6 | Integration tests tagged `:bastille_live` — create/destroy under `jeff/zed-test/bastille-test-<uuid>` | 3 h |
| A5.7 | `scripts/host-setup-bastille.sh` + pilot migration of plausible | 2 h |
| A5.8 | Docs + plan updates | 1 h |

Total ~19 h ≈ 1.0 pm.

---

## Integration test strategy

Same shape as A1's jail round-trip:

- `test/zed/platform/bastille_test.exs` — unit tests for the adapter
  (version probe, argv construction, error classification).
- `test/zed/platform/bastille_integration_test.exs` tagged
  `:bastille_live` — requires a FreeBSD host with `bastille`
  installed and a usable release bootstrap cache. Skip on Linux dev
  host. Run in jail or on the real FreeBSD host during Layer C
  iterations.

Tests assert via side-effect checks:
- After `create`, `jail -c` lists the jail.
- After `start`, `jls` includes it.
- After `stop`, it's gone from `jls`.
- After `destroy`, the dataset is gone and `bastille list` doesn't include it.

No parsing of `bastille list` output beyond "name present yes/no."

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Bastille CLI output is human-readable, not JSON-stable | Parse only documented-stable fields; prefer side-effect verification |
| Bastille rewrites jail.conf behind zed's back | Converge re-renders from `com.zed:*` props; treat Bastille files as cache |
| Bastille version skew across hosts | Pin minimum version; version probe at module load; error with a clear message |
| `bastille zfs jail` delegation vs zed's encrypted `<base>/zed/secrets` | Delegate non-secret datasets to Bastille jails; keep the secrets dataset outside any jail delegation |
| Single-maintainer project | Pure shell, readable, fork-able if needed; no lock-in at the FreeBSD primitives layer |
| Community templates pull arbitrary content | Zed only uses `zed/*` templates under `${bastille_prefix}/templates/zed/`; never auto-execute external |

---

## Open questions for the user (before kickoff)

1. **Pilot timing.** Migrate plausible now (before A5 code lands), or wait until A5.4 is ready and do the migration as part of verifying the adapter?
2. **Cutover to A4/A5 order.** A4 (SSH-key admin auth) is still not started. Run A5 first because C3 depends on it? Or A4 first because it's the shortest?
3. **Template provenance policy.** Accept community Bastillefiles as starting points (copy-paste into `zed/*`) or hand-write every one?
4. **Minimum Bastille version pin.** Probably current (1.4.2). Bump only when a feature we rely on moves.

---

## Cross-references

- Comparison research (retained as context): Bastille commit-today, pure POSIX shell, single-binary-ish (~525 KB), pkgbase + HardenedBSD + Linux-jail support, Bastillefile DSL with ARG/CMD/CP/CONFIG/INCLUDE/LIMITS/LINE_IN_FILE/MOUNT/PKG/HPKG/RDR/RENDER/SERVICE/SYSRC/TAGS hooks, `rdr` pf-table integration, `migrate` for ZFS-send cross-host.
- A1: `Zed.Bootstrap` + ZFS 3-tier storage (unchanged).
- A2a/A2b: LiveView + QR admin (unchanged).
- A3: passkey auth (unchanged).
- C3 (future): SMB + TM + mDNS will run inside a Bastille-managed jail instead of iocage.
- D6/D7 (future Probnik Vault): orthogonal.
