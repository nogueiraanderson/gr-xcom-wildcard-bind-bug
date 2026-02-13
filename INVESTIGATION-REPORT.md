# Oracle Bug #110591: GR XCOM Always Binds to Wildcard Address

## Summary

MySQL Group Replication's XCOM communication layer always binds its
listening socket to the wildcard address (`:::33061` on IPv6,
`0.0.0.0:33061` on IPv4), ignoring the hostname component of
`group_replication_local_address`. This prevents running multiple GR
instances on the same host when they share a GR port but use different
network interfaces.

The second instance fails with `EADDRINUSE` because the first already
claimed the port on all interfaces.

Oracle tracked this as Bug #110591 (S4, Duplicate) consolidated into
Bug #110773 (S3, Verified). No fix from Oracle as of February 2026.

## Root Cause Analysis

### The Structural Gap

The bug is not a simple missing parameter. It is a **structural gap**
in the `Network_configuration_parameters` struct, which carries
configuration from the GR plugin to the XCOM network provider. The
struct has a `port` field but **no hostname field at all**.

```
network_provider.h:191-196
struct Network_configuration_parameters {
    unsigned short port;          // <-- port is here
    struct ssl_parameters ssl_params;
    struct tls_parameters tls_params;
    // NO hostname/bind_address field!
};
```

### Where the Hostname is Lost

At `gcs_xcom_control_interface.cc:1885`, the code constructs a
`Network_configuration_parameters` and sets only the port:

```cpp
Network_configuration_parameters params;
params.port = xcom_node_address->get_member_port();  // port only!
m_comms_operation_interface->configure_active_provider(params);
```

The `xcom_node_address` object has both `get_member_ip()` (returns
`"172.30.1.10"`) and `get_member_port()` (returns `33061`), but only
the port is forwarded. The hostname is used for GCS peer identification
but never reaches the socket binding layer.

### Where the Wildcard Bind Happens

In `xcom_network_provider_native_lib.cc:89`, the `init_server_addr()`
function passes `nullptr` as the hostname to `getaddrinfo()`:

```cpp
hints.ai_flags = AI_PASSIVE;
checked_getaddrinfo_port(nullptr, port, &hints, &address_info);
//                       ^^^^^^^ NULL hostname = wildcard
```

Per POSIX, `getaddrinfo(NULL, port, {AI_PASSIVE})` returns the wildcard
address (`::` for IPv6, `0.0.0.0` for IPv4). The socket then binds to
all interfaces.

### Full Call Chain (16 Steps)

| # | File | Line | Action |
|---|------|------|--------|
| 1 | `plugin.cc` | 4414 | Sysvar stored as string |
| 2 | `plugin.cc` | 2553 | Passed as `"local_node"` param |
| 3 | `plugin.cc` | 2766 | `gcs_module->configure()` |
| 4 | `gcs_xcom_interface.cc` | 961 | `set_node_address()` |
| 5 | `gcs_xcom_interface.cc` | 1226 | Parses host+port correctly |
| 5a | `gcs_xcom_group_member_information.cc` | 37 | `get_ip_and_port()` splits |
| **6** | **`gcs_xcom_control_interface.cc`** | **1885** | **hostname discarded** |
| 7 | `network_provider_manager.cc` | 176 | Port-only config stored |
| 8 | `gcs_xcom_control_interface.cc` | 85 | Port extracted again |
| 9 | `gcs_xcom_proxy.cc` | 244 | `xcom_init(port)` |
| 10 | `xcom_base.cc` | 1459 | `init_xcom_transport(port)` |
| 11 | `network_provider_manager.cc` | 151 | `configure(port-only)` |
| 12 | `xcom_network_provider.h` | 76 | `m_port = params.port` |
| 13 | `xcom_network_provider.cc` | 406 | TCP server thread |
| 14 | `xcom_network_provider.cc` | 48 | `announce_tcp(port)` |
| 15 | `native_lib.cc` | 278 | `init_server_addr(NULL,port)` |
| 16 | `native_lib.cc` | 89 | `getaddrinfo(NULL)` = wildcard |

Step 6 is the critical point. The `Network_configuration_parameters`
struct has no hostname field, so the information is structurally
impossible to pass through.

## Reproduction

### Environment

