# Zed and Its Satellites

*Six repositories, one BEAM cluster, three operating systems, two
GPUs from 2013, and a deliberate refusal to call any of it a
platform. A state-of-the-project post for May 2026.*

---

## What zed is, today

Zed is a declarative BEAM application deployment tool. Its center
is an Elixir DSL that compiles to an intermediate representation,
a converger that diffs the IR against ZFS user properties to plan
changes, and a small set of executors that apply those changes
through ZFS snapshots, FreeBSD jails, and Erlang distribution.

The codebase is roughly 3,000 lines of Elixir and 80 lines of C.
The C is one NIF — `peer_cred` — that calls `getpeereid(2)` on
the Unix-domain socket between zed's web frontend (`zedweb`) and
its operations daemon (`zedops`). The privilege boundary is
enforced at the kernel level; without those 80 lines, the rest of
zed couldn't run as a non-root user.

The A-series of iteration layers is shipped:

- **A0**: DSL slot validation. Compile-time `storage:` mode check.
- **A1**: Bootstrap. Encrypted `<base>/zed/secrets` dataset,
  fingerprint-stamped ZFS user properties, archived rotation history.
  The state-store is the filesystem; nothing else.
- **A2a/b**: Phoenix LiveView admin. Password login + 8h session
  + dashboard, then QR-paired first-login via single-use tokens.
- **A3**: Passkey (WebAuthn) auth. WAX-backed; verified on Chrome
  desktop, Safari iOS, Chrome Android.
- **A4**: SSH-key challenge auth. `ssh-keygen -Y sign` + login
  script. Key-pair-based, no shared secrets on the wire.
- **A5.1**: Bastille jail adapter. 540 lines; live-verified after
  seven real-world bugs that no mock could have predicted. The
  story is in *[The Lie at Exit Zero](blog-lie-at-exit-zero.html)*.
- **A5a**: Privilege boundary. zedweb runs unprivileged; zedops
  takes capability-scoped doas commands; the two communicate over
  a Unix socket the kernel authenticates via `getpeereid`.

May 7, 2026 — the day before this post — the dual-mac runbook ran
across two FreeBSD Mac Pros end-to-end. R1 through R5 in a single
pass. The chaos test (R5) caught a real P0 bug in coordinated
rollback. A 200-line TLA+ specification then caught a *second* bug
that five rounds of manual chaos testing had missed. The
implementation now mirrors the spec; three invariants hold across
172 reachable states. The arc is in
*[TLA+ Caught the Bug We Shipped](blog-tla-plus-caught-the-bug.html)*.

## The piece de resistance: the `host` verb

The moment zed graduated from a single-host deployment tool to a
real multi-host one was a verb. Mid-runbook, on May 7, mac-248
implemented `host` in the DSL — and what had been a hand-rolled
sequence of `:rpc.call` invocations became declarative:

```elixir
defmodule MyInfra.TwoHost do
  use Zed.DSL

  deploy :two_host, pool: "tank/zed-test" do
    host :mac_248, node: :"zed-controller@192.168.0.248",
                   pool: "mac_zroot/zed-test" do
      dataset "shared-app-248" do
        mountpoint :none
      end
    end

    host :mac_247, node: :"zed-agent@192.168.0.247",
                   pool: "zroot/zed-test" do
      dataset "shared-app-247" do
        mountpoint :none
      end
    end

    snapshots do
      before_deploy true
      keep 3
    end
  end
end

# Use it
MyInfra.TwoHost.diff()                  # both hosts, in one diff
MyInfra.TwoHost.converge_coordinated()  # 2-phase commit across both
MyInfra.TwoHost.status()                # aggregated state
```

The verb is unremarkable to look at. What it makes possible is not.
The diff aggregates state across all declared hosts. The converge
runs two phases — prepare + apply — across the cluster. If any host
fails, the rollback is coordinated: each host's pre-prepared
rollback target (a snapshot for modifications, a destroy for new
datasets) fires, and `NoPartialState` holds. The same TLA+ invariants
that govern the protocol underneath make the verb's contract
*provable*, not just intuitive.

This is the difference between "zed deploys to a host" and "zed
declaratively manages a fleet." It is the smallest visible artifact
that captures the largest design decision in the project. Twelve
lines of DSL produce a 100-millisecond two-host coordinated deploy
across two Erlang-distributed FreeBSD Mac Pros. The protocol is
verified. The runbook proved it on real ZFS, real RPC, real
hardware, with a chaos test that surfaced a real P0 — and the
verb is the same verb users will eventually write to deploy a
real production fleet.

The verb is the product.

## What it isn't yet

The honest summary lives in the README's *Road to Production*
section. Five P0 items, five P1 items, four explicit non-goals.

