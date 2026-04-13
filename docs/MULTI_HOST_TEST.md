# Multi-Host RPC Test Setup

Testing Zed's distributed deployment across multiple FreeBSD jails on TrueNAS.


<img width="3162" height="840" alt="image" src="https://github.com/user-attachments/assets/1579577c-74c6-4678-8f9a-9740f33cc935" />


## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  TrueNAS Host (192.168.0.33)                                       │
│                                                                    │
│  ┌──────────────────┐     ┌──────────────────┐                     │
│  │ plausible        │     │ zed-agent-1      │                     │
│  │ (controller)     │     │ (agent)          │                     │
│  │                  │     │                  │                     │
│  │ IP: DHCP         │◄───►│ IP: DHCP         │                     │
│  │ ZFS: jeff/zed-*  │     │ ZFS: jeff/agent1 │                     │
│  │                  │     │                  │                     │
│  │ iex --name       │     │ iex --name       │                     │
│  │ zed@plausible    │     │ zed@zed-agent-1  │                     │
│  └──────────────────┘     └──────────────────┘                     │
│           │                        │                               │
│           └────────────────────────┘                               │
│                 Erlang Distribution                                │
│                 Cookie: zed_test_cookie                            │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- TrueNAS with iocage
- Root access to TrueNAS host
- ZFS pool `jeff` (or adjust commands below)

---

## Part 1: Provision Agent Jail

Run these commands **on the TrueNAS host** (not inside plausible jail):

```sh
# SSH to TrueNAS host
ssh root@192.168.0.33
```

### 1.1 Create the Jail

```sh
# First, check what releases are available locally
iocage list -r

# If empty, fetch a release (or list remote releases)
iocage fetch -r 13.1-RELEASE
# Or to see what's available remotely:
# iocage fetch -r --list

# Check what release the host is running (safest to match)
freebsd-version
# e.g., 13.1-RELEASE-p9

# Create jail with available release and DHCP networking
iocage create -n zed-agent-1 -r 13.5-RELEASE \
  dhcp=on \
  bpf=yes \
  vnet=on \
  allow_raw_sockets=1 \
  boot=on

# Start the jail
iocage start zed-agent-1

# Verify it's running
iocage list
```

### 1.2 Delegate ZFS Dataset

```sh
# Create dataset for the agent
zfs create jeff/agent1

# Delegate ZFS permissions to the jail
# This allows the jail to manage child datasets
iocage set allow_mount=1 zed-agent-1
iocage set allow_mount_zfs=1 zed-agent-1
iocage set enforce_statfs=1 zed-agent-1

# Delegate the dataset
zfs allow -ldu root create,destroy,mount,snapshot,rollback,hold,release jeff/agent1

# Mount the dataset in the jail
iocage fstab -a zed-agent-1 "/mnt/jeff/agent1 /mnt/agent1 nullfs rw 0 0"

# Or use jail-specific ZFS delegation
iocage set jail_zfs=on zed-agent-1
iocage set jail_zfs_dataset=jeff/agent1 zed-agent-1
```

### 1.3 Install Erlang/Elixir in Agent Jail

```sh
# Enter the jail
iocage console zed-agent-1

# Install packages
pkg update
pkg install -y erlang elixir git

# Verify
elixir --version
erl -version

# Exit jail
exit
```

### 1.4 Deploy Zed to Agent Jail

```sh
# From TrueNAS host, copy the zed project
# Option A: Clone from git
iocage exec zed-agent-1 "cd /root && git clone git@192.168.0.33:/mnt/jeff/home/git/repos/zed.git"

# Option B: Copy from plausible jail
cp -r /mnt/jeff/home/io/zed /mnt/jeff/iocage/jails/zed-agent-1/root/root/zed

# Enter jail and compile
iocage console zed-agent-1
cd /root/zed
mix local.hex --force
mix local.rebar --force
mix deps.get
mix compile
```

### 1.5 Get Jail IP Address

```sh
# From TrueNAS host
iocage exec zed-agent-1 "ifconfig epair0b | grep inet"
# Note the IP, e.g., 192.168.0.117
```

---

## Part 2: Configure Erlang Distribution

### 2.1 Set Up Hosts Resolution

On **both** jails, add hostname entries:

```sh
# In plausible jail
echo "192.168.0.117 zed-agent-1" >> /etc/hosts

# In zed-agent-1 jail (use plausible's IP)
echo "192.168.0.116 plausible" >> /etc/hosts
```

Or use fully qualified names with DNS.

### 2.2 Create Shared Cookie

```sh
# Generate a cookie (same on both nodes)
echo "zed_test_cookie_$(date +%s)" > ~/.erlang.cookie
chmod 400 ~/.erlang.cookie

# Or set via environment
export RELEASE_COOKIE=zed_test_cookie
```

---

## Part 3: Start the Cluster

### 3.1 Start Controller Node (plausible)

```sh
# In plausible jail
cd /usr/home/io/zed

# Start named node
iex --name zed@plausible --cookie zed_test_cookie -S mix
```

```elixir
# In IEx, start the agent
Zed.Agent.start_link()
```

### 3.2 Start Agent Node (zed-agent-1)

```sh
# In zed-agent-1 jail
cd /root/zed

# Start named node
iex --name zed@zed-agent-1 --cookie zed_test_cookie -S mix
```

```elixir
# In IEx, start the agent
Zed.Agent.start_link()
```

### 3.3 Connect Nodes

From the **controller** (plausible):

