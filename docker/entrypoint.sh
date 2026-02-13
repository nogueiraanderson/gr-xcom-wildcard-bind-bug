#!/bin/bash
set -euo pipefail

echo "=== GR Bind Bug Lab - Entrypoint ==="
echo "Container started at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Fix permissions: base image declares /var/log/mysql as a VOLUME which resets
# ownership to root at runtime. Must chown here, not in Dockerfile.
chown -R mysql:mysql /var/log/mysql /var/run/mysqld /var/lib/mysql-a /var/lib/mysql-b \
    /etc/mysql/conf.d/custom 2>/dev/null || true

# ---------------------------------------------------------------------------
# Phase 1: Wait for both Docker network interfaces to be assigned.
# The container is attached to net-alpha (172.30.1.x) and net-beta (172.30.2.x).
# Docker assigns the second NIC asynchronously, so we must wait.
# ---------------------------------------------------------------------------
echo "[Phase 1] Waiting for network interfaces..."
if [[ -f /opt/scripts/wait-for-interfaces.sh ]]; then
    source /opt/scripts/wait-for-interfaces.sh
else
    echo "WARN: wait-for-interfaces.sh not found, sleeping 5s as fallback"
    sleep 5
fi
echo "[Phase 1] Network interfaces ready."
ip -4 addr show | grep "inet " || true

# ---------------------------------------------------------------------------
# Phase 2: Optionally disable IPv6 (some GR bind bugs are IPv6 related).
# Set TEST_DISABLE_IPV6=1 in the .env file to activate.
# ---------------------------------------------------------------------------
if [[ "${TEST_DISABLE_IPV6:-0}" == "1" ]]; then
    echo "[Phase 2] Disabling IPv6 via sysctl..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
else
    echo "[Phase 2] IPv6 remains enabled."
fi

# ---------------------------------------------------------------------------
# Phase 3: Optionally create network namespaces and move interfaces.
# Used to test GR behavior when interfaces are in separate net namespaces.
# Set TEST_NETNS=1 in the .env file to activate.
# ---------------------------------------------------------------------------
if [[ "${TEST_NETNS:-0}" == "1" ]]; then
    echo "[Phase 3] Creating network namespaces..."
    source /opt/scripts/setup-netns.sh

    # Reconfigure supervisord for netns: run as root (ip netns exec needs it)
    # and inject NETNS_NAME per instance so the wrapper knows which namespace.
    echo "[Phase 3] Patching supervisord.conf for netns execution..."
    sed -i 's/^user=mysql$/user=root/' /etc/supervisord.conf
    sed -i '/INSTANCE_NAME="instance-a"/s|$|,NETNS_NAME="ns-alpha"|' /etc/supervisord.conf
    sed -i '/INSTANCE_NAME="instance-b"/s|$|,NETNS_NAME="ns-beta"|' /etc/supervisord.conf
    echo "[Phase 3] supervisord.conf patched (user=root, NETNS_NAME injected)"
else
    echo "[Phase 3] Network namespace isolation skipped."
fi

# ---------------------------------------------------------------------------
# Phase 4: Initialize MySQL data directories if they don't already exist.
# Uses --initialize-insecure (no root password) for lab simplicity.
# Two separate datadirs: instance-a on port 3306, instance-b on port 3307.
# ---------------------------------------------------------------------------
echo "[Phase 4] Checking MySQL data directories..."

if [[ ! -d /var/lib/mysql-a/mysql ]]; then
    echo "[Phase 4] Initializing instance-a datadir..."
    mysqld --initialize-insecure \
        --user=mysql \
        --datadir=/var/lib/mysql-a \
        --log-error=/var/log/mysql/init-a.log
    echo "[Phase 4] instance-a initialized."
fi

if [[ ! -d /var/lib/mysql-b/mysql ]]; then
    echo "[Phase 4] Initializing instance-b datadir..."
    mysqld --initialize-insecure \
        --user=mysql \
        --datadir=/var/lib/mysql-b \
        --log-error=/var/log/mysql/init-b.log
    echo "[Phase 4] instance-b initialized."
fi

# ---------------------------------------------------------------------------
# Phase 5: Optionally build force_bind.so (LD_PRELOAD library).
# force_bind intercepts bind() syscall to force a specific source address.
# This is used to test whether GR respects the configured bind address.
# Set TEST_FORCE_BIND=1 in the .env file to activate.
# ---------------------------------------------------------------------------
if [[ "${TEST_FORCE_BIND:-0}" == "1" ]]; then
    echo "[Phase 5] Building force_bind.so..."
    if [[ -f /opt/scripts/build-force-bind.sh ]]; then
        bash /opt/scripts/build-force-bind.sh
        echo "[Phase 5] force_bind.so built at /opt/force_bind.so"
    else
        echo "ERROR: build-force-bind.sh not found but TEST_FORCE_BIND=1"
        exit 1
    fi
else
    echo "[Phase 5] force_bind build skipped."
fi

# ---------------------------------------------------------------------------
# Phase 5b: Apply dynamic GR config overrides from environment variables.
# This allows test env files to change GR ports, communication stack, etc.
# without needing separate cnf files for every test variation.
# ---------------------------------------------------------------------------
echo "[Phase 5b] Applying GR config overrides from environment..."

# Copy source configs to writable location (source is mounted :ro)
CNF_DIR="/etc/mysql/conf.d/custom"
mkdir -p "$CNF_DIR"
cp /etc/mysql/conf.d/custom-src/*.cnf "$CNF_DIR/" 2>/dev/null || true
cp /etc/mysql/conf.d/custom-src/*.env "$CNF_DIR/" 2>/dev/null || true

# Override GR port for instance A
if [[ -n "${TEST_GR_PORT_A:-}" && "${TEST_GR_PORT_A}" != "33061" ]]; then
    echo "  Overriding instance A GR port to ${TEST_GR_PORT_A}"
    sed -i "s|172.30.1.10:33061|172.30.1.10:${TEST_GR_PORT_A}|g" "${CNF_DIR}/instance-a.cnf"
fi

# Override GR port for instance B
if [[ -n "${TEST_GR_PORT_B:-}" && "${TEST_GR_PORT_B}" != "33061" ]]; then
    echo "  Overriding instance B GR port to ${TEST_GR_PORT_B}"
    sed -i "s|172.30.2.10:33061|172.30.2.10:${TEST_GR_PORT_B}|g" "${CNF_DIR}/instance-b.cnf"
fi

# Override communication stack (XCOM or MYSQL)
if [[ -n "${TEST_COMM_STACK:-}" && "${TEST_COMM_STACK}" != "XCOM" ]]; then
    echo "  Overriding communication stack to ${TEST_COMM_STACK}"
    sed -i "s|group_replication_communication_stack.*=.*XCOM|group_replication_communication_stack = ${TEST_COMM_STACK}|g" "${CNF_DIR}/base.cnf"
fi

echo "[Phase 5b] Config overrides applied."

# ---------------------------------------------------------------------------
# Phase 6: Start supervisord as PID 1.
# supervisord manages both mysqld instances and handles their lifecycle.
# Using exec replaces this shell so supervisord becomes PID 1 (receives signals).
# ---------------------------------------------------------------------------
echo "[Phase 6] Starting supervisord..."
echo "=== Entrypoint complete, handing off to supervisord ==="

exec /usr/local/bin/supervisord -n -c /etc/supervisord.conf
