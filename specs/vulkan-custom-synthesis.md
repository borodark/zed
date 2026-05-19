# Vulkan Custom-Distribution Chain Shader Synthesis — Spec

**Status:** R0–R3 complete, validated on mac-247 (GT 650M
Mac Edition, FreeBSD 15.0), 2026-05-19. R4 cutover + R5 tag γ
pending; obs-axis-parallel (Design A) is an open optimisation.
See `exmc/docs/MISSION_II_SYNTHESIS.md` for the as-shipped
pipeline + perf numbers.

**Original problem (2026-05-18):** the regime trial on mac-247
hits the **per-op Vulkan dispatch path** because
`ChainShaderCodegen.detect_meta/1` only matches 5 standard
families (Normal, Exponential, Student-t, Cauchy, Half-Normal).
The regime model uses `Exmc.Dist.Custom` — falls through to the
JIT'd `multi_step_fn` → ~150,000× slower than the fused-shader
path benchmarked at 162 ms/sample on the same hardware.

**Outcome (2026-05-19):** synthesised regime chain shader on GT
650M runs at 60 ms / K=32-dispatch (1.87 ms / leapfrog step,
projected ~60 ms / NUTS sample at tree depth 5 — **8.3× under
the 500 ms budget**), numerically equivalent to a Defn reference
to f32 precision across all 8 RVs.

**Two horizons, one architecture:**

- **Near (Mission II finish-line):** synthesise a fused chain
  shader for the regime model so the live trial moves to mac-247.
  Scope = log-prob expressions. ~1–2 weeks.
