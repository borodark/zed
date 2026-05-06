# Nx.Vulkan — GPU Tensor Backend for FreeBSD via Vulkan Compute

**Date:** 2026-04-28
**Status:** plan — main path for GPU-accelerated Nx on FreeBSD
**Supersedes:** IPC bridge approach in `nx-gpu-freebsd.md` (kept as fallback)

---

## Why Vulkan, not CUDA

NVIDIA ships no `libcuda.so` for FreeBSD. They do ship a Vulkan driver.
Spirit (`~/spirit/`) proves Vulkan compute works on this exact machine
(FreeBSD 15.0, NVIDIA GPU) for real scientific computation — 111 GLSL
compute shaders dispatched through `vulkan.h`, achieving 2-3x over
mumax3 on CUDA.

Vulkan compute is:
- **Native on FreeBSD** — no Linuxulator, no IPC, no ABI crossing
- **Multi-vendor** — same backend works on NVIDIA, AMD, Intel
- **Already proven on this host** — Spirit runs here

## Architecture

```
Elixir                     C NIF                       GPU
─────────                  ─────                       ───
Nx.Defn                    nx_vulkan.so                SPIR-V shaders
  │                          │                           │
  │  Nx.Vulkan.Backend       │  VkDevice                 │
  │  ─ tensor alloc ───────▶ │  ─ VkBuffer alloc ──────▶ │ device memory
  │  ─ element_wise_op ────▶ │  ─ vkCmdDispatch ───────▶ │ compute shader
  │  ─ reduce ─────────────▶ │  ─ vkCmdDispatch ───────▶ │ reduction shader
  │  ─ dot ────────────────▶ │  ─ vkCmdDispatch ───────▶ │ matmul shader
  │  ─ fft ────────────────▶ │  ─ VkFFT ───────────────▶ │ FFT shader
  │  ─ to_binary ──────────▶ │  ─ transferDataToCPU ───▶ │ → host memory
  │                          │                           │
  │  Nx.Defn.jit/3           │  command buffer batching  │
  │  ─ whole graph ────────▶ │  ─ record cmd buffer ───▶ │
  │                          │  ─ vkQueueSubmit ───────▶ │ execute all
  │                          │  ─ vkQueueWaitIdle ─────▶ │
  │  ◀─── result tensor ──── │  ◀── read result buffer   │
```

Single process, single NIF. BEAM loads `nx_vulkan.so` (native FreeBSD),
which initializes a `VkDevice` and manages GPU buffers + shader
dispatch. No IPC, no second process, no Linuxulator.

## What Spirit contributes

Spirit's `Vulkan_Compute.hpp` (7964 lines) is a complete Vulkan
compute infrastructure. Key pieces we reuse:

| Spirit piece | What it does | Reuse in Nx.Vulkan |
|---|---|---|
| `createInstance()` | Vulkan instance + device selection | Verbatim |
| `findPhysicalDevice()` | GPU enumeration | Verbatim |
| `createDevice()` | Compute queue + command pool | Verbatim |
| `allocateBuffer()` | GPU memory alloc with staging | Adapt for tensor shapes |
| `transferDataFromCPU()` | Host → GPU via staging buffer | Verbatim |
| `transferDataToCPU()` | GPU → Host readback | Verbatim |
| `VulkanCollection` | Pipeline + descriptor set bundle | Generalize for tensor ops |
| `vkCmdDispatch` pattern | Shader dispatch with push constants | Core pattern for all ops |
| VkFFT integration | GPU FFT | Wrap for `Nx.fft` |
| `ReduceDot.comp` | Parallel dot product with subgroup ops | Adapt for general reduce |
| `Scale.comp` | Element-wise scalar multiply | Template for all element-wise |

**We don't fork Spirit.** We extract the Vulkan compute patterns
into a standalone C library (`libnx_vulkan`) that Spirit's author
can also use. The shaders are new (tensor-generic, not spin-specific).

## Shader inventory

### Core tensor ops (~25 shaders)

