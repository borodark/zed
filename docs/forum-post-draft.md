# Elixir Forum Post Draft: S6 Demo Milestone

---

**Title:** Deployed 3 BEAM apps across FreeBSD jails with distributed Erlang — no Docker, no K8s, just ZFS + Bastille

---

I have been building [Zed](https://github.com/youruser/zed), an Elixir tool that deploys BEAM applications on FreeBSD using ZFS as the state store. The idea is that ZFS user properties and snapshots replace the need for etcd, Terraform state files, or container registries — deployment state travels with the filesystem.

This week I hit the first real demo milestone: three BEAM nodes (a Phoenix LiveView admin, an Nx-based NUTS sampler, and Livebook) running in separate FreeBSD jails, connected via distributed Erlang over a loopback network. PostgreSQL and ClickHouse run in their own jails on the same host. One script converges the whole thing from scratch.

**What it proves:**

- Distributed Erlang across Bastille jails works cleanly — EPMD binds to jail IPs, distribution routes over the internal network.
- A shared cookie stored in an encrypted ZFS dataset, nullfs-mounted read-only into each jail, solves secret distribution with zero file duplication.
- `:erpc.call` from a LiveView on one node triggers computation on another node and streams results back to the browser. The cluster page at `/cluster` shows `Node.list()` live and has a button to run 4-chain NUTS sampling on the exmc node.
- The one-command converge script (`demo-converge.sh`) is idempotent — rerun it and it skips already-converged state.

**What did not work:**

- **Livebook EPMD.** Livebook uses a custom EPMD module that prevents standard cluster joins. Workaround: `--hidden` node with explicit longname and cookie.
- **GPU on FreeBSD.** NVIDIA's FreeBSD driver does not expose CUDA. No EXLA, no Torchx. The production path for GPU work is a Linux node in the cluster connected via distributed Erlang.
- **BinaryBackend numerical stability.** Wide priors overflow in Nx.BinaryBackend's f64 math. Conservative parameter scales are required without EXLA.
- **App config complexity.** Two apps (craftplan, Plausible) are deferred because their runtime configuration needs (business secrets, migrations, license checks) are outside Zed's scope. This clarified where the tool's boundary should be.

The demo runs on a single Mac Pro. Next steps: a `Zed.Jail.Standard` behaviour for infrastructure services (pg, clickhouse), wiring the converge engine to replace shell script workarounds, and multi-host with a Linux GPU node for compute.

[Full technical report](docs/demo-report.md) | [Repository](https://github.com/youruser/zed)

---

*~400 words. Adjust repo URL before posting.*
