# Patch Proposal: XCOM Should Bind to Configured Address, Not Wildcard

**Bug References**: Oracle Bug #110591 (S4, Duplicate), Oracle Bug #110773 (S3, Verified)
**Affected Versions**: All MySQL 8.x / Percona Server 8.x with Group Replication XCOM stack
**Source Analyzed**: Percona Server 8.4, branch `release-8.4.3-3`

## Problem Statement

The XCOM communication layer in MySQL Group Replication always binds its
server socket to the wildcard address (`0.0.0.0` / `::`) regardless of the
hostname or IP specified in `group_replication_local_address`. The hostname
component of this system variable is parsed and used for GCS peer
communication but is never propagated to the socket binding layer.

This prevents running multiple GR instances on the same port across
different network interfaces on a single host. The second instance fails
with `EADDRINUSE` because the first instance's wildcard bind claims the
port on all interfaces.

The expected behavior, consistent with the documented purpose of
`group_replication_local_address`, is that XCOM should bind exclusively
to the address specified in the variable.

## Root Cause Analysis

The hostname is discarded at a single chokepoint in the XCOM network
configuration pipeline. The `Network_configuration_parameters` struct
has no field for hostname, so when the control interface populates it,
only the port is carried forward. Below is the complete 6-hop path from
the parsed address to the `bind()` call.

### Hop 1: Hostname parsed correctly

**File**: `gcs_xcom_group_member_information.cc:37-48`

`Gcs_xcom_node_address` parses the `"host:port"` string from
`group_replication_local_address` into `m_member_ip` and `m_member_port`
via `get_ip_and_port()`. Both values are correctly extracted.

### Hop 2: Hostname discarded (THE BUG)

**File**: `gcs_xcom_control_interface.cc:1885-1887`

```cpp
Network_configuration_parameters params;
params.port = xcom_node_address->get_member_port();
m_comms_operation_interface->configure_active_provider(params);
```

`xcom_node_address->get_member_ip()` is available but never assigned to
`params`. The struct `Network_configuration_parameters` (defined in
`network_provider.h:191-196`) has no hostname field:

```cpp
struct Network_configuration_parameters {
  unsigned short port;              // <-- only transport config
  struct ssl_parameters ssl_params;
  struct tls_parameters tls_params;
  // NO hostname field
};
```

### Hop 3: Port-only config stored

**File**: `network_provider_manager.cc:176-181`

```cpp
bool Network_provider_manager::configure_active_provider(
    Network_configuration_parameters &params) {
  m_active_provider_configuration = params;   // port only, no hostname
  return false;
}
```

### Hop 4: Provider receives port only

**File**: `xcom_network_provider.h:75-78`

```cpp
bool configure(const Network_configuration_parameters &params) override {
  m_port = params.port;    // m_port stored, no hostname member exists
  return true;
}
```

### Hop 5: TCP server announces with port only

**File**: `xcom_network_provider.cc:44-48`

```cpp
void xcom_tcp_server_startup(Xcom_network_provider *net_provider) {
  xcom_port port = net_provider->get_port();
  // ...
  tcp_fd = Xcom_network_provider_library::announce_tcp(port);
```

### Hop 6: `getaddrinfo(nullptr)` produces wildcard

**File**: `xcom_network_provider_native_lib.cc:79-89`

```cpp
void Xcom_network_provider_library::init_server_addr(
    struct sockaddr **sock_addr, socklen_t *sock_len,
    xcom_port port, int family) {
  // ...
  hints.ai_flags = AI_PASSIVE;
  // ...
  checked_getaddrinfo_port(nullptr, port, &hints, &address_info);
  //                       ^^^^^^^
  //                       ALWAYS nullptr: produces 0.0.0.0 / ::
```

Per POSIX, `getaddrinfo(NULL, service, {AI_PASSIVE}, ...)` returns the
wildcard address suitable for `bind()`. When a non-NULL hostname is
provided, `AI_PASSIVE` is ignored and the specific address is resolved.

