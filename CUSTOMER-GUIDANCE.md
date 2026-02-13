# MySQL Group Replication: Port Conflict When Running Multiple Groups on Shared Servers

## The Problem

When you run multiple MySQL Group Replication (GR) groups on the same server,
each instance bound to a different network interface, you expect to be able to
use the same GR communication port (e.g., 33061) across instances. After all,
the instances are configured with different IPs in `group_replication_local_address`.

This does not work. The internal XCOM consensus engine always binds to the
**wildcard address** (`0.0.0.0` / `::`) regardless of the IP you configure.
The first instance claims port 33061 on all interfaces. The second instance
fails with:

```
[ERROR] [MY-011735] [Repl] Plugin group_replication reported:
  '[GCS] Unable to announce tcp port 33061. Port already in use?'
```

The error repeats on every retry until GR gives up with a timeout.

### Who is affected

Any deployment where two or more GR groups share a physical or virtual host
and attempt to use the same GR communication port on separate network interfaces.
This includes:

- Database consolidation on multi-NIC servers
- Container or VM hosts running multiple GR instances
- Migration scenarios that temporarily co-locate GR groups

### Oracle bug references

| Bug | Severity | Status | Description |
|-----|----------|--------|-------------|
| [#110591](https://bugs.mysql.com/bug.php?id=110591) | S4 | Duplicate | Original report (wildcard bind) |
| [#110773](https://bugs.mysql.com/bug.php?id=110773) | S3 | Verified | Consolidated tracking bug |

As of February 2026, there is no fix available in any MySQL release
(tested through Percona Server 8.4.7-7). The bug is confirmed and verified
by Oracle but has no published fix timeline.

## Workarounds

Three approaches are available, each with different trade-offs. Choose based
on the decision matrix at the end of this section.

### Option 1: Use Different GR Ports (Recommended)

Assign a unique GR communication port to each instance. This avoids the
wildcard bind conflict entirely because each instance binds `0.0.0.0` on
a port that no other instance uses.

**Configuration change for Instance A:**

```ini
[mysqld]
group_replication_local_address = 192.168.1.10:33061
group_replication_group_seeds  = 192.168.1.10:33061
```

**Configuration change for Instance B:**

```ini
[mysqld]
group_replication_local_address = 192.168.2.10:33062
group_replication_group_seeds  = 192.168.2.10:33062
```

**Steps:**

1. Stop Group Replication on all members of the affected group:
   `STOP GROUP_REPLICATION;`
2. Update `group_replication_local_address` to use a unique port on every member
   of each group that shares the host.
3. Update `group_replication_group_seeds` on every member to reflect the new ports.
4. Update firewall rules to allow the new ports between all GR members.
5. Restart Group Replication: `START GROUP_REPLICATION;`
6. Verify with `SELECT * FROM performance_schema.replication_group_members;`
   and confirm all members show `MEMBER_STATE = ONLINE`.

**Port allocation suggestion:** Use a simple scheme like `33061 + group_number`.
Group A gets 33061, Group B gets 33062, and so on.

**Pros:** Zero risk, no external tooling, works with all MySQL versions.

**Cons:** Requires firewall rule updates for each new port. Breaks the
assumption that all groups use a standard port.

### Option 2: LD_PRELOAD Bind Override (Advanced)

A small C library intercepts the `bind()` system call and replaces
the wildcard address with a specific IP, forcing each mysqld process
to listen only on its designated interface.

**Step 1: Create the C source file**

Save the following as `/opt/force_bind.c`:

```c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

typedef int (*orig_bind_t)(int, const struct sockaddr *, socklen_t);

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    orig_bind_t orig_bind = (orig_bind_t)dlsym(RTLD_NEXT, "bind");
    const char *force_addr = getenv("FORCE_BIND_ADDRESS");

    if (!force_addr || force_addr[0] == '\0')
        return orig_bind(sockfd, addr, addrlen);

    /* AF_INET: replace 0.0.0.0 */
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)addr;
        if (sin->sin_addr.s_addr == htonl(INADDR_ANY)) {
            struct sockaddr_in mod;
            memcpy(&mod, sin, sizeof(mod));
            if (inet_pton(AF_INET, force_addr, &mod.sin_addr) == 1)
                return orig_bind(sockfd, (struct sockaddr *)&mod, sizeof(mod));
        }
    }

    /* AF_INET6: replace :: (including IPv4-mapped IPv6) */
    if (addr->sa_family == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)addr;
        if (memcmp(&sin6->sin6_addr, &in6addr_any, sizeof(in6addr_any)) == 0) {
            struct sockaddr_in6 mod;
            memcpy(&mod, sin6, sizeof(mod));

            if (inet_pton(AF_INET6, force_addr, &mod.sin6_addr) == 1)
                return orig_bind(sockfd, (struct sockaddr *)&mod, sizeof(mod));

            /* IPv4 address on IPv6 socket: map to ::ffff:x.x.x.x */
            struct in_addr v4;
            if (inet_pton(AF_INET, force_addr, &v4) == 1) {
                memset(&mod.sin6_addr, 0, sizeof(mod.sin6_addr));
                mod.sin6_addr.s6_addr[10] = 0xff;
                mod.sin6_addr.s6_addr[11] = 0xff;
                memcpy(&mod.sin6_addr.s6_addr[12], &v4, 4);
                return orig_bind(sockfd, (struct sockaddr *)&mod, sizeof(mod));
            }
        }
    }

    return orig_bind(sockfd, addr, addrlen);
}
```

**Step 2: Compile**

```bash
gcc -shared -fPIC -o /opt/force_bind.so /opt/force_bind.c -ldl
```

On minimal OS images you may need to install `gcc` and `glibc-devel` (or
`libc6-dev` on Debian/Ubuntu) first.

**Step 3: Create a mysqld wrapper script**

Save as `/opt/mysqld-wrapper.sh` and make it executable (`chmod +x`):

```bash
#!/bin/bash
# Wrapper that injects LD_PRELOAD before starting mysqld.
# FORCE_BIND_ADDRESS must be set in the environment.

if [[ -n "${FORCE_BIND_ADDRESS}" && -f /opt/force_bind.so ]]; then
    export LD_PRELOAD=/opt/force_bind.so
fi

exec /usr/sbin/mysqld "$@"
```

**Step 4: Configure each instance to use the wrapper**

If you manage mysqld through systemd, create an override:

```bash
# For Instance A
systemctl edit mysqld-a
```

Add:

```ini
[Service]
Environment="FORCE_BIND_ADDRESS=192.168.1.10"
ExecStart=
ExecStart=/opt/mysqld-wrapper.sh --defaults-file=/etc/mysql/instance-a.cnf
```

Repeat for Instance B with its own IP.

If you use supervisord or another process manager, set the
`FORCE_BIND_ADDRESS` environment variable and point the command
to the wrapper script.

**Step 5: Verify**

After starting both instances, confirm each listens only on its own IP:

```bash
ss -tlnp | grep 33061
```

Expected output (two lines, each with a specific IP, no wildcards):

```
LISTEN  0  32  192.168.1.10:33061  0.0.0.0:*  users:(("mysqld",pid=...,fd=...))
LISTEN  0  32  192.168.2.10:33061  0.0.0.0:*  users:(("mysqld",pid=...,fd=...))
```

Then verify GR status on each instance:

```sql
SELECT * FROM performance_schema.replication_group_members;
```

All members should show `MEMBER_STATE = ONLINE`.

**Important notes:**

- The IPv4-mapped IPv6 handling (`::ffff:x.x.x.x`) is required because MySQL's
  XCOM opens AF_INET6 sockets even when you configure IPv4 addresses.
- This library intercepts **all** `bind()` calls in the process, not just the
  GR port. The `bind_address` setting for the MySQL client protocol port
  already binds to a specific IP, so the library only changes calls that
  use the wildcard address.
- After any MySQL upgrade or patch, verify that `ss` still shows specific IPs.
  Internal changes to XCOM socket handling could interact with the override.

**Pros:** Allows the same port on all instances. No firewall changes needed.

**Cons:** Requires compiling a C library on each server. Fragile across
MySQL upgrades. Must be revalidated after every patch. Adds operational
complexity to mysqld startup.

### Option 3: Linux Network Namespaces (Enterprise)

Each mysqld instance runs in its own network namespace, giving it a
completely isolated socket table. Port conflicts become impossible because
each namespace has its own `0.0.0.0:33061`.

**Overview of steps:**

1. Create a network namespace for each instance:
   `ip netns add gr-instance-a`
2. Create a veth pair connecting the namespace to the host:
   `ip link add veth-a0 type veth peer name veth-a1`
3. Move one end into the namespace:
   `ip link set veth-a1 netns gr-instance-a`
4. Assign IP addresses and bring up interfaces in both the host and
   the namespace.
5. Configure routing so that GR members across namespaces (and across
   physical hosts) can reach each other.
6. Start mysqld inside the namespace:
   `ip netns exec gr-instance-a /usr/sbin/mysqld --defaults-file=...`

This approach has been validated in a Docker lab environment (test 6),
where both instances reached ONLINE with XCOM binding to wildcard
within each isolated namespace. The detailed routing configuration
depends on your physical network topology, whether you use containers,
and your existing namespace or VLAN layout.

**Pros:** Complete isolation. No library hacks. Survives MySQL upgrades
without revalidation.

**Cons:** Highest operational complexity. Requires privileged access
for namespace creation. Routing configuration can be non-trivial.
May conflict with container runtimes that manage their own namespaces.

## Decision Matrix

| Factor | Different Ports | LD_PRELOAD | Network Namespaces |
|--------|:-:|:-:|:-:|
| Implementation effort | Low | Medium | High |
| Operational risk | None | Medium | Low (once set up) |
| Survives MySQL upgrades | Yes | Must revalidate | Yes |
| Same port across groups | No | Yes | Yes |
| Firewall changes needed | Yes | No | Depends on topology |
| External tooling | None | gcc (one-time build) | ip netns, routing |
| Container-friendly | Yes | Yes | Requires privileged |
| Lab validated | Test 4 | Test 5 | Test 6 |

**Recommendation:**

- **Start with Option 1** (different ports) unless you have a hard requirement
  for identical port numbers across groups. It is the safest and simplest path.
- **Use Option 2** (LD_PRELOAD) if port uniformity is a firm requirement and
  your team is comfortable maintaining a syscall override library.
- **Use Option 3** (network namespaces) for large-scale deployments
  where you already manage network namespaces as part of your infrastructure.
  Validated in test 6.

## Requesting a Percona Server Patch

The root cause is well understood and the fix is low-risk (threading the
configured hostname from `group_replication_local_address` down to the
XCOM socket bind call). If you would like Percona to include a fix in
a future Percona Server release:

1. Open a support ticket at [Percona Support](https://www.percona.com/services/support)
   or through your existing support channel.
2. Reference Oracle Bug [#110773](https://bugs.mysql.com/bug.php?id=110773)
   and the original report [#110591](https://bugs.mysql.com/bug.php?id=110591).
3. Describe your deployment scenario (number of groups per host, port
   requirements, timeline).
4. Mention that the source-level patch involves adding a hostname field
   to the `Network_configuration_parameters` struct and threading it
   through `Xcom_network_provider` to `init_server_addr()` in
   `xcom_network_provider_native_lib.cc`.

Customer demand helps prioritize the backport. The more tickets reference
this bug, the stronger the case for including it in an upcoming release.
