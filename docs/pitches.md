# Zed Pitches

## ZFS Properties Replace etcd/consul

### Traditional Stack

```
┌─────────────────────────────────────────────────────────────────┐
│  "Where is my deployment state?"                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  etcd/consul         State Files              Config DB         │
│  ┌──────────┐       ┌──────────────┐        ┌──────────────┐   │
│  │ key:     │       │ terraform    │        │ app_versions │   │
│  │  /apps/  │       │   .tfstate   │        │ ┌──────────┐ │   │
│  │  trading │       │ stored in    │        │ │ app: 1.4 │ │   │
│  │  =1.4.2  │       │ S3 bucket    │        │ │ host: a  │ │   │
│  └──────────┘       └──────────────┘        └──────────────┘   │
│       │                    │                       │            │
│       └────────────────────┼───────────────────────┘            │
│                            ▼                                    │
│                   THREE SOURCES OF TRUTH                        │
│                   (that can drift)                              │
└─────────────────────────────────────────────────────────────────┘
```

**Problems:**
- etcd/consul need 3-5 node quorum, monitoring, backups
- State files in S3 can desync from reality
- "What's actually running?" requires querying multiple systems
- Disaster recovery = restore DB + restore state + hope they match

### Zed with ZFS Properties

```
┌─────────────────────────────────────────────────────────────────┐
│  "Where is my deployment state?"                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  $ zfs get all jeff/apps/trading | grep com.zed                 │
│                                                                 │
│  jeff/apps/trading  com.zed:managed      true        local      │
│  jeff/apps/trading  com.zed:app          trading     local      │
│  jeff/apps/trading  com.zed:version      1.4.2       local      │
│  jeff/apps/trading  com.zed:deployed_at  2026-04-12  local      │
│                                                                 │
│                    ONE SOURCE OF TRUTH                          │
│                    (the filesystem itself)                      │
└─────────────────────────────────────────────────────────────────┘
```

### Comparison

| Feature | etcd/consul | ZFS properties |
|---------|-------------|----------------|
| Storage | Separate cluster | Filesystem metadata |
| Replication | Raft consensus | `zfs send/receive` |
| Backup | Separate backup job | Snapshots include it |
| Recovery | Restore DB + reconcile | `zfs receive` = done |
| Drift | State ≠ reality | State IS reality |
| Infrastructure | 3-5 nodes + monitoring | Zero (already have ZFS) |

### Why It Works

```elixir
# Snapshot captures BOTH data AND state
zfs snapshot jeff/apps/trading@v1.4.2

# Send to another host - properties travel WITH data
zfs send jeff/apps/trading@v1.4.2 | ssh host2 zfs receive tank/apps/trading

# On host2, the properties arrived automatically:
# com.zed:version = 1.4.2
# com.zed:app = trading
# No separate state sync needed
```

**The insight:** Every deployment tool eventually needs to answer "what version is deployed here?" Traditional tools store this answer *separately* from the deployed artifacts. ZFS lets you store it *with* the data. When you replicate data, you replicate state. When you rollback data, you rollback state. They cannot drift because they are the same thing.

### Rollback Comparison

```
Rollback in traditional stack:
  1. Restore previous container image
  2. Update etcd with old version
  3. Update state file
  4. Hope all three match
  5. Pray

Rollback in Zed:
  $ zfs rollback jeff/apps/trading@v1.4.1
  # Done. Data AND state reverted atomically.
```
