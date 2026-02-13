#!/bin/bash
set -euo pipefail

# build-force-bind.sh - Compile an LD_PRELOAD library that forces bind() to a specific address
#
# When MySQL's Group Replication binds to 0.0.0.0 or ::, this library intercepts
# the bind() syscall and replaces the wildcard address with the IP specified in
# the FORCE_BIND_ADDRESS environment variable.
#
# This is the key workaround tested in test5 to verify whether forcing GR to
# bind to a specific interface resolves the multi-network bind conflict.

C_SOURCE="/tmp/force_bind.c"
SO_OUTPUT="/opt/force_bind.so"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Writing C source to ${C_SOURCE}"

cat > "$C_SOURCE" << 'CSOURCE'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

typedef int (*orig_bind_t)(int sockfd, const struct sockaddr *addr, socklen_t addrlen);

static const char* get_force_addr(void) {
    return getenv("FORCE_BIND_ADDRESS");
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    orig_bind_t orig_bind = (orig_bind_t)dlsym(RTLD_NEXT, "bind");
    if (!orig_bind) {
        fprintf(stderr, "force_bind: dlsym failed\n");
        return -1;
    }

    const char *force_addr = get_force_addr();
    if (!force_addr || force_addr[0] == '\0') {
        return orig_bind(sockfd, addr, addrlen);
    }

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
                        ntohs(modified.sin6_port), mapped, ntohs(modified.sin6_port), force_addr);
                return orig_bind(sockfd, (struct sockaddr *)&modified, sizeof(modified));
            }
        }
    }

    return orig_bind(sockfd, addr, addrlen);
}
CSOURCE

log "Compiling ${SO_OUTPUT}"

# Install gcc if not present (Oracle Linux / percona-server image)
if ! command -v gcc &>/dev/null; then
    log "gcc not found, installing..."
    if command -v dnf &>/dev/null; then
        dnf install -y gcc glibc-devel
    elif command -v yum &>/dev/null; then
        yum install -y gcc glibc-devel
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y gcc libc6-dev
    else
        log "ERROR: No package manager found to install gcc"
        exit 1
    fi
fi

gcc -shared -fPIC -o "$SO_OUTPUT" "$C_SOURCE" -ldl

log "Built successfully: ${SO_OUTPUT}"
log "Usage: FORCE_BIND_ADDRESS=172.30.1.x LD_PRELOAD=${SO_OUTPUT} mysqld ..."
