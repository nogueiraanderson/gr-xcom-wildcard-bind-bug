# MySQL GR XCOM Wildcard Binding Bug - Reproduction Lab
# Docker commands use standard docker/docker compose

set dotenv-load := false
set shell := ["bash", "-euo", "pipefail", "-c"]

project := justfile_directory()
compose := "docker compose -f " + project + "/docker/docker-compose.yml"
container := "gr-bind-lab"

# Default: show experiments overview and available recipes
default:
    @echo "╔══════════════════════════════════════════════════════════════╗"
    @echo "║  MySQL GR XCOM Wildcard Bind Bug Lab                      ║"
    @echo "║  Oracle Bug #110591 / #110773                              ║"
    @echo "╠══════════════════════════════════════════════════════════════╣"
    @echo "║                                                            ║"
    @echo "║  # │ Experiment                  │ Expected Outcome        ║"
    @echo "║  ──┼─────────────────────────────┼─────────────────────────║"
    @echo "║  1 │ Baseline (XCOM, same port)  │ *:33061, B EADDRINUSE  ║"
    @echo "║  2 │ IPv6 disabled               │ Same failure           ║"
    @echo "║  3 │ MYSQL comm stack            │ No XCOM port opened    ║"
    @echo "║  4 │ Different ports (control)   │ Both ONLINE            ║"
    @echo "║  5 │ LD_PRELOAD force_bind       │ Both ONLINE, same port ║"
    @echo "║  6 │ Network namespaces          │ Both ONLINE (netns)    ║"
    @echo "║  7 │ Patched source build        │ Specific IPs, ONLINE   ║"
    @echo "║                                                            ║"
    @echo "║  Quick start:  just build && just test1                    ║"
    @echo "║  Full patch:   just build-patched && just test7            ║"
    @echo "║                                                            ║"
    @echo "╚══════════════════════════════════════════════════════════════╝"
    @echo ""
    @just --list

# ─── Build & Lifecycle ───────────────────────────────────────────────

# Build the custom Docker image
build *FLAGS:
    {{ compose }} build {{ FLAGS }}

# Build the patched image from source (compiles group_replication.so with fix)
build-patched *FLAGS:
    docker build -f {{ project }}/docker/Dockerfile.patched \
        -t gr-bind-lab:patched {{ FLAGS }} {{ project }}

# Start the container with default test env (test1)
up:
    {{ compose }} up -d
    @echo "Waiting for container to initialize..."
    @sleep 5
    just status

# Start with a specific test env file (1-7)
up-test N:
    TEST_ENV={{ project }}/config/test{{ N }}-*.env {{ compose }} up -d
    @echo "Waiting for container to initialize..."
    @sleep 8
    just status

# Stop and remove container + volumes
down:
    {{ compose }} down -v 2>/dev/null || true

# Full reset: remove everything including datadirs
reset: down
    docker volume rm gr-bind-bug_mysql-a-data gr-bind-bug_mysql-b-data 2>/dev/null || true
    @echo "Reset complete"

# Show container and supervisor status
status:
    {{ compose }} ps
    @echo ""
    @echo "=== Supervisor Status ==="
    docker exec {{ container }} supervisorctl status 2>/dev/null || echo "(container not running)"

# Follow container logs
logs *FLAGS:
    {{ compose }} logs {{ FLAGS }}

# Open a shell inside the container
shell:
    docker exec -it {{ container }} bash

# ─── GR Operations ──────────────────────────────────────────────────

# Set empty root password (after --initialize-insecure)
set-password:
    @echo "Setting password for instance A..."
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-a.sock -u root \
        -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '';" 2>/dev/null || true
    @echo "Setting password for instance B..."
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-b.sock -u root \
        -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '';" 2>/dev/null || true

# Bootstrap Group Replication on instance A
bootstrap-a:
    @echo "Bootstrapping GR on instance A (172.30.1.10)..."
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-a.sock -u root -e " \
        SET GLOBAL group_replication_bootstrap_group=ON; \
        START GROUP_REPLICATION; \
        SET GLOBAL group_replication_bootstrap_group=OFF;"
    @echo "Instance A bootstrap complete"