## Proposed Changes

Six files require modification. The change threads the hostname from
`Gcs_xcom_node_address` through the network configuration pipeline to
`getaddrinfo()`.

### 1. `network_provider.h` (line 191)

Add a `hostname` field to `Network_configuration_parameters`.

```diff
 struct Network_configuration_parameters {
+  std::string hostname;
   unsigned short port;

   struct ssl_parameters ssl_params;
   struct tls_parameters tls_params;
 };
```

### 2. `gcs_xcom_control_interface.cc` (line 1885)

Set `params.hostname` from the node address.

```diff
   Network_configuration_parameters params;
+  params.hostname = xcom_node_address->get_member_ip();
   params.port = xcom_node_address->get_member_port();
   m_comms_operation_interface->configure_active_provider(params);
```

### 3. `xcom_network_provider.h` (line 49, 75, 129, 148)

Add `m_hostname` member and accessor; update `configure()`.

```diff
   Xcom_network_provider()
-      : m_port(0),
+      : m_hostname(),
+        m_port(0),
         m_initialized(false),
         // ...

   bool configure(const Network_configuration_parameters &params) override {
+    m_hostname = params.hostname;
     m_port = params.port;
     return true;
   }

+  const std::string &get_hostname() const { return m_hostname; }

  private:
+   std::string m_hostname;
    xcom_port m_port;
```

### 4. `xcom_network_provider.cc` (line 44-48)

Pass hostname from provider to `announce_tcp()`.

```diff
 void xcom_tcp_server_startup(Xcom_network_provider *net_provider) {
   xcom_port port = net_provider->get_port();
+  const std::string &hostname = net_provider->get_hostname();

   result tcp_fd = {0, 0};
-  tcp_fd = Xcom_network_provider_library::announce_tcp(port);
+  tcp_fd = Xcom_network_provider_library::announce_tcp(port, hostname);
```

### 5. `xcom_network_provider_native_lib.h` (line 55, 83)

Update `announce_tcp()` and `init_server_addr()` signatures.

```diff
-  static result announce_tcp(xcom_port port);
+  static result announce_tcp(xcom_port port,
+                              const std::string &hostname = std::string());

  private:
-  static void init_server_addr(struct sockaddr **sock_addr,
-                                socklen_t *sock_len,
-                                xcom_port port, int family);
+  static void init_server_addr(struct sockaddr **sock_addr,
+                                socklen_t *sock_len,
+                                xcom_port port, int family,
+                                const std::string &hostname = std::string());
```

### 6. `xcom_network_provider_native_lib.cc` (lines 79, 253)

Pass hostname to `getaddrinfo()` instead of `nullptr`.

```diff
 void Xcom_network_provider_library::init_server_addr(
     struct sockaddr **sock_addr, socklen_t *sock_len,
-    xcom_port port, int family) {
+    xcom_port port, int family, const std::string &hostname) {
   struct addrinfo *address_info = nullptr, hints, *address_info_loop;
   memset(&hints, 0, sizeof(hints));

   hints.ai_flags = AI_PASSIVE;
   hints.ai_protocol = IPPROTO_TCP;
   hints.ai_family = AF_UNSPEC;
   hints.ai_socktype = SOCK_STREAM;
-  checked_getaddrinfo_port(nullptr, port, &hints, &address_info);
+  const char *node = hostname.empty() ? nullptr : hostname.c_str();
+  checked_getaddrinfo_port(node, port, &hints, &address_info);
```

```diff
-result Xcom_network_provider_library::announce_tcp(xcom_port port) {
+result Xcom_network_provider_library::announce_tcp(
+    xcom_port port, const std::string &hostname) {
   // ...
-  init_server_addr(&sock_addr, &sock_addr_len, port,
-                   server_socket_v6_ok ? AF_INET6 : AF_INET);
+  init_server_addr(&sock_addr, &sock_addr_len, port,
+                   server_socket_v6_ok ? AF_INET6 : AF_INET, hostname);
   // ... (also update the IPv4 fallback call)
-    init_server_addr(&sock_addr, &sock_addr_len, port, AF_INET);
+    init_server_addr(&sock_addr, &sock_addr_len, port, AF_INET, hostname);
```

