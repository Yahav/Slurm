#!/bin/bash
# Open OnDemand entrypoint.
# Brings up the same identity/auth plumbing the cluster uses (munge + SSSD),
# stages the Slurm config (for the slurm job adapter), regenerates the portal
# config from ood_portal.yml, then runs Dex (OIDC, LDAP-backed) + Apache.
# NOTE: deliberately NOT using `set -u` — sourcing /etc/apache2/envvars below
# references unset vars and would abort under nounset.
set -eo pipefail
log() { echo "[ood] $*"; }

wait_for() { local h="$1" p="$2"; log "waiting for $h:$p"; until nc -z "$h" "$p" 2>/dev/null; do sleep 1; done; }

# --- munge (so the slurm client can authenticate to the cluster) ------------
chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge 2>/dev/null || true
mkdir -p /run/munge && chown munge:munge /run/munge
chmod 0700 /etc/munge && chmod 0400 /etc/munge/munge.key
runuser -u munge -- /usr/sbin/munged
log "munge started"

# --- SSSD (resolve LDAP users; PUNs setuid to them) -------------------------
if [[ -f /etc/sssd/sssd.conf ]]; then
    chown root:root /etc/sssd/sssd.conf; chmod 0600 /etc/sssd/sssd.conf
    mkdir -p /var/lib/sss/db /var/lib/sss/pipes /var/log/sssd
    wait_for openldap 389
    /usr/sbin/sssd
    for _ in $(seq 1 20); do getent passwd smith >/dev/null 2>&1 && break; sleep 1; done
    log "sssd started ($(getent passwd smith >/dev/null 2>&1 && echo 'LDAP ok' || echo 'LDAP NOT resolving'))"
fi

# --- stage Slurm config for the job adapter ---------------------------------
mkdir -p /etc/slurm
[[ -d /etc/slurm-host ]] && cp -f /etc/slurm-host/*.conf /etc/slurm/ 2>/dev/null || true

# --- generate the portal (apache vhost + dex config) from ood_portal.yml ----
log "running update_ood_portal"
/opt/ood/ood-portal-generator/sbin/update_ood_portal || update_ood_portal || true

# update_ood_portal writes the vhost on *:8050 but doesn't add a matching
# Listen directive, so tell apache to actually bind 8050. (We keep internal =
# external port so OIDC redirect URIs line up.) Drop the default :80 site.
grep -q "Listen 8050" /etc/apache2/ports.conf || echo "Listen 8050" >> /etc/apache2/ports.conf
a2dissite 000-default >/dev/null 2>&1 || true

# --- Dex (OIDC provider backed by LDAP) -------------------------------------
# update_ood_portal writes /etc/ood/dex/config.yaml from ood_portal.yml's dex:
if [[ -f /etc/ood/dex/config.yaml ]]; then
    chown -R _dex:_dex /etc/ood/dex 2>/dev/null || true
    log "starting ondemand-dex"
    ( /usr/sbin/ondemand-dex serve /etc/ood/dex/config.yaml 2>&1 | sed 's/^/[dex] /' ) &
fi

# --- Apache (the portal itself), in the foreground --------------------------
wait_for slurmctld 6817
log "slurmctld reachable; preparing apache"
set +e   # apache's envvars + foreground exit shouldn't abort the script
. /etc/apache2/envvars 2>/dev/null || true
rm -f /run/apache2/apache2.pid 2>/dev/null || true
log "starting apache (portal on :8050)"
apache2 -D FOREGROUND
code=$?
log "APACHE EXITED code=$code — dumping apache logs:"
for f in /var/log/apache2/*.log; do echo "--- $f ---"; tail -25 "$f" 2>/dev/null; done
exec sleep infinity
