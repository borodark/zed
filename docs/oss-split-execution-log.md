# OSS Split — Execution Log (2026-05-16)

What was already done, and what landed today.

## Pre-existing state

The OSS extraction had been substantially completed already, at
`_exmc-things/exmc/` and pushed to `github.com/borodark/exmc`
(remembered as `borodark/eXMC` in the GitHub URL).

- Repo: 280-line README, version `0.2.0`, dual-licensed
  (Apache-2.0 + Commercial), Hex-ready `package()` + `docs()`
  config.
- Architecture: **no `Application.ex` in OSS** — it's a pure library;
  user wires their own supervision.
- Module surface: the full PPL core (`advi`, `builder`, `compiler`,
  `dist`, `dsl`, `ir`, `jit`, `nuts/*`, `pathfinder`, `sampler`,
  `smc`, `stan`, `transform`, …). 34 test files.
- Drift vs phd/exmc as of 2026-05-03 (port date): the W7 vulkan
  validator dir (`nuts/vulkan/*`), `nuts/chain_shader_codegen.ex`,
  `mlx/`, and a handful of stability tweaks (W6 / sampler heuristic)
  haven't been backported.

`nx_vulkan` is similarly already public at
`github.com/borodark/nx_vulkan`, 178/178 tests on FreeBSD + GT 650M.

## Today's deliverables

### Track 1 — extract trading layer to its own repo

New repo skeleton at `/home/io/projects/learn_erl/_exmc-things/exmc_trading/`,
commit `ceb650c`, local-only (no GitHub remote yet — needs the
operator's repo creation step).

Contents:
- `lib/exmc/` — the proprietary subtree copied from `phd/exmc`:
  - `trading/` (39 files: Alpaca / IBKR / OANDA brokers, market
    feed, instrument supervision, hot-reload, GPU scheduler,
    risk, paper broker, dashboard)
  - `trading.ex`
  - `experiment/` (gradient_service, parallel_tree)
  - `license/` + `license.ex`
- `lib/exmc_trading/application.ex` — boot supervisor; ports the
  `trading_mode?()` env-guard logic and adds the M-II.fix
  `gpu_children/0` that starts `Nx.Vulkan.Node` when compiler is
  Vulkan. ABI-safe on other backends (returns `[]`).
- `native/exmc_license/` — Rust NIF crate.
- `mix.exs` — depends on OSS `exmc` via `{:exmc, github:
  "borodark/exmc", branch: "main"}` (default) or
  `EXMC_PATH=/local/path` for local iteration. Adds the trading-
  specific deps: `req`, `jose`, `fresh`, Phoenix LiveView,
  Bandit, telemetry, recon, propcheck.
- `README.md` — what's here vs what's not, local-iteration recipe,
  release build pattern.
- `.gitignore` for the standard `_build/deps/trial-checkpoints/
  accounts.config` exclusions.

**Status:** `EXMC_PATH=../exmc mix compile` succeeds. One known
cross-link issue: `Exmc.License.Native` hard-codes `otp_app: :exmc`,
so the NIF load fails because it looks in the wrong app's `priv/`.
Easy follow-up — change `otp_app: :exmc_trading`. Doesn't block
the structural verification.

**Reversibility:** `phd/exmc` is untouched. The live trial keeps
running on it. `exmc_trading` is a parallel artifact; cutover is
a future operation.

**Remaining for a clean ship:**
1. Decide repo home — private GitHub repo (`borodark/exmc_trading`?) or self-hosted.
2. Fix the `otp_app:` cross-link in the license NIF binding.
3. Bring across `trial/` scripts (start_trial.sh, run_trial.exs)
   and `bench/` from phd/exmc. Excluded today: large state
   (`trial/checkpoints/` is 761 MB).
4. Wire the trader's deploy path to use `exmc_trading` instead of
   `phd/exmc` (the Mission II cutover).

### Track 2 — Vulkan livebook

New livebook in OSS exmc:
`notebooks/17_vulkan_chains_and_gpu_process.livemd`, commit
`a15fb6b`, **pushed to `github.com/borodark/exmc:main`**.

Companion to the existing `16_vulkan_demo.livemd` (which proves
posterior parity). The new one explains *how the machinery is
built*:

- **Part 1 — The GPU process.** Why `Nx.Vulkan.Node` is a long-
  lived OTP GenServer (owns the vkPipelineCache, persistent buffer
  registry, watchdog). The pattern for supervision-tree
  integration with a `case Exmc.JIT.detect_compiler() do …`
  guard. The Mission-II failure mode written up as a cautionary
  tale: backend present + Node missing = NUTS hangs + watchdog
  resets + broker polls keep working = nine-hour load-bearing
  zombie.
- **Part 2 — Shader chain compilation.** Spec → templated GLSL
  → `glslangValidator` → SPIR-V → content-addressed cache. Cold
  vs warm timings to illustrate the cache. `compile_with_source/1`
  to inspect the rendered GLSL.
- **Part 3 — Dispatching.** Push-constant layout for a Beta
  family dispatch; how one dispatch executes K leapfrog steps in
  a single GPU command buffer.
- **Part 4 — Failure modes.** Broken spec, runtime watchdog
  timeout, missing Node — what each looks like at runtime and
  the operator handle.

The livebook is a tutorial-shape document. Runnable on any host
with `nx_vulkan` available (FreeBSD + Vulkan ICD, Linux +
mesa/NVIDIA Vulkan, macOS + MoltenVK).

## What this unblocks

- **Mission II cutover** can use `exmc_trading` as the release
  target on mac-247 (after the otp_app fix). Decouples the trial's
  release-engineering from the live working tree in `phd/exmc`.
- **OSS exmc visibility**: notebook 17 is the doc the
  "Vulkan-on-FreeBSD: the proof" blog implicitly promised. Hex
  publish + a CI badge are now the remaining gates to a credible
  Hex package launch.

## Not done today (deferred)

- nx_vulkan Hex publish (precondition for OSS exmc Hex publish).
- Backport of W7 vulkan validator + chain_shader_codegen from
  phd/exmc to OSS exmc.
- MLX decision (port to OSS or keep private as commercial
  backend?).
- Trading-repo GitHub remote setup + first push.
- License NIF `otp_app` fix.
