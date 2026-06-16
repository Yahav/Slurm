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
        sssd sssd-ldap libnss-sss libpam-sss ldap-utils \
        openssh-server python3-pip \
    && rm -rf /var/lib/apt/lists/*

# --- Jupyter (for the Open OnDemand interactive app on compute nodes) --------
RUN pip3 install --no-cache-dir jupyterlab

# --- Passwordless SSH for the OOD Shell app ---------------------------------
# A single keypair baked into /etc/skel so every user's home (created from skel)
# can SSH to the login node without a password. Lab-only convenience.
RUN mkdir -p /etc/skel/.ssh && \
    ssh-keygen -t ed25519 -N "" -f /etc/skel/.ssh/id_ed25519 -C "lab-shared" && \
    cp /etc/skel/.ssh/id_ed25519.pub /etc/skel/.ssh/authorized_keys && \
    printf 'Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n' > /etc/skel/.ssh/config && \
    chmod 700 /etc/skel/.ssh && chmod 600 /etc/skel/.ssh/* && \
    mkdir -p /run/sshd

# --- Identity: route NSS through SSSD so LDAP users resolve cluster-wide -----
# sssd.conf must be 0600 root; nsswitch tells glibc to consult sss. The
# entrypoint starts sssd once LDAP is reachable.
COPY sssd/sssd.conf /etc/sssd/sssd.conf
COPY sssd/nsswitch.conf /etc/nsswitch.conf
RUN chmod 0600 /etc/sssd/sssd.conf && chown root:root /etc/sssd/sssd.conf && \
    sed -i 's/^session.*pam_unix.so.*/&\nsession optional pam_mkhomedir.so skel=\/etc\/skel umask=0022/' /etc/pam.d/common-session

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