| Category | Shaders | Complexity |
|---|---|---|
| **Element-wise unary** | `neg`, `exp`, `log`, `sqrt`, `tanh`, `abs`, `sign`, `ceil`, `floor` | Trivial — 1 line per op |
| **Element-wise binary** | `add`, `subtract`, `multiply`, `divide`, `power`, `max`, `min` | Trivial — broadcasting adds complexity |
| **Reduction** | `sum`, `product`, `max`, `min`, `mean` | Medium — subgroup reduction (Spirit's `ReduceDot` pattern) |
| **Dot/MatMul** | `dot`, `outer` | Medium — tiled matmul for performance |
| **Comparison** | `equal`, `greater`, `less`, `logical_and`, `logical_or` | Trivial |
| **Type conversion** | `as_type` (f32↔f64, f32↔i32) | Trivial |
| **Random** | `normal`, `uniform` | Medium — GPU RNG (philox counter-based) |
| **Gather/Scatter** | `slice`, `put_slice`, `gather`, `indexed_put` | Medium |
| **FFT** | via VkFFT | Already done |

Total: ~25 shaders, most trivial (element-wise ops are one-line
GLSL bodies with the same dispatch wrapper).

### Broadcasting

The hard part. Nx operations broadcast shapes automatically
(`[3, 1] + [1, 5]` → `[3, 5]`). Each shader needs a
`broadcast_index()` helper that maps output indices to input
indices. Spirit doesn't need this (fixed 3D vector fields).

```glsl
// broadcast_index: map output flat index to input flat index
// accounting for broadcast dimensions (stride=0 on broadcast axes)
uint broadcast_idx(uint out_idx, uint ndim, uint[8] out_shape,
                   uint[8] in_strides) {
    uint idx = 0;
    uint remaining = out_idx;
    for (int d = int(ndim) - 1; d >= 0; d--) {
        uint coord = remaining % out_shape[d];
        remaining /= out_shape[d];
        idx += coord * in_strides[d];  // stride=0 broadcasts
    }
    return idx;
}
```

This is a ~10 line GLSL function shared by all binary ops.

### defn JIT compilation

The real payoff. When `Nx.Defn.jit/3` is called, Nx builds an
expression graph. Instead of executing ops one at a time (each
needing a GPU dispatch + sync), the Vulkan backend records a
**Vulkan command buffer** with all dispatches batched:

```
1. vkBeginCommandBuffer
2. vkCmdBindPipeline(exp_shader)     # exp(x)
3. vkCmdDispatch(...)
4. vkCmdPipelineBarrier              # sync
5. vkCmdBindPipeline(multiply_shader) # result * y
6. vkCmdDispatch(...)
7. vkCmdPipelineBarrier
8. ...
9. vkEndCommandBuffer
10. vkQueueSubmit                     # ONE submit for the whole graph
11. vkQueueWaitIdle                   # ONE sync point
```

This is the same pattern Spirit uses for its solver iterations.
The overhead is one kernel launch per op (~5μs) with no CPU↔GPU
round-trips until the final result readback.

## NIF structure

```
nx_vulkan/
├── c_src/
│   ├── nx_vulkan_nif.c          # Erlang NIF entry points
│   ├── vk_context.c             # Instance, device, queue (from Spirit)
│   ├── vk_buffer.c              # Tensor buffer management
│   ├── vk_dispatch.c            # Shader load + dispatch
│   ├── vk_command.c             # Command buffer recording (defn JIT)
│   └── vk_fft.c                 # VkFFT wrapper
├── shaders/
│   ├── elementwise_unary.comp   # Parametric: push constant selects op
│   ├── elementwise_binary.comp  # Parametric: push constant selects op
│   ├── reduce.comp              # Sum/max/min/mean via subgroup ops
│   ├── matmul.comp              # Tiled matrix multiply
│   ├── random_normal.comp       # Philox RNG → normal distribution
│   └── ...
├── lib/
│   ├── nx_vulkan.ex             # Elixir module, loads NIF
│   ├── nx/vulkan/backend.ex     # Nx.Backend behaviour implementation
│   └── nx/vulkan/device.ex      # Device enumeration + selection
└── mix.exs
```

### Parametric shaders

Instead of 25 separate shader files, use **specialization constants**
(Vulkan's equivalent of template parameters):

```glsl
// elementwise_binary.comp — ONE shader for all binary ops
layout (constant_id = 0) const int OP = 0;  // 0=add, 1=mul, 2=sub, ...

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= consts.n) return;

    float a = input_a[broadcast_idx(i, ...)];
    float b = input_b[broadcast_idx(i, ...)];

    float result;
    switch (OP) {
        case 0: result = a + b; break;
        case 1: result = a * b; break;
        case 2: result = a - b; break;
        case 3: result = a / b; break;
        case 4: result = pow(a, b); break;
        case 5: result = max(a, b); break;
        case 6: result = min(a, b); break;
    }
    output[i] = result;
}
```

Vulkan compiles specialization constants at pipeline creation time,
so the switch is eliminated — same performance as individual shaders
but one source file.

## What this means for exmc

```elixir
# config/runtime.exs
config :nx, :default_backend, Nx.Vulkan.Backend
config :nx_vulkan, device: 0  # first GPU

# exmc code — ZERO CHANGES
{trace, stats} = Exmc.NUTS.Sampler.sample(ir, %{}, num_samples: 4000)
```

The NUTS sampler's `defn` functions compile into batched Vulkan
command buffers. Log-probability evaluation, leapfrog integration,
tree building — all run on GPU without code changes.

## Phases

### Phase 1: Vulkan context + basic ops (2 weeks)

- Extract Spirit's Vulkan init into standalone `vk_context.c`
- NIF: `init/0`, `create_buffer/2`, `to_binary/1`, `from_binary/3`
- Shaders: `elementwise_binary.comp`, `elementwise_unary.comp`
- Test: `Nx.add(a, b)` runs on GPU, result matches BinaryBackend

### Phase 2: Reductions + matmul (1 week)

- Shader: `reduce.comp` (Spirit's ReduceDot pattern, generalized)
- Shader: `matmul.comp` (tiled, handles non-square)
- Test: `Nx.sum(x)`, `Nx.dot(a, b)` on GPU

### Phase 3: Broadcasting + types (1 week)

- `broadcast_index()` in all binary shaders
- f32 and f64 support (specialization constant for type)
- Shape metadata in push constants
- Test: `Nx.add(Nx.tensor([1,2,3]), Nx.tensor([[1],[2]]))` broadcasts correctly

### Phase 4: Random + FFT (1 week)

- Shader: `random_normal.comp` (philox counter-based RNG)
- VkFFT integration from Spirit
- Test: `Nx.Random.normal(key, shape: {1000})` on GPU

### Phase 5: defn JIT (2 weeks)

- `__jit__/4` callback: walk expression graph, record command buffer
- Intermediate buffers allocated once, reused across ops
- Pipeline barrier insertion between dependent ops
- Test: `Nx.Defn.jit(fn x -> Nx.exp(x) |> Nx.sum() end)` — one submit

### Phase 6: exmc integration (1 week)

- Run exmc test suite with `Nx.Vulkan.Backend`
- Tune workgroup sizes for NUTS access patterns
- Benchmark vs BinaryBackend

### Phase 7: Polish + packaging (1 week)

- Hex package `nx_vulkan`
- FreeBSD port (depends on `vulkan-headers`, `spirv-tools`)
- CI on FreeBSD (GitHub Actions has no FreeBSD, use Cirrus CI)

## Effort

| Phase | Effort | Cumulative |
|---|---|---|
| 1. Context + basic ops | 2 w | 2 w |
| 2. Reductions + matmul | 1 w | 3 w |
| 3. Broadcasting + types | 1 w | 4 w |
| 4. Random + FFT | 1 w | 5 w |
| 5. defn JIT | 2 w | 7 w |
| 6. exmc integration | 1 w | 8 w |
| 7. Polish + packaging | 1 w | 9 w |
| **Total** | **~9 weeks** | |

**Usable for exmc after Phase 5** (7 weeks). Phases 6-7 are polish.

## Risks

1. **f64 on Vulkan.** Not all GPUs support `shaderFloat64`. NVIDIA
   does (on desktop GPUs). Need `VkPhysicalDeviceFeatures` check
   at init. Fallback: f32 with log-space arithmetic for stability.

2. **Vulkan driver stability on FreeBSD.** Spirit works, but it uses
   a subset of Vulkan (compute only, no graphics). Edge cases in
   buffer management or synchronization could surface. Mitigation:
   validation layers enabled during development.

3. **defn graph complexity.** Some `defn` graphs have control flow
   (`while`, `cond`). These can't be baked into a single command
   buffer — need CPU-side loop with per-iteration submits. Same
   pattern as XLA's `While` op.

4. **Memory management.** GPU OOM on large models. Need a buffer
   pool with eviction. Phase 1 uses naive alloc/free; Phase 5
   adds pooling.

## What this is NOT

- **Not a general Vulkan graphics engine.** Compute shaders only.
- **Not a CUDA replacement.** XLA on CUDA will always be faster
  (mature compiler, tensor cores, cuDNN). This is the FreeBSD path.
- **Not specific to NVIDIA.** Same shaders run on AMD (via RADV
  on FreeBSD) and Intel (via ANV). The multi-vendor story is a bonus.

## Relation to IPC bridge spec

The IPC bridge (`nx-gpu-freebsd.md`) is the **fallback** if Vulkan
proves too painful. The IPC bridge works today (XLA Linux binaries
exist) but adds latency and complexity. Vulkan is the main path
because it's native, single-process, multi-vendor, and builds on
proven infrastructure (Spirit).

If Phase 1 fails (Vulkan compute doesn't work reliably from an
Erlang NIF on FreeBSD), fall back to IPC bridge. Decision point:
end of Phase 1.

## Cross-references

- `~/spirit/` — Vulkan compute framework, proof of concept
- `~/spirit/core/include/data/Vulkan_Compute.hpp` — 7964-line Vulkan infra
- `~/spirit/shaders/ReduceDot.comp` — subgroup reduction pattern
- `~/spirit/shaders/Scale.comp` — element-wise pattern
- `specs/nx-gpu-freebsd.md` — IPC bridge fallback
- `docs/s6-milestone.md` — BinaryBackend limitations that motivate this
- EXLA source: `github.com/elixir-nx/nx/tree/main/exla`
- VkFFT: `github.com/DTolm/VkFFT`
