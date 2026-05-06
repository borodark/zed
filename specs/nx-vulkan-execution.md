# Nx.Vulkan Execution Plan

**Date:** 2026-04-28
**Status:** ready to execute

---

## Machine roles

| Machine | Role | Why |
|---|---|---|
| **Linux box** (192.168.0.33) | Primary development | Full toolchain (gcc, glslangValidator available via pkg), lavapipe software Vulkan for CI, fast iteration without GPU dependency |
| **FreeBSD Mac** (192.168.0.248) | GPU validation | Real NVIDIA hardware, target platform. Validate each phase here after it passes on Linux. |

**Both machines contribute.** Linux does the fast dev loop (compile,
test against software Vulkan). FreeBSD does the real GPU validation.
Push/pull via the shared git remote at 192.168.0.33.

## Pre-requisites (FreeBSD Mac)

The NVIDIA Vulkan ICD is missing. Fix before Phase 1 GPU validation:

```sh
# The kmod is 470 series (legacy). Match the driver version:
doas pkg install nvidia-driver-470
# This installs libGLX_nvidia, libnvidia-glcore, and the Vulkan ICD
# at /usr/local/share/vulkan/icd.d/nvidia_icd.json

# Install shader compiler
doas pkg install glslang

# Verify
vulkaninfo --summary  # should show NVIDIA GPU
glslangValidator --version
```

If the 470 kmod doesn't support Vulkan compute (it might — 470
added compute shader support), upgrade to nvidia-kmod + nvidia-driver
(latest 580 series).

## Pre-requisites (Linux box)

```sh
# Software Vulkan renderer (no GPU needed for dev)
sudo pkg install mesa-vulkan-lvp  # or apt install mesa-vulkan-drivers
sudo pkg install glslang spirv-tools

# Elixir + Erlang (already present for zed development)
```

---

## Project structure

New repo: `nx_vulkan` (or start as a directory under zed, extract later).

```
nx_vulkan/
├── c_src/
│   ├── nx_vulkan_nif.c       # NIF entry: init, alloc, dispatch, read
│   ├── vk_context.h/.c       # Vulkan instance, device, queue
│   ├── vk_buffer.h/.c        # GPU buffer alloc, host↔device transfer
│   ├── vk_shader.h/.c        # Load SPIR-V, create pipeline
│   ├── vk_dispatch.h/.c      # Record command buffer, submit, wait
│   └── vk_fft.h/.c           # VkFFT wrapper (Phase 4)
├── shaders/
│   ├── elementwise_unary.comp
│   ├── elementwise_binary.comp
│   ├── reduce.comp
│   ├── matmul.comp
│   ├── random_philox.comp
│   └── compile.sh             # glslangValidator → .spv
├── lib/
│   ├── nx_vulkan.ex           # Top-level, loads NIF
│   ├── nx/vulkan/backend.ex   # Nx.Backend behaviour
│   ├── nx/vulkan/device.ex    # Device info + selection
│   └── nx/vulkan/compiler.ex  # Defn compiler (Phase 5)
├── test/
│   ├── nx_vulkan_test.exs     # Basic ops
│   ├── backend_test.exs       # Nx.Backend contract
│   └── defn_test.exs          # JIT compilation
├── Makefile                   # Compiles c_src + shaders
└── mix.exs
```

---

## Phase 1: Vulkan context + basic ops (2 weeks)

### Week 1: C infrastructure + NIF skeleton

**Day 1-2: vk_context.c** — Extract from Spirit

```c
// Minimal Vulkan compute context
typedef struct {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue compute_queue;
    uint32_t queue_family_index;
    VkCommandPool command_pool;
    VkPhysicalDeviceMemoryProperties mem_props;
} NxVkContext;

int nx_vk_init(NxVkContext* ctx, int device_id);
void nx_vk_destroy(NxVkContext* ctx);
```

Source: Spirit's `createInstance()` (L355), `findPhysicalDevice()` (L396),
`createDevice()` (L432). Strip micromagnetics config, keep core Vulkan.

Test on Linux: `./test_vk_init` prints device name + memory info.
Test on FreeBSD: same, with NVIDIA device shown.

**Day 3-4: vk_buffer.c** — GPU tensor storage