- **Far (Mission III and beyond):** generalise the synthesis
  machinery to ANY Nx.Defn function — making `nx_vulkan` a real
  Nx backend on FreeBSD + Linux non-CUDA + macOS via MoltenVK,
  parity-aspirant with EXLA on the subsets that matter (Axon
  forward+backward, Scholar's compute-bound algorithms).

The two horizons share infrastructure: Nx.Defn → GLSL emitter +
glslangValidator + content-addressed pipeline cache. Near work
delivers value alone; far work compounds.

---

## Part A — Mission II reframed: live regime trial → mac-247

Five phases. Phase R0 is the dispatch hookup, R1–R3 is the
synthesis machinery, R4 is the cutover.

### R0 — Hookup point (no-op infrastructure)
**Goal:** wire `ChainShaderCodegen.detect_meta/1` to a new
`synthesise_meta/1` branch when the model contains a Custom
distribution. The branch initially returns `:unsupported`; this
phase just locates the entry point.

Files:
- `exmc/lib/exmc/nuts/chain_shader_codegen.ex` — add
  `def detect_meta(%IR{...} = ir)` clause matching the regime
  shape (single Normal+HalfCauchy+Custom hierarchy), routes to
  `Exmc.NUTS.CustomSynth.synthesise(ir)`.
- `exmc/lib/exmc/nuts/custom_synth.ex` — new module, returns
  `:unsupported` initially.

**Acceptance:** existing tests still pass; regime IR routes
through the new branch (verified by tracing).

**Effort:** half day.

### R1 — Distribution log-prob emitter
**Goal:** given an `Exmc.Dist.Custom` with a `defn log_prob/2`,
emit a GLSL expression for the log-prob value AND its gradient
w.r.t. the position.

The trick: `Exmc.Dist.Custom` already declares `log_prob` as a
Defn (the regime model uses Builder + Custom + Defn). Defn is
a typed graph IR. We can walk it.

The set of ops we have to handle for log-prob is small:
```
+, -, *, /, **, neg, abs,
log, exp, log1p, expm1, sigmoid, tanh, softplus,
max, min, where, select,
reduce_sum, reduce_mean (over a known small axis),
constants, parameter refs.
```

That's ~25 ops. Each maps to a GLSL fragment.

**Gradient generation:** two options:
1. **Use Nx.Defn.Grad** to produce a Defn graph for
   `dlogp/dq`, then emit GLSL for that graph too. Reuses Nx's
   autodiff. Recommended.
2. **Manually emit GLSL for the gradient** (tedious, error-prone).

Stick with (1). It composes with the existing `Nx.Defn.value_and_grad`.

The emitter:

```elixir
defmodule Exmc.NUTS.CustomSynth.GLSL do
  @doc """
  Compile an Nx.Defn graph to a GLSL expression body.  Returns
  `{:ok, glsl_body, n_buffer_inputs, n_buffer_outputs}`.

  The body assumes:
    * input buffers q_init[], inv_mass[], obs[] in scope
    * output buffers q_chain[], p_chain[], logp_chain[], grad_chain[]
    * push-constant struct with eps, K, n, plus any custom-dist
      parameters
  """
  def emit(defn_graph, opts), do: ...
end
```

**Acceptance:** for the regime model's `log_prob` Defn, the
emitter produces compilable GLSL whose output matches
`Exmc.Dist.Custom.log_prob/2` on the BinaryBackend within
1e-6 absolute tolerance over a fuzz suite of 100 random inputs.

**Effort:** 3–5 days. The autodiff hookup is the load-bearing
piece; once it works, GLSL emission is mechanical.

### R2 — Plug into the leapfrog template
**Goal:** take the existing `Nx.Vulkan.ShaderTemplate.FamilySpec`
+ the regime model's log-prob/grad GLSL, render a complete
chain shader, run through `Synthesis.compile/1` (already
content-addresses + caches).

The existing template (`nx_vulkan/lib/nx_vulkan/shader_template.ex`)
parameterises the leapfrog body on placeholders like
`{{LOG_PROB_BODY}}` and `{{GRAD_BODY}}`. R2 fills those in from
the R1 emitter rather than hand-written family-specific bodies.

**Acceptance:** regime model goes through synthesis end-to-end,
producing a cached SPIR-V file. First `compile/1` cold ≤ 1 s;
second is cache-hit (≤ 1 ms).

**Effort:** 2–3 days.

### R3 — Bench
**Goal:** measure regime-model sample wall time on GT 650M.

Target: ≤ 500 ms/sample (3× the trivial-Normal 162 ms baseline
seems generous). If we hit it, mac-247 is throughput-viable.
If we miss by 10× (worst plausible case from inefficient
GLSL emission), still acceptable — the live trial's
`update_every: 20 s` means we can keep up with ~40 instruments at
500 ms each, or ~10 instruments at 2 s each.

**Acceptance:** 5 timed samples on regime IR, mean ≤ 500 ms,
zero divergences after 200-step warmup, posterior agrees with
EXLA reference to 2-σ.

**Effort:** half day.

### R2 — Plug into the leapfrog template *(refined 2026-05-18 after R1.5)*

**Key finding from inspecting nx_vulkan's shim header:** the generic
dispatch NIF that R2.1 was meant to build **already exists**.

`nxv_leapfrog_chain_synth` (`nx_vulkan_shim.h:95`) was added during
Phase 2 of nx_vulkan with this contract:

```
int nxv_leapfrog_chain_synth(
    void* q_chain, void* p_chain, void* grad_chain, void* logp_chain,
    void* q_init,  void* p_init,  void* inv_mass,
    const void* push_data, unsigned int push_size,
    const char* spv_path
);
```

Opaque push-constants block up to 128 bytes; 3 read SSBOs + 4 write
SSBOs at fixed bindings 0–6; spv_path is whatever shader the host
hands it. Comments confirm: *"Generic K-step leapfrog chain dispatch
for synthesized shaders. The push-constants block layout is OPAQUE
to this shim — `push_data` is a raw `push_size`-byte blob assembled
by the caller (Elixir-side codegen knows the per-shader layout)."*

The Rust binding and Elixir stub
(`Nx.Vulkan.Native.leapfrog_chain_synth/6`) are also already in
place. So R2.1's "build Rust NIF for generic dispatch" task is
**done before we started**.

This collapses R2 to four Elixir-side pieces:

#### R2.1 *(done — pre-existing infrastructure)*

#### R2.2 — Render leapfrog template with R1 emitter bodies

**Investigation finding (2026-05-18): the existing template is the
wrong shape for custom multi-RV models.** Real architectural
work, not just text substitution.

The existing `Nx.Vulkan.ShaderTemplate.FamilySpec` template
(`nx_vulkan/lib/nx_vulkan/shader_template.ex:51`) is
**single-RV-per-thread**:

- `local_size_x = 256` workgroup
- Each thread reads its own `qi = q_init[i]` at thread index i
- Each thread updates its `qi` + `pi` independently
- Each thread writes `q_chain[k * n + i]`
- The K-step leapfrog body assumes `grad_q` and `lp_i` are
  **functions of qi alone** (and the push constants)

That is correct for Normal/Exponential/StudentT/Cauchy/HalfNormal —
each q[i] is iid with the same scalar distribution, so the joint
log_p is a sum of per-component scalars and the gradient is a
per-component scalar derivative.

The **regime model breaks both assumptions**:

| | Single-RV family (existing) | Regime model (R2.2 target) |
|---|---|---|
| RVs | independent over q[i] | hierarchical, 8 distinct named RVs |
| log_p | sum over q[i] of scalar log_pdf(q[i]) | sum over **obs[j]** of log of softmax-mixture using ALL q[i] |
| grad q[i] | f(q[i]) only | f(q[0..7], obs[0..199]) — depends on whole q AND the obs vector |
| Obs data | none | obs[200] — too large for push constants (1600 B vs 128 B limit) |
| Parallelism axis | q dimension i (d-way) | obs dimension j (n-way) |

The right template shape for multi-RV custom models:

**Design A — Multi-RV with obs-axis parallelism.**
```
local_size_x = 256  // threads = obs-axis parallelism
shared float q_shared[d_max];  // broadcast q to all threads
shared float partial_logp[256];
shared float partial_grad[d_max][256];

void main() {
    uint j = gl_GlobalInvocationID.x;            // obs index
    uint tid = gl_LocalInvocationIndex;
    bool in_obs = (j < pc.n_obs);

    // Thread 0..d-1 load q_shared
    if (tid < pc.d) q_shared[tid] = q_init[tid];
    barrier();

    for (uint k = 0; k < pc.K; k++) {
        // -- Half-step momentum at q --
        // Each thread computes its contribution to log_p AND to
        // each ∂logp/∂q[i] for i in 0..d-1.
        float my_logp = in_obs ? <emitted log_p contribution at obs[j]> : 0.0;
        partial_logp[tid] = my_logp;
        for (uint i = 0; i < pc.d; i++) {
            float my_grad_i = in_obs ? <emitted ∂logp/∂q[i] contribution at obs[j]> : 0.0;
            partial_grad[i][tid] = my_grad_i;
        }
        barrier();

        // Standard 256-way reduction across threads ...
        // grad_shared[i] = sum of partial_grad[i][:]
        // logp_shared    = sum of partial_logp[:]
        barrier();

        // Thread 0..d-1 do their own leapfrog update using grad_shared[i]
        if (tid < pc.d) {
            float grad_q = grad_shared[tid];
            // p_half, qi, then half-step momentum at qn ...
        }
        barrier();
    }
}
```

This is a different shader, sharing only the K-loop structure and
the push-constants header with the existing FamilySpec template.
Worth a new `Nx.Vulkan.ShaderTemplate.MultiRvCustomSpec` module
rather than overloading `FamilySpec`.

**Open issue: obs SSBO.** The existing `nxv_leapfrog_chain_synth`
binds exactly 7 buffers (3 read + 4 write). For multi-RV custom
models, we need an 8th: `obs[]` at binding 7. Two options:

1. **Extend the shim** to accept a variable number of input
   buffers (real C++ work, ~50 lines).
2. **Repack obs into one of the existing input buffers.** E.g.,
   inv_mass is d-sized; obs is much larger. Could allocate one
   "input_extras" buffer carrying obs[0..n-1] followed by
   inv_mass[0..d-1]. Caller-side packing only; shim unchanged.

Option 2 is the smaller bite. Probably the right R2.2 choice
unless extending the shim is cheap.

**R2.2's actual deliverable:**

- `Nx.Vulkan.ShaderTemplate.MultiRvCustomSpec` with the
  Design-A skeleton above
- `MultiRvCustomSpec.render/1` filling `{log_p_body}` +
  `{grad_body_for_q_i}` placeholders from the R1 emitter
- Tests: rendered GLSL passes glslangValidator
- Defer: actual numerical correctness vs Defn — that lands when
  R2.4 + R2.5 wire dispatch end-to-end

#### R2.3 — Push-constants layout for synthesised shaders

The push block needs:
- `uint n` — dimension (8 for the regime model)
- `uint K` — leapfrog steps per dispatch (typically 32)
- `float eps` — step size
- per-RV constant parameters (the regime model's standard-family
  priors: mu/sigma for each Normal, scale for each HalfCauchy)
- observation data... no — obs is too large for push constants
  (128 byte limit); obs goes in an additional SSBO. **R2.3 must
  extend the chain_synth shim signature to accept >3 input
  buffers**, OR keep obs in a thread-local global the shader reads
  by binding 7. Worth checking the existing shim limits.

#### R2.4 — Wire CustomSynth.synthesise/1

Replace the `:unsupported` stub in `Exmc.NUTS.CustomSynth` with:

```elixir
def synthesise(%IR{} = ir) do
  with {:ok, components} <- extract_components(ir),
       {:ok, glsl} <- render_template(components),
       {:ok, spv_path} <- Nx.Vulkan.Synthesis.compile_glsl(glsl),
       push_spec <- build_push_spec(components) do
    sha = :crypto.hash(:sha256, glsl) |> Base.encode16(case: :lower)
    {:ok, {:synthesised, sha, components.layout, push_spec, spv_path}}
  else
    err -> err
  end
end
```

`Nx.Vulkan.Synthesis.compile_glsl/1` doesn't exist today (only
`Synthesis.compile/1` taking a FamilySpec) — needs a sibling
function that accepts arbitrary GLSL strings. This is the
narrowest piece of nx_vulkan work R2 needs.

