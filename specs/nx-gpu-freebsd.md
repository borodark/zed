# Nx GPU on FreeBSD: NIF IPC Bridge

**Date:** 2026-04-28
**Status:** proposal, informed by S6 demo + ports tree analysis

---

## Problem

Nx on FreeBSD has no GPU path. The native NVIDIA driver (580.95.05)
ships graphics-only — zero compute libraries (`libcuda.so` is absent).
EXLA requires Linux. BinaryBackend overflows on non-trivial NUTS
models. The demo proved the cluster works, but exmc on BinaryBackend
is a toy.

## What's already on this machine

```
NATIVE (FreeBSD)                     LINUXULATOR
────────────────                     ──────────
nvidia-kmod-470        ←→           linux-nvidia-libs (libcuda.so,
nvidia-driver-580                    libnvidia-ptxjitcompiler.so)
  lib/libnvidia-ml.so                CUDA runtime: yes
  lib/libnvidia-glcore.so            XLA prebuilt: available
  CUDA: NO                           BEAM: NO (Linux binary)
  BEAM: YES (native)
```

The gap: BEAM runs native, CUDA runs under Linuxulator. They can't
load each other's `.so` files.

## The bridge

```
┌─────────────────────────────┐     ┌──────────────────────────────┐
│  BEAM (native FreeBSD)      │     │  GPU worker (Linux binary)   │
│                             │     │                              │
│  Nx.BinaryBackend (CPU)     │     │  XLA / CUDA runtime          │
│        ↓                    │     │        ↑                     │
│  Nx.IPC.Backend             │     │  ipc_gpu_server              │
│    serialize tensor op      │────▶│    deserialize                │
│    send via unix socket     │     │    execute on GPU             │
│    receive result           │◀────│    serialize result           │
│    return Nx.Tensor         │     │    send via unix socket       │
│                             │     │                              │
└─────────────────────────────┘     └──────────────────────────────┘
     /var/run/nx_gpu.sock              runs under Linuxulator
```

Two processes, one socket. The BEAM never loads Linux libraries.
The GPU worker never loads FreeBSD libraries. The kernel module
(`nvidia-kmod`) bridges the hardware, same as it does for graphics.

## Protocol

Flatbuffers or a minimal binary protocol. Each message:

```
┌──────┬──────┬────────┬───────────┐
│ op   │ dtype│ shape  │ data      │
│ u16  │ u8   │ u32[]  │ bytes     │
└──────┴──────┴────────┴───────────┘
```

Operations batched: the BEAM sends a computation graph (like XLA's
HLO), not individual tensor ops. This is what EXLA already does —
compile a `defn` into an XLA computation, send it as one unit,
get the result back.

### Op categories

| Category | Examples | Batch? |
|---|---|---|
| Element-wise | add, multiply, exp, log | Yes, fused |
| Reduction | sum, mean, max | Yes |
| Linear algebra | dot, solve, cholesky | Yes |
| Random | normal, uniform | Yes (seed on GPU side) |
| Control flow | while, cond | Compiled into graph |

For NUTS sampling, the hot path is: `log_prob` computation (many
element-wise + reductions) and the leapfrog integrator (dot products,
gradient via AD). These compile into a single XLA computation that
runs entirely on GPU. The IPC cost is one round-trip per leapfrog
step, not per tensor op.

## The GPU worker

A standalone Linux binary. Options for implementation:

### Option A: Elixir + EXLA under Linuxulator

```sh
# Install Linux Elixir + EXLA in the Linuxulator prefix
/compat/linux/usr/bin/elixir --no-halt -e '
  NxGpu.Server.start(socket: "/var/run/nx_gpu.sock")
'
```

Pro: reuse EXLA as-is. `Nx.Defn.jit` on the GPU side handles
compilation, caching, memory management.

Con: full Linux BEAM under Linuxulator. Works but heavy.

### Option B: Python + JAX

```sh
/compat/linux/usr/bin/python3 -c '
  import jax, socket
  # ... listen on unix socket, execute JAX computations
'
```

Pro: JAX is battle-tested, same XLA backend as EXLA.
Con: Python dependency, serialization overhead, two ecosystems.

### Option C: C++ XLA client

A minimal C++ binary that links `libcuda.so` + XLA's C API directly.
Reads computation graphs from the socket, executes via
`xla::Client::Execute`, returns results.

Pro: smallest possible worker, no interpreter overhead.
Con: most implementation work. XLA's C API is under-documented.

**Recommendation: Option A.** An Elixir process under Linuxulator
that wraps EXLA. The FreeBSD-side `Nx.IPC.Backend` serializes the
`defn` expression, the Linux-side worker JIT-compiles and runs it.
This reuses all of EXLA's compilation caching, memory management,
and multi-device support.

