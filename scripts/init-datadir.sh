#!/bin/bash
set -euo pipefail

# init-datadir.sh - Initialize MySQL data directories for instances A and B
# Creates datadirs, log dirs, and runs mysqld --initialize-insecure if needed.

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Directories needed by both instances
log "Creating shared directories..."
mkdir -p /var/run/mysqld /var/log/mysql
chown -R mysql:mysql /var/run/mysqld /var/log/mysql

for instance in a b; do
    DATADIR="/var/lib/mysql-${instance}"
    log "Checking instance ${instance} (datadir: ${DATADIR})"

    if [[ -f "${DATADIR}/ibdata1" ]]; then
        log "  Instance ${instance}: datadir already initialized, skipping"
        continue
    fi

    log "  Initializing datadir for instance ${instance}..."
    mkdir -p "$DATADIR"
    chown mysql:mysql "$DATADIR"

    mysqld \
        --initialize-insecure \
        --datadir="$DATADIR" \
        --user=mysql \
        2>&1 | while IFS= read -r line; do
            log "  [init-${instance}] $line"
        done

    if [[ -f "${DATADIR}/ibdata1" ]]; then
        log "  Instance ${instance}: initialization complete"
    else
        log "  ERROR: Instance ${instance}: ibdata1 not found after init"
        exit 1
    fi
done

log "All data directories ready"