#### R2.5 — Tree.do_dispatch routing

`Exmc.NUTS.Tree.do_dispatch/10` already pattern-matches on the
meta tuple's family tag. Add a clause for `{:synthesised, sha,
layout, push_spec, spv_path}` that:
- Builds the push-constants binary using `push_spec`
- Calls `Nx.Vulkan.Native.leapfrog_chain_synth/6` with q/p/inv_mass
  + push_data + spv_path
- Returns the 4 output tensors in the same shape as
  `Exmc.NUTS.Vulkan.Dispatch.chain/8` produces

**Effort revised:** R2 total ~3–5 days instead of "1–2 weeks." The
generic dispatch infrastructure being pre-built is the largest
cost the original plan didn't anticipate.

### R3 — Bench

(unchanged from the original plan: target ≤ 500 ms/sample on GT
650M)

### R4 — Cutover
**Goal:** migrate the live trial.

Sequence:
1. Snapshot dev-host checkpoints + instruments file.
2. `zfs send | ssh mac-247 zfs recv` the alpaca_6k subtree.
3. Copy accounts.config (or a subset of the 4 paper accounts
   we choose for mac-247).
4. Restart mac-247 trader (already has the fixed Application +
   ComputePool patches from M-II.fix and M-II.fix2).
5. Stop the corresponding instruments on the dev-host trial via
   HotReloadWorker (modify `instruments.txt`).
6. Watch 1 h for divergence between the two trials.

**Effort:** half day, modulo any operational surprises.

### R5 — Tag γ
Document + commit the synthesis machinery on `borodark/exmc` +
`borodark/nx_vulkan`. The "Custom-distribution synthesis on
Vulkan" angle is a publishable result.

**Effort:** half day.

**Total for Part A:** 7–10 days focused work.

---

## Part B — General Custom Compute Synthesis (Mission III)

The R1 emitter is, at heart, **"Nx.Defn → GLSL for a small op set
on small tensors."** Mission III generalises that into a
multi-layer architecture.

### Layer 1 — Distribution log_prob synthesis
**Scope:** function `(params, x) -> scalar` where `x` and
`params` are scalars or small tensors (typically dim ≤ 256 to
fit a single workgroup).

This is what R1 ships. Covers:
- All MCMC log_prob expressions, including hierarchical models
  with one custom likelihood and standard priors.
- Variational ELBO computations (ADVI).
- Loss functions for small models.

### Layer 2 — General Nx.Defn → SPIR-V
**Scope:** any `defn` function consuming and producing tensors
of bounded size (≤ ~1 GB on Kepler, less on integrated GPUs).

This is the "small XLA" — a real Nx backend competing with
`Nx.BinaryBackend` and `Nx.Defn.Evaluator` on correctness, with
Vulkan acceleration on top.

**Required ops (in dependency order):**

| Tier | Ops | Scope |
|---|---|---|
| **T1** | element-wise (+, -, *, /, **, neg, abs, log, exp, etc.) | 50 ops; one GLSL fragment each |
| **T2** | reductions (sum, mean, max, argmax along axes) | shared-memory + barrier patterns; the existing leapfrog template already does this for log_p |
| **T3** | broadcasts, slices, gathers | index-arithmetic templates; gather is the load-bearing primitive for embeddings + indexing |
| **T4** | matmul, transpose, conv | tiled compute shaders; cooperative-matrix on newer GPUs, fall back to plain MAD loops on Kepler |
| **T5** | control flow (while, cond) | bounded; Vulkan compute shaders don't have unbounded dynamic dispatch — use a host-side loop with multiple kernel calls |
| **T6** | scatter, custom kernels | scatter is hard on GPU (needs atomics); custom kernels are an escape hatch for users who want to hand-roll |

T1 + T2 + T3 covers ~80 % of typical Nx.Defn workloads. T4
unlocks Axon and Scholar. T5–T6 are the long tail.

**Backend protocol:** implement `Nx.Defn.Compiler` (the protocol
EXLA + Defn evaluator both implement). Hook is `__compile__/4` —
given a Defn graph, return a function that takes args and
returns results. Inside, walk the graph and emit GLSL.

Pipeline:
```
Nx.Defn graph
   → Vulkan compiler walks the graph
   → emits GLSL kernels (one per "fused block")
   → glslangValidator → SPIR-V
   → cache by graph-hash (already supported)
   → at call time: bind buffers, dispatch, read back
