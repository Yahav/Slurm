"""
Seed ColdFront with the example scenario using FRIENDLY limit fields.

This also declutters the allocation attribute types: it removes ColdFront's
example defaults (cloud/storage/billing) and the duplicates, leaving a curated
set — the Slurm "holder" attributes (read by the plugin) plus simple per-limit
fields that admins actually fill in. The cf_slurm_limits hook compiles the
per-limit fields into the holders automatically.

Run:
  docker compose exec -T coldfront coldfront shell < coldfront/seed_scenario.py
"""
from django.contrib.auth import get_user_model

from coldfront.core.resource.models import (
    Resource, ResourceType, ResourceAttribute, ResourceAttributeType,
    AttributeType as ResAttributeType,
)
from coldfront.core.allocation.models import (
    Allocation, AllocationStatusChoice, AllocationAttribute,
    AllocationAttributeType, AllocationUser, AllocationUserStatusChoice,
    AttributeType as AllocAttributeType,
)
from coldfront.core.project.models import (
    Project, ProjectStatusChoice, ProjectUser, ProjectUserRoleChoice,
    ProjectUserStatusChoice,
)
from coldfront.core.field_of_science.models import FieldOfScience

User = get_user_model()
def out(*a): print("[seed]", *a)

text = AllocAttributeType.objects.get_or_create(name="Text")[0]
integer = AllocAttributeType.objects.get_or_create(name="Int")[0]

# NOTE: the curated allocation attribute types (holders + friendly fields) are
# created and kept pruned at every boot by coldfront/configure_attributes.py
# (run from the entrypoint). The seed just uses them by name below.

# --- Cluster resource --------------------------------------------------------
text_res = ResAttributeType.objects.get_or_create(name="Text")[0]
ResourceAttributeType.objects.get_or_create(name="slurm_cluster", defaults={"attribute_type": text_res})
cluster_type = ResourceType.objects.get_or_create(name="Cluster", defaults={"description": "Compute cluster"})[0]
cluster = Resource.objects.get_or_create(name="lab", defaults={"resource_type": cluster_type, "description": "Lab GPU cluster"})[0]
ResourceAttribute.objects.get_or_create(
    resource=cluster, resource_attribute_type=ResourceAttributeType.objects.get(name="slurm_cluster"),
    defaults={"value": "lab"})
out("cluster resource ready")

# --- Users -------------------------------------------------------------------
def make_user(username, first, last, is_pi=False):
    u, _ = User.objects.get_or_create(username=username, defaults={
        "first_name": first, "last_name": last, "email": f"{username}@cluster.local"})
    p = u.userprofile; p.is_pi = is_pi; p.save()
    return u

smith = make_user("smith", "Professor", "Smith", is_pi=True)
jones = make_user("jones", "Professor", "Jones", is_pi=True)
alice = make_user("alice", "Alice", "Student")
bob = make_user("bob", "Bob", "Student")
carol = make_user("carol", "Carol", "Student")

active_proj = ProjectStatusChoice.objects.get_or_create(name="Active")[0]
active_alloc = AllocationStatusChoice.objects.get_or_create(name="Active")[0]
active_au = AllocationUserStatusChoice.objects.get_or_create(name="Active")[0]
role_mgr = ProjectUserRoleChoice.objects.get_or_create(name="Manager")[0]
role_user = ProjectUserRoleChoice.objects.get_or_create(name="User")[0]
active_pu = ProjectUserStatusChoice.objects.get_or_create(name="Active")[0]
fos = FieldOfScience.objects.first() or FieldOfScience.objects.create(description="Other")

def project(title, pi):
    p, _ = Project.objects.get_or_create(title=title, defaults={
        "pi": pi, "description": f"{title} — managed in ColdFront.",
        "field_of_science": fos, "status": active_proj})
    ProjectUser.objects.get_or_create(project=p, user=pi, defaults={"role": role_mgr, "status": active_pu})
    return p

def set_attr(alloc, name, value):
    # update_or_create fires post_save → the cf_slurm_limits hook recompiles.
    AllocationAttribute.objects.update_or_create(
        allocation=alloc, allocation_attribute_type=AllocationAttributeType.objects.get(name=name),
        defaults={"value": str(value)})

storage = Resource.objects.get(name="lab-storage")

def allocation(proj, account, fields, users):
    # Key by the cluster resource (a project may also hold a storage allocation).
    alloc = proj.allocation_set.filter(resources=cluster).first()
    if not alloc:
        alloc = Allocation.objects.create(project=proj, status=active_alloc, justification=f"Slurm account {account}")
        alloc.resources.add(cluster)
    set_attr(alloc, "Slurm Account Name", account)
    for name, val in fields.items():   # friendly fields → hook compiles holders
        set_attr(alloc, name, val)
    for u in users:
        AllocationUser.objects.get_or_create(allocation=alloc, user=u, defaults={"status": active_au})
        ProjectUser.objects.get_or_create(project=proj, user=u, defaults={"role": role_user, "status": active_pu})
    return alloc

def storage_allocation(proj, gb):
    # Modelled only — NOT enforced on any filesystem in the lab (see README).
    alloc = proj.allocation_set.filter(resources=storage).first()
    if not alloc:
        alloc = Allocation.objects.create(project=proj, status=active_alloc, justification="Project storage")
        alloc.resources.add(storage)
    set_attr(alloc, "Storage Quota GB (not enforced)", gb)
    return alloc

# --- The scenario (friendly fields only) -------------------------------------
p_lab = project("Smith Lab (research)", smith)
allocation(p_lab, "smith_lab",
           {"Max CPUs": 12, "Max GPUs": 6, "QOS": "research", "Per-User Max GPUs": 4},
           [smith])
storage_allocation(p_lab, 500)   # demo: Smith Lab gets 500 GB (modelled only)

allocation(project("Smith CS101 (class)", smith), "smith_cs101",
           {"Max CPUs": 4, "Max GPUs": 2, "QOS": "student",
            "Per-User Max GPUs": 1, "Per-User Max Running Jobs": 2},
           [smith, alice, bob])
allocation(project("Jones ML200 (class)", jones), "jones_ml200",
           {"Max CPUs": 4, "Max GPUs": 2, "QOS": "student",
            "Per-User Max GPUs": 1, "Per-User Max Running Jobs": 2},
           [jones, carol])

out("scenario seeded with friendly fields; hook generated the Slurm specs.")
out("DONE — run scripts/sync-coldfront.sh to push into Slurm")