Update the debug log to reflect what address was bound:

```diff
-  G_DEBUG("Successfully bound to %s:%d (socket=%d).", "INADDR_ANY", port,
-          fd.val);
+  G_DEBUG("Successfully bound to %s:%d (socket=%d).",
+          hostname.empty() ? "INADDR_ANY" : hostname.c_str(), port, fd.val);
```

And the error message for the IPv4 fallback:

```diff
-      G_MESSAGE("Unable to bind to INADDR_ANY:%d (socket=%d, errno=%d)!",
-                port, fd.val, err);
+      G_MESSAGE("Unable to bind to %s:%d (socket=%d, errno=%d)!",
+                hostname.empty() ? "INADDR_ANY" : hostname.c_str(),
+                port, fd.val, err);
```

## Backward Compatibility Analysis

The patch is fully backward compatible. Every new parameter uses a
default empty string:

| Scenario | Hostname Value | `getaddrinfo()` First Arg | Bind Result |
|----------|---------------|--------------------------|-------------|
| Default (no hostname) | `""` | `nullptr` | Wildcard (current behavior) |
| Hostname specified | `"172.30.1.10"` | `"172.30.1.10"` | Specific address |
| DNS name specified | `"node1.example.com"` | `"node1.example.com"` | Resolved address |

When `hostname` is empty, `node` evaluates to `nullptr`, and
`getaddrinfo(nullptr, port, {AI_PASSIVE}, ...)` returns the wildcard
address. This is identical to the current behavior.

When `hostname` is non-empty, `getaddrinfo("172.30.1.10", port, ...)` returns
the specific address. The `AI_PASSIVE` flag is ignored per POSIX when a
non-NULL node name is provided, which is the correct behavior: we want to
bind to the specific address, not a passive wildcard.

No changes to the GR plugin interface, system variable parsing, or
configuration file format are required. The MySQL communication stack
path is unaffected because it uses a separate `Network_provider`
implementation (confirmed in test 3: MYSQL stack opens no XCOM port).

## Risk Assessment

**Risk Level**: LOW

| Factor | Assessment |
|--------|-----------|
| Scope | 6 files, all within `libmysqlgcs` network layer |
| Struct change | Adding a field to `Network_configuration_parameters`; all initialization sites are identified |
| ABI impact | `Network_configuration_parameters` is an internal struct, not part of any public plugin API |
| Default behavior | Empty hostname preserves exact current behavior |
| Failure mode | If hostname resolution fails, `getaddrinfo()` returns error; existing error handling applies |
| SSL path | Unaffected. SSL configuration uses separate fields in the same struct |
| MySQL comm stack | Unaffected. Only `Xcom_network_provider` is modified. Confirmed by test 3 |
| IPv4/IPv6 dual-stack | Preserved. IPv4 on AF_INET6 produces `::ffff:` mapped addresses. See Dual-Stack section below |

The only behavioral change occurs when `group_replication_local_address`
contains a hostname/IP component AND that hostname is not the wildcard.
In that case, the socket binds to the specified address rather than all
interfaces. This is the documented and expected behavior.

## Dual-Stack Consideration: IPv4-Mapped IPv6 Addresses

XCOM creates `AF_INET6` sockets with `IPV6_V6ONLY=0` (dual-stack mode).
When the user specifies an IPv4 address like `172.30.1.10` in
`group_replication_local_address`, `getaddrinfo("172.30.1.10", port, {AF_INET6})`
returns `::ffff:172.30.1.10` in a `sockaddr_in6` structure. This is correct
POSIX behavior: IPv4-mapped IPv6 addresses allow an `AF_INET6` socket to
accept both IPv4 and IPv6 connections to that specific IP.

