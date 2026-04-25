# Handoff to Claude on mac-248

This Mac already finished **S4 ClickHouse-on-FreeBSD validation**
in commit `628ebda`. Verdict: native FreeBSD pkg `clickhouse` 25.11
is clean; Plausible stays in the demo. Next chunk: **S5b — the
three easy app releases (zedweb, livebook, exmc) plus the two
database jails (pg + ch).**

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
> 4. `specs/clickhouse-on-freebsd.md` — your own S4 result; the
>    pkg + jail recipe lives here, including the four Plausible XML
>    config snippets that ride along.
> 5. `lib/zed/examples/demo_off_compose.ex` — the demo DSL module
>    (the OTHER Mac wrote it during S3). Read the `:pg`, `:ch`,
>    `:zedweb`, `:livebook`, `:exmc` jail blocks; you'll need their
>    IPs and verbs.
> 6. `docs/demo-runtime-snippets.md` — per-app `runtime.exs` blocks
>    the Linux session prepared (covers all five apps).
>
> ### Your scope: S5b — three easy releases + two DB jails
>
> Five distinct deliverables; each is small enough to land + commit
> independently. Order matters because zedweb depends on the zed
> repo state and livebook is the most predictable; do them first
> while the longer-running DB jail builds happen in the background.
>
> #### 1. zedweb release
>
> Already a release target in `mix.exs` (zed repo).
>
> ```sh
> cd ~/zed
> MIX_ENV=prod mix release zedweb --overwrite
> ls _build/prod/rel/zedweb/bin
> ```
>
> Note the artifact path. The release already exists from A5a.7
> work; just confirm it builds clean on this Mac too. **No commit
> needed unless something breaks** — this is a verify step.
>
> #### 2. livebook release
>
> Clone fresh under `~/livebook/` from
> `https://github.com/livebook-dev/livebook` (use the latest tag,
> not main).
>
> 1. `mix.exs` — confirm a `releases:` block exists for `:livebook`.
>    Livebook does ship one upstream.
> 2. `config/runtime.exs` — paste the livebook block from
>    `docs/demo-runtime-snippets.md`. Bind on `10.17.89.13:8080`;
>    password from `/var/db/zed/secrets/livebook_passwd`.
> 3. `rel/env.sh.eex` — cookie-loading template; `RELEASE_NODE` is
>    `livebook@10.17.89.13`.
> 4. `MIX_ENV=prod mix release`. Capture artifact path.
> 5. Commit + push as "S5b: livebook release scaffold + runtime.exs".
>
> #### 3. exmc release
>
> Repo at `~/projects/learn_erl/pymc/exmc/` on this Mac (or pull
> latest from origin if needed).
>
> 1. **GPU disable** — confirm
>    `Application.put_env(:exmc, :compiler, :binary_backend)` is
>    set in the prod runtime path. The `:compiler` key already
>    exists per the catalog notes; just make sure the prod default
>    is `:binary_backend` (jails can't passthrough GPU).
> 2. `mix.exs` — add a `releases:` block targeting `:unix`, name
>    `:exmc`. exmc may not have one today.
> 3. `config/runtime.exs` — paste the exmc block from
>    `docs/demo-runtime-snippets.md`. ALPACA_API_KEY_ID and
>    ALPACA_SECRET_KEY come from env (operator-supplied).
> 4. `rel/env.sh.eex` — cookie-loading template; `RELEASE_NODE` is
>    `exmc@10.17.89.14`.
> 5. `MIX_ENV=prod mix release`. Capture artifact path.
> 6. Commit + push as "S5b: exmc release scaffold + binary backend".
>
> #### 4. pg (PostgreSQL) jail prep
>
> No release; this is a host-side jail bootstrap doc. Drop
> `scripts/demo-pg-bootstrap.sh` that:
>
> 1. `bastille create pg 15.0-RELEASE 10.17.89.20/24`
> 2. `bastille pkg pg install -y postgresql16-server`
> 3. Copy `data/pg` ZFS dataset (created by zed converge) into the
>    jail's `/var/db/postgres` via the nullfs mount the demo plan
>    lays out.
> 4. `bastille cmd pg /usr/local/etc/rc.d/postgresql initdb`
> 5. `sysrc -j pg postgresql_enable=YES`
> 6. `bastille service pg postgresql start`
> 7. Create `craftplan` and `plausible_db` databases + their users
>    (passwords from `/var/db/zed/secrets/pg_admin_passwd`).
>
> Don't *run* this script yet — S6 will. Just commit the script.
>
> #### 5. ch (ClickHouse) jail prep
>
> Same shape as pg, in `scripts/demo-ch-bootstrap.sh`. Use the
> recipe from your own `specs/clickhouse-on-freebsd.md` — the four
> Plausible XML config snippets included.
>
> 1. `bastille create ch 15.0-RELEASE 10.17.89.21/24`
> 2. `bastille pkg ch install -y clickhouse`
> 3. Drop the four Plausible XML overrides into
>    `/usr/local/etc/clickhouse-server/config.d/`
> 4. `sysrc -j ch clickhouse_enable=YES`
> 5. `bastille service ch clickhouse start`
> 6. Create the `plausible_events_db` database + user.
>
> Commit as separate commits per script.
>
> ### What you do NOT touch
>
> - `lib/zed/` — the Linux session is the owner of all DSL, IR,
>   converge, cluster module work.
> - The two compose-translation apps (Plausible, craftplan) — those
>   are mac-247's territory. `docs/handoff-mac-247.md` has its
>   scope.
>
> ### Coordination
>
> Three sessions are live: Linux is on cluster-config plan-step
> wiring. mac-247 is on Plausible + craftplan releases. You are on
> the easy releases + DB jail prep. **Rebase before every commit:**
>
> ```sh
> git fetch origin && git rebase origin/feat/demo-cluster
> ```
>
> If a rebase conflict surfaces, stop and ping the operator.
>
> ### Things you can run as `io` without password
>
> Per the existing `/usr/local/etc/doas.conf`:
> - `doas bastille create/start/stop/list/cmd` (no password)
> - Wheel doas with persist (5-min cache after first prompt)
>
> Don't need root for the release builds. Need root via doas for
> any `bastille create` you choose to dry-run-test the bootstrap
> scripts against (recommend NOT running yet — S6 is the
> integration step).
>
> Confirm you've read the spec + the runtime snippets doc + your
> own clickhouse-on-freebsd.md before starting.

---

## Out-of-band notes (don't paste)

### Why mac-248 gets the easy apps + DB jails

This Mac just finished S4 (ClickHouse research), so its session
has fresh context on the FreeBSD pkg landscape — perfect for the
DB jail bootstrap scripts. The "easy" releases (zedweb, livebook,
exmc) are mostly mechanical paste-from-snippet work; can run in
parallel with the DB scripts.

### Why exmc is on this Mac and not the other

exmc's repo is at `~/projects/learn_erl/pymc/exmc/` on this Mac
already. mac-247 doesn't have a checkout. Avoiding cross-Mac scp.

### When the DB scripts get tested

S6 (end-to-end converge) is when scripts get exercised. Don't
test-run them yet — bastille-create + initdb leaves state on the
host that we'd then need to teardown. S6 will do it once, cleanly.

### Order of expected pushes (rough)

1. Linux: cluster_config plan step (~2h)
2. mac-248: zedweb verify + livebook + exmc releases (~2h, parallel)
3. mac-247: plausible scaffold (~3h)
4. mac-248: pg + ch bootstrap scripts (~2h, after releases)
5. mac-247: craftplan release (~1h, after plausible)
6. Sync point: all S5 work in main → S6 starts

### When to retire this doc

After the demo lands.