# Bootstrap Group Replication on instance B
bootstrap-b:
    @echo "Bootstrapping GR on instance B (172.30.2.10)..."
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-b.sock -u root -e " \
        SET GLOBAL group_replication_bootstrap_group=ON; \
        START GROUP_REPLICATION; \
        SET GLOBAL group_replication_bootstrap_group=OFF;"
    @echo "Instance B bootstrap complete"

# Show GR member status for instance A
gr-status-a:
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-a.sock -u root -e \
        "SELECT * FROM performance_schema.replication_group_members\G"

# Show GR member status for instance B
gr-status-b:
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-b.sock -u root -e \
        "SELECT * FROM performance_schema.replication_group_members\G"

# ─── Internal Helpers ────────────────────────────────────────────────

# Wait for a mysqld instance to accept connections
[private]
wait-mysql socket retries="30":
    #!/usr/bin/env bash
    set -euo pipefail
    for i in $(seq 1 {{ retries }}); do
        if docker exec {{ container }} mysql -S {{ socket }} -u root -e "SELECT 1" &>/dev/null; then
            echo "MySQL on {{ socket }} is ready (attempt $i)"
            exit 0
        fi
        sleep 2
    done
    echo "ERROR: MySQL on {{ socket }} did not become ready after {{ retries }} attempts"
    exit 1

# Run a test: teardown, start with env, wait, bootstrap, collect
[private]
run-test N NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  TEST {{ N }}: {{ NAME }}"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    # Teardown previous
    just down
    sleep 2
    # Find the matching env file
    ENV_FILE=$(ls {{ project }}/config/test{{ N }}-*.env 2>/dev/null | head -1)
    if [ -z "$ENV_FILE" ]; then
        echo "ERROR: No env file found for test {{ N }}"
        exit 1
    fi
    echo "Using env file: $ENV_FILE"
    # Start container
    TEST_ENV="$ENV_FILE" {{ compose }} up -d
    echo "Waiting for container initialization..."
    sleep 10
    # Wait for instance A
    echo "Waiting for instance A..."
    just wait-mysql /var/run/mysqld/mysqld-a.sock 45
    # Bootstrap instance A (may fail for some test configs like MYSQL comm stack)
    echo ""
    just bootstrap-a || echo "Instance A bootstrap failed (may be expected for this test)"
    sleep 3
    # Wait for instance B (may fail for some tests, that's expected)
    echo ""
    echo "Waiting for instance B..."
    just wait-mysql /var/run/mysqld/mysqld-b.sock 30 || echo "Instance B not ready (may be expected for this test)"
    # Attempt bootstrap B (may fail, capture the error)
    echo ""
    just bootstrap-b || echo "Instance B bootstrap failed (may be expected)"
    sleep 2
    # Collect evidence
    echo ""
    just collect {{ NAME }}
    echo ""
    echo "Test {{ N }} ({{ NAME }}) complete. Evidence in evidence/{{ NAME }}/"

# ─── Test Matrix ─────────────────────────────────────────────────────

# Test 1: Baseline bug reproduction (XCOM + IPv6 + same port)
test1: (run-test "1" "baseline-bug-repro")

# Test 2: XCOM with IPv6 disabled
test2: (run-test "2" "xcom-no-ipv6")

# Test 3: MYSQL communication stack
test3: (run-test "3" "mysql-comm-stack")

# Test 4: Different GR ports (control test, should work)
test4: (run-test "4" "different-ports-control")

# Test 5: LD_PRELOAD force_bind workaround
test5: (run-test "5" "force-bind-workaround")

# Test 6: Network namespace isolation
test6: (run-test "6" "netns-isolation")

