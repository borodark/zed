# Mission II + III — Consolidated Plan (2026-05-18)

The state of the Mission II → III arc, including the vulkano
investigation triggered at the end of R2.2.

## Where we are

| Phase | Status | Wall summary |
|---|---|---|
| **R0** hookup point (CustomSynth routing) | ✓ | `phd@53eaef09e` |
| **R1.1** GLSL emitter | ✓ | 22 ops, glslang-validated |
| **R1.2** scalar gradient via `Nx.Defn.grad` | ✓ | +`:select` + 6 comparison ops |
| **R1.3** regime model end-to-end (value) | ✓ | Production model emits cleanly |
| **R1.4** `emit_vector` (vector gradients) | ✓ | Regime grad: 6 contributing indices at `[0,1,4,5,6,7]` |
| **R1.5** correctness gate via parallel Elixir walker | ✓ | ~500 fuzz cases agree with `Defn.Evaluator` to 1e-12 |
| **R2.1** generic dispatch NIF | ✓ pre-existing | `nxv_leapfrog_chain_synth` already shipped in nx_vulkan |
| **R2.2** template design | architectural gap found | Existing template is single-RV-per-thread; regime model needs obs-axis-parallel multi-RV template (Design A) |
| **R2.3** push-constants layout | open | Plus obs-SSBO question (regime obs[200] > 128 B push limit) |
| **R2.4** `CustomSynth.synthesise/1` wiring | open | Needs `Nx.Vulkan.Synthesis.compile_glsl/1` (sibling to existing FamilySpec compile) |
| **R2.5** `Tree.do_dispatch` clause for synthesised meta | open | Routes to existing `Nx.Vulkan.Native.leapfrog_chain_synth/6` |
| **R3** bench on GT 650M | open | Target: ≤ 500 ms/sample |
| **R4** cutover live trial to mac-247 | open | `zfs send` checkpoints, HotReloadWorker swap |
| **R5** γ tag + writeup | open | Publishable result |

R1 is **complete**. R2.1 collapsed (pre-existing). R2.2 is the
next real work and it's harder than R1 — designing a new shader
template, not just text fill.

## The biggest open architectural question — `vulkano`

The user pointed at `/home/io/projects/learn_erl/vulkano/` —
**vulkano 0.35.0**, the canonical safe-Rust wrapper for the
Vulkan API, freshly cloned. Strategic question: should the
nx_vulkan dispatch path be re-platformed onto vulkano instead of
the current C++ shim?

### Current architecture (nx_vulkan today)
```
Elixir (Nx.Vulkan.Native)
   ↓ NIF call
Rust binding (nx_vulkan_native)
   ↓ extern "C"
C++ shim (nx_vulkan_shim.cpp — 1120 lines)
   ↓ namespace calls
spirit::vulkan (custom C++ Vulkan wrapper)
   ↓ raw Vulkan API
libvulkan.so
```

Three native-code layers (Rust binding, C++ shim, spirit). The
shim was the slow part of building anything new — adding a
buffer to `nxv_leapfrog_chain_synth` is C++ + rebuild + lib.so
churn.

### Hypothetical vulkano architecture
```
Elixir (Nx.Vulkan.Native)
   ↓ NIF call
Rust binding (uses vulkano directly)
   ↓ Rust API
vulkano (canonical safe Vulkan wrapper)
   ↓ ash / vulkano-sys
libvulkan.so
```

One native-code layer. C++ entirely removed. spirit dep removed.

### What we'd gain

1. **Single native language.** Elixir + Rust only. No C++ build
   path, no extern "C" boundary maintenance.
2. **Safe compile-time guarantees.** vulkano's whole pitch:
   "as long as you don't use unsafe code you shouldn't be able to
   trigger undefined behavior." Type-safe descriptor sets,
   automatic synchronization, lifetime-checked buffer access.
3. **R2.2's obs-SSBO question evaporates.** vulkano supports
   arbitrary buffer counts at descriptor-set creation; no fixed
   "3 read + 4 write" layout cap. The "extend the C++ shim or
   repack obs caller-side" choice becomes "just bind 8 buffers."
4. **Easier Mission III.** Building a full `Nx.Defn → SPIR-V`
   backend means hundreds of operation patterns. Each new op
   means a new shader + dispatch shape. vulkano's API makes this
   linear ("declare buffers, dispatch") instead of growing the
   C++ shim's surface for every op family.
5. **Standard library + community.** vulkano is the canonical
   Rust Vulkan crate (vulkano-rs/vulkano on GitHub). External
   contributors can read it. spirit is bespoke.

