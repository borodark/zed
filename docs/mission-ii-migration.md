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