Single Docker container (percona/percona-server:8.4) attached to two
isolated Docker bridge networks, running two mysqld instances via
supervisord:

```
Container: gr-bind-lab
  eth0: 172.30.1.10/24 (net-alpha)
  eth1: 172.30.2.10/24 (net-beta)

  mysqld-a: bind=172.30.1.10:3306, gr_local=172.30.1.10:33061
  mysqld-b: bind=172.30.2.10:3307, gr_local=172.30.2.10:33061
```

Both instances configured with `group_replication_local_address`
pointing to their respective IPs on the same GR port (33061).

### Reproduction Commands

```bash
just build    # Build custom Docker image
just test1    # Run baseline bug reproduction
just test5    # Run force_bind workaround test
```

### Bug Evidence (Test 1: Baseline)

Socket state shows wildcard binding:

```
$ ss -tlnp | grep 33061
LISTEN  *:33061  *:*  users:(("mysqld",pid=110,fd=38))
```

Instance B error log:

```
Unable to bind to INADDR_ANY:33061 (socket=53, errno=98)!
```

### Fix Evidence (Test 5: force_bind Workaround)

Socket state shows specific IP binding:

```
$ ss -tlnp | grep 33061
LISTEN [::ffff:172.30.1.10]:33061 *:* users:(("mysqld",pid=121,fd=37))
LISTEN [::ffff:172.30.2.10]:33061 *:* users:(("mysqld",pid=122,fd=39))
```

Both instances ONLINE:

```
Instance A: MEMBER_STATE=ONLINE, HOST=172.30.1.10, PORT=3306
Instance B: MEMBER_STATE=ONLINE, HOST=172.30.2.10, PORT=3307
```

## Test Matrix Results

| # | Test | XCOM Bind | Instance B | Notes |
|---|------|-----------|------------|-------|
| 1 | Baseline | `*:33061` | EADDRINUSE | Bug confirmed |
| 2 | No IPv6 | `INADDR_ANY:33061` | EADDRINUSE | IPv6 irrelevant |
| 3 | MYSQL comm stack | No XCOM port | N/A (needs SSL) | Bug impossible: no XCOM listener |
| 4 | Diff ports | `*:33061`,`*:33062` | ONLINE | Works but still wildcard |
| 5 | force_bind | `[::ffff:IP]:33061` | ONLINE | Workaround works |
| 6 | netns isolation | `*:33061` per ns | ONLINE | Workaround: separate network stacks |
| 7 | Patched source | `IP:33061` per instance | ONLINE | **6-file C++ fix validated** |

Key observations:

- **Test 1 vs Test 2**: Disabling IPv6 does not fix the bug. XCOM
  falls back from `:::33061` to `0.0.0.0:33061` but still uses
  wildcard. The root cause is the `nullptr` hostname, not IPv6.
- **Test 4**: Even with different ports, XCOM still uses wildcard
  binding. It works only because the ports differ, not because binding
  is correct.
- **Test 5**: The LD_PRELOAD `force_bind.so` library intercepts the
  `bind()` syscall and replaces the wildcard with the IP from the
  `FORCE_BIND_ADDRESS` environment variable. This proves the fix is
  simply passing the correct IP to `bind()`.
- **Test 3**: The MYSQL communication stack does not open an XCOM port
  at all. No listener on 33061. SQL ports bind to specific IPs via
  `bind_address`. GR bootstrap fails because the MYSQL stack requires
  SSL/TLS credentials, but the wildcard bind bug is structurally
  impossible with this stack.
- **Test 6**: Network namespace isolation gives each instance its own
  socket table. XCOM still binds to wildcard (`*:33061`) within each
  namespace, but there is no conflict because the namespaces are
  independent. Both instances reach ONLINE.

## Workaround Recommendations

### 1. Different GR Ports (Simplest, Recommended)

Assign unique `group_replication_local_address` ports per instance.

```ini
# Instance A
group_replication_local_address = "172.30.1.10:33061"
# Instance B
group_replication_local_address = "172.30.2.10:33062"
```

**Pros**: No external tools, no operational risk.
**Cons**: Requires configuration changes. Firewall rules must cover
multiple ports. Does not actually fix the wildcard binding.

### 2. LD_PRELOAD force_bind (Proven Fix)