# Test 7: Patched source build (self-contained before/after experiment)
test7:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  TEST 7: PATCHED SOURCE BUILD (BEFORE/AFTER)               ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  Validates the 6 file C++ patch by building                ║"
    echo "║  group_replication.so from Percona Server 8.4 source.      ║"
    echo "║                                                            ║"
    echo "║  Phase A (BEFORE): Stock image, no workarounds.            ║"
    echo "║    Expected: wildcard bind *:33061, Instance B EADDRINUSE  ║"
    echo "║                                                            ║"
    echo "║  Phase B (AFTER): Patched plugin, no workarounds.          ║"
    echo "║    Expected: specific IP bind, both instances ONLINE       ║"
    echo "║                                                            ║"
    echo "║  Phase C: Side by side comparison + PASS/FAIL verdict.     ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    EVIDENCE="{{ project }}/evidence/patched-source"
    ENV_FILE="{{ project }}/config/test7-patched-source.env"

    # Preflight: verify patched image exists
    if ! docker image inspect gr-bind-lab:patched &>/dev/null; then
        echo "ERROR: gr-bind-lab:patched image not found."
        echo "Build it first with: just build-patched"
        exit 1
    fi

    rm -rf "$EVIDENCE"
    mkdir -p "$EVIDENCE/before" "$EVIDENCE/after"

    # ── Phase A: BEFORE (stock image, no workarounds) ──────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Phase A: BEFORE (stock percona-server:8.4, no workarounds)"
    echo ""
    echo "  Image:    docker-gr-bind-lab:latest (unpatched)"
    echo "  Config:   XCOM stack, IPv6 on, both instances on port 33061"
    echo "  Expected: Wildcard bind (*:33061), Instance B fails EADDRINUSE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    just down
    sleep 2
    GR_IMAGE=docker-gr-bind-lab:latest TEST_ENV="$ENV_FILE" {{ compose }} up -d
    echo "Waiting for container initialization..."
    sleep 10
    echo "Waiting for instance A..."
    just wait-mysql /var/run/mysqld/mysqld-a.sock 45
    just bootstrap-a
    sleep 3
    echo "Waiting for instance B..."
    just wait-mysql /var/run/mysqld/mysqld-b.sock 30 || echo "Instance B not ready (expected for stock image)"
    just bootstrap-b || echo "Instance B bootstrap failed (expected: EADDRINUSE)"
    sleep 2

    # Collect BEFORE evidence
    echo ""
    echo "Collecting BEFORE evidence..."
    docker exec {{ container }} bash -c 'ss -tlnp | grep 33061 || echo "No listeners on 33061"' > "$EVIDENCE/before/ss-33061.txt" 2>&1 || true
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-a.sock \
        -e "SELECT * FROM performance_schema.replication_group_members\G" \
        > "$EVIDENCE/before/gr-status-a.txt" 2>&1 || true
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-b.sock \
        -e "SELECT * FROM performance_schema.replication_group_members\G" \
        > "$EVIDENCE/before/gr-status-b.txt" 2>&1 || true
    docker exec {{ container }} bash -c 'cat /var/log/mysql/error-b.log | tail -50' \
        > "$EVIDENCE/before/error-b.log" 2>&1 || true
    docker exec {{ container }} env > "$EVIDENCE/before/env.txt" 2>&1 || true

    echo "BEFORE phase complete."
    just down
    sleep 3

    # ── Phase B: AFTER (patched image, no workarounds) ─────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Phase B: AFTER (patched group_replication.so, no workarounds)"
    echo ""
    echo "  Image:    gr-bind-lab:patched (6 file C++ fix compiled in)"
    echo "  Config:   Same as Phase A (XCOM, IPv6, same port 33061)"
    echo "  Expected: Specific IP bind per instance, both ONLINE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    GR_IMAGE=gr-bind-lab:patched TEST_ENV="$ENV_FILE" {{ compose }} up -d
    echo "Waiting for container initialization..."
    sleep 10
    echo "Waiting for instance A..."
    just wait-mysql /var/run/mysqld/mysqld-a.sock 45
    just bootstrap-a
    sleep 3
    echo "Waiting for instance B..."
    just wait-mysql /var/run/mysqld/mysqld-b.sock 45
    just bootstrap-b
    sleep 5

    # Collect AFTER evidence
    echo ""
    echo "Collecting AFTER evidence..."
    docker exec {{ container }} bash -c 'ss -tlnp | grep 33061 || echo "No listeners on 33061"' > "$EVIDENCE/after/ss-33061.txt" 2>&1 || true
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-a.sock \
        -e "SELECT * FROM performance_schema.replication_group_members\G" \
        > "$EVIDENCE/after/gr-status-a.txt" 2>&1 || true
    docker exec {{ container }} mysql -S /var/run/mysqld/mysqld-b.sock \
        -e "SELECT * FROM performance_schema.replication_group_members\G" \
        > "$EVIDENCE/after/gr-status-b.txt" 2>&1 || true
    docker exec {{ container }} bash -c 'cat /var/log/mysql/error-b.log | tail -50' \
        > "$EVIDENCE/after/error-b.log" 2>&1 || true
    docker exec {{ container }} env > "$EVIDENCE/after/env.txt" 2>&1 || true

    echo "AFTER phase complete."

    # ── Phase C: COMPARISON ────────────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Phase C: COMPARISON"
    echo ""
    echo "  Comparing BEFORE vs AFTER evidence side by side."
    echo "  Pass criteria: wildcard in BEFORE, specific IPs in AFTER,"
    echo "  both instances ONLINE, no bind errors, no LD_PRELOAD."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    {
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  TEST 7: PATCHED SOURCE BUILD COMPARISON                   ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo ""
        echo "=== XCOM Port 33061 Binding ==="
        echo ""
        echo "BEFORE (stock percona-server:8.4):"
        cat "$EVIDENCE/before/ss-33061.txt"
        echo ""
        echo "AFTER (patched group_replication.so):"
        cat "$EVIDENCE/after/ss-33061.txt"
        echo ""
        echo "=== GR Member Status (Instance A view) ==="
        echo ""
        echo "BEFORE:"
        grep -E "MEMBER_STATE|MEMBER_HOST|MEMBER_PORT" "$EVIDENCE/before/gr-status-a.txt" 2>/dev/null || echo "(no data)"
        echo ""
        echo "AFTER:"
        grep -E "MEMBER_STATE|MEMBER_HOST|MEMBER_PORT" "$EVIDENCE/after/gr-status-a.txt" 2>/dev/null || echo "(no data)"
        echo ""
        echo "=== Instance B Error Log (key lines) ==="
        echo ""
        echo "BEFORE:"
        grep -iE "EADDRINUSE|Address already in use|bind.*fail|Unable to announce" "$EVIDENCE/before/error-b.log" 2>/dev/null || echo "(no bind errors)"
        echo ""
        echo "AFTER:"
        grep -iE "EADDRINUSE|Address already in use|bind.*fail|Unable to announce" "$EVIDENCE/after/error-b.log" 2>/dev/null || echo "(no bind errors)"
        echo ""
        echo "=== LD_PRELOAD Check ==="
        echo ""
        echo "BEFORE:"
        grep -E "LD_PRELOAD|FORCE_BIND" "$EVIDENCE/before/env.txt" 2>/dev/null || echo "  No LD_PRELOAD or FORCE_BIND_ADDRESS (clean)"
        echo ""
        echo "AFTER:"
        grep -E "LD_PRELOAD|FORCE_BIND" "$EVIDENCE/after/env.txt" 2>/dev/null || echo "  No LD_PRELOAD or FORCE_BIND_ADDRESS (clean)"
        echo ""
        echo "=== VERDICT ==="
        echo ""

        # Determine pass/fail
        BEFORE_WILDCARD=false
        AFTER_SPECIFIC=false
        AFTER_ONLINE=false
        AFTER_NO_ERRORS=false

        if grep -q '\*:33061\|:::33061\|0\.0\.0\.0:33061' "$EVIDENCE/before/ss-33061.txt" 2>/dev/null || \
           grep -q 'Unable to announce' "$EVIDENCE/before/error-b.log" 2>/dev/null; then
            BEFORE_WILDCARD=true
        fi
        if grep -q '172\.30\.1\.10:33061' "$EVIDENCE/after/ss-33061.txt" 2>/dev/null && \
           grep -q '172\.30\.2\.10:33061' "$EVIDENCE/after/ss-33061.txt" 2>/dev/null && \
           ! grep -q '\*:33061\|:::33061\|0\.0\.0\.0:33061' "$EVIDENCE/after/ss-33061.txt" 2>/dev/null; then
            AFTER_SPECIFIC=true
        fi
        if grep -q 'ONLINE' "$EVIDENCE/after/gr-status-a.txt" 2>/dev/null && \
           grep -q 'ONLINE' "$EVIDENCE/after/gr-status-b.txt" 2>/dev/null; then
            AFTER_ONLINE=true
        fi
        if ! grep -qiE 'EADDRINUSE|Address already in use|Unable to announce' "$EVIDENCE/after/error-b.log" 2>/dev/null; then
            AFTER_NO_ERRORS=true
        fi

        GREEN=$'\033[1;32m'
        RED=$'\033[1;31m'
        RESET=$'\033[0m'

        if $BEFORE_WILDCARD && $AFTER_SPECIFIC && $AFTER_ONLINE && $AFTER_NO_ERRORS; then
            echo "  ┌────────────────────────────────────────────────────────┐"
            echo "  │  ${GREEN}PASS${RESET}                                                 │"
            echo "  └────────────────────────────────────────────────────────┘"
            echo ""
            echo "  BEFORE: Wildcard bind (*:33061), Instance B EADDRINUSE"
            echo "  AFTER:  Specific IP bind, both instances ONLINE, no errors"
            echo ""
            echo "  The 6 file C++ patch fixes the bug. No LD_PRELOAD needed."
        else
            echo "  ┌────────────────────────────────────────────────────────┐"
            echo "  │  ${RED}FAIL${RESET}                                                 │"
            echo "  └────────────────────────────────────────────────────────┘"
            echo ""
            echo "  before_wildcard=$BEFORE_WILDCARD"
            echo "  after_specific=$AFTER_SPECIFIC"
            echo "  after_online=$AFTER_ONLINE"
            echo "  after_no_errors=$AFTER_NO_ERRORS"
        fi

        echo ""
        echo "╚══════════════════════════════════════════════════════════════╝"
    } | tee "$EVIDENCE/comparison.txt"

    echo ""
    echo "Test 7 complete. Evidence in evidence/patched-source/"