```c
typedef struct {
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize size;
    uint32_t dtype;   // 0=f32, 1=f64, 2=i32, 3=i64
    uint32_t ndim;
    uint32_t shape[8];
} NxVkTensor;

int nx_vk_tensor_alloc(NxVkContext* ctx, NxVkTensor* t, uint32_t dtype, uint32_t ndim, uint32_t* shape);
int nx_vk_tensor_from_binary(NxVkContext* ctx, NxVkTensor* t, void* data, size_t size);
int nx_vk_tensor_to_binary(NxVkContext* ctx, NxVkTensor* t, void* out, size_t size);
void nx_vk_tensor_free(NxVkContext* ctx, NxVkTensor* t);
```

Source: Spirit's `allocateBuffer()` (L490), `transferDataFromCPU()` (L510),
`transferDataToCPU()` (L540).

**Day 5: NIF skeleton** — Erlang NIF loading the C library

```elixir
# nx_vulkan.ex
defmodule NxVulkan do
  @on_load :load_nif
  defp load_nif, do: :erlang.load_nif(~c"#{:code.priv_dir(:nx_vulkan)}/nx_vulkan", 0)

  def init(), do: :erlang.nif_error(:not_loaded)
  def create_tensor(_dtype, _shape, _data), do: :erlang.nif_error(:not_loaded)
  def read_tensor(_ref), do: :erlang.nif_error(:not_loaded)
  def destroy_tensor(_ref), do: :erlang.nif_error(:not_loaded)
end
```

Test: `NxVulkan.init()` returns `:ok`, `create_tensor` round-trips data.

### Week 2: First shader + Nx.Backend wiring

**Day 6-7: elementwise_binary.comp** — the parametric shader

```glsl
#version 450
layout (local_size_x = 256) in;
layout (constant_id = 0) const int OP = 0;
layout (push_constant) uniform Push { uint n; } pc;
layout (std430, binding = 0) readonly buffer A { float a[]; };
layout (std430, binding = 1) readonly buffer B { float b[]; };
layout (std430, binding = 2) writeonly buffer C { float c[]; };

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.n) return;
    float x = a[i], y = b[i];
    float r;
    switch (OP) {
        case 0: r = x + y; break;
        case 1: r = x * y; break;
        case 2: r = x - y; break;
        case 3: r = x / y; break;
        case 4: r = pow(x, y); break;
        case 5: r = max(x, y); break;
        case 6: r = min(x, y); break;
    }
    c[i] = r;
}
```

Compile: `glslangValidator -V elementwise_binary.comp -o elementwise_binary.spv`

**Day 8: vk_shader.c + vk_dispatch.c**

```c
int nx_vk_load_shader(NxVkContext* ctx, const char* spv_path, VkShaderModule* module);
int nx_vk_create_pipeline(NxVkContext* ctx, VkShaderModule shader,
                          int n_buffers, int spec_const, VkPipeline* pipeline,
                          VkPipelineLayout* layout, VkDescriptorSetLayout* desc_layout);
int nx_vk_dispatch(NxVkContext* ctx, VkPipeline pipeline, VkPipelineLayout layout,
                   VkDescriptorSet desc_set, uint32_t group_count_x,
                   uint32_t push_const_size, void* push_const_data);
```

Source: Spirit's shader loading (L465), pipeline creation (L1213-1243),
descriptor binding + dispatch patterns.

**Day 9-10: Nx.Vulkan.Backend** — first ops working

```elixir
defmodule Nx.Vulkan.Backend do
  @behaviour Nx.Backend

  defstruct [:ref, :shape, :type]

  @impl true
  def from_binary(out, binary) do
    ref = NxVulkan.create_tensor(nx_type(out.type), Tuple.to_list(out.shape), binary)
    put_in(out.data, %__MODULE__{ref: ref, shape: out.shape, type: out.type})
  end

  @impl true
  def to_binary(%{data: %{ref: ref}}, _limit) do
    NxVulkan.read_tensor(ref)
  end

  @impl true
  def add(out, l, r), do: binary_op(out, l, r, 0)
  def multiply(out, l, r), do: binary_op(out, l, r, 1)
  def subtract(out, l, r), do: binary_op(out, l, r, 2)
  def divide(out, l, r), do: binary_op(out, l, r, 3)

  defp binary_op(out, l, r, op_code) do
    ref = NxVulkan.elementwise_binary(l.data.ref, r.data.ref, op_code,
            Tuple.to_list(out.shape), nx_type(out.type))
    put_in(out.data, %__MODULE__{ref: ref, shape: out.shape, type: out.type})
  end
end
```