Use a custom shared library that intercepts `bind()` and replaces
wildcard addresses with the specific IP.

```bash
FORCE_BIND_ADDRESS=172.30.1.10 \
LD_PRELOAD=/opt/force_bind.so \
mysqld --defaults-file=instance-a.cnf
```

**Pros**: Actually fixes the binding behavior. Both instances can
share the same GR port.
**Cons**: Requires building a C library. LD_PRELOAD is fragile across
MySQL upgrades. May interact with other LD_PRELOAD libraries.
Not suitable for production without thorough testing.

### 3. Network Namespace Isolation (Most Robust, Validated)

Place each mysqld instance in its own Linux network namespace.
Validated in test 6: both instances reached ONLINE with XCOM binding
to wildcard within each isolated namespace.

```bash
ip netns add ns-a
ip link set eth0 netns ns-a
ip netns exec ns-a mysqld --defaults-file=instance-a.cnf
```

**Pros**: Complete network isolation. Each namespace has its own
socket table, so wildcard binding doesn't conflict.
**Cons**: Significant operational complexity. Requires privileged
containers. Routing between namespaces needs configuration.

## Patch Feasibility Assessment

### Verdict: LOW Risk, 6 Files

The fix requires adding a hostname field to
`Network_configuration_parameters` and threading it through the XCOM
network provider to the `bind()` call.

### Files Requiring Changes

| # | File | Change |
|---|------|--------|
| 1 | `network_provider.h` | Add `std::string hostname` field |
| 2 | `xcom_network_provider.h` | Add `m_hostname`, `get_hostname()` |
| 3 | `xcom_network_provider.cc` | Pass hostname to `announce_tcp()` |
| 4 | `native_lib.h` | Update signatures |
| 5 | `native_lib.cc` | Pass hostname to `getaddrinfo()` |
| 6 | `gcs_xcom_control_interface.cc` | Set `params.hostname` |

### Key Change (gcs_xcom_control_interface.cc:1885)

```cpp
// Before (current code):
Network_configuration_parameters params;
params.port = xcom_node_address->get_member_port();

// After (patch):
Network_configuration_parameters params;
params.port = xcom_node_address->get_member_port();
params.hostname = xcom_node_address->get_member_ip();
```

### Key Change (xcom_network_provider_native_lib.cc:89)

```cpp
// Before (current code):
checked_getaddrinfo_port(nullptr, port, &hints, &address_info);

// After (patch):
checked_getaddrinfo_port(
    hostname.empty() ? nullptr : hostname.c_str(),
    port, &hints, &address_info);
```

### Backward Compatibility

When `hostname` is empty (default), `getaddrinfo(nullptr, ...)`
produces the current wildcard behavior. Existing deployments that
don't rely on specific interface binding are unaffected. The
`AI_PASSIVE` flag is ignored when a non-NULL hostname is provided,
per POSIX, so the existing flag can remain.

### Why NOT a New System Variable

A new `group_replication_bind_address` variable is unnecessary. The
hostname is already available from `group_replication_local_address`.
Adding a separate variable creates user confusion and potential for
misconfiguration (two variables specifying the same IP).

## Customer Guidance

For any deployment blocked by this bug:

1. **Immediate**: Use different GR ports per instance (workaround #1).
   This unblocks the migration with zero risk.
2. **If same port required**: Evaluate the LD_PRELOAD `force_bind.so`
   approach in a test environment. The C library source is at
   `scripts/build-force-bind.sh`.
3. **Long term**: File a Percona support ticket requesting the 6-file
   patch described above. Reference Oracle Bug #110773 (S3, Verified).
   The patch is low-risk and backward compatible.

## References

### Oracle Bug Tracker

- [Bug #110591](https://bugs.mysql.com/bug.php?id=110591): Original
  report (S4, Duplicate)
- [Bug #110773](https://bugs.mysql.com/bug.php?id=110773): Consolidated
  report (S3, Verified)

### Source Code

- Repository: percona/percona-server (branch release-8.4.3-3)
- Sparse clone: `source/` (run `just clone-source`)
- Key file: `xcom_network_provider_native_lib.cc` (the `nullptr` bug)

### Reproduction Workspace

- Evidence: `evidence/` (generated by `just test1` through `just test7`)
- Docker image: `gr-bind-lab` (built via `just build`)