### What we'd lose / what's the cost

1. **Rewrite cost.** ~1120 lines of C++ shim → ~600–1000 lines
   of Rust against vulkano. Probably 1–2 weeks of focused work
   to reach parity on all the current op entry points.
2. **Pipeline cache implementation.** spirit has it; vulkano has
   `PipelineCache` as a first-class type. Mapping the existing
   disk-persistence semantics is straightforward but real work.
3. **FreeBSD support — open question.** vulkano's official
   support list per upstream docs:
   - Windows (MSVC / GNU)
   - Linux
   - macOS, iOS, tvOS (via MoltenVK)
   - **No FreeBSD on the list.**

   vulkano is a thin wrapper over `ash` which is a thin wrapper
   over `libvulkan.so`. We have working `libvulkan.so` on mac-247
   + verified Vulkan compute via NVIDIA's ICD. In principle
   vulkano should build and run on FreeBSD; in practice we'd need
   to verify before committing.

   **Pre-commit verification:** `cargo build` of a vulkano hello-
   world on mac-247. If it builds + dispatches a trivial compute
   shader, FreeBSD support is empirically fine. If it fails on
   some Linux-specific syscall in `ash`, we have a real problem.

4. **Performance — likely negligible.** vulkano's safety wrappers
   add some overhead vs raw Vulkan C calls (descriptor set
   validation, etc.). For compute-bound workloads where dispatch
   is amortised over K=32 leapfrog steps per call, the wrapper
   overhead is in the microseconds — irrelevant.
5. **Loss of spirit's pipeline caching tuning.** spirit's
   `get_or_create_pipe` is hand-tuned for the existing
   nx_vulkan workloads. vulkano has its own caching primitives
   but the runtime behaviour may differ.

### Decision criteria

| Aspect | Stay (C++/spirit) | Switch (vulkano) |
|---|---|---|
| Time-to-Mission-II-finish | shorter — current path works | longer — rewrite first |
| Time-to-Mission-III | longer — C++ growth | shorter — Rust ergonomics |
| FreeBSD support | known good | needs verification |
| Maintenance | ongoing C++ + Rust | Rust only |
| OSS contribution friction | high (bespoke shim) | low (standard tool) |
| Risk if it goes wrong | none | needs C++ fallback during transition |

### Recommendation

**Two-phase strategy:**

#### Phase 1 (Mission II): keep the current C++ path

Finish R2.2 → R5 on the existing shim. The regime trial gets to
mac-247 with the infrastructure we have. Don't rewrite during the
landing. The R2.2 obs-SSBO question gets the "caller-side repack"
treatment (the lower-cost option).

#### Phase 2 (post-Mission II, before Mission III): vulkano spike

A focused 1-week spike:
1. Build a vulkano hello-world on mac-247 (verifies FreeBSD
   support empirically). Half day.
2. Port `nxv_leapfrog_chain_synth` to vulkano (one entry point;
   prove the pattern). 2 days.
3. Bench vs the existing C++ shim — wall time per dispatch +
   per K-step chain. Half day.
4. Decision based on data: if vulkano runs within 10 % of the C++
   path on mac-247, commit to the port for Mission III.

If the spike goes green, then **Mission III's full Nx.Defn → SPIR-V
backend lands in vulkano-only Rust** — that's where the ergonomics
payoff is.

#### Phase 3 (Mission III, contingent on spike): port the rest

Migrate the existing nx_vulkan dispatch entry points to vulkano
one family at a time. The C++ shim shrinks as Rust grows. The
Elixir-side API stays unchanged — `Nx.Vulkan.Native.*` keeps the
same signatures, just routes through Rust instead of C++.

Estimated total: ~3 weeks (1 week spike + 2 weeks port).

## Detailed R2.2+ plan (unchanged regardless of vulkano decision)

### R2.2 — MultiRvCustomSpec template

(per the prior R2.2 update in `specs/vulkan-custom-synthesis.md`)

New template module with Design A: 256-thread workgroup
parallelising over the obs axis, shared memory for q broadcast,
per-thread contributions to log_p + per-RV gradient, cross-
thread reduction, thread 0..d-1 do leapfrog update.

Placeholders fill from R1.1's `emit/2` (log_p body) +
`emit_vector/2` (per-RV grad bodies).

**Effort:** 2–3 focused days. Real shader-design work.

### R2.3 — Push-constants + obs-SSBO

Push block: `n_obs`, `K`, `eps`, `d`, per-RV prior parameters
(mu, sigma for Normals; scale for HalfCauchys). Fits in 128 B
comfortably (regime model has ~10 scalar prior params).

