# LD_PRELOAD force_bind Workaround for MySQL GR Wildcard Bind Bug

Technical deep-dive into the `force_bind.so` LD_PRELOAD library that intercepts the
`bind()` syscall to force MySQL Group Replication's XCOM layer to bind to a specific
IP address instead of wildcard.

**Related bugs:**

- [Oracle Bug #110591](https://bugs.mysql.com/bug.php?id=110591) (S4, Duplicate)
- [Oracle Bug #110773](https://bugs.mysql.com/bug.php?id=110773) (S3, Verified)

## Table of Contents

1. [The Problem](#the-problem)
2. [How LD_PRELOAD Works](#how-ld_preload-works)
3. [The force_bind.c Implementation](#the-force_bindc-implementation)
4. [The IPv4-Mapped IPv6 Subtlety](#the-ipv4-mapped-ipv6-subtlety)
5. [Deployment Instructions](#deployment-instructions)
6. [Verification](#verification)
7. [Limitations and Production Considerations](#limitations-and-production-considerations)
8. [Relationship to the Upstream Fix](#relationship-to-the-upstream-fix)

## The Problem

MySQL Group Replication's XCOM consensus layer always binds its server socket to the
wildcard address (`0.0.0.0` / `::`) regardless of the IP configured in
`group_replication_local_address`. The root cause is in
`xcom_network_provider_native_lib.cc`, where `init_server_addr()` passes `nullptr` as
the hostname to `getaddrinfo()`:

```cpp
// xcom_network_provider_native_lib.cc, line 89
checked_getaddrinfo_port(nullptr, port, &hints, &address_info);
```

When `getaddrinfo()` receives `NULL` as the node name with the `AI_PASSIVE` flag set,
POSIX mandates it returns the wildcard address. The configured
`group_replication_local_address` hostname is extracted and used for GCS peer
communication, but never passed to the socket binding layer.

This means two GR instances on the same host cannot use the same port on different
network interfaces. The first instance binds `*:33061`, and the second gets
`EADDRINUSE`:

```
# Baseline evidence (before fix):
LISTEN *:33061 *:* users:(("mysqld",pid=110,fd=38))
```

Only one listener on port 33061, owned by pid 110. Instance B (pid 111) failed to
start its GR communication stack.

## How LD_PRELOAD Works

`LD_PRELOAD` is a feature of the ELF dynamic linker (`ld-linux.so` / `ld.so`). It
tells the linker to load a specified shared object before any others, including libc.
Because symbol resolution follows load order, functions defined in the preloaded
library shadow identically named functions in subsequently loaded libraries.

### The Symbol Resolution Chain

When a dynamically linked program calls `bind()`:

1. **Without LD_PRELOAD:** The linker resolves `bind` to the libc implementation
   in `libc.so.6`. This is the kernel syscall wrapper.

2. **With LD_PRELOAD=force_bind.so:** The linker resolves `bind` to the
   replacement function in `force_bind.so`. Our code runs first, inspects and
   optionally modifies the arguments, then calls the real `bind` via
   `dlsym(RTLD_NEXT, "bind")`.

`RTLD_NEXT` is the key mechanism. It tells `dlsym` to find the *next* occurrence of
the named symbol in the search order, skipping the current library. This gives us a
function pointer to libc's real `bind()`, which we invoke after modifying the address.

### Why This Works for mysqld

mysqld is a standard dynamically linked ELF binary. It calls `bind()` through the
normal C library interface, making it eligible for LD_PRELOAD interception. The XCOM
layer does not use any unusual syscall mechanisms (inline assembly, direct syscall
numbers, or statically linked socket code) that would bypass the dynamic linker.

### Key Properties

- **Process-scoped**: The preloaded library only affects the process it is loaded
  into. Other processes on the system are unaffected.
- **Transparent**: The target program does not need modification or recompilation.
  It does not know its `bind()` calls are being intercepted.
- **Inheritable**: Child processes forked from the preloaded process inherit the
  `LD_PRELOAD` environment variable unless explicitly cleared.

## The force_bind.c Implementation

### Full Annotated Source

```c
#define _GNU_SOURCE
#include <dlfcn.h>        // dlsym, RTLD_NEXT
#include <sys/socket.h>   // bind, sockaddr, AF_INET, AF_INET6
#include <netinet/in.h>   // sockaddr_in, sockaddr_in6, INADDR_ANY, in6addr_any
#include <arpa/inet.h>    // inet_pton, inet_ntop
#include <string.h>       // memcpy, memcmp, memset
#include <stdlib.h>       // getenv
#include <stdio.h>        // fprintf

// Function pointer type matching the real bind() signature
typedef int (*orig_bind_t)(int sockfd, const struct sockaddr *addr, socklen_t addrlen);

// Read the target address from the environment on every call.
// This allows different values per-process via supervisord configuration.
static const char* get_force_addr(void) {
    return getenv("FORCE_BIND_ADDRESS");
}
```

The `_GNU_SOURCE` define is required for `RTLD_NEXT` to be available from `dlfcn.h`.
The `typedef` creates a clean function pointer type for calling through to the real
`bind()`.

```c
int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    // Resolve the real bind() from libc. RTLD_NEXT skips our library.
    orig_bind_t orig_bind = (orig_bind_t)dlsym(RTLD_NEXT, "bind");
    if (!orig_bind) {
        fprintf(stderr, "force_bind: dlsym failed\n");
        return -1;
    }

    // If no address configured, pass through unchanged
    const char *force_addr = get_force_addr();
    if (!force_addr || force_addr[0] == '\0') {
        return orig_bind(sockfd, addr, addrlen);
    }
```

This is the entry gate. Every `bind()` call in the process hits this function. If
`FORCE_BIND_ADDRESS` is not set, all calls pass through with zero overhead beyond the
`dlsym` lookup and `getenv` check.

```c
    /* AF_INET: replace 0.0.0.0 with forced address */
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)addr;
        if (sin->sin_addr.s_addr == htonl(INADDR_ANY)) {
            struct sockaddr_in modified;
            memcpy(&modified, sin, sizeof(modified));
            if (inet_pton(AF_INET, force_addr, &modified.sin_addr) == 1) {
                fprintf(stderr, "force_bind: redirecting 0.0.0.0:%d -> %s:%d\n",
                        ntohs(modified.sin_port), force_addr, ntohs(modified.sin_port));
                return orig_bind(sockfd, (struct sockaddr *)&modified, sizeof(modified));
            }
        }
    }
```

**AF_INET path:** For IPv4 sockets binding to `INADDR_ANY` (0.0.0.0), the code copies
the original `sockaddr_in`, replaces the address with the forced IP, and calls the
real `bind()`. The port is preserved. Non-wildcard binds (like mysqld's regular
`bind("172.30.1.10", 3306)`) pass through unchanged.

```c
    /* AF_INET6: replace :: with forced address (handles IPv4-mapped IPv6) */
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)addr;
        if (memcmp(&sin6->sin6_addr, &in6addr_any, sizeof(in6addr_any)) == 0) {
            struct sockaddr_in6 modified;
            memcpy(&modified, sin6, sizeof(modified));

            /* Try native IPv6 address first */
            if (inet_pton(AF_INET6, force_addr, &modified.sin6_addr) == 1) {
                fprintf(stderr, "force_bind: IPv6 [::]:%d -> [%s]:%d\n",
                        ntohs(modified.sin6_port), force_addr, ntohs(modified.sin6_port));
                return orig_bind(sockfd, (struct sockaddr *)&modified, sizeof(modified));
            }

            /* IPv4 address on IPv6 socket: convert to ::ffff:x.x.x.x mapped form */
            struct in_addr v4addr;
            if (inet_pton(AF_INET, force_addr, &v4addr) == 1) {
                memset(&modified.sin6_addr, 0, sizeof(modified.sin6_addr));
                modified.sin6_addr.s6_addr[10] = 0xff;
                modified.sin6_addr.s6_addr[11] = 0xff;
                memcpy(&modified.sin6_addr.s6_addr[12], &v4addr, 4);

                char mapped[64];
                inet_ntop(AF_INET6, &modified.sin6_addr, mapped, sizeof(mapped));
                fprintf(stderr, "force_bind: IPv6 [::]:%d -> [%s]:%d (mapped from %s)\n",
                        ntohs(modified.sin6_port), mapped, ntohs(modified.sin6_port),
                        force_addr);
                return orig_bind(sockfd, (struct sockaddr *)&modified, sizeof(modified));
            }
        }
    }

    // Non-wildcard binds, or address families we don't handle: pass through
    return orig_bind(sockfd, addr, addrlen);
}
```

**AF_INET6 path:** This is the critical section. XCOM creates AF_INET6 sockets, so
this branch handles the actual interception. It has two sub-cases, explained in the
next section.

### Build Script

The `build-force-bind.sh` script writes the C source to `/tmp/force_bind.c`, installs
`gcc` if missing (supports dnf, yum, and apt-get), and compiles:

```bash
gcc -shared -fPIC -o /opt/force_bind.so /tmp/force_bind.c -ldl
```

Flags:

- `-shared`: Produce a shared object (.so) instead of an executable
- `-fPIC`: Position-independent code, required for shared libraries
- `-ldl`: Link against libdl for `dlsym`

## The IPv4-Mapped IPv6 Subtlety

This is the most important technical detail and the reason a naive LD_PRELOAD
implementation silently fails.

### What XCOM Actually Does

Looking at `create_server_socket()` in `xcom_network_provider_native_lib.cc`:

```cpp
// Line 131: Always creates an IPv6 socket
fd = xcom_checked_socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);

// Lines 160-162: Sets dual-stack mode (accepts both IPv4 and IPv6)
int mode = 0;
setsockopt(fd.val, IPPROTO_IPV6, IPV6_V6ONLY, (xcom_buf *)&mode, sizeof(mode));
```

Then in `announce_tcp()`:

```cpp
// Line 278-279: Resolves the wildcard for AF_INET6
init_server_addr(&sock_addr, &sock_addr_len, port, AF_INET6);

// Line 280: Binds the AF_INET6 socket to the resolved (wildcard) address
bind(fd.val, sock_addr, sock_addr_len);
```

The socket is `AF_INET6` with `IPV6_V6ONLY=0` (dual-stack). The `bind()` call
receives a `sockaddr_in6` with `in6addr_any` (`::`), **not** a `sockaddr_in` with
`INADDR_ANY` (`0.0.0.0`).

### Why Naive Interception Fails

A first attempt at a force_bind library might only handle `AF_INET`:

```c
// WRONG: This never fires for XCOM
if (addr->sa_family == AF_INET && sin->sin_addr.s_addr == htonl(INADDR_ANY)) {
    // Replace with forced address...
}
```

Since XCOM uses `AF_INET6` sockets, this check never matches. The wildcard bind
passes through unmodified. No error, no log message. The library loads, appears to
work, but does nothing.

### The IPv4-Mapped IPv6 Solution

RFC 4291 Section 2.5.5.2 defines IPv4-mapped IPv6 addresses: `::ffff:a.b.c.d`. When
a dual-stack socket binds to an IPv4-mapped address, the kernel binds the underlying
IPv4 address on that socket. This is exactly what we need.

The conversion in force_bind.c constructs the mapped address manually:

```c
// Start with 16 zero bytes
memset(&modified.sin6_addr, 0, sizeof(modified.sin6_addr));

// Bytes 10-11: the 0xFFFF marker that identifies IPv4-mapped addresses
modified.sin6_addr.s6_addr[10] = 0xff;
modified.sin6_addr.s6_addr[11] = 0xff;

// Bytes 12-15: the 4-byte IPv4 address in network byte order
memcpy(&modified.sin6_addr.s6_addr[12], &v4addr, 4);
```

For `FORCE_BIND_ADDRESS=172.30.1.10`, this produces
`::ffff:172.30.1.10` (hex: `00 00 00 00 00 00 00 00 00 00 ff ff ac 1e 01 0a`).

The 128-bit IPv6 address layout:

```
Bytes:   0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
Values: 00 00 00 00 00 00 00 00 00 00 ff ff ac 1e 01 0a
        |__________ zeros __________|  |ff|  |_IPv4__|
                                       |ff|
                                       marker
```

Where `ac 1e 01 0a` is `172.30.1.10` in hex.

### The Decision Cascade

The AF_INET6 handler tries two conversions in order:

1. **`inet_pton(AF_INET6, force_addr, ...)`**: If FORCE_BIND_ADDRESS is already a
   valid IPv6 address (e.g., `fd00::1`), use it directly. This handles pure IPv6
   deployments.

2. **`inet_pton(AF_INET, force_addr, ...)`**: If step 1 fails, try parsing as IPv4.
   If it succeeds, manually construct the `::ffff:x.x.x.x` mapped form. This handles
   the common case where `group_replication_local_address` uses IPv4 addresses.

If neither parse succeeds, the bind passes through unchanged, and a diagnostic
message would help identify configuration errors (though in practice a valid IP
should always be configured).

## Deployment Instructions

### Prerequisites

- GCC and glibc development headers (the build script auto-installs them)
- The container or host must support `LD_PRELOAD` (standard on Linux)
- The `FORCE_BIND_ADDRESS` environment variable set to the desired bind IP

### Step 1: Compile the Library

Inside the container (or on the host):

```bash
/opt/scripts/build-force-bind.sh
```

This produces `/opt/force_bind.so`. Alternatively, build outside and copy in:

```bash
gcc -shared -fPIC -o force_bind.so force_bind.c -ldl
docker cp force_bind.so <container>:/opt/force_bind.so
```

### Step 2: Configure Environment Variables

Each mysqld instance needs its own `FORCE_BIND_ADDRESS`. In our test lab, supervisord
handles this:

```ini
# supervisord.conf
[program:instance-a]
command=/opt/scripts/mysqld-wrapper.sh instance-a
environment=FORCE_BIND_ADDRESS="172.30.1.10"

[program:instance-b]
command=/opt/scripts/mysqld-wrapper.sh instance-b
environment=FORCE_BIND_ADDRESS="172.30.2.10"
```

### Step 3: Inject via Wrapper Script

The `mysqld-wrapper.sh` conditionally activates LD_PRELOAD:

```bash
#!/bin/bash
set -euo pipefail

if [[ "${TEST_FORCE_BIND:-0}" == "1" && -f /opt/force_bind.so ]]; then
    ADDR="${FORCE_BIND_ADDRESS:-}"
    if [[ -n "$ADDR" ]]; then
        echo "[mysqld-wrapper] Injecting LD_PRELOAD (bind to ${ADDR})"
        export LD_PRELOAD=/opt/force_bind.so
        export FORCE_BIND_ADDRESS="$ADDR"
    fi
fi

exec mysqld --defaults-file="$DEFAULTS"
```

The `exec` replaces the shell with mysqld, so the LD_PRELOAD environment is
inherited by the mysqld process directly.

### Step 4: Enable the Workaround

Set `TEST_FORCE_BIND=1` in the container environment. In the Docker Compose test
matrix, this is configured per test via environment files.

## Verification

### Check Socket Binding with `ss`

The definitive verification is checking what address the GR port is bound to:

```bash
# Before (wildcard, the bug):
ss -tlnp | grep 33061
# LISTEN *:33061 *:*  users:(("mysqld",pid=110,fd=38))
#
# One listener on wildcard. Second instance cannot bind.

# After (force_bind active):
ss -tlnp | grep 33061
# LISTEN [::ffff:172.30.1.10]:33061 *:*  users:(("mysqld",pid=121,fd=37))
# LISTEN [::ffff:172.30.2.10]:33061 *:*  users:(("mysqld",pid=122,fd=39))
#
# Two listeners, each bound to its own IP. Both instances running.
```

The `::ffff:` prefix confirms the IPv4-mapped IPv6 form is in use, which is
expected given XCOM's dual-stack AF_INET6 sockets.

### Check GR Cluster Status

```sql
-- On instance A:
SELECT MEMBER_STATE, MEMBER_HOST, MEMBER_PORT
FROM performance_schema.replication_group_members;
-- MEMBER_STATE: ONLINE
-- MEMBER_HOST: 172.30.1.10
-- MEMBER_PORT: 3306

-- On instance B:
SELECT MEMBER_STATE, MEMBER_HOST, MEMBER_PORT
FROM performance_schema.replication_group_members;
-- MEMBER_STATE: ONLINE
-- MEMBER_HOST: 172.30.2.10
-- MEMBER_PORT: 3307
```

Both members ONLINE confirms GR communication is working through the forced bind
addresses.

### Check stderr Logs

The force_bind library writes interception events to stderr:

```
force_bind: IPv6 [::]:33061 -> [::ffff:172.30.1.10]:33061 (mapped from 172.30.1.10)
```

These appear in the supervisord stderr log for each instance
(`/var/log/mysql/instance-a-stderr.log`).

## Limitations and Production Considerations

### This Is a Diagnostic Workaround, Not a Production Fix

The force_bind library is designed to prove the hypothesis: "if XCOM bound to the
correct IP, the multi-network conflict would be resolved." It validates the
upstream bug report. It is not intended as a permanent production deployment.

### Security

- `LD_PRELOAD` libraries run with the same privileges as the target process.
  The `.so` file must be owned by root and not world-writable.
- The library intercepts ALL `bind()` calls in the process, not just XCOM's.
  While it only modifies wildcard binds, any unexpected socket behavior should be
  investigated.

### Performance

- The overhead is negligible. Each `bind()` call adds one `dlsym` lookup (cached
  by the linker after first resolution), one `getenv` call, and one address
  comparison. Socket binding happens at startup, not on the hot path.

### Fragility

- If MySQL changes its socket creation strategy (e.g., switches from AF_INET6
  dual-stack to AF_INET, or starts binding to a specific address), the
  interception conditions change. The library's passthrough logic means it would
  still work (non-wildcard binds pass through), but the interception would no
  longer fire.
- The library assumes the `bind()` function signature matches the POSIX standard.
  This is true for all glibc-based Linux systems.

### Not Applicable When

- **GR uses the MYSQL communication stack** (`group_replication_communication_stack=MYSQL`):
  This stack uses MySQL's own networking layer, which respects `bind-address`.
  The XCOM wildcard bind bug is specific to the XCOM stack. Confirmed in test 3:
  no XCOM port opened, SQL ports bind to specific IPs.
- **IPv6-only deployments with native addresses**: If `group_replication_local_address`
  uses native IPv6 addresses and XCOM is patched to pass them correctly, the
  library is unnecessary.
- **Containerized single-instance deployments**: If each mysqld runs in its own
  network namespace (separate container), wildcard binding is not a conflict.
  Validated in test 6: both instances ONLINE with wildcard bind in separate namespaces.

### Container vs. Host Deployment

In containerized environments, the `.so` must be inside the container filesystem.
Building it in the Dockerfile or copying it in at startup both work. For host-based
MySQL installations, place it in a path accessible to the mysqld user and configure
LD_PRELOAD in the systemd unit file:

```ini
# /etc/systemd/system/mysqld.service.d/force-bind.conf
[Service]
Environment="LD_PRELOAD=/opt/force_bind.so"
Environment="FORCE_BIND_ADDRESS=10.0.1.5"
```

## Relationship to the Upstream Fix

The force_bind workaround and the proper upstream fix operate on the same principle:
**pass the configured IP address to the socket binding layer instead of NULL/wildcard.**

### What the Upstream Fix Would Change

In `init_server_addr()`, instead of:

```cpp
checked_getaddrinfo_port(nullptr, port, &hints, &address_info);
```

The fix would pass the hostname from `group_replication_local_address`:

```cpp
checked_getaddrinfo_port(configured_hostname, port, &hints, &address_info);
```

When `getaddrinfo()` receives a specific hostname instead of NULL, it resolves to
that host's address rather than the wildcard. The resulting `sockaddr` passed to
`bind()` then contains the specific IP, and the socket binds to that interface only.

### Why the LD_PRELOAD Proof Matters

The force_bind test demonstrates that the *only* problem is the wildcard bind. The
GR protocol, XCOM consensus, and cluster membership all work correctly when each
instance binds to its designated IP. This is strong evidence that the upstream fix
(passing the configured hostname through to `getaddrinfo`) will resolve the bug
without side effects.

The `announce_tcp()` function already has the port. The hostname is available in the
GCS layer above. The fix is a matter of plumbing it through the call chain.

### Evidence Summary

| Test | Bind Address | Port 33061 Listeners | GR Status |
|------|-------------|---------------------|-----------|
| Baseline (bug) | `*` (wildcard) | 1 (second fails EADDRINUSE) | Instance B fails |
| force_bind | `::ffff:172.30.x.10` | 2 (one per instance) | Both ONLINE |

The single-variable change (wildcard to specific IP) transitions from failure to
success, confirming the root cause and validating the fix approach.
