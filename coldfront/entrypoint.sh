#!/bin/bash
# ColdFront startup: wait for DB, migrate, load initial lookup data, ensure an
# admin superuser exists, then run the server.
set -e

export COLDFRONT_CONFIG=/etc/coldfront/local_settings.py

echo "[coldfront] waiting for postgres ..."
until nc -z coldfront-db 5432; do sleep 1; done
echo "[coldfront] postgres is up."

echo "[coldfront] collecting static assets ..."
coldfront collectstatic --noinput >/dev/null 2>&1 || true

echo "[coldfront] migrating database ..."
coldfront migrate --noinput

# NOTE: `coldfront initial_setup` is INTERACTIVE (prompts on stdin) and is
# all-or-nothing — if any sub-step fails it aborts the rest. With no TTY it
# hits EOFError and silently does nothing. So we run its idempotent, non-
# interactive sub-commands directly instead. Each uses get_or_create, so
# re-running on restart is safe.
echo "[coldfront] loading initial lookup data ..."
# NOTE: import_field_of_science_data is intentionally OMITTED — it runs
# `FieldOfScience.objects.all().delete()` every boot, and Project.field_of_science
# is on_delete=CASCADE, so it would wipe all projects/allocations on every
# restart. configure_attributes.py instead ensures a single default
# FieldOfScience exists (also declutters that dropdown to one option).
for cmd in \
    add_default_grant_options \
    add_default_project_choices \
    add_resource_defaults \
    add_allocation_defaults \
    add_default_publication_sources \
    add_scheduled_tasks ; do
    coldfront "$cmd" >/dev/null 2>&1 || echo "   (warn: $cmd reported an issue — usually 'already exists')"
done

# Curate allocation attribute types: add_allocation_defaults (above) recreates
# ColdFront's example attribute types every boot, so prune them back to our
# friendly set here — otherwise the "Add Attribute" dropdown re-clutters.
echo "[coldfront] curating allocation attribute types ..."
coldfront shell < /opt/configure_attributes.py 2>/dev/null | grep configure_attributes || true

# Ensure a local admin superuser (admin / admin) for the GUI.
echo "[coldfront] ensuring admin superuser ..."
coldfront shell -c "
from django.contrib.auth import get_user_model
U = get_user_model()
if not U.objects.filter(username='admin').exists():
    U.objects.create_superuser('admin', 'admin@cluster.local', 'admin')
    print('created admin/admin')
else:
    print('admin already exists')
" || true

echo "[coldfront] starting server on :8000 ..."
exec coldfront runserver 0.0.0.0:8000
