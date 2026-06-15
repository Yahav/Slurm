# Single image used by every container in the cluster (controller, dbd,
# login, compute). Each container just runs a different daemon via the
# entrypoint. Building Slurm from source so we control the exact version.
FROM ubuntu:22.04

# Change this to any version published at https://download.schedmd.com/slurm/
ARG SLURM_VERSION=24.11.5

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/sbin:/usr/local/bin:$PATH

# --- Build + runtime dependencies -------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        wget \
        bzip2 \
        munge libmunge-dev libmunge2 \
        default-libmysqlclient-dev \
        mariadb-client \
        libssl-dev \
        libpam0g-dev \
        libjson-c-dev \
        libyaml-dev \
        libjwt-dev \
        libhwloc-dev \
        libcurl4-openssl-dev \
        python3 \
        gettext-base \
        iproute2 \
        netcat-openbsd \
        vim less \
    && rm -rf /var/lib/apt/lists/*

# --- Consistent users across all nodes --------------------------------------
# slurm user must have the same UID everywhere. We also add a normal "lab"
# user to submit jobs as a non-root account.
RUN groupadd -g 990 slurm && \
    useradd  -m -u 990 -g 990 -s /bin/bash slurm && \
    groupadd -g 1000 lab && \
    useradd  -m -u 1000 -g 1000 -s /bin/bash lab && \
    echo 'lab:lab' | chpasswd

# --- Build Slurm from source ------------------------------------------------
RUN cd /tmp && \
    wget -q "https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2" && \
    tar xjf "slurm-${SLURM_VERSION}.tar.bz2" && \
    cd "slurm-${SLURM_VERSION}" && \
    ./configure \
        --prefix=/usr/local \
        --sysconfdir=/etc/slurm \
        --enable-multiple-slurmd \
        --with-mysql_config=/usr/bin && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig && \
    cd /tmp && rm -rf "slurm-${SLURM_VERSION}" "slurm-${SLURM_VERSION}.tar.bz2"

# --- Runtime directories -----------------------------------------------------
RUN mkdir -p /etc/slurm \
             /var/spool/slurmctld \
             /var/spool/slurmd \
             /var/log/slurm \
             /run/slurm && \
    chown -R slurm:slurm /var/spool/slurmctld /var/log/slurm /run/slurm && \
    chown -R root:root  /var/spool/slurmd

# --- Munge auth key ----------------------------------------------------------
# Baked into the shared image so every container has an identical key, which
# is exactly what munge requires for inter-node authentication. Fine for a lab;
# never do this in production (the key would be public in the image).
RUN dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null && \
    chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge && \
    chmod 0700 /etc/munge && \
    chmod 0400 /etc/munge/munge.key

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["login"]
