# MySQL GR XCOM Wildcard Bind Bug

**Oracle Bug [#110591](https://bugs.mysql.com/bug.php?id=110591)** (S4, Duplicate) /
**[#110773](https://bugs.mysql.com/bug.php?id=110773)** (S3, Verified).
No fix from Oracle as of February 2026.

`group_replication_local_address = "192.168.1.10:33061"` tells MySQL to bind
to that IP, but XCOM ignores it and binds to `*:33061`. A second instance on
the same host with a different IP fails with `EADDRINUSE`.

This repo reproduces the bug, validates workarounds, and provides a proven
source code fix.

## Test Results

| # | Test | Result | What it proves |
|---|------|--------|----------------|
| 1 | Baseline (same port) | Bug confirmed | `*:33061`, Instance B EADDRINUSE |
| 2 | IPv6 disabled | Bug confirmed | IPv6 is irrelevant |
| 3 | MYSQL comm stack | No XCOM port | Bug structurally impossible with MYSQL stack |
| 4 | Different ports | Both ONLINE | Workaround: unique ports |
| 5 | LD_PRELOAD force_bind | Both ONLINE | Workaround: intercept bind() |
| 6 | Network namespaces | Both ONLINE | Workaround: isolated network stacks |
| 7 | **Patched source build** | **Both ONLINE** | **6-file C++ fix validated** |

Run `just` to see all experiments.

## Fix: 6-File C++ Patch (Validated)

The patch adds a `hostname` field to `Network_configuration_parameters` and
threads it through to `getaddrinfo()`. Compiled and tested against
Percona Server 8.4.7:

```
BEFORE (stock):  LISTEN *:33061       -> Instance B: EADDRINUSE
AFTER (patched): LISTEN 172.30.1.10:33061  -> Both ONLINE
                 LISTEN 172.30.2.10:33061
```

No `LD_PRELOAD`. No workaround. The fix is entirely within `group_replication.so`.

Patch file: [`patches/xcom-bind-hostname.patch`](patches/xcom-bind-hostname.patch)
Full proposal: [PATCH-PROPOSAL.md](PATCH-PROPOSAL.md)

## Workarounds

| Option | Complexity | Notes |
|--------|------------|-------|
| **Different GR ports** | Low | Use unique ports per instance. Zero risk. |
| **LD_PRELOAD force_bind** | Medium | Intercept bind() to force specific IPs. [Guide](FORCE-BIND-GUIDE.md) |
| **Network namespaces** | High | Full socket isolation via `ip netns`. Validated in test 6. |

See [CUSTOMER-GUIDANCE.md](CUSTOMER-GUIDANCE.md) for step-by-step instructions.

## Quick Start

**Prerequisites**: Docker, Docker Compose, [just](https://github.com/casey/just)

```bash
just build                # Build test image
just test1                # Reproduce the bug
just test5                # Prove the LD_PRELOAD workaround
just build-patched        # Build patched group_replication.so from source
just test7                # Before/after patch validation
just summary              # Compare all test results
just                      # Show all available experiments
```

## Architecture

Single container, two networks, two mysqld instances via supervisord:

```
Container: gr-bind-lab (percona/percona-server:8.4)
  eth0: 172.30.1.10/24 (net-alpha)
  eth1: 172.30.2.10/24 (net-beta)

  mysqld-a: bind=172.30.1.10:3306, gr_local=172.30.1.10:33061
  mysqld-b: bind=172.30.2.10:3307, gr_local=172.30.2.10:33061
                                                    ^^^^^ same port!
```

## Root Cause

`Network_configuration_parameters` has no hostname field
(`gcs_xcom_control_interface.cc:1885`). Only the port reaches XCOM.
`getaddrinfo(nullptr)` returns the wildcard address.

Full 16-step call chain: [INVESTIGATION-REPORT.md](INVESTIGATION-REPORT.md)

## Project Structure

```
gr-bind-bug/
├── Justfile                    # All automation (just --list)
├── INVESTIGATION-REPORT.md     # Full 16-step call chain analysis
├── PATCH-PROPOSAL.md           # Formal upstream patch proposal
├── CUSTOMER-GUIDANCE.md        # Workaround decision matrix
├── FORCE-BIND-GUIDE.md         # LD_PRELOAD technical deep-dive
├── PROGRESS.md                 # Test execution tracking
├── docker/
│   ├── Dockerfile              # percona-server:8.4 + supervisord
│   ├── Dockerfile.patched      # Multi-stage: patched group_replication.so
│   ├── docker-compose.yml      # Dual-network topology
│   ├── entrypoint.sh           # Multi-phase container init
│   └── supervisord.conf        # Two mysqld instances
├── patches/
│   └── xcom-bind-hostname.patch
├── config/
│   ├── base.cnf, instance-{a,b}.cnf
│   └── test{1..7}-*.env
├── scripts/                    # Build, init, evidence collection
├── evidence/                   # Test outputs (gitignored)
└── source/                     # Percona Server sparse clone (gitignored)
```

## References

- Oracle Bug [#110591](https://bugs.mysql.com/bug.php?id=110591) (S4, Duplicate)
- Oracle Bug [#110773](https://bugs.mysql.com/bug.php?id=110773) (S3, Verified)
- Source: [percona/percona-server](https://github.com/percona/percona-server)
  tags `release-8.4.3-3` (analysis), `Percona-Server-8.4.7-7` (patch build)

## License

This reproduction lab is provided for educational and diagnostic purposes.
MySQL/Percona Server source code is licensed under GPL v2.
