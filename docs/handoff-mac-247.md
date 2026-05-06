# Handoff to Claude on mac-247 (free-macpro-gpu)

This Mac already finished **S3 enriched-jail-DSL-verbs** in commits
`1035969` + `8237763`. Next chunk: **S5a — per-app releases for the
two compose-translation apps (Plausible + craftplan).** These are
the painful ones — both ship docker-compose stacks today and need
real release surgery.

Paste the **Briefing** block below into a fresh Claude session
running here.

---

## Briefing (paste verbatim)

> You are continuing work on the **`zed`** project. Branch:
> `feat/demo-cluster`. Read these in order before suggesting any
> action:
>
> 1. `git fetch origin && git checkout feat/demo-cluster && git pull --ff-only`
> 2. `git log feat/demo-cluster --oneline | head -15` — iteration arc.
> 3. `specs/demo-cluster-plan.md` — the off-docker-compose 5-app
>    cluster demo plan. The framing is migration *off* docker-compose.
> 4. `specs/clickhouse-on-freebsd.md` — the OTHER Mac's S4 result;
>    Plausible stays in the demo, native FreeBSD `clickhouse` 25.11
>    pkg is the path.
> 5. `lib/zed/examples/demo_off_compose.ex` — the demo DSL module
>    using S3's enriched syntax (you wrote that).
> 6. `docs/demo-runtime-snippets.md` — per-app `runtime.exs` blocks
>    the Linux session prepared (covers all five apps).
>
> ### Your scope: S5a — Plausible + craftplan releases
>
> The two compose-translation apps. Each one's docker-compose.yml
> is the source-of-truth; you produce a `mix release` artifact that
> reproduces the same behaviour, plus a `runtime.exs` block that
> wires into the cluster.
>
> #### App 1 — Plausible (the harder one; do first)
>
> Repo: clone fresh under `~/plausible/` from
> `https://github.com/plausible/community-edition` (or upstream
> `plausible/analytics`; pick the one whose compose maps cleanest).
>
> 1. **Survey first** — `cat docker-compose.yml` and list every
>    service, env var, volume, and port. Compare to
>    `specs/demo-cluster-plan.md`'s `:plausible` jail block.
> 2. **`mix.exs` release config** — add a `releases:` block targeting
>    `:unix`, name `:plausible`. Plausible may not currently produce
>    a clean `mix release`; this is the surgery part.
> 3. **`config/runtime.exs`** — paste the Plausible block from
>    `docs/demo-runtime-snippets.md`. DATABASE_URL points at
>    `10.17.89.20`; CLICKHOUSE_DATABASE_URL at `10.17.89.21`.
>    Drop the `mail` (Postfix) sidecar — out of demo scope.
> 4. **`rel/env.sh.eex`** — paste the cookie-loading template from
>    the same doc. Set `RELEASE_NODE` to
>    `plausible@<jail-ip>` (10.17.89.12 hardcoded is fine; the
>    cluster topology is also hardcoded).
> 5. **Build** — `MIX_ENV=prod mix release plausible`. If it builds,
>    note the artifact path. If it doesn't, capture the failure and
>    commit a `specs/plausible-release-blockers.md` listing what's
>    in the way; don't keep banging on it.
> 6. **Commit** under `feat/demo-cluster` with a message like
>    "S5a: plausible release scaffold + runtime.exs". Push.
>
> #### App 2 — craftplan
>
> Repo already at `~/projects/learn_erl/sim_ex/research/craftplan/`
> on this Mac.
>
> 1. **Survey** — `cat docker-compose.prod.yml`. Compare to the
>    `:craftplan` jail block in the demo plan.
> 2. **Already has `mix release` config?** Check `mix.exs`. If yes,
>    just add the cluster snippets. If not, add a `releases:` block.
> 3. **`config/runtime.exs`** — paste the craftplan block from
>    `docs/demo-runtime-snippets.md`. DATABASE_URL points at
>    `10.17.89.20` (same Postgres jail Plausible uses).
> 4. **`rel/env.sh.eex`** — same cookie-loading template; `RELEASE_NODE`
>    is `craftplan@10.17.89.11`.
> 5. **Build** — `MIX_ENV=prod mix release`. Note the artifact path.
>    The `_build/prod/rel/craftplan/` tarball is what S6 will land
>    inside the jail.
> 6. **Commit + push** as a separate commit.
>
> ### What you do NOT touch
>
> - `lib/zed/` — the Linux session is the owner of all DSL, IR,
>   converge, cluster module work. Don't change anything under
>   `lib/zed/`.
> - `lib/zed/examples/demo_off_compose.ex` — also Linux-session
>   territory.
> - The five "easy" apps (zedweb, livebook, exmc) and the DB jails
>   (pg, ch) — those are mac-248's territory. `docs/handoff-mac-248.md`
>   has its scope.
>
> ### Coordination
>
> Three sessions are live: Linux is on cluster-config plan-step
> wiring. mac-248 is on the easy apps + DB jails. You are on
> Plausible + craftplan. **Rebase before every commit:**
>
> ```sh
> git fetch origin && git rebase origin/feat/demo-cluster
> ```
>
> If a rebase conflict surfaces, stop and ping the operator —
> don't resolve creatively.
>
> ### Things you can run as `io` without password
>
> Per the existing `/usr/local/etc/doas.conf`:
> - `doas bastille create/start/stop/list/cmd` (no password)
> - Anything via `doas` for wheel members (`io` is in wheel) with
>   `permit persist :wheel as :root` — first call prompts, then
>   5-min cache.
>
> Don't need root for any S5a work — `mix release` is unprivileged.
>
> Confirm you've read the spec + the runtime snippets doc before
> starting.

---

## Out-of-band notes (don't paste)

### Why mac-247 gets the painful apps

This Mac just finished S3, so its session has the most context on
the demo's IR shape and where the runtime.exs blocks need to plug
in. Plausible is the highest-risk piece (Docker-first project, may
not produce a clean release without surgery); doing it on the
machine with the most demo context minimizes confusion.

If Plausible's release proves intractable in <4h of work, ping the
operator before further investment. Realworld backend or Phoenix
Storybook are documented fallbacks in the demo plan.

### Why this doesn't touch DSL code

The Linux session is mid-flight on the `:cluster_config_write` plan
step (the artifact-write hook). Two sessions writing in `lib/zed/`
simultaneously is asking for a merge conflict.

### Order of expected pushes (rough)

1. Linux: cluster_config plan step + tests (~2h)
2. mac-247: plausible scaffold (~3h, may stall on release surgery)
3. mac-248: DB jails + zedweb + livebook + exmc (~3h, parallel)
4. mac-247: craftplan release (~1h, after plausible)
5. Sync point: all S5 work in main → S6 starts

### When to retire this doc

After the demo lands. Same as `handoff-mac-session.md`.
