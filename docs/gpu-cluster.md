# GPU Cluster Vision

Distributed ML/AI workloads across heterogeneous GPU machines using ZFS as the model store and state tracker.

## The Scenario

```
┌─────────────────────────────────────────────────────────────────────┐
│  Your Fleet                                                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │ Workstation │  │ Laptop 1    │  │ Laptop 2    │  │ Server      │ │
│  │ RTX 4090    │  │ M3 Max      │  │ RTX 3080    │  │ 2x A100     │ │
│  │ 24GB VRAM   │  │ 64GB unified│  │ 10GB VRAM   │  │ 80GB each   │ │
│  │             │  │             │  │             │  │             │ │
│  │ ZFS: tank/  │  │ ZFS: zpool/ │  │ ZFS: data/  │  │ ZFS: nvme/  │ │
│  │ Zed.Agent   │  │ Zed.Agent   │  │ Zed.Agent   │  │ Zed.Agent   │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘ │
│         │                │                │                │        │
│         └────────────────┴────────────────┴────────────────┘        │
│                              │                                      │
│                    Erlang Distribution                              │
│                              │                                      │
│                    ┌─────────▼─────────┐                            │
│                    │ Controller        │                            │
│                    └───────────────────┘                            │
└─────────────────────────────────────────────────────────────────────┘
```

## ZFS Properties for ML

```
tank/models/llama-70b    com.zed:type       model
tank/models/llama-70b    com.zed:version    2.1
tank/models/llama-70b    com.zed:size_gb    140
tank/models/llama-70b    com.zed:quantized  q4_k_m
tank/models/llama-70b    com.zed:requires   vram:48

tank/jobs/train-001      com.zed:type       job
tank/jobs/train-001      com.zed:status     running
tank/jobs/train-001      com.zed:gpu        rtx4090
tank/jobs/train-001      com.zed:started    2024-04-13T10:00:00Z
tank/jobs/train-001      com.zed:checkpoint @epoch-15
```

## Proposed DSL

```elixir
defmodule MyCluster.GPU do
  use Zed.DSL

  deploy :gpu_cluster, pool: "tank" do
    # Declare hardware capabilities
    node :workstation do
      gpu "RTX 4090", vram: 24
      dataset "models"
      dataset "jobs"
    end

    node :macbook do
      gpu "M3 Max", vram: 64, type: :unified
      dataset "models"  # replicated subset
    end

    # Model artifact
    model :llama70b do
      dataset "models/llama-70b"
      version "2.1"
      requires vram: 48  # only runs on nodes with enough VRAM
    end

    # Training job
    job :finetune do
      model :llama70b
      dataset "jobs/finetune-001"
      checkpoint_every "1 epoch"
      prefer gpu: "A100"  # soft preference
    end

    # Replication policy
    replicate :models do
      from :server
      to [:workstation, :macbook]
      filter "size_gb < 20"  # only small models to laptops
    end
  end
end
```

## What This Enables

### Model Distribution via ZFS

```elixir
# Model trained on A100 server
zfs snapshot nvme/models/llama-finetune@v1

# Replicate to workstation for inference
Zed.ZFS.Replicate.sync_to_remote(
  "nvme/models/llama-finetune@v1",
  "root@workstation",
  "tank/models/llama-finetune"
)

# Properties travel with it:
# com.zed:trained_on = a100
# com.zed:epochs = 50
# com.zed:loss = 0.0023
```

### GPU-Aware Scheduling

```elixir
# Find nodes that can run this model
Zed.Cluster.nodes_matching(requires: [vram: 48])
# => [:"zed@server", :"zed@workstation"]

# Dispatch job to best available
Zed.Cluster.dispatch(:finetune_job,
  prefer: [gpu: "A100"],
  fallback: [gpu: "RTX 4090"]
)
```

### Checkpoint = Snapshot

```elixir
# Training checkpoint is just a ZFS snapshot
zfs snapshot tank/jobs/train-001@epoch-15

# Resume from checkpoint on ANY machine with the data:
Zed.Cluster.resume_job(:train_001,
  from: "@epoch-15",
  on: :"zed@workstation"  # different machine!
)
```

### Instant Rollback on Bad Training

```
Epoch 20: loss 0.001 ✓
Epoch 21: loss 0.002
Epoch 22: loss 0.850  ← something went wrong

$ zfs rollback tank/jobs/train-001@epoch-20
# Instant. Resume from known-good state.
```

## Replaces

| Traditional | Zed + ZFS |
|-------------|-----------|
| MLflow | ZFS properties |
| DVC | zfs snapshot |
| Weights & Biases | ZFS properties + snapshots |
| Model registry | ZFS datasets + properties |
| NFS/S3 for models | zfs send/receive |
| Kubernetes for GPUs | Erlang distribution |
| Checkpoint files | ZFS snapshots |

## Implementation Phases

### Phase 7a — Node Capabilities
- [ ] `node` verb for hardware declaration
- [ ] GPU detection (nvidia-smi, Metal)
- [ ] Capability reporting in Agent

### Phase 7b — Model/Job Verbs
- [ ] `model` verb for artifact tracking
- [ ] `job` verb for distributed job state
- [ ] Checkpoint as snapshot

### Phase 7c — Smart Routing
- [ ] Match requirements to capabilities
- [ ] Dispatch to best available
- [ ] Replication policies

### Phase 7d — Linux + macOS
- [ ] Test Agent on Linux + OpenZFS
- [ ] Explore macOS + OpenZFS
