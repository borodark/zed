# Handoff to a Claude Code session on the Mac (FreeBSD host)

Paste the **Briefing** block below as the first message in a fresh
Claude Code session running on the FreeBSD Mac (`free-macpro-gpu`,
`192.168.0.247`, account `io`). It gets the new session productive
in under two minutes without re-deriving project state.

---

## Briefing (paste verbatim)

> You are continuing work on the **`zed`** project — a declarative
> BEAM deploy tool on FreeBSD + ZFS. We're on the
> `feat/demo-cluster` branch. Read these in order, then ask before
> doing anything that touches the host:
>
> 1. `specs/demo-cluster-plan.md` — the off-docker-compose 5-app
>    cluster demo plan (this is what we're building toward).
> 2. `lib/zed/examples/demo_off_compose.ex` — the MVP DSL module
>    that already compiles and produces a 17-resource diff.
> 3. `git log feat/demo-cluster --oneline | head -10` — the
>    iteration arc so far.
> 4. `specs/iteration-plan.md` — the broader roadmap.
>
> ### Where we are in the demo plan
>
> - **S1 done** — spec + MVP DSL example committed.
> - **S2 partial** — cluster validation + `Zed.Cluster.Topology`
>   bridge committed. Still ahead in S2: dataset:mountpoint
>   converge wiring (already half-supported per converge/diff.ex
>   grep) and the cluster-config artifact apps actually read at
>   boot. Both gate on S3's app-inside-jail nesting decision.
> - **S3 pending** — DSL verbs: `packages`, `service`,
>   `nullfs_mount`, `app`-inside-`jail`.
> - **S4 pending** — validate ClickHouse on FreeBSD (port? linux
>   compat? fixture?). This gates Plausible's existence in the demo.
> - **S5 pending** — per-app releases for craftplan, plausible,
>   livebook, exmc, zedweb. Plausible is the painful one.
> - **S6 pending** — end-to-end converge against this Mac Pro.
> - **S7 pending** — recording + replay script + blog post.
>
> ### Host setup on this machine
>
> - User: `io`, in `wheel`.
> - doas rule: `permit nopass :wheel as :root cmd bastille` (A5.1
>   posture, not yet replaced by `docs/doas.conf.zedops`).
> - ZFS pool: `zroot_mac`. Test parent dataset:
>   `zroot_mac/zed-test` (already created with `canmount=off`).
> - Bastille: 1.4.1 installed; `15.0-RELEASE` bootstrapped.
> - Existing live tests: `:bastille_live` (7) and `:zfs_live` (24)
>   both run green here.
>
> ### Test-running patterns
>
> ```sh
> # Pure unit suite (no host touch)
> mix test
>
> # ZFS live (needs root for encrypted-dataset mount; persist via
> # nopass doas rule, no password prompt expected)
> doas env PATH="$PATH" ZED_TEST_DATASET=zroot_mac/zed-test \
>   mix test --include zfs_live
>
> # Bastille live (no doas needed at the test layer; Runner.System
> # always prepends doas internally and the wheel rule covers it)
> mix test --include bastille_live
> ```
>
> Don't run Claude Code itself under doas — that gives every
> subsequent action root. Use per-command doas instead.
>
> ### Don't run yet
>
> - `scripts/host-bring-up.sh` — would replace the existing
>   `/usr/local/etc/doas.conf` with the strict A5a template,
>   tightening the wheel rule. Defer until A5a.6's relaxed shim is
>   ready or until the demo is on its own host.
>
> ### What's likely to be the first action
>
> Probably **S4 — ClickHouse validation**. Quickest path: `pkg
> search clickhouse` and report what's available, then sketch
> whether linux-compat or pkgsrc is needed. This is research, not
> install — don't `pkg install` anything without checking first.
>
> Confirm you've read the plan + the example DSL before suggesting
> next actions.

---

## Out-of-band notes (don't paste; for the operator)

### What this Linux-side session has been doing

- Drafted the spec, wrote the MVP DSL module, added cluster
  validation + Topology bridge, set up the task list.
- Six Tasks queued (S2-finish through S7) with dependencies.
- Branch pushed to `origin/feat/demo-cluster` (192.168.0.33).

### Why two sessions instead of one

- DSL / IR / test work iterates fast on the Linux box (no SSH
  round-trip, full toolchain present).
- Host-touching work (bastille / zfs / pf live) belongs on FreeBSD.
- Splitting along this seam means each session does only what its
  environment is good at.

### Re-syncing the two sessions

- Branch is the source of truth. Both sessions push and pull from
  `origin/feat/demo-cluster`.
- Don't merge to `main` from either session without checking with
  the operator first — that's a coordination point.
- If both sessions need to edit the same file, the operator pauses
  one, lets the other land its commit, then resumes.

### When to retire this handoff doc

After the demo lands. The handoff is iteration-specific; once the
demo is on `main` and the next iteration starts on a different
branch, this doc gets either updated (if multi-machine continues)
or deleted (if everything moves back to one box).