obs[200] (1600 B f64, or 800 B f32 if we downcast) doesn't fit
push constants. Options:

1. **Caller-side repack** — pack obs into the existing input
   buffers (inv_mass is much smaller; create a fused "input_extras"
   layout). Shim unchanged.
2. **Add 8th binding to the shim** — bigger architectural change;
   exactly the kind of churn that motivates the vulkano question.

Choosing (1) for Mission II.

### R2.4 — `synthesise/1` wiring

Replace the `:unsupported` stub. Needs `Nx.Vulkan.Synthesis.compile_glsl/1`
(sibling to `compile/1` which takes a FamilySpec) — ~30 lines.

### R2.5 — Tree.do_dispatch routing

Add a `{:synthesised, ...}` clause. Builds push data binary,
calls `Native.leapfrog_chain_synth/6`. Returns the 4 output
tensors in the same shape as `Exmc.NUTS.Vulkan.Dispatch.chain/8`.

### R3 — Bench

Run on mac-247, 5 timed samples on the regime model with the
synthesised shader. Compare to:
- E2 baseline: 162 ms/sample for trivial Normal (lower bound for
  what fused-shader perf looks like on GT 650M)
- Original per-op path: 3–10 h/sample (the disaster we're fixing)

Target: ≤ 500 ms/sample, ≤ 5 % posterior divergence vs EXLA-CUDA
reference run on dev host.

### R4 — Cutover

(unchanged: zfs send checkpoints; restart trader on mac-247;
HotReloadWorker drops regime symbols from dev-host trial)

### R5 — γ tag

(unchanged: doc + commit + tag)

## Mission III dependencies on Mission II + vulkano decision

| Mission III layer | Depends on | Affected by vulkano? |
|---|---|---|
| L1 — Distribution log_prob synthesis (generalised R1) | R1 (done) | No — pure Elixir |
| L2 T1–T3 — element-wise + reductions + gather/scatter | R2 dispatch infra | Yes — vulkano makes new op patterns easier |
| L2 T4 — matmul + conv | L2 T1–T3 | Yes — vulkano's cooperative-matrix bindings |
| L3 — Axon specialised shaders | L2 | Yes — many small shaders, vulkano ergonomics dominate |
| L4 — Scholar specialised shaders | L2 | Yes |
| L5 — `Nx.Vulkan.Kernel` escape hatch | L2 | Yes — user-supplied GLSL needs flexible dispatch |

Every Mission III layer past L1 benefits from the vulkano path.
That's the strongest argument for doing the Phase-2 spike between
Mission II and Mission III rather than postponing it indefinitely.

## What this plan commits to

- **Mission II finish-line goal**: regime trial running on mac-247
  via custom-synthesised fused chain shader, ≤ 500 ms/sample, in
  ≤ 1 week of focused R2.2–R5 work on the **current C++ shim**.
- **Pre-Mission III vulkano spike**: 1 week, blocking Mission III
  start.
- **Mission III implementation**: routed through whichever path
  the spike validated (current shim or vulkano), with the
  emitter + synthesise pipeline from R1 fully reused.

## Open questions worth flagging

1. **Does vulkano build on FreeBSD?** — settled by a half-day
   spike on mac-247 (`cargo build` a hello-world).
2. **Can the existing `nxv_leapfrog_chain_synth` accommodate obs
   as a repacked input slot, or do we need an 8th binding?** —
   answered by reading the shim's buffer-count handling +
   matching to template requirements (covered in R2.3).
3. **What's `Nx.Vulkan.Synthesis.compile_glsl/1`'s right home?**
   — in nx_vulkan (the OSS dep). Worth a tiny PR even before R2.4
   lands.
4. **f32 vs f64 in the regime model.** Vulkan compute is f32
   (per `Exmc.JIT.precision/0`); the dev-host trial runs f64 via
   EXLA. R3 benchmarks must measure posterior agreement to
   characterise the precision-induced drift.

---

## Where to commit + tag

This doc lives on `feat/mission-ii-linux` (zed repo). When R5
ships γ, the relevant pieces of this plan move into:

- `borodark/exmc` notebooks/ + lib/ — the R1 synthesis machinery
  and the regime-model example
- `borodark/nx_vulkan` lib/ + tests/ — the `compile_glsl/1`
  function and the new multi-RV template
- `zed/docs/mission-ii-migration.md` — the cutover narrative
- `zed/specs/linux-cuda-platform.md` — stays valid (it's the
  Mission II/III alternative for CUDA hosts; nothing here invalidates it)