```elixir
# Connect to agent
Zed.Cluster.connect(:"zed@zed-agent-1")
# => :ok

# Verify connection
Zed.Cluster.nodes()
# => [:"zed@zed-agent-1"]

# Ping agent
Zed.Cluster.ping(:"zed@zed-agent-1")
# => {:pong, :"zed@zed-agent-1"}

# Get agent info
Zed.Cluster.info(:"zed@zed-agent-1")
```

---

## Part 4: Test Distributed Operations

### 4.1 Create Test IR

```elixir
# Define a simple deployment
ir = %Zed.IR{
  name: :cluster_test,
  pool: "jeff",
  datasets: [
    %Zed.IR.Node{
      id: "agent1/testapp",
      type: :dataset,
      config: %{compression: :lz4}
    }
  ],
  apps: [
    %Zed.IR.Node{
      id: :testapp,
      type: :app,
      config: %{
        dataset: "agent1/testapp",
        version: "1.0.0"
      },
      deps: ["agent1/testapp"]
    }
  ],
  jails: [],
  zones: [],
  clusters: [],
  snapshot_config: %{before_deploy: false, keep: 5}
}
```

### 4.2 Test Remote Diff

```elixir
# Get diff from remote agent
Zed.Cluster.diff(:"zed@zed-agent-1", ir)
```

### 4.3 Test Remote Converge (Dry Run)

```elixir
# Dry run on remote
Zed.Cluster.converge(:"zed@zed-agent-1", ir, dry_run: true)
```

### 4.4 Test Actual Converge

```elixir
# Actually converge on remote
Zed.Cluster.converge(:"zed@zed-agent-1", ir)

# Check status
Zed.Cluster.status(:"zed@zed-agent-1", ir)
```

### 4.5 Test Multi-Node Operations

```elixir
# Converge on all connected nodes
Zed.Cluster.converge_all(ir, dry_run: true)

# Coordinated converge with rollback on failure
Zed.Cluster.converge_coordinated(ir)

# Get status from all nodes
Zed.Cluster.status_all(ir)
```

### 4.6 Test ZFS Replication

```elixir
# Replicate a dataset to remote (via SSH)
Zed.ZFS.Replicate.sync_to_remote(
  "jeff/zed-test",
  "root@zed-agent-1",
  "jeff/agent1/replicated",
  version: "1.0.0"
)

# Verify properties traveled with the data
# On remote:
# zfs get all jeff/agent1/replicated | grep com.zed
```

---

## Part 5: Verify Results

### 5.1 Check ZFS Properties on Agent

```sh
# In zed-agent-1 jail or via SSH
zfs list -r jeff/agent1
zfs get all jeff/agent1/testapp | grep com.zed
```

Expected output:
```
jeff/agent1/testapp  com.zed:managed   true    local
jeff/agent1/testapp  com.zed:app       testapp local
jeff/agent1/testapp  com.zed:version   1.0.0   local
```

### 5.2 Check Deployment Status

```elixir
# From controller
Zed.Cluster.info(:"zed@zed-agent-1")
# Shows deployments map with last_converge timestamps
```

---

## Part 6: Teardown (Optional)

### 6.1 Stop the Nodes

```elixir
# In each IEx session
System.stop(0)
# Or Ctrl+C twice
```

### 6.2 Clean Up Test Datasets

```sh
# On TrueNAS host or in agent jail
zfs destroy -r jeff/agent1/testapp
```

### 6.3 Stop and Remove Agent Jail

```sh
# On TrueNAS host
iocage stop zed-agent-1
iocage destroy -f zed-agent-1

# Remove delegated dataset (optional)
zfs destroy -r jeff/agent1
```

### 6.4 Full Teardown Script

Save as `teardown-agent.sh` on TrueNAS host:

```sh
#!/bin/sh
# Teardown zed-agent-1 jail and associated resources

JAIL_NAME="zed-agent-1"
DATASET="jeff/agent1"

echo "Stopping jail $JAIL_NAME..."
iocage stop $JAIL_NAME 2>/dev/null

echo "Destroying jail $JAIL_NAME..."
iocage destroy -f $JAIL_NAME 2>/dev/null

echo "Destroying dataset $DATASET..."
zfs destroy -r $DATASET 2>/dev/null

echo "Cleaning up hosts entries..."
sed -i '' "/$JAIL_NAME/d" /etc/hosts

echo "Done."
```

---

## Troubleshooting

### Connection Refused

```elixir
# Check if epmd is running
System.cmd("epmd", ["-names"])

# Verify cookie matches
Node.get_cookie()
```

### Node Not Responding

```sh
# Check if jail is running
iocage list

# Check if Elixir process is running in jail
iocage exec zed-agent-1 "ps aux | grep beam"

# Check network connectivity
ping zed-agent-1
```

### ZFS Permission Denied

```sh
# Verify ZFS delegation
zfs allow jeff/agent1

# Re-delegate if needed
zfs allow -ldu root create,destroy,mount,snapshot,rollback jeff/agent1
```

### RPC Timeout

```elixir
# Increase timeout for slow operations
Zed.Cluster.converge(:"zed@zed-agent-1", ir, timeout: 120_000)
```

---

## Quick Reference

| Command | Purpose |
|---------|---------|
| `iocage create -n NAME -r 13.2-RELEASE` | Create jail |
| `iocage start NAME` | Start jail |
| `iocage console NAME` | Enter jail shell |
| `iocage exec NAME "cmd"` | Run command in jail |
| `iocage stop NAME` | Stop jail |
| `iocage destroy -f NAME` | Remove jail |
| `zfs allow DATASET` | Check ZFS permissions |
| `Node.connect(:'name@host')` | Connect Erlang nodes |
| `Node.list()` | List connected nodes |
