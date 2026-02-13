#!/bin/bash
set -euo pipefail

# setup-netns.sh - Create network namespaces for test6 (netns isolation)
# Moves each network interface into its own namespace so the two mysqld
# instances have completely isolated network stacks. This is the "nuclear"
# workaround: each instance only sees its own IP.
#
# This script is sourced by entrypoint.sh when TEST_NETNS=1.

log() { echo "[$(date '+%H:%M:%S')] [netns] $*"; }

log "Creating network namespaces ns-alpha and ns-beta..."

# Identify interfaces by their subnet
IFACE_ALPHA=$(ip -o addr show | grep '172\.30\.1\.' | awk '{print $2}')
IFACE_BETA=$(ip -o addr show | grep '172\.30\.2\.' | awk '{print $2}')

if [[ -z "$IFACE_ALPHA" || -z "$IFACE_BETA" ]]; then
    log "ERROR: Could not identify interfaces"
    log "  Alpha (172.30.1.x): ${IFACE_ALPHA:-not found}"
    log "  Beta  (172.30.2.x): ${IFACE_BETA:-not found}"
    ip addr show
    return 1
fi

log "Found interfaces: alpha=${IFACE_ALPHA}, beta=${IFACE_BETA}"

# Create namespaces
ip netns add ns-alpha
ip netns add ns-beta

# Move interfaces into their namespaces
ip link set "$IFACE_ALPHA" netns ns-alpha
ip link set "$IFACE_BETA" netns ns-beta

# Bring up interfaces inside namespaces
ip netns exec ns-alpha ip addr add 172.30.1.10/24 dev "$IFACE_ALPHA"
ip netns exec ns-alpha ip link set "$IFACE_ALPHA" up
ip netns exec ns-alpha ip link set lo up

ip netns exec ns-beta ip addr add 172.30.2.10/24 dev "$IFACE_BETA"
ip netns exec ns-beta ip link set "$IFACE_BETA" up
ip netns exec ns-beta ip link set lo up

# Add default routes via Docker bridge gateways for inter-namespace connectivity
ip netns exec ns-alpha ip route add default via 172.30.1.1 2>/dev/null || true
ip netns exec ns-beta ip route add default via 172.30.2.1 2>/dev/null || true

log "Network namespaces ready"
log "  ns-alpha: $(ip netns exec ns-alpha ip -4 addr show | grep inet)"
log "  ns-beta:  $(ip netns exec ns-beta ip -4 addr show | grep inet)"

# Export a flag so supervisord knows to use ip netns exec
export NETNS_READY=1
