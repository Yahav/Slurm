# Open OnDemand portal.
# Built FROM the Slurm image so it already has the slurm client binaries,
# the shared munge key, SSSD, and ldap tooling — exactly what OOD needs to
# submit jobs as the logged-in user and resolve LDAP identities.
FROM slurm-lab:local

ENV DEBIAN_FRONTEND=noninteractive

# Install the latest OnDemand 3.1 release for jammy, then the portal + Dex.
# The release deb just configures the apt repo; we resolve its exact filename
# dynamically so we don't pin a patch version that may rotate.
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg apt-transport-https openssh-client && \
    REL=$(curl -fsSL https://apt.osc.edu/ondemand/3.1/ \
            | grep -oE 'ondemand-release-web_3\.1\.[0-9]+-jammy_all\.deb' | sort -V | tail -1) && \
    echo "Installing OOD release: $REL" && \
    curl -fsSL -o /tmp/ood-release.deb "https://apt.osc.edu/ondemand/3.1/$REL" && \
    apt-get install -y /tmp/ood-release.deb && \
    apt-get update && \
    apt-get install -y ondemand ondemand-dex && \
    rm -f /tmp/ood-release.deb && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/ood-entrypoint.sh
RUN chmod +x /usr/local/bin/ood-entrypoint.sh

EXPOSE 8050 5556
ENTRYPOINT ["/usr/local/bin/ood-entrypoint.sh"]