The P0 list is the part that matters: end-to-end converge on a
real prod-shaped target (one to two weeks of live-burn beyond the
dual-mac runbook); health checks wired to convergence (the spec
exists, the executor doesn't yet wait on them); chaos-tested
rollback under realistic failure modes (network partition during
apply, ZFS pool full, jail.conf syntax error mid-apply); secrets
distributed into the deploying app's env (designed, half-shipped);
Erlang-distribution TLS or `epmd_proxy` (cookies on the open
network are not a production boundary).

None of those is research. All of them are work. The estimate is
five to seven weeks of focused effort to clear P0. After that, the
P1 items — CI/CD, telemetry, upgrade strategies, depths of the
DSL — become reasonable to chase.

What zed has is the substrate. What it does not yet have is the
operational confidence to be trusted with production workloads. The
gap is named, listed, prioritized. It is also still a gap.

## The satellites

```
                            ┌──────┐
                            │ zed  │   declarative deploy tool
                            └──┬───┘   ZFS state store
                               │
              ┌────────────────┼─────────────────┐
              │                │                 │
        ┌─────▼─────┐    ┌─────▼─────┐    ┌──────▼──────┐
        │probnik_qr │    │nx_vulkan  │    │   exmc      │
        └───────────┘    └─────┬─────┘    └─────┬───────┘
                               │                 │
                         ┌─────▼─────┐           │
                         │  spirit   │  ◄────────┘
                         │ (vendored)│
                         └───────────┘

           ┌──────────────────────────────┐
           │      dataalienist.com        │   the writing surface
           └──────────────────────────────┘
```

### probnik_qr — the mobile companion (B0)

The QR scanner / admin companion. Mobile-side counterpart to
zed's first-login flow. Forks the existing `probnik` codebase,
adds a `zed_admin` payload handler, and ships as B0 in zed's
iteration plan. **Status: planned, not started.** A1's QR generation
landed in the dashboard months ago; the mobile half hasn't. The
spec is at `specs/b0-zedz-plan.md` in the zed repo.

### nx_vulkan — the GPU substrate

A GPU tensor backend for Nx via Vulkan compute. The only Nx GPU
backend that runs on FreeBSD. Cross-platform validated on Linux
RTX 3060 Ti, FreeBSD GT 750M, and FreeBSD GT 650M — 178 of 178
tests green on all three.

Phase 2 shipped this month: a long-lived per-machine GPU node
(`Nx.Vulkan.Node` GenServer with `with_node/2`), a disk-persistent
`vkPipelineCache` with header-validated UUID matching (4× cold-start
speedup), runtime shader synthesis from per-family specs (Beta,
Gamma, Lognormal compile to working SPIR-V in ~150 ms cold path; 5
ms cache hit), and a hand-written + synthesized chain-shader
catalog covering nine distribution families.

The honest parity gap versus EXLA and EMLX is documented in
[the README](https://github.com/borodark/nx_vulkan#position-vs-exla-and-emlx).
Op coverage is still ~30 plus 9 chain shaders against Nx's full
~200; that's 6-12 months of work to close. For the workloads that
fit the current op set, mesa-radv on FreeBSD is **seven times
faster** than NVIDIA Linux on the chain-shader path. Driver
quality, not silicon, dominates that regime. The measurement is in
*[Vulkan on FreeBSD: the Proof](blog-vulkan-on-freebsd-the-proof.html)*.

### exmc — probabilistic programming on top

An Elixir analog to PyMC. NUTS sampler, distribution catalog,
model DSL. The first real consumer of `nx_vulkan`'s GPU node API.

`Exmc.NUTS.Vulkan.Dispatch` routes chain shader calls through
`Nx.Vulkan.Node.with_node/2`. `Exmc.NUTS.Vulkan.SuspectTracker`
adds per-shader eviction policy plus cross-shader sliding-window
detection — the W6 Phase 1 work that lets a misbehaving shader
evict itself rather than tying up the GPU node forever. A
prior-aware mass-matrix initializer landed last week; the full
ESS-per-second gain it enables (1.6×-9× per the diagnosis at
`nx_vulkan/research/gpu_node/beta_gamma_adaptation.md`) needs a
structural change to the warmup-window-doubling logic that's
still pending. The foundation is correct; the second layer is
work.

### spirit — the most important satellite no one sees

The C++ Vulkan compute backend. About 800 lines of code. Vendored
into `nx_vulkan/c_src/spirit/`. The vendoring was deliberate —
pinning the upstream commit means a hex-published `nx_vulkan`
doesn't depend on the user cloning Spirit before they can
`mix compile`. The pinned commit and refresh procedure live in
`c_src/spirit/VENDOR.md`.

Spirit was originally an atomistic spin simulator. Its Vulkan
backend got extracted because it had something nobody else's
compute substrate had: a working FreeBSD Vulkan ICD pipeline,
verified end-to-end on a 2013 Mac Pro with a GeForce GT 750M.
*[The GPU That Doesn't Need CUDA](blog-vulkan-on-freebsd.html)* is
that origin story. Spirit is the layer that made the rest of the
constellation possible. It is also the layer most users of
`nx_vulkan` will never need to read.

### dataalienist.com — the writing surface

The blog you're reading this on. Eight long-form posts since
April 2026, mostly chronicling the constellation as it formed.
The posts aren't documentation; they're decisions stamped with
the date they were made. When a future engineer asks why zed's
coordinated converge has three phases instead of two, the answer
is in *[TLA+ Caught the Bug We Shipped](blog-tla-plus-caught-the-bug.html)*.
When they ask why the chain shaders are templated instead of
hand-written for each new distribution, the per-fence-latency
table in *[Vulkan on FreeBSD: the Proof](blog-vulkan-on-freebsd-the-proof.html)*
has the budget.

The blog is also the public record. Honesty here means the
README's *Road to Production* list goes into the post when it's
relevant, not just onto GitHub. Production-readiness gaps are the
same in both places, deliberately.

## How they relate

**They share the same NAS git server.** Two FreeBSD Mac Pros and
one Linux workstation push to `192.168.0.33`. mac-248 owns FreeBSD
bring-up; mac-247 is its SSH-reachable peer; super-io is the Linux
dev box. Cross-platform validation runs on every meaningful change
— a commit with `nx_vulkan` shader work doesn't ship until mac-248
runs it on FreeBSD. The Mac Pros are also the boxes the blog gets
written from. There is no CI farm. There are three machines and a
runbook and a discipline of running the runbook.

**They share OTP 27 and Elixir 1.18.** Same minimum baseline. A
change to Erlang's `:gen_statem` semantics affects all of them
simultaneously, which is fine because they all live in the same
monorepo of repos and update together.

**They don't share Mix dependencies.** zed doesn't import
`nx_vulkan`. `nx_vulkan` doesn't import `exmc`. The coupling is
operational — zed *deploys* a BEAM node that *uses* exmc that
*uses* nx_vulkan — not source-level. This is deliberate. zed
deploys things; it doesn't have opinions about what they are.
nx_vulkan is a GPU substrate; it doesn't have opinions about what
runs on top.

**The integration story is loose; the validation discipline is
tight.** Every commit on each repo gets verified on at least Linux
plus one FreeBSD Mac. The dual-mac runbook validated the multi-host
coordination layer end-to-end. The R10 cross-platform run on
`nx_vulkan` validated 178/178 tests on three distinct platforms.
None of this is automated; all of it is run by hand on real
hardware before pushing.

## What's next

Three things, in roughly the order they get done.

**zed Road to Production, P0 layer.** Health-check wiring (one
week). End-to-end converge on a real prod-shaped target (one to
two weeks live-burn beyond the dual-mac runbook). Distributed-Erlang
TLS or `epmd_proxy` (one week). Secrets-into-app-env pipeline (two
weeks — designed in `docs/SECRETS_DESIGN.md`, the agent-side
decrypt path is the missing half). Total: five to seven weeks of
focused work to clear P0.

**nx_vulkan Phase 3 — multi-client mDNS discovery.** The GPU node
is currently per-process. Phase 3 makes it discoverable across
BEAM nodes via `mdns_lite` advertisements. Coordinates with zed's
mDNS layer (also on the roadmap), so the two need to agree on
service-name conventions before either ships. Estimated: 2-3 weeks
joint.

**Beta/Gamma adaptation tuning, full fix.** The mass-matrix init
heuristic is shipped; the warmup-window-doubling structural change
is not. Ship the second layer and the headline gains become
reachable. One day to ship the structural change; another to
verify on the dual-mac runbook.

After those: probnik_qr (B0) for the mobile companion; op-coverage
push on `nx_vulkan` (3-6 months for `Nx.Defn` graph optimization
to reach EXLA-comparable parity for graph-heavy workloads); and
whatever the next bug surfaces. The bugs continue to surface.
They are not the kind of bug that breaks production; they are the
kind that improves the substrate. The arc of the constellation is
the arc of catching them.

## The shape

A constellation, not a monolith. Six repositories. One BEAM cluster.
Three operating systems. Two FreeBSD Mac Pros, two GPUs from 2013,
one Linux workstation, one Linux dev box, one NAS, one runbook,
one discipline.

The point is not the scale. The point is that none of this requires
Kubernetes, Docker, etcd, Consul, an external secret store, or a
cloud provider. ZFS is the state store. BEAM distribution is the
RPC layer. FreeBSD jails are the isolation primitive. TLA+ is the
design tool. The blog is the public record. Each piece is older
than this project; the project is the integration.

When zed reaches P0-clean — five to seven weeks of focused work
— the constellation is shippable. The Mountain of CUDA sophistication
is still there. We still aren't climbing it. We are walking around
it on a path that has now been measured, formally specified,
chaos-tested, and written down.

---

*This post is a snapshot of May 2026. The state changes; the snapshot
is the date.*