**Phase 1 gate test:**

```elixir
Nx.default_backend(Nx.Vulkan.Backend)
a = Nx.tensor([1.0, 2.0, 3.0])
b = Nx.tensor([4.0, 5.0, 6.0])
Nx.add(a, b) |> Nx.to_binary()  # => <<5.0, 7.0, 9.0>>
```

If this works on FreeBSD with the NVIDIA GPU, the path is proven.
If it fails, evaluate IPC bridge fallback.

---

## Phase 2-7 summary

| Phase | Deliverable | Gate test |
|---|---|---|
| 2 (1w) | reduce.comp + matmul.comp | `Nx.sum(x)`, `Nx.dot(a, b)` |
| 3 (1w) | Broadcasting + f64 | `Nx.add(Nx.tensor([1,2,3]), Nx.tensor([[1],[2]]))` |
| 4 (1w) | random_philox.comp + VkFFT | `Nx.Random.normal(key, shape: {10000})` |
| 5 (2w) | defn JIT (command buffer batching) | `Nx.Defn.jit(fn x -> Nx.exp(x) \|> Nx.sum() end)` |
| 6 (1w) | exmc integration | NUTS sampling on GPU, matches BinaryBackend |
| 7 (1w) | hex package, FreeBSD port, CI | `mix hex.publish` |

---

## Execution workflow

```
Linux box                          FreeBSD Mac
──────────                         ────────────
1. Write C + shaders               
2. Compile + test (lavapipe)       
3. git push                        
                                   4. git pull
                                   5. Compile + test (NVIDIA)
                                   6. Performance benchmark
                                   7. git push (if fixes needed)
```

Both machines push to `192.168.0.33:/mnt/jeff/home/git/repos/nx_vulkan.git`.

### Day 1 action items (today)

**On FreeBSD Mac (here):**
1. `doas pkg install nvidia-driver-470 glslang` — get Vulkan ICD + shader compiler
2. Create the repo skeleton at `~/nx_vulkan/`
3. Write `c_src/vk_context.c` — extract from Spirit
4. Write `Makefile` — compile C + shaders
5. Test: `./priv/test_vk_init` prints GPU name

**On Linux box (parallel, if available):**
1. Install `mesa-vulkan-drivers glslang-tools`
2. Clone the repo
3. Same test against lavapipe (software renderer)

Want me to start with item 2+3 — create the repo and extract the Vulkan context from Spirit?

---

## Phase 2 status update (2026-05-06)

Updated retroactively to reflect the actual state of `nx_vulkan` after
the gpu-node + Phase 2 architectural work. The original execution
plan above is preserved as the historical record; this section
supersedes any "to be created" language.

### What's shipped in `nx_vulkan` (the repo now exists at `~/projects/learn_erl/nx_vulkan/`)

The plan's Phases 1-7 are all closed. Beyond that, the gpu-node arc
added a layered architecture that the original spec didn't anticipate:

```
                     ┌─────────────────────────────────────────────┐
                     │  Nx.Vulkan.Node     (named GenServer)        │
                     │  • with_node/2 — generic serialized dispatch │
                     │  • watchdog timeout → {:error, :node_*}      │
                     │  • lifecycle owns the pipeline cache         │
                     └──────────────┬──────────────────────────────┘
                                    │
        ┌───────────────────────────┴───────────────────────────┐
        │                                                       │
┌───────▼──────────┐  ┌────────────────────┐  ┌─────────────────▼────┐
│ Nx.Vulkan.       │  │ Nx.Vulkan.         │  │ Nx.Vulkan.            │
│   PipelineCache  │  │   Synthesis +      │  │   ChainShaderSpecs    │
│   (vkPipeline-   │  │   ShaderTemplate   │  │   (Beta/Gamma/        │
│    Cache disk    │  │   (runtime GLSL +  │  │    Lognormal +        │
│    persistence)  │  │    glslangValidator│  │    6 hand-written)    │
└──────────────────┘  └────────────────────┘  └───────────────────────┘
                                    │
                              ┌─────▼──────┐
                              │  spirit    │
                              │  vendored  │
                              │  Vulkan    │
                              │  backend   │
                              └────────────┘
```

