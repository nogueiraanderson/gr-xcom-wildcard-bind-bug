FROM percona/percona-server:8.4

# Switch to root for package installation and privileged operations
USER root

# Install required tools:
# - net-tools/iproute: ifconfig, ip addr for network interface inspection
# - strace/procps: runtime debugging (strace bind() calls, ps)
# - gcc/glibc-devel: compile force_bind.c (LD_PRELOAD .so for bind address override)
# - python3 + pip: supervisord (not in Oracle Linux repos, installed via pip)
RUN microdnf install -y \
        net-tools \
        iproute \
        strace \
        procps-ng \
        gcc \
        glibc-devel \
        python3 \
        python3-pip \
    && microdnf clean all \
    && pip3 install supervisor

# Create directories for logs, data, sockets, and evidence collection
RUN mkdir -p /var/log/mysql /var/run/mysqld \
    && mkdir -p /var/lib/mysql-a /var/lib/mysql-b \
    && mkdir -p /opt/scripts /opt/evidence \
    && mkdir -p /etc/mysql/conf.d/custom-src /etc/mysql/conf.d/custom \
    && chown -R mysql:mysql /var/lib/mysql-a /var/lib/mysql-b \
        /var/log/mysql /var/run/mysqld /etc/mysql/conf.d/custom

# Copy MySQL configs into the image (source configs, entrypoint copies to writable dir)
# Build context is the project root, so paths are relative to gr-bind-bug/
COPY config/ /etc/mysql/conf.d/custom-src/

# Copy helper scripts and make executable
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Copy supervisord configuration
COPY docker/supervisord.conf /etc/supervisord.conf

# Copy entrypoint and set execute permission
COPY docker/entrypoint.sh /opt/entrypoint.sh
RUN chmod 755 /opt/entrypoint.sh

# Expose both MySQL instance ports and GR ports
EXPOSE 3306 3307 33061 33062

ENTRYPOINT ["/opt/entrypoint.sh"]
