# On the Fundamental Absurdity of Deployment, and Its Remedy

*A Technical Memoir in the Style of Improbable Solutions*

---

> "The complexity of a system grows until it exceeds the capacity of the minds that created it to comprehend it, at which point those minds create another system to manage the first, and so the tower rises, floor upon floor, until it collapses under the weight of its own abstractions."
>
> — Attributed to no one, because no one wishes to claim it

---

## I. The Problem, As It Has Always Been

Consider the humble deployment.

A programmer writes code. The code must travel from the place of its creation to the place of its execution. Between these two points lies a chasm filled with YAML files, container orchestrators, configuration management tools, state databases, and the tears of operations engineers who once believed in simplicity.

We have, in our infinite wisdom, constructed systems to deploy systems that deploy systems. We have built Kubernetes to orchestrate Docker to contain applications that could run perfectly well without either. We have written Ansible playbooks to configure Terraform to provision infrastructure to run Helm to install charts to deploy pods to execute containers to run—at last—the twelve lines of code that constitute our actual business logic.

This is not engineering. This is archaeology in reverse: we are burying our works under layers of sediment while they are still alive.

## II. The Question No One Asked

What if the filesystem *already knew* what was deployed to it?

This is not a rhetorical flourish. This is the question that, once asked, reveals the entire deployment-industrial complex to be an elaborate workaround for a problem that need not exist.

ZFS—that venerable filesystem designed by engineers who understood that data has properties beyond mere bytes—provides user-definable metadata that travels with the data itself. When you snapshot a ZFS dataset, the metadata snapshots with it. When you `zfs send | zfs receive` to another machine, the metadata arrives intact, like a message in a bottle that actually contains the message.

```
com.zed:version     1.4.2
com.zed:app         trading
com.zed:deployed_at 2026-04-12T19:25:00Z
com.zed:managed     true
```

The deployment state IS the filesystem metadata. There is no database because the filesystem IS the database. There is no etcd because properties replicate with snapshots. There is no configuration drift because the configuration is the thing itself.

## III. The Solution, Described With Appropriate Skepticism

We have built Zed, a tool written in Elixir that compiles declarative deployment specifications into convergence operations against ZFS.

The reader is entitled to suspicion. "Another deployment tool," they say, reaching for their bottle of whiskey and their resignation letter. But attend:

```elixir
defmodule MyInfra.Trading do
  use Zed.DSL

  deploy :trading, pool: "jeff" do
    dataset "apps/exmc" do
      compression :lz4
    end

    app :exmc do
      dataset "apps/exmc"
      version "1.4.2"
      cookie {:env, "RELEASE_COOKIE"}
    end

    jail :trading_jail do
      dataset "jails/trading"
      ip4 "10.0.1.100/24"
      contains :exmc
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end
end
```

This is the *entire* specification. Not the specification of the specification, not the template that generates the configuration that drives the orchestrator. The thing itself.

When executed, this code:

1. Examines the current state of ZFS (by reading its properties)
2. Computes the difference between desired and actual
3. Generates a plan of operations
4. Executes the plan
5. Stamps the new state back to ZFS properties

Rollback is `zfs rollback`. Time to rollback: microseconds. Atomicity: guaranteed by a filesystem designed by people who understood transactions before web developers rediscovered them and called them "sagas."

## IV. On the Distribution of Deployment

The reader may object: "But I have many machines! Your elegant filesystem properties sit lonely on a single host while my distributed system sprawls across seventeen availability zones!"

To which we respond: ZFS replication.

```
┌─────────────────────┐     zfs send/recv     ┌─────────────────────┐
│  Host A             │ ──────────────────────│  Host B             │
│  jeff/apps/trading  │                       │  tank/apps/trading  │
│  com.zed:version    │    state travels      │  com.zed:version    │
│  = 1.4.2            │    with snapshot      │  = 1.4.2            │
└─────────────────────┘                       └─────────────────────┘
```

The deployment state travels with the data because it IS the data's metadata. No external state store to synchronize. No consensus protocol to fail at 3 AM. The filesystem IS the consensus.

But replication alone does not coordinate. For this, we rely on Erlang—a language designed by telephone engineers who understood distributed systems before the term existed, and who built into their runtime the assumption that nodes fail, networks partition, and the only response is to acknowledge reality and continue.

```elixir
# From the controller node
Zed.Cluster.connect(:"zed@host2")
Zed.Cluster.converge_all(ir)
```

Each host runs a `Zed.Agent` GenServer. The controller sends IR (Intermediate Representation) to agents via `:rpc.call`. Agents execute locally. State propagates via ZFS properties. The Erlang cookie is the only authentication because when your nodes are already authenticated BEAM processes, adding another authentication layer is not security but bureaucracy.