## The FreeBSD-side backend

A new Nx backend module: `Nx.IPC.Backend` (or `Nx.Bridge.Backend`).

```elixir
defmodule Nx.Bridge.Backend do
  @behaviour Nx.Backend

  # Tensors on this backend are references to GPU-side memory.
  # The actual data lives in the worker process.
  defstruct [:ref, :shape, :type, :worker_pid]

  @impl true
  def from_binary(binary, type, shape, _opts) do
    # Send binary to worker, get a ref back
    ref = Worker.send_tensor(binary, type, shape)
    %__MODULE__{ref: ref, shape: shape, type: type}
  end

  @impl true
  def to_binary(tensor, _limit) do
    # Fetch data from worker
    Worker.fetch_tensor(tensor.ref)
  end

  # Defn compilation — the hot path
  @impl true
  def concatenate(tensors, axis) do
    Worker.exec(:concatenate, [refs(tensors), axis])
  end

  # ... etc for each Nx operation

  # The real power: defn sends the whole graph
  def __jit__(key, vars, fun, opts) do
    Worker.jit(key, vars, fun, opts)
  end
end
```

The `__jit__/4` callback is where it gets interesting. When a `defn`
is compiled, instead of executing locally, the backend serializes
the expression tree and sends it to the worker. The worker compiles
it with XLA (once, cached) and runs it on GPU. Subsequent calls
with the same key skip compilation.

## Wire protocol detail

### Shared memory fast path

For large tensors, Unix socket serialization is too slow. Use
POSIX shared memory (`shm_open` / `mmap`) for the data payload:

```
Control message (socket):  {op: :jit_exec, key: hash, shm_name: "/nx_0x1234", size: 4096}
Data (shared memory):      [raw tensor bytes at /dev/shm/nx_0x1234]
Result (shared memory):    [raw result bytes at /dev/shm/nx_0x5678]
Ack (socket):              {ok: true, result_shm: "/nx_0x5678", shape: [1000], type: :f64}
```

FreeBSD's Linuxulator supports `shm_open` — Linux processes and
FreeBSD processes can share the same POSIX shm segment.

## What this enables for exmc

```elixir
# In exmc's runtime.exs (production, FreeBSD + GPU):
config :nx, :default_backend, Nx.Bridge.Backend
config :nx_bridge, socket: "/var/run/nx_gpu.sock"

# The NUTS sampler doesn't change at all — it uses Nx operations
# which transparently route through the bridge to GPU.
{trace, stats} = Exmc.NUTS.Sampler.sample(ir, %{}, num_samples: 4000)
```

No code changes in exmc. No code changes in the sampler. The backend
swap is config-only. BinaryBackend for dev/test, Bridge for prod.

## Effort

| Piece | Effort |
|---|---|
| `Nx.Bridge.Backend` — socket client, tensor refs | 3 d |
| GPU worker (Option A: Elixir+EXLA under Linuxulator) | 2 d |
| Wire protocol (flatbuffers or custom binary) | 2 d |
| Shared memory fast path | 2 d |
| `defn` graph serialization + remote JIT | 3 d |
| Integration with exmc (config swap, test suite) | 1 d |
| Linuxulator setup automation (jail or host script) | 1 d |
| **Total** | **~14 d** |

### Risks

1. **Linuxulator CUDA stability.** The Linux CUDA runtime under
   FreeBSD's Linuxulator works for simple programs. Unknown if XLA's
   full CUDA usage (streams, events, unified memory) is stable.
   Mitigation: test with a simple XLA computation before building
   the bridge.

2. **Shared memory across ABI boundary.** POSIX shm between FreeBSD
   and Linuxulator processes should work (same kernel), but edge
   cases around `mmap` flags and alignment need testing.

3. **XLA compilation latency.** First `defn` call compiles the XLA
   graph (can take seconds). Subsequent calls are cached. The bridge
   must handle the cache on the worker side, keyed by graph hash.

## What this does NOT solve

- **Jail GPU passthrough.** The GPU worker runs on the host or in a
  bhyve VM, not in a jail. exmc in a jail talks to the worker via
  the socket (which can be nullfs-mounted into the jail).
- **Multi-GPU.** Single GPU for v1. XLA supports multi-device but
  the bridge would need device placement logic.
- **AMD/Intel GPUs.** This is NVIDIA-specific via CUDA. ROCm on
  FreeBSD is even further away than CUDA.

## Cross-references

- `specs/standard-jails.md` — exmc jail topology
- `specs/demo-cluster-plan.md` — the demo that surfaced BinaryBackend limits
- `docs/s6-milestone.md` — GPU research findings
- EXLA source: `github.com/elixir-nx/nx/tree/main/exla`
- FreeBSD Linuxulator: `man 4 linux`