### Consumer surface

A consumer that wants the GPU node calls:

```elixir
# Once at app start (or under a supervisor):
{:ok, _} = Nx.Vulkan.Node.start_link()

# Per-dispatch (any client — exmc, smc_ex, custom):
result =
  Nx.Vulkan.Node.with_node(fn ->
    # Whatever GPU work needs to share the pipeline cache + buffer
    # state. The function runs serialized through the node's
    # GenServer process.
    Nx.Vulkan.Native.leapfrog_chain_synth(q_ref, p_ref, m_ref, push, k, spv_path)
  end)

case result do
  {:error, :node_timeout} -> exla_fallback()
  {:error, :node_dead} -> exla_fallback()
  ok_result -> ok_result
end
```

### Where zed plugs in

`zed` and `nx_vulkan` are **sibling repos**, not coupled at the Mix
dependency level. The deployment pattern is:

1. `zed` orchestrates BEAM nodes (start, stop, health-check, supervisor).
2. The BEAM nodes' own `mix.exs` lists `nx_vulkan` (and `exmc`, etc.)
   as Hex deps.
3. Each node loads `nx_vulkan` at boot; the application supervisor
   starts `Nx.Vulkan.Node`; the rest of the stack uses
   `with_node/2` for any GPU work.
4. `zed` doesn't need to know about Vulkan APIs at all — it deploys
   processes, supervises them, and the Vulkan-using ones come up
   under their own supervisors.

### What zed's specs originally proposed vs what shipped

| Item | Original plan | Actual |
|------|---------------|--------|
| Repo location | "directory under zed, extract later" | Standalone at `~/projects/learn_erl/nx_vulkan/`, vendor-published. |
| Single NIF | "`nx_vulkan_nif.c`" | Multiple NIFs through `c_src/nx_vulkan_shim.h`, dispatched via Rust `lib.rs`. |
| Parametric SPIR-V | "Single shader for many ops" | 9 hand-written chain shaders + runtime-templated synthesis for new families. |
| Defn JIT integration | "Command buffer batching" | Persistent buffer + batched IO at the dispatch level (R3 result on Linux NVIDIA). |
| Phase 7 milestone (week 7) | "exmc integration: NUTS sampling on GPU, matches BinaryBackend" | Shipped — see `pymc/exmc@feat/gpu-node` (now merged to main). |

### Open work that affects zed

- **W6 Phase 2** — driver-level dispatch cancellation (vkResetCommandPool,
  vkQueueWaitIdle). Only matters for `zed` if zed's supervisor strategy
  needs to recover from a hung GPU dispatch by restarting the GPU node.
  Currently the `Nx.Vulkan.Node`'s in-flight dispatch is uncancellable;
  the Phase 0 watchdog returns the caller to EXLA fallback but the
  GenServer process stays blocked until the driver returns.
- **Phase 3 of `PLAN_GPU_NODE.md`** — multi-client + protocol via
  `mdns_lite` discovery. Once shipped, `zed`'s mDNS layer (also planned
  with `mdns_lite`) and `nx_vulkan`'s GPU-node discovery can share the
  same advertisement infrastructure. Coordinate on service-name
  conventions (`_zed._tcp.local` vs `_exmc_gpu._tcp.local`).
- **Beta/Gamma adaptation tuning** (`nx_vulkan/research/gpu_node/beta_gamma_adaptation.md`)
  — pure exmc concern; doesn't touch zed.

### Practical compatibility check

`zed` and `nx_vulkan` are operationally compatible *today*:

- Both pin OTP 27 / Elixir 1.18.
- Both push to the same NAS git server.
- A BEAM node deployed via zed that imports `nx_vulkan` boots the
  Vulkan context per-node via `Nx.Vulkan.init/0`.
- No conflicting global state — `Nx.Vulkan.Node` registers under a
  named atom (`Nx.Vulkan.Node`), zed's services have their own names.