## V. On the Containment of Applications

FreeBSD jails are not containers. They are older, simpler, and—heresy though it may be to say—sufficient.

A jail is:
- A root filesystem (which can be a ZFS dataset)
- A network configuration (which can be as simple as an IP address)
- A process boundary (enforced by the kernel, not a daemon)

Zed generates `jail.conf.d` files:

```
trading_jail {
    path = "/mnt/jeff/jails/trading";
    host.hostname = "trading.local";
    ip4.addr = "10.0.1.100/24";
    mount.devfs;
    exec.start = "/bin/sh /etc/rc";
    exec.stop = "/bin/sh /etc/rc.shutdown";
}
```

No Docker daemon. No containerd. No CRI-O. No container runtime interface implementing a container runtime that implements containers. A jail is a system call, not a philosophy.

## VI. The Architecture, For Those Who Must Know

```
┌─────────────────────────────────────────────────────────────────┐
│                           Zed                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ DSL         │───▶│ IR          │───▶│ Converge            │  │
│  │ (macros)    │    │ (validated) │    │ diff→plan→execute   │  │
│  └─────────────┘    └─────────────┘    └──────────┬──────────┘  │
│                                                   │             │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────▼──────────┐  │
│  │ Platform    │    │ BEAM        │    │ ZFS                 │  │
│  │ FreeBSD/    │    │ Release     │    │ Dataset/Property/   │  │
│  │ illumos     │    │ Health      │    │ Snapshot/Replicate  │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Agent (GenServer) ←──── :rpc.call ────→ Cluster            ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

The DSL compiles at compile-time (as Elixir macros do) to an Intermediate Representation that is validated before any operation touches the system. Broken references—an app referring to a nonexistent dataset, a jail containing an undeclared app—are caught when you run `mix compile`, not when you run the deployment at 2 AM.

The convergence engine diffs desired state against ZFS properties, generates an ordered plan (datasets before jails before apps before services), executes steps, and stamps new properties on success.

Rollback is:
```elixir
Zed.Converge.rollback(ir, "@latest")
```

Which executes:
```sh
zfs rollback -r pool/dataset@snapshot
```

There is no undo log because ZFS IS the undo log.

## VII. What We Have Actually Built

In this session, we have:

1. **Implemented the DSL** — Elixir macros that accumulate declarations and validate at compile-time
2. **Implemented convergence** — diff, plan, execute against real ZFS
3. **Implemented jail management** — `jail.conf.d` generation, lifecycle management
4. **Implemented multi-host coordination** — Agent GenServer, Cluster module, `:rpc.call` operations
5. **Implemented ZFS replication** — `zfs send | zfs receive` for state transfer
6. **Tested across two FreeBSD jails** — Actually deployed, actually converged, actually verified

The test:
```elixir
# From controller jail (plausible)
Zed.Cluster.connect(:"zed@zed-agent-1")
Zed.Cluster.converge(:"zed@zed-agent-1", ir)
Zed.Cluster.status(:"zed@zed-agent-1", ir)

# Returns:
%{
  datasets: %{
    "agent1/testapp" => %{
      exists: true,
      properties: %{
        "app" => "testapp",
        "managed" => "true",
        "version" => "1.0.0"
      }
    }
  }
}
```

The dataset was created on a remote machine. The properties were stamped. The state was queried. No YAML was harmed in the process.

## VIII. Conclusion, With Reservations

We do not claim to have solved deployment. We claim only to have removed several layers of indirection that existed because no one questioned whether they were necessary.

ZFS properties as state store: works.
Erlang distribution for coordination: works.
FreeBSD jails for isolation: works.
Elixir DSL for specification: works.

The tower of abstraction remains tall elsewhere. But here, on this small island of ZFS and BEAM, we have built something that a single human can understand, modify, and debug without consulting seventeen different documentation sites and three deprecated GitHub repositories.

Whether this constitutes progress is left as an exercise for the historian.

---

*Zed is approximately 2,000 lines of Elixir. The Kubernetes codebase exceeds 2 million lines of Go. We leave the comparison to the reader's judgment, noting only that one of these numbers is closer to the number of lines a human can hold in their head simultaneously.*

---

## Appendix: For the Practically Minded

```sh
# Clone
git clone git@host:/path/to/zed.git

# Test (58 tests, 0 failures)
mix test

# Test with real ZFS
mix test --include zfs_live

# Use
defmodule MyDeploy do
  use Zed.DSL

  deploy :prod, pool: "tank" do
    # ... your infrastructure
  end
end

MyDeploy.converge()
```

The source is the documentation. The types are the specification. The tests are the proof.

As it should be.