```

**Effort:** 4–8 weeks. The T1–T3 work compounds; T4 is a real
project on its own.

### Layer 3 — Axon-shaped synthesis
**Scope:** Axon models (Dense, Conv2D, BatchNorm, ReLU,
attention, dropout, …) — both forward and backward pass.

If Layer 2 covers the underlying Nx.Defn ops, **Axon
"compiles for free"** — Axon's `Axon.compile/3` already
produces a Defn function. The catch: real performance needs
specialised shaders for the bottleneck layers:

| Layer | Specialised shader | Hardness |
|---|---|---|
| Dense (matmul + bias) | Tiled matmul, bias broadcast in same dispatch | medium — well-trodden |
| Conv2D | Im2col + matmul, or direct conv | medium — same as Dense but with index math |
| BatchNorm | Fused with the preceding op | easy if Layer 2 has reductions |
| Activation (ReLU, GELU, etc.) | Element-wise, fused into the prior op's dispatch | easy |
| Attention | Flash-attention-style fused kernel | hard — large memory bandwidth opportunity |
| Embedding | Gather over a table | T3 gather primitive |

Without specialised shaders, Axon-on-Vulkan would still WORK at
Layer 2 performance — useful, not great. With them, transformer
inference becomes feasible on the FreeBSD path.

### Layer 4 — Scholar-shaped synthesis
**Scope:** Scholar's classical-ML algorithms (KMeans, kNN,
PCA, SVM, linear regression).

Most are pure Nx.Defn already — Layer 2 covers them.
Specialised shaders matter for two: KMeans (centroid update is a
scatter + reduce) and large-scale kNN (top-k over distances is a
parallel reduction).

### Layer 5 — Escape hatch
**Scope:** users who want to write hand-rolled GLSL for a
specific kernel.

API sketch:
```elixir
defmodule MyKernel do
  use Nx.Vulkan.Kernel

  shader """
  #version 450
  layout (local_size_x = 256) in;
  layout (std430, binding = 0) buffer In  { float a[]; };
  layout (std430, binding = 1) buffer Out { float b[]; };
  void main() {
    uint i = gl_GlobalInvocationID.x;
    b[i] = sin(a[i]) + cos(a[i]);
  }
  """

  def run(a), do: Nx.Vulkan.Kernel.dispatch(__MODULE__, [a], output_shape: Nx.shape(a))
