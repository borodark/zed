# Mission II — Live Trial Migration to mac-247

**Status:** in progress, branch `feat/mission-ii-linux` (will rename;
the original framing was Linux+CUDA but the user pivoted to a
FreeBSD+Vulkan target).

**Goal:** move the production exmc trial off super-io (Linux + RTX
3060 Ti) onto mac-247 (FreeBSD + GT 650M Vulkan), with a graceful
cutover that doesn't lose checkpoints or stranded positions.

**Constraint discovered early:** GT 650M is a Kepler-era GPU with
~20× lower raw throughput than RTX 3060 Ti, and ~1 GB VRAM vs
8 GB. The full 67-instrument live trial can't move wholesale —
this is a **subset migration**, not a 1:1 swap.

---

## M-II.fix3 — Vulkan cold-path code-server deadlock *(open, found 2026-05-17)*

Found while verifying M-II.fix2. Three NUTS workers spawned
concurrently on the freshly-patched trader; **none completed in
8 minutes**. Stack traces revealed three different stuck states:

```
SPY pid=#PID<0.4792.0> dev=vulkan status=:waiting
  current_function: {:code_server, :call, 1}
  stacktrace:
    code_server.call/1 (line 159)
    code_server.call/1 (line 159)          ← recursive code-server wait
    Nx.Vulkan.shader_path/1 (line 174)
    Nx.Vulkan.add/2         (line 166)
    Nx.Vulkan.Backend.do_binary/4
    Nx.Defn.Evaluator.eval_apply/4

GLD pid=#PID<0.4791.0> dev=vulkan status=:running
  current_function: {Enum, :drop_list, 2}

XOM pid=#PID<0.4793.0> dev=vulkan status=:running
  current_function: {Nx.Vulkan.Native, :upload_binary, 1}
```

Diagnosis: first-dispatch cold-path on the Vulkan shader triggers
`Code.ensure_loaded/1` somewhere in `Nx.Vulkan.shader_path/1`
(line 174) or its callee `Nx.Vulkan.Synthesis.compile/1` (which
needs `:crypto.hash/2` for the content-addressed cache key). The
`code_server` serialises module loads. If multiple workers race
the cold path, the second and third deadlock behind the first.

This is the M-I.0 finding (`:crypto` not auto-started under mix
test) coming back in a different form — same root cause, different
trigger.

### Patch sketch

After `Nx.Vulkan.Node` starts and BEFORE the trading children:

```elixir
defp gpu_children do
  with Nx.Vulkan <- Exmc.JIT.detect_compiler(),
       true <- Code.ensure_loaded?(Nx.Vulkan.Node) do
    [Nx.Vulkan.Node, {Task, fn -> vulkan_warmup() end}]
  else
    _ -> []
  end
end

defp vulkan_warmup do
  # Resolve every module the cold-path uses, then one trivial
  # dispatch.  After this returns, code_server lookups for the
  # Vulkan path are warm and worker races can't deadlock.
  for mod <- [Nx.Vulkan, Nx.Vulkan.Native, Nx.Vulkan.Synthesis,
              Nx.Vulkan.ChainShaderSpecs, :crypto] do
    Code.ensure_loaded!(mod)
  end
  Application.ensure_all_started(:crypto)
  Nx.Vulkan.Node.with_node(fn ->
    Nx.iota({16}, type: :f32) |> Nx.add(1.0) |> Nx.sum() |> Nx.to_number()
  end)
  Logger.info("[Application] Vulkan warmup complete")
end
```

The Task is a transient child — it runs once, exits clean. The
Supervisor restart strategy keeps the warmup from re-running on
worker crashes.

### Status

- The 3 stuck workers from the fix2 verification will eventually
  resolve (the first one's code_server lookup completes, then the
  queue drains slowly).
- Until M-II.fix3 lands, every trader restart will replay this
  dance.
- TLA+ angle: same shape as the rotation SOP's invariants —
  "every active worker completes within max_runtime." A
  ComputePool TLA+ spec would catch the no-warmup race as a
  liveness violation. Worth doing alongside the rotation spec.

## M-II.fix2 — backend-aware GPU tag *(done, 2026-05-17)*

`Exmc.Trading.ComputePool` hard-coded `:cuda` as the GPU worker
tag (line 246 of compute_pool.ex). On mac-247 (Vulkan-only),
workers got `device: :cuda` passed into `sample_opts`; the
compiler set `client: :cuda` on a host with no CUDA; the sampler
hung forever. Live evidence at the swap point:
**3 of 258 jobs completed, 141 went stale, 7 workers stuck for hours**
(gens 1, 2, 3 still pending alongside gen 51).

Patch shipped upstream at `phd@bb2249a1e`:

```elixir
defp gpu_tag do
  case Exmc.JIT.detect_compiler() do
    EXLA -> :cuda
    EMLX -> :metal
    Nx.Vulkan -> :vulkan
    _ -> :host
  end
end

defp sampler_device(:cuda), do: :cuda
defp sampler_device(_),     do: :host
```

Two-stage translation: the **accounting tag** (`:cuda`/`:vulkan`/
`:metal`/`:host`) is what `count_by_device` uses for slot
budgeting; the **sampler device opt** is what the compiler/JIT
actually understands. Vulkan and MLX dispatch through their own
backends (`Nx.Vulkan.Node`, `EMLX.Backend`), so the JIT client
must stay `:host` for them — anything else routes through a
non-existent JIT client.

`count_by_device` extended to match all GPU tags
(`:cuda | :vulkan | :metal`) so Vulkan workers count toward the
GPU concurrency budget (`Nx.Vulkan.Node` serialises through one
GenServer; over-scheduling just queues at the mailbox).

