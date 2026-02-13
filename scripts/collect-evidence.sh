#!/bin/bash
set -euo pipefail

# collect-evidence.sh - Capture diagnostic evidence from inside the container
# Usage: collect-evidence.sh <test-name>
# Outputs to /opt/evidence/<test-name>/

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <test-name>"
    exit 1
fi

TEST_NAME="$1"
EVIDENCE_DIR="/opt/evidence/${TEST_NAME}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Collecting evidence for test: ${TEST_NAME}"
mkdir -p "$EVIDENCE_DIR"

# Helper: run a command, save output, don't fail if it errors
capture() {
    local file="$1"
    shift
    log "  Capturing: $file"
    "$@" > "${EVIDENCE_DIR}/${file}" 2>&1 || true
}

# Socket / port information
# In netns mode, sockets live inside each namespace, not the root namespace.
if [[ "${TEST_NETNS:-0}" == "1" ]]; then
    capture "ss-all.txt" bash -c '
        echo "=== ns-alpha ===" && ip netns exec ns-alpha ss -tlnp 2>/dev/null;
        echo ""; echo "=== ns-beta ===" && ip netns exec ns-beta ss -tlnp 2>/dev/null;
        echo ""; echo "=== root namespace ===" && ss -tlnp'
    capture "ss-33061.txt" bash -c '
        echo "=== ns-alpha ===" && ip netns exec ns-alpha ss -tlnp 2>/dev/null | grep 33061;
        echo "=== ns-beta ===" && ip netns exec ns-beta ss -tlnp 2>/dev/null | grep 33061;
        echo "=== root namespace ===" && (ss -tlnp | grep 33061 || echo "No listeners on 33061 in root ns")'
    capture "netns-routing.txt" bash -c '
        echo "=== ns-alpha routes ===" && ip netns exec ns-alpha ip route;
        echo ""; echo "=== ns-beta routes ===" && ip netns exec ns-beta ip route;
        echo ""; echo "=== ns-alpha addrs ===" && ip netns exec ns-alpha ip -4 addr show;
        echo ""; echo "=== ns-beta addrs ===" && ip netns exec ns-beta ip -4 addr show'
else
    capture "ss-all.txt"   ss -tlnp
    capture "ss-33061.txt" bash -c 'ss -tlnp | grep 33061 || echo "No listeners on 33061"'
fi

# MySQL error logs
capture "error-a.log" cat /var/log/mysql/error-a.log
capture "error-b.log" cat /var/log/mysql/error-b.log

# Group Replication member status
capture "gr-status-a.txt" \
    mysql -S /var/run/mysqld/mysqld-a.sock \
    -e "SELECT * FROM performance_schema.replication_group_members\G"

capture "gr-status-b.txt" \
    mysql -S /var/run/mysqld/mysqld-b.sock \
    -e "SELECT * FROM performance_schema.replication_group_members\G"

# Network state
capture "ip-addr.txt"     ip addr show
capture "ipv6-sysctl.txt" sysctl net.ipv6.conf.all.disable_ipv6
capture "tcp6-33061.txt"  bash -c 'cat /proc/net/tcp6 | grep -i 8135 || echo "No tcp6 entries for port 33061 (0x8135)"'

# Environment and process info
capture "env.txt"         env
capture "ps.txt"          ps auxf

log "Evidence saved to ${EVIDENCE_DIR}/"
ls -la "$EVIDENCE_DIR/"