end
```

For users who need ops that the synthesis layer hasn't grown to
yet — they bypass the synthesiser and ship their own GLSL. The
content-addressed cache + Vulkan.Node lifecycle still apply.

---

## What this unlocks, ranked

1. **mac-247 hosts the live regime trial** at ~hundreds of ms per
   sample (Part A).
2. **`nx_vulkan` becomes a first-class Nx backend** for FreeBSD +
   non-CUDA Linux (Part B Layer 2).
3. **Axon on FreeBSD becomes real** (Part B Layer 3) — gateway
   to ML-on-BEAM on hardware EXLA-CUDA can't touch.
4. **The FreeBSD Foundation pitch** (per
   `bsd-confs.md`) gets a concrete deliverable: a Vulkan-backed
   ML stack with reproducible posteriors on Kepler-era GPUs.

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Autodiff for Custom dist's Defn breaks on non-trivial graphs | medium | Test against the regime model + 3 other published hierarchical models before claiming generality |
| Synthesis output is correct but slow (un-optimised GLSL) | high | Layer 2 ships with a "Q-grade" target; Layer 3 specialised shaders close the perf gap as needed |
| Cooperative matrix unavailable on Kepler → matmul slow | high | Plain MAD-loop fallback; documented perf cliff vs Ampere+ |
| Reductions across large tensors (> single workgroup) need multi-dispatch | known | Existing leapfrog template already does single-workgroup reductions; multi-pass reduction is a standard pattern |
| OSS adoption requires Hex publish + docs + CI | known | Already in the OSS-split work; pre-condition for Mission III |

---

## Phasing for the full thing

| Mission | Scope | Duration |
|---|---|---|
| **M-II (in flight)** | Part A R0–R5 — regime trial on mac-247 | 1–2 weeks |
| **M-III.1** | Part B Layer 1 generalisation (post-R1 cleanup, more dist families, more autodiff coverage) | 2 weeks |
| **M-III.2** | Part B Layer 2 T1–T3 (element-wise + reductions + gather/scatter) | 4 weeks |
| **M-III.3** | Part B Layer 2 T4 (matmul + conv) | 4 weeks |
| **M-III.4** | Part B Layer 3 (Axon specialised shaders + benchmarks) | 3 weeks |
| **M-III.5** | Part B Layer 4 (Scholar) + Layer 5 (escape hatch + docs) | 2 weeks |
| **M-III.6** | Hex publish nx_vulkan @ 0.2, benchmarks blog | 1 week |

**Total Mission III:** ~16 weeks of focused effort. Could be
shorter with parallelisation across multiple R&D streams.

---

## Where this lives

- **Mission II Part A** lands in `borodark/exmc` and
  `borodark/nx_vulkan` — the synthesis machinery is in
  `nx_vulkan/lib/nx_vulkan/synthesis.ex` + a new
  `exmc/lib/exmc/nuts/custom_synth.ex` for the NUTS-specific
  bridge.
- **Mission III** is mostly `nx_vulkan` — the Nx backend +
  shader emitter live there. Axon / Scholar specialisations
  could be in their own packages (`axon_vulkan`, `scholar_vulkan`)
  or vendored into the respective upstream projects via PRs.

---

## Note on scope decisions

The user's framing was "custom compute synthesis for Axon/Scholar
is in the scope." This spec interprets that as **Mission III's
ambition**, with **Mission II Part A** as the immediate, concrete
delivery. The full Mission III is a half-year of work; Mission II
Part A is two weeks. Both compose into a coherent FreeBSD-GPU
story for BEAM ML.