Verified live on mac-247: post-swap, `active=3 devs=%{vulkan: 3}`
(no `:cuda` tags). The tag bug is fixed; the deeper M-II.fix3
deadlock is now the bottleneck.

## M-II.fix — Vulkan.Node auto-start *(done, 2026-05-16)*

The Mission II investigation immediately surfaced a latent
production bug: the Mission-I-deployed trader on mac-247 had been
running 9 hours with `compiler=Nx.Vulkan` and
`default_backend=Nx.Vulkan.Backend`, but **`Nx.Vulkan.Node` was
never started** in the live BEAM process. NUTS calls hung; the
HealthCheck watchdog reset instruments every 300 s; equity polls
kept working so the trader *looked* alive.

This was the M-I.2 follow-up gap "Nx.Vulkan.Node not auto-started
by Exmc.Application," promoted from "small upstream fix" to "this
is why Mission II investigation started."

**Fix shipped at `phd@a59def26c`:**
```elixir
defp gpu_children do
  with Nx.Vulkan <- Exmc.JIT.detect_compiler(),
       true <- Code.ensure_loaded?(Nx.Vulkan.Node) do
    Logger.info("[Application] Starting Nx.Vulkan.Node (compiler=Nx.Vulkan)")
    [Nx.Vulkan.Node]
  else
    _ -> []
  end
end
```
Wired into `Exmc.Application.start/2` as `gpu_children() ++ trading_children()`.

**Verification on mac-247 after rebuild + tar swap:**
```
vulkan_node: #PID<0.1832.0>
sum(iota(1024)+1) = 5.248e5 in 1077us
device: NVIDIA GeForce GT 650M
```
Round-trip on Vulkan confirmed. `Process.whereis(Nx.Vulkan.Node)`
returns a live pid at boot, every boot.

**Side discovery:** the M-I.2 deploy log + erlang.log.{1,2,3} on
mac-247 prove the bug had been silent for the entire window
between M-I.2 and Mission II. The trader was producing zero
posterior updates. Equity stayed flat at $6912.29 across all four
of yesterday's log rotations. The trader was a load-bearing zombie.

---

## M-II.bench — measure GT 650M throughput *(in progress)*

After M-II.fix, the 3-instrument trial (SPY/GLD/XOM) on mac-247 is
the test fixture for measuring real GT 650M throughput. Metrics
captured:

| Metric | Source | Target |
|---|---|---|
| Wall time per NUTS round | `:sys.get_state` `sample_gen` delta + wall clock | establish per-instrument cost |
| GPU occupancy | `Nx.Vulkan.Node` message queue length over time | identify queueing vs idle |
| VRAM headroom | (not directly observable on FreeBSD; back-calculate from MEMORY #64 estimate) | ~1 GB GT 650M Mac Edition |
| Watchdog resets | grep erlang.log.* for "stuck sampling" | should be **zero** post-fix |
| Posterior update cadence | `ticks_since_update` over time | aim for `update_interval` honoured |

Headroom calculation: ~25 MB/job × N instruments = VRAM budget.
At 1 GB total, ceiling ≈ 40 concurrent jobs. With `gpu=3` workers
in `ComputePool` (per Mission I boot log), VRAM is **not** the
bottleneck for 3-15 instruments — wall-time-per-step is.

Bench results pending — log monitor watching for `sample_gen`
advancement on the 3 instruments. First natural NUTS pass arrives
within `orchestrator interval_ms` (default 5 min) from the M-II.fix
restart at 17:01 UTC.

---

## M-II.subset — pick what moves *(planned)*

GT 650M can't do 67 instruments at the dev-host's rate. A subset
chosen by importance × NUTS cost.

Selection axes:
- **importance** — instruments with open positions; instruments
  the regime model is producing actionable signals on; instruments
  in higher-equity accounts
- **NUTS cost** — model complexity per instrument (HMC chain depth
  varies with parameter count; some instruments fit faster than
  others)
- **policy** — instruments the operator wants live regardless

Default policy proposal (subject to user override):
1. All instruments with non-zero current position
2. Top N by absolute z-score over the last 7 days (highest signal)
3. Pad to ~12–15 total instruments

The rest stay on the dev host until either (a) mac-247 capacity
allows expansion or (b) a better GPU is added to a FreeBSD host.

---

## M-II.cutover — graceful migration *(planned)*

Sequence:
1. Snapshot dev-host checkpoints + instruments file at a stop point.
2. `zfs send | ssh mac-247 zfs recv` the relevant checkpoint subtree
   (the `alpaca_6k/` subdir for the chosen subset).
3. Update mac-247's accounts.config with the production credentials
   (paper account only; live account stays on dev host or moves to
   a separate jail).
4. Restart mac-247 trader to pick up new instruments.
5. Confirm posteriors restoring + first NUTS pass green.
6. Stop the corresponding instruments on the dev-host trial (don't
   kill the whole trial — `HotReloadWorker` should remove just the
   migrated symbols).
7. Watch for ~1 h for any divergence between the two trials.

Rollback story:
- If mac-247 trial misbehaves: stop mac-247 trader, re-add
  instruments to dev-host trial's `instruments.txt`, the hot-reload
  worker picks them back up.
- ZFS snapshots at every step provide bit-exact rollback of the
  checkpoint state.

---

## M-II.docs+tag — γ *(planned)*

When the cutover is stable, tag `γ` with the migration receipt and
the subset policy as a `policy/` file.

---

## What was *not* the answer

The original Mission II framing (Linux + CUDA backend) was the
obvious next step from Mission I given super-io's RTX 3060 Ti, but
the user pivoted to "move the live trial to mac-247." The Linux +
CUDA platform-backend research (`specs/linux-cuda-platform.md`)
stays valid for a future mission; mac-247 + Vulkan is the immediate
target.
