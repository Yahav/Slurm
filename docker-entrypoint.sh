#!/bin/bash
# Decides which Slurm daemon this container runs, based on the first argument
# passed from docker-compose. Every container first starts munged (the auth
# daemon), then waits for whatever it depends on, then execs its daemon.
set -euo pipefail

ROLE="${1:-login}"

log() { echo "[entrypoint:${ROLE}] $*"; }

# Wait until host:port accepts a TCP connection.
wait_for() {
    local host="$1" port="$2" name="${3:-$1:$2}"
    log "waiting for ${name} ..."
    until nc -z "$host" "$port" 2>/dev/null; do
        sleep 1
    done
    log "${name} is up."
}

start_munge() {
    # Volumes can reset ownership/perms on bind, so re-assert them here.
    chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge 2>/dev/null || true
    mkdir -p /run/munge && chown munge:munge /run/munge
    chmod 0700 /etc/munge
    chmod 0400 /etc/munge/munge.key
    log "starting munged"
    runuser -u munge -- /usr/sbin/munged
    # Give munged a moment and sanity-check it.
    sleep 1
    munge -n | unmunge >/dev/null && log "munge OK"
}

# Copy configs from the read-only bind mount into an image-local, writable
# dir so we can set the ownership/permissions Slurm requires (slurmdbd.conf
# in particular must be 0600 owned by SlurmUser). Copying also avoids Docker
# Desktop bind-mount permission quirks on Windows/macOS hosts.
stage_config() {
    mkdir -p /etc/slurm
    if [[ -d /etc/slurm-host ]]; then
        cp -f /etc/slurm-host/*.conf /etc/slurm/ 2>/dev/null || true
    fi
    if [[ -f /etc/slurm/slurmdbd.conf ]]; then
        chown slurm:slurm /etc/slurm/slurmdbd.conf
        chmod 600 /etc/slurm/slurmdbd.conf
    fi
}

fix_perms() {
    chown -R slurm:slurm /var/spool/slurmctld /var/log/slurm /run/slurm 2>/dev/null || true
}

# Start SSSD so LDAP users resolve via NSS (id/getpwnam). Needs the directory
# reachable first. Used by every node that must resolve users: the controller
# (loads associations by name→uid), compute nodes (run jobs as the user), and
# the login host (submit + interactive login).
start_sssd() {
    if [[ ! -f /etc/sssd/sssd.conf ]]; then
        return 0
    fi
    wait_for openldap 389 "OpenLDAP"
    chown root:root /etc/sssd/sssd.conf
    chmod 0600 /etc/sssd/sssd.conf
    mkdir -p /var/lib/sss/db /var/lib/sss/pipes /var/log/sssd
    log "starting sssd"
    /usr/sbin/sssd
    # Wait until at least one known LDAP user resolves.
    for _ in $(seq 1 20); do
        if getent passwd hpcadmin >/dev/null 2>&1; then
            log "sssd OK — LDAP users resolve"
            return 0
        fi
        sleep 1
    done
    log "WARNING: sssd started but LDAP users not resolving yet"
}

# Pre-create home dirs on the shared /home volume for every LDAP user, so jobs
# launched by slurmd (which doesn't go through PAM/mkhomedir) have a home.
create_ldap_homes() {
    getent passwd | awk -F: '$3>=6000 && $3<65000 {print $1":"$3":"$4":"$6}' | \
    while IFS=: read -r name uid gid home; do
        [[ -z "$home" ]] && continue
        if [[ ! -d "$home" ]]; then
            mkdir -p "$home"
            cp -an /etc/skel/. "$home/" 2>/dev/null || true
        fi
        # Backfill the SSH key into pre-existing homes (for the OOD Shell app).
        if [[ ! -d "$home/.ssh" ]]; then
            cp -an /etc/skel/.ssh "$home/" 2>/dev/null || true
        fi
        chown -R "$uid:$gid" "$home"
        chmod 0700 "$home" "$home/.ssh" 2>/dev/null || true
    done
}

start_munge
stage_config
fix_perms

case "$ROLE" in
    slurmdbd)
        # slurmdbd authorizes sacctmgr requests (incl. the coordinator check),
        # so it must resolve the caller's uid→username via LDAP too.
        start_sssd
        wait_for mysql 3306 "MariaDB"
        log "starting slurmdbd"
        exec slurmdbd -D -vvv
        ;;

    slurmctld)
        start_sssd
        wait_for slurmdbd 6819 "slurmdbd"
        # Register this cluster in the accounting DB (idempotent).
        log "registering cluster in accounting db"
        sacctmgr -i add cluster lab 2>/dev/null || true
        log "starting slurmctld"
        exec slurmctld -D -vvv
        ;;

    slurmd)
        # Create fake GPU device files. Slurm's gpu GRES plugin ignores
        # file-less GPUs, so we need real device nodes for gres.conf's File=
        # to point at. mknod works in a default (unprivileged) container
        # because Docker grants the MKNOD capability; touch is the fallback.
        for i in 0 1; do
            if [[ ! -e "/dev/fakegpu${i}" ]]; then
                mknod "/dev/fakegpu${i}" c 195 "${i}" 2>/dev/null || touch "/dev/fakegpu${i}"
            fi
        done
        start_sssd
        wait_for slurmctld 6817 "slurmctld"
        log "starting slurmd as node $(hostname)"
        exec slurmd -D -vvv -N "$(hostname)"
        ;;

    login)
        start_sssd
        create_ldap_homes
        # sshd so the Open OnDemand Shell app can SSH in as the user (pubkey).
        ssh-keygen -A 2>/dev/null || true
        mkdir -p /run/sshd
        /usr/sbin/sshd && log "sshd started"
        wait_for slurmctld 6817 "slurmctld"
        log "login node ready. Use: docker compose exec login bash"
        # Keep the container alive.
        exec sleep infinity
        ;;

    *)
        log "unknown role '$ROLE' — exec'ing it directly"
        exec "$@"
        ;;
esac
