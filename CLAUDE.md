# GR XCOM Wildcard Bind Bug Reproduction Lab

## What This Is

A self-contained Docker lab reproducing MySQL Group Replication
Oracle Bug [#110591](https://bugs.mysql.com/bug.php?id=110591) /
[#110773](https://bugs.mysql.com/bug.php?id=110773).

XCOM always binds to the wildcard address (`:::33061` or
`0.0.0.0:33061`), ignoring the hostname from
`group_replication_local_address`. This prevents running multiple
GR instances on the same host with the same GR port on different
network interfaces.

## Architecture

```
Container: gr-bind-lab (percona/percona-server:8.4)
  eth0: 172.30.1.10/24 (net-alpha)
  eth1: 172.30.2.10/24 (net-beta)

  mysqld-a: bind=172.30.1.10:3306, gr_local=172.30.1.10:33061
  mysqld-b: bind=172.30.2.10:3307, gr_local=172.30.2.10:33061
```

Both instances use the same GR port 33061 on different IPs.
Supervisord manages both mysqld processes inside a single
privileged container attached to two Docker bridge networks.

## Key Paths

| What | Path |
|------|------|
| Automation | `Justfile` |
| Docker image | `docker/Dockerfile` |
| Patched build | `docker/Dockerfile.patched` |
| Source patch | `patches/xcom-bind-hostname.patch` |
| Compose topology | `docker/docker-compose.yml` |
| Container init | `docker/entrypoint.sh` |
| MySQL configs | `config/base.cnf`, `instance-{a,b}.cnf` |
| Test env files | `config/test{1..7}-*.env` |
| Helper scripts | `scripts/` |
| Test evidence | `evidence/<test-name>/` (gitignored) |
| Source clone | `source/` (gitignored, sparse clone) |

## Commands

```bash
just build              # Build custom Docker image
just build-patched      # Build patched image from source (compiles fix)
just test1              # Bug reproduction (EADDRINUSE)
just test4              # Control test (different ports)
just test5              # Workaround (force_bind LD_PRELOAD)
just test7              # Patched source build (before/after experiment)
just summary            # Compare test results
just shell              # Open container shell
just clone-source       # Sparse clone percona-server source
just show-bug           # Show the nullptr in announce_tcp
```

## Test Matrix

| # | Test | Expected Outcome |
|---|------|------------------|
| 1 | Baseline | Instance B fails EADDRINUSE |
| 2 | IPv6 disabled | Same failure (IPv6 not the cause) |
| 3 | MYSQL comm stack | No XCOM port, SQL binds specific IPs (validated) |
| 4 | Different ports | Both succeed (control) |
| 5 | force_bind LD_PRELOAD | Both succeed on same port |
| 6 | Network namespaces | Both ONLINE, wildcard per netns (validated) |
| 7 | Patched source build | Both succeed, specific IP bind (patch validated) |

## Root Cause

The hostname is correctly parsed from `group_replication_local_address`
at step 5a (`Gcs_xcom_node_address::get_ip_and_port()`), but
discarded at step 6 because `Network_configuration_parameters` has
no hostname field:

```
gcs_xcom_control_interface.cc:1885
  Network_configuration_parameters params;
  params.port = xcom_node_address->get_member_port();
  // hostname is NOT set (struct has no field for it)
```

Downstream at `xcom_network_provider_native_lib.cc:89`:

```
checked_getaddrinfo_port(nullptr, port, &hints, &address_info);
//                       ^^^^^^^ = wildcard bind
```

## Documentation

| Document | Purpose |
|----------|---------|
| `README.md` | Overview and quick start |
| `INVESTIGATION-REPORT.md` | Full 16-step call chain analysis |
| `PATCH-PROPOSAL.md` | Formal 6-file upstream fix |
| `CUSTOMER-GUIDANCE.md` | Actionable workaround steps |
| `FORCE-BIND-GUIDE.md` | LD_PRELOAD technical deep-dive |
| `PROGRESS.md` | Test execution tracking |
