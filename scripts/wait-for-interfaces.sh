#!/bin/bash
set -euo pipefail

# wait-for-interfaces.sh - Poll until both Docker network interfaces are available
# Used inside the container to ensure networking is ready before starting MySQL instances.

TIMEOUT=30
INTERVAL=1
elapsed=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Waiting for network interfaces (timeout: ${TIMEOUT}s)..."

while true; do
    ip1=$(ip addr show | grep -oP '172\.30\.1\.\d+' | head -1 || true)
    ip2=$(ip addr show | grep -oP '172\.30\.2\.\d+' | head -1 || true)

    if [[ -n "$ip1" && -n "$ip2" ]]; then
        log "Found interfaces:"
        log "  Network 1: $ip1"
        log "  Network 2: $ip2"
        echo "$ip1" > /tmp/ip_net1
        echo "$ip2" > /tmp/ip_net2
        # Use return (not exit) because this script is sourced by entrypoint.sh
        return 0
    fi

    if (( elapsed >= TIMEOUT )); then
        log "ERROR: Timed out after ${TIMEOUT}s waiting for interfaces"
        log "  Network 1 (172.30.1.x): ${ip1:-NOT FOUND}"
        log "  Network 2 (172.30.2.x): ${ip2:-NOT FOUND}"
        ip addr show >&2
        return 1
    fi

    sleep "$INTERVAL"
    (( elapsed += INTERVAL ))
done
