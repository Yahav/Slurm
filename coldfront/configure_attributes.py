"""
Curate the allocation attribute types: ensure our friendly set exists and
prune everything else. Run on EVERY ColdFront boot (from the entrypoint),
right after add_allocation_defaults — which recreates ColdFront's example
attribute types each start, so a one-time cleanup wouldn't stick.
"""
from coldfront.core.allocation.models import AllocationAttributeType, AttributeType
from coldfront.core.field_of_science.models import FieldOfScience
from coldfront.core.project.models import Project
from coldfront.core.resource.models import Resource, ResourceType
from coldfront.core.utils.common import import_from_settings

# Name of the storage-quota field. It is MODELLED ONLY — no filesystem is wired
# up in the lab, so the label says so (see scripts/sync-storage.sh + README).
STORAGE_QUOTA_FIELD = "Storage Quota GB (not enforced)"

# Holder names come from settings so they stay in lockstep with the hook/plugin.
ACCOUNT_NAME = import_from_settings("SLURM_ACCOUNT_ATTRIBUTE_NAME", "slurm_account_name")
GROUP_NAME = import_from_settings("SLURM_SPECS_ATTRIBUTE_NAME", "slurm_specs")
USER_NAME = import_from_settings("SLURM_USER_SPECS_ATTRIBUTE_NAME", "slurm_user_specs")
PARENT_NAME = import_from_settings("SLURM_PARENT_ATTRIBUTE_NAME", "slurm_parent")

# Collapse Field of Science to a single default option. We don't load
# ColdFront's full NSF hierarchy (see entrypoint), but old rows may linger.
# Reassign any projects to the default FIRST (Project.field_of_science is
# on_delete=CASCADE), THEN prune the rest — so we never cascade-delete projects.
default_fos, _ = FieldOfScience.objects.update_or_create(
    pk=FieldOfScience.DEFAULT_PK, defaults={"description": "N/A"})
Project.objects.exclude(field_of_science=default_fos).update(field_of_science=default_fos)
FieldOfScience.objects.exclude(pk=FieldOfScience.DEFAULT_PK).delete()

text = AttributeType.objects.get_or_create(name="Text")[0]
integer = AttributeType.objects.get_or_create(name="Int")[0]

# (name, attribute_type, is_private). The two limit holders are auto-generated
# by the cf_slurm_limits hook — their "(Generated)" labels come from settings.
HOLDERS = [
    (ACCOUNT_NAME, text, False),
    (GROUP_NAME, text, True),
    (USER_NAME, text, True),
    (PARENT_NAME, text, False),
]
FRIENDLY = [
    # --- group (account-wide) ---
    ("Max CPUs", integer), ("Max GPUs", integer), ("Max Memory (GB)", integer),
    ("Max Nodes", integer),
    ("Max CPU-hours", integer), ("Max GPU-hours", integer),
    ("Max Running Jobs", integer), ("Max Submitted Jobs", integer),
    ("Max Total Walltime (hours)", integer), ("Fairshare Shares", integer),
    ("QOS", text),
    # --- per-user (each member) ---
    ("Per-User Max CPUs", integer), ("Per-User Max GPUs", integer),
    ("Per-User Max Memory (GB)", integer),
    ("Per-Job Max CPUs", integer), ("Per-Job Max GPUs", integer),
    ("Per-User Max Running Jobs", integer), ("Per-User Max Submitted Jobs", integer),
    ("Per-User Max Walltime per Job (hours)", integer),
    # --- storage (modelled only; enforced by the filesystem in production) ---
    (STORAGE_QUOTA_FIELD, integer),
]
KEEP = {n for n, *_ in HOLDERS} | {n for n, _ in FRIENDLY}

# Prune everything not in our curated set (the example defaults + the lowercase
# slurm_* duplicates + any old holder names from before a rename). These carry
# no data we depend on (holders are regenerated below), so deletion is safe.
removed = AllocationAttributeType.objects.exclude(name__in=KEEP).delete()

for name, atype, priv in HOLDERS:
    AllocationAttributeType.objects.update_or_create(
        name=name, defaults={"attribute_type": atype, "is_private": priv})
for name, atype in FRIENDLY:
    AllocationAttributeType.objects.update_or_create(
        name=name, defaults={"attribute_type": atype, "is_private": False})

# Storage resource — projects can hold a storage allocation here. It has NO
# slurm_cluster attribute, so slurm_dump ignores it; enforcement (if any) is a
# separate filesystem step (scripts/sync-storage.sh, a stub in this lab).
storage_type = ResourceType.objects.get_or_create(
    name="Storage", defaults={"description": "Project storage"})[0]
Resource.objects.get_or_create(
    name="lab-storage",
    defaults={"resource_type": storage_type,
              "description": "Project storage — quota is NOT enforced in the lab (see README)"})

# Regenerate the (renamed) holder attributes from each allocation's friendly
# fields — so the generated values are always present/current after a boot or
# a rename, without needing to re-seed.
try:
    from cf_slurm_limits.signals import recompile
    from coldfront.core.allocation.models import Allocation
    n = 0
    for a in Allocation.objects.all():
        recompile(a); n += 1
    print(f"[configure_attributes] recompiled {n} allocation(s)")
except Exception as e:  # noqa: BLE001
    print("[configure_attributes] recompile skipped:", e)

print("[configure_attributes] pruned:", removed, "| kept:", sorted(KEEP))