# Run all standard tests sequentially (test 7 is separate, requires patched image)
test-all: test1 test2 test3 test4 test5 test6
    @echo ""
    @echo "Tests 1-6 complete. Run 'just test7' for patch validation."
    @echo "Run 'just summary' for results."

# ─── Evidence ────────────────────────────────────────────────────────

# Collect evidence from running container
collect NAME:
    @echo "Collecting evidence for '{{ NAME }}'..."
    docker exec {{ container }} bash /opt/scripts/collect-evidence.sh {{ NAME }}
    @echo "Copying evidence from container to local..."
    rm -rf {{ project }}/evidence/{{ NAME }}
    docker cp {{ container }}:/opt/evidence/{{ NAME }} {{ project }}/evidence/{{ NAME }}
    @echo "Evidence saved to evidence/{{ NAME }}/"

# Trace bind() syscalls on mysqld processes
strace-bind:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Attaching strace to mysqld processes inside container..."
    # Get mysqld PIDs
    PIDS=$(docker exec {{ container }} pgrep mysqld | tr '\n' ' ')
    if [ -z "$PIDS" ]; then
        echo "No mysqld processes found"
        exit 1
    fi
    echo "Found mysqld PIDs: $PIDS"
    for PID in $PIDS; do
        echo ""
        echo "=== Strace for PID $PID ==="
        docker exec {{ container }} timeout 5 strace -p "$PID" -e trace=bind 2>&1 || true
    done

