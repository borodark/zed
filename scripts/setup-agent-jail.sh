#!/bin/sh
#
# Setup Zed agent jail for multi-host testing
# Run as root on TrueNAS host
#
# Usage: ./setup-agent-jail.sh [jail-name] [dataset-name]
#
# Example: ./setup-agent-jail.sh zed-agent-1 agent1
#

set -e

# Configuration
JAIL_NAME="${1:-zed-agent-1}"
DATASET_NAME="${2:-agent1}"
RELEASE="${RELEASE:-13.5-RELEASE}"
POOL="${POOL:-jeff}"
ZED_REPO="${ZED_REPO:-/mnt/jeff/home/io/zed}"
COOKIE="${COOKIE:-zed_cluster_cookie}"

echo "=== Zed Agent Jail Setup ==="
echo "Jail:    $JAIL_NAME"
echo "Dataset: $POOL/$DATASET_NAME"
echo "Release: $RELEASE"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Must run as root"
    exit 1
fi

# Check if jail already exists
if iocage list | grep -q "^| $JAIL_NAME "; then
    echo "Warning: Jail $JAIL_NAME already exists"
    read -p "Destroy and recreate? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo "Destroying existing jail..."
        iocage stop $JAIL_NAME 2>/dev/null || true
        iocage destroy -f $JAIL_NAME
    else
        echo "Aborting."
        exit 1
    fi
fi

# Step 1: Create jail
echo ""
echo "=== Step 1: Creating jail ==="
iocage create -n $JAIL_NAME -r $RELEASE \
    dhcp=on \
    bpf=yes \
    vnet=on \
    allow_raw_sockets=1 \
    boot=on

# Step 2: Configure ZFS delegation
echo ""
echo "=== Step 2: Configuring ZFS delegation ==="

# Stop jail to configure ZFS properties
echo "Stopping jail for ZFS configuration..."
iocage stop $JAIL_NAME 2>/dev/null || true

# Create dataset if it doesn't exist
if ! zfs list $POOL/$DATASET_NAME >/dev/null 2>&1; then
    echo "Creating dataset $POOL/$DATASET_NAME..."
    zfs create $POOL/$DATASET_NAME
fi

# Set jail properties for ZFS (must be stopped)
iocage set allow_mount=1 $JAIL_NAME
iocage set allow_mount_zfs=1 $JAIL_NAME
iocage set enforce_statfs=1 $JAIL_NAME

# Delegate ZFS permissions
zfs allow -ldu root create,destroy,mount,snapshot,rollback,hold,release,send,receive $POOL/$DATASET_NAME

# Enable jail ZFS (must be stopped)
# Note: jail_zfs_dataset is relative to the pool, not full path
iocage set jail_zfs=on $JAIL_NAME
iocage set jail_zfs_dataset=$DATASET_NAME $JAIL_NAME

# Step 3: Start jail
echo ""
echo "=== Step 3: Starting jail ==="
iocage start $JAIL_NAME

# Wait for jail to get IP
echo "Waiting for DHCP..."
sleep 5

# Get jail IP
JAIL_IP=$(iocage exec $JAIL_NAME "ifconfig epair0b 2>/dev/null | grep 'inet ' | awk '{print \$2}'" || echo "")
if [ -z "$JAIL_IP" ]; then
    JAIL_IP=$(iocage exec $JAIL_NAME "ifconfig | grep 'inet ' | grep -v 127.0.0.1 | head -1 | awk '{print \$2}'" || echo "unknown")
fi
echo "Jail IP: $JAIL_IP"

# Step 4: Install packages
echo ""
echo "=== Step 4: Installing Erlang/Elixir ==="
iocage exec $JAIL_NAME "pkg update -q"
iocage exec $JAIL_NAME "pkg install -qy erlang elixir git ca_root_nss"

# Step 5: Copy Zed project
echo ""
echo "=== Step 5: Deploying Zed ==="
JAIL_ROOT="/mnt/$POOL/iocage/jails/$JAIL_NAME/root"

if [ -d "$ZED_REPO" ]; then
    echo "Copying from $ZED_REPO..."
    cp -r "$ZED_REPO" "$JAIL_ROOT/root/zed"
else
    echo "Warning: Zed repo not found at $ZED_REPO"
    echo "You'll need to manually clone or copy the zed project"
fi

# Step 6: Compile Zed in jail
echo ""
echo "=== Step 6: Compiling Zed ==="
iocage exec $JAIL_NAME "cd /root/zed && mix local.hex --force && mix local.rebar --force"
iocage exec $JAIL_NAME "cd /root/zed && mix deps.get"
iocage exec $JAIL_NAME "cd /root/zed && mix compile"

# Step 7: Setup hosts file
echo ""
echo "=== Step 7: Configuring /etc/hosts ==="

# Add jail to host's /etc/hosts
if ! grep -q "$JAIL_NAME" /etc/hosts; then
    echo "$JAIL_IP $JAIL_NAME" >> /etc/hosts
    echo "Added $JAIL_NAME to /etc/hosts"
fi

# Add controller (plausible) to jail's /etc/hosts
PLAUSIBLE_IP=$(iocage exec plausible "ifconfig | grep 'inet ' | grep -v 127.0.0.1 | head -1 | awk '{print \$2}'" 2>/dev/null || echo "")
if [ -n "$PLAUSIBLE_IP" ]; then
    iocage exec $JAIL_NAME "echo '$PLAUSIBLE_IP plausible' >> /etc/hosts"
    echo "Added plausible ($PLAUSIBLE_IP) to jail's /etc/hosts"
fi

# Step 8: Create startup script
echo ""
echo "=== Step 8: Creating startup script ==="
cat > "$JAIL_ROOT/root/start-zed-agent.sh" << EOF
#!/bin/sh
cd /root/zed
iex --name zed@$JAIL_NAME --cookie $COOKIE -S mix -e "Zed.Agent.start_link()"
EOF
chmod +x "$JAIL_ROOT/root/start-zed-agent.sh"

# Done
echo ""
echo "=========================================="
echo "=== Setup Complete ==="
echo "=========================================="
echo ""
echo "Jail:     $JAIL_NAME"
echo "IP:       $JAIL_IP"
echo "Dataset:  $POOL/$DATASET_NAME"
echo "Cookie:   $COOKIE"
echo ""
echo "To start the Zed agent:"
echo "  iocage console $JAIL_NAME"
echo "  /root/start-zed-agent.sh"
echo ""
echo "Or manually:"
echo "  iocage exec $JAIL_NAME 'cd /root/zed && iex --name zed@$JAIL_NAME --cookie $COOKIE -S mix'"
echo ""
echo "From controller (plausible), connect with:"
echo "  Zed.Cluster.connect(:\"zed@$JAIL_NAME\")"
echo ""