This is already validated empirically. The `force_bind.so` workaround
produces exactly this mapping, and `ss` output confirms it:

```
LISTEN [::ffff:172.30.1.10]:33061 *:* users:(("mysqld",pid=121,fd=37))
LISTEN [::ffff:172.30.2.10]:33061 *:* users:(("mysqld",pid=122,fd=39))
```

Both instances reach ONLINE state, confirming that IPv4-mapped IPv6
binding works correctly for GR peer communication.

The `init_server_addr()` function iterates `getaddrinfo()` results by
family preference (IPv6 first, IPv4 fallback). When a hostname resolves
to an IPv4-mapped IPv6 address, the `AF_INET6` result is selected first,
which is the desired outcome for dual-stack sockets.

**No additional code change is needed** beyond what is proposed above.
The `getaddrinfo()` call with a non-NULL IPv4 hostname and `AF_UNSPEC`
hint naturally returns both `AF_INET` and `AF_INET6` (mapped) results.
The existing family selection logic picks the correct one.

However, the following edge case should be tested:

| Input | Socket Family | `getaddrinfo()` Returns | Bind Address |
|-------|--------------|------------------------|--------------|
| `172.30.1.10` | `AF_INET6` | `::ffff:172.30.1.10` | Correct |
| `172.30.1.10` | `AF_INET` (fallback) | `172.30.1.10` | Correct |
| `::1` | `AF_INET6` | `::1` | Correct |
| `node1.example.com` | `AF_INET6` | Resolved + mapped | Correct |

## Testing Recommendations

### Unit Tests

1. **Existing test suite**: Run the full GCS/XCOM unit test suite to verify
   no regressions. The change to `Network_configuration_parameters` will
   require updating any tests that construct this struct.

2. **New unit test**: `init_server_addr()` with a specific IPv4 address
   should produce a `sockaddr_in` with that address, not `INADDR_ANY`.

3. **New unit test**: `init_server_addr()` with an empty hostname should
   produce `INADDR_ANY` / `in6addr_any` (backward compat).

### Integration Tests (MTR)

1. **Single-host, multi-network**: Two GR instances on the same host,
   each bound to a different IP on the same port. Both should reach
   ONLINE state. This is the primary reproducer for the original bug.

2. **Single-host, same-IP, different ports**: Current common deployment
   pattern. Should continue working unchanged.

3. **Hostname resolution**: Use a resolvable DNS name in
   `group_replication_local_address`. Verify the socket binds to the
   resolved address.

4. **IPv6 specific address**: Use an IPv6 address in
   `group_replication_local_address`. Verify the socket binds to that
   specific IPv6 address.

5. **Backward compat**: Omit the hostname (port-only config) or use
   `0.0.0.0` explicitly. Verify wildcard binding is preserved.

6. **Dual-stack IPv4-mapped**: Use an IPv4 address on an `AF_INET6`
   (dual-stack) socket. Verify `ss` shows `[::ffff:x.x.x.x]:port` and
   the instance accepts connections over both IPv4 and IPv6.

7. **IPv4-only host**: On a system with `net.ipv6.conf.all.disable_ipv6=1`,
   verify the IPv4 fallback path binds correctly to the specific address.

### Validation Already Performed

An `LD_PRELOAD` proof-of-concept (`force_bind.so`) that intercepts
`bind()` and replaces wildcard addresses with the configured IP from
`group_replication_local_address` was tested. Two Percona Server 8.4
instances on isolated Docker networks, both using port 33061, achieved
ONLINE GR status simultaneously. This confirms the fix is correct in
principle: the only missing piece is passing the hostname to
`getaddrinfo()`.

## Summary

The fix is a straightforward plumbing change. The hostname is already
parsed and available at the point where it is needed. The
`Network_configuration_parameters` struct simply lacks a field for it,
so the information is dropped. Adding the field and threading it through
the 6-hop path from `set_node_address()` to `init_server_addr()` resolves
the bug with no change to default behavior.