# Print summary comparison across all test evidence
summary:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          GR XCOM WILDCARD BIND: TEST SUMMARY               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    printf "%-30s %-20s %-20s\n" "TEST" "GR PORT BINDING" "INSTANCE B"
    printf "%-30s %-20s %-20s\n" "----" "---------------" "----------"
    for dir in {{ project }}/evidence/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")

        # Handle patched-source nested evidence (has before/after subdirs)
        if [ "$name" = "patched-source" ]; then
            before_bind="(no data)"
            after_bind="(no data)"
            if [ -f "$dir/before/ss-33061.txt" ]; then
                before_bind=$(head -2 "$dir/before/ss-33061.txt" | tail -1 | awk '{print $4}' 2>/dev/null || echo "?")
            fi
            if [ -f "$dir/after/ss-33061.txt" ]; then
                after_bind=$(head -2 "$dir/after/ss-33061.txt" | tail -1 | awk '{print $4}' 2>/dev/null || echo "?")
            fi
            after_status="(no data)"
            if [ -f "$dir/after/error-b.log" ]; then
                if grep -qiE "EADDRINUSE|Address already in use|Unable to announce|bind.*fail" "$dir/after/error-b.log" 2>/dev/null; then
                    after_status="EADDRINUSE"
                else
                    after_status="OK (patched)"
                fi
            fi
            printf "%-30s %-20s %-20s\n" "$name (before)" "$before_bind" "EADDRINUSE"
            printf "%-30s %-20s %-20s\n" "$name (after)" "$after_bind" "$after_status"
            continue
        fi

        # Check what port 33061 is bound to
        binding="(no data)"
        if [ -f "$dir/ss-33061.txt" ]; then
            binding=$(head -2 "$dir/ss-33061.txt" | tail -1 | awk '{print $4}' 2>/dev/null || echo "(parse error)")
        fi
        # Check instance B status
        b_status="(no data)"
        if [ -f "$dir/error-b.log" ]; then
            if grep -qiE "EADDRINUSE|Address already in use|Unable to announce|bind.*fail" "$dir/error-b.log" 2>/dev/null; then
                b_status="EADDRINUSE"
            elif grep -q "ready for connections\|ONLINE" "$dir/error-b.log" 2>/dev/null; then
                b_status="OK"
            else
                b_status="ERROR (other)"
            fi
        fi
        printf "%-30s %-20s %-20s\n" "$name" "$binding" "$b_status"
    done
    echo ""

