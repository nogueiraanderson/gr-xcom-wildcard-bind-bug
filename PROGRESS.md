# GR XCOM Wildcard Bind: Progress Tracker

## Test Matrix

| # | Test | Status | Date | Key Finding |
|---|------|--------|------|-------------|
| 1 | baseline-bug-repro | DONE | 2026-02-13 | `*:33061` wildcard, B gets EADDRINUSE |
| 2 | xcom-no-ipv6 | DONE | 2026-02-13 | Same failure with IPv6 off |
| 3 | mysql-comm-stack | DONE | 2026-02-14 | No XCOM port, SQL port binds to specific IP; GR fails (needs SSL) |
| 4 | different-ports-control | DONE | 2026-02-13 | Both ONLINE, still wildcard |
| 5 | force-bind-workaround | DONE | 2026-02-13 | Both ONLINE, same port, specific IPs |
| 6 | netns-isolation | DONE | 2026-02-14 | Both ONLINE, wildcard bind in separate namespaces, no conflict |
| 7 | patched-source-build | DONE | 2026-02-13 | Patch validated: specific IP bind, both ONLINE |

Evidence paths: `evidence/<test-name>/`

## Source Analysis Checklist

| Step | Status | Notes |
|------|--------|-------|
| Clone source | DONE | Sparse clone release-8.4.3-3 |
| Trace `announce_tcp()` chain | DONE | 16-step call chain documented |
| Identify nullptr hostname | DONE | `native_lib.cc:89` passes NULL |
| Map `getaddrinfo(NULL)` | DONE | NULL + AI_PASSIVE = wildcard |
| Where hostname is lost | DONE | `gcs_xcom_control_interface.cc:1885` |
| Patch feasibility | DONE | LOW risk, 6 files, backward compat |
| Document in report | DONE | Full chain in investigation report |
| Build patched source | DONE | Compiled from Percona-Server-8.4.7-7 with 6 file fix |
| Validate patch | DONE | Before/after: wildcard to specific IP, both ONLINE |

## Evidence Index

Evidence is collected per test into `evidence/<test-name>/` directories.

| File | Contents |
|------|----------|
| `ss-33061.txt` | Socket state for GR port |
| `ss-all.txt` | All listening sockets |
| `netstat.txt` | Network connections |
| `gr-status-a.txt` | GR member status from instance A |
| `gr-status-b.txt` | GR member status from instance B |
| `error-a.log` | MySQL error log for instance A |
| `error-b.log` | MySQL error log for instance B |
| `variables-a.txt` | GR related variables from instance A |
| `variables-b.txt` | GR related variables from instance B |
| `strace-bind.txt` | bind() syscall traces (if captured) |
| `full-evidence.txt` | Combined evidence dump (test5) |

## Key Results

**Bug confirmed**: XCOM always binds to wildcard regardless of
`group_replication_local_address`.

**Root cause identified**: `Network_configuration_parameters` struct has
no hostname field. At `gcs_xcom_control_interface.cc:1885`, only
`params.port` is set. Downstream, `init_server_addr()` passes `nullptr`
to `getaddrinfo()`, which returns wildcard.

**Workaround proven**: LD_PRELOAD `force_bind.so` intercepts `bind()`
and redirects wildcard to the configured IP. Both instances run ONLINE
on the same port with specific IP binding.

**Patch feasibility**: LOW risk, 6 files. Add hostname to
`Network_configuration_parameters`, thread it through
`Xcom_network_provider` to `announce_tcp()` and `init_server_addr()`.
Fully backward compatible (empty hostname = current wildcard behavior).

**Patch validated (Test 7)**: Built `group_replication.so` from
Percona Server 8.4.7 source with the 6 file patch applied. Self-contained
before/after experiment confirms: stock image shows wildcard bind and
EADDRINUSE, patched image shows specific IP binding (172.30.1.10:33061,
172.30.2.10:33061) with both instances ONLINE. No LD_PRELOAD needed.
