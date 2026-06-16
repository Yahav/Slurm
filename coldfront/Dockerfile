# ColdFront — the allocation-management web portal (Django).
# Authenticates users against LDAP, and its Slurm plugin exports the
# account/association/limit data for sacctmgr to load into slurmdbd.
FROM python:3.11-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DJANGO_SETTINGS_MODULE=coldfront.config.settings

# Build deps for python-ldap (libldap/libsasl) and psycopg2 (libpq).
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        libldap2-dev \
        libsasl2-dev \
        libpq-dev \
        netcat-openbsd \
        ldap-utils \
    && rm -rf /var/lib/apt/lists/*

# ColdFront + the LDAP auth backend + Postgres driver.
RUN pip install --no-cache-dir \
        coldfront \
        django-auth-ldap \
        python-ldap \
        psycopg2-binary

# ColdFront's ldap_user_search plugin (used by the GUI "add users" search)
# imports ldap3 — separate layer so it doesn't re-pull coldfront on rebuild.
RUN pip install --no-cache-dir ldap3

# Our settings overrides are included by ColdFront via the COLDFRONT_CONFIG env
# var (set in the entrypoint). Do NOT also copy into the package config dir —
# ColdFront would then include it twice, double-running non-idempotent lines.
COPY local_settings.py /etc/coldfront/local_settings.py

# Our hook app (compiles friendly limit fields → slurm_specs). Installed onto
# the Python path so INSTALLED_APPS += ["cf_slurm_limits"] resolves.
COPY cf_slurm_limits /usr/local/lib/python3.11/site-packages/cf_slurm_limits

# Boot-time attribute-type curation (prunes the example defaults each start).
COPY configure_attributes.py /opt/configure_attributes.py

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
