#!/bin/bash
set -euo pipefail

# mysqld-wrapper.sh - Wraps mysqld invocation for supervisord
# Handles LD_PRELOAD injection for force_bind test (test5) and
# network namespace execution for netns isolation test (test6).
# Called by supervisord with instance name as argument.
#
# Environment (set by supervisord program.environment):
#   INSTANCE_DEFAULTS  - path to --defaults-file cnf
#   FORCE_BIND_ADDRESS - IP to force for bind() (only used when TEST_FORCE_BIND=1)
#   NETNS_NAME         - network namespace name (only used when TEST_NETNS=1)

INSTANCE="${1:-unknown}"
DEFAULTS="${INSTANCE_DEFAULTS:-/etc/mysql/conf.d/custom/instance-a.cnf}"

echo "[mysqld-wrapper] Starting ${INSTANCE} with defaults: ${DEFAULTS}"

if [[ "${TEST_FORCE_BIND:-0}" == "1" && -f /opt/force_bind.so ]]; then
    ADDR="${FORCE_BIND_ADDRESS:-}"
    if [[ -n "$ADDR" ]]; then
        echo "[mysqld-wrapper] Injecting LD_PRELOAD for ${INSTANCE} (bind to ${ADDR})"
        export LD_PRELOAD=/opt/force_bind.so
        export FORCE_BIND_ADDRESS="$ADDR"
    fi
fi

# Network namespace mode: run mysqld inside the assigned namespace.
# Requires root (supervisord user=root when TEST_NETNS=1).
# mysqld drops privileges via --user=mysql.
if [[ -n "${NETNS_NAME:-}" ]]; then
    echo "[mysqld-wrapper] Running ${INSTANCE} in network namespace: ${NETNS_NAME}"
    exec ip netns exec "$NETNS_NAME" mysqld --defaults-file="$DEFAULTS" --user=mysql
fi

exec mysqld --defaults-file="$DEFAULTS"