# ─── Source Code Analysis ────────────────────────────────────────────

# Sparse clone Percona Server source for GR plugin analysis
clone-source:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ project }}/source
    if [ -d ".git" ]; then
        echo "Source already cloned. Use 'git pull' to update."
        exit 0
    fi
    echo "Sparse cloning percona/percona-server (release-8.4.3-3)..."
    git clone --filter=blob:none --sparse \
        https://github.com/percona/percona-server.git . \
        --branch release-8.4.3-3 --depth 1
    git sparse-checkout set \
        plugin/group_replication/libmysqlgcs/src/bindings/xcom/xcom/network/ \
        plugin/group_replication/libmysqlgcs/src/bindings/xcom/xcom/xcom_transport.cc \
        plugin/group_replication/libmysqlgcs/src/bindings/xcom/xcom/xcom_transport.h \
        plugin/group_replication/libmysqlgcs/src/bindings/xcom/xcom/xcom_base.cc \
        plugin/group_replication/libmysqlgcs/include/ \
        plugin/group_replication/src/gcs_operations.cc
    echo "Sparse clone complete. Key files:"
    find . -name "*.cc" -o -name "*.h" | head -20

# Show the bug: nullptr hostname in announce_tcp
show-bug:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{ project }}/source"
    if [ ! -d "$SRC/.git" ]; then
        echo "Source not cloned yet. Run 'just clone-source' first."
        exit 1
    fi
    echo "=== The Bug: nullptr hostname passed to init_server_addr ==="
    echo ""
    echo "In xcom_network_provider_native_lib.cc, announce_tcp():"
    grep -n -A5 -B5 "init_server_addr\|announce_tcp\|nullptr.*host\|getaddrinfo.*NULL" \
        "$SRC"/plugin/group_replication/libmysqlgcs/src/bindings/xcom/xcom/network/*.cc \
        2>/dev/null || echo "(file not found, run 'just clone-source' first)"
    echo ""
    echo "=== How group_replication_local_address is parsed ==="
    grep -n -B3 -A3 "local_address\|local_node\|port.*extract\|host.*extract" \
        "$SRC"/plugin/group_replication/libmysqlgcs/src/bindings/xcom/xcom/xcom_transport.cc \
        2>/dev/null || echo "(file not found)"

# ─── Cleanup ─────────────────────────────────────────────────────────

# Remove all evidence directories (keep .gitkeep)
clean-evidence:
    rm -rf {{ project }}/evidence/*/
    @echo "Evidence cleaned"

# Full cleanup: container + evidence + images
clean: down clean-evidence
    docker rmi gr-bind-bug-lab 2>/dev/null || true
    @echo "Full cleanup complete"
