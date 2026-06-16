"""
Compile friendly per-limit allocation attributes into the slurm_specs /
slurm_user_specs holders that ColdFront's Slurm plugin reads.

Covers the common Slurm *association* limits at both levels:
  GROUP (account)   → "Slurm Group Limits (Generated)"
  PER-USER (member) → "Slurm Per-User Limits (Generated)"

Admins fill simple numeric fields; this hook assembles the sacctmgr strings.
"""
import logging

from django.db.models.signals import post_save, post_delete
from django.dispatch import receiver

from coldfront.core.allocation.models import AllocationAttribute, AllocationAttributeType
from coldfront.core.utils.common import import_from_settings

logger = logging.getLogger(__name__)

SPECS_NAME = import_from_settings("SLURM_SPECS_ATTRIBUTE_NAME", "slurm_specs")
USER_SPECS_NAME = import_from_settings("SLURM_USER_SPECS_ATTRIBUTE_NAME", "slurm_user_specs")

# --- GROUP (account-wide) field → spec mappings ------------------------------
GROUP_TRES = {                       # combined into one GrpTRES=
    "Max CPUs": "cpu", "Max GPUs": "gres/gpu",
    "Max Memory (GB)": "mem", "Max Nodes": "node",
}
GROUP_TRESMINS = {                   # combined into one GrpTRESMins= (hours→min)
    "Max CPU-hours": "cpu", "Max GPU-hours": "gres/gpu",
}
GROUP_SCALAR = {                     # field → sacctmgr key (value used as-is)
    "Max Running Jobs": "GrpJobs",
    "Max Submitted Jobs": "GrpSubmitJobs",
    "Fairshare Shares": "Fairshare",
}
GROUP_WALL = "Max Total Walltime (hours)"   # → GrpWall=H:00:00

# --- PER-USER (each member) field → spec mappings ----------------------------
USER_TRES = {                        # concurrent, combined into GrpTRES=
    "Per-User Max CPUs": "cpu", "Per-User Max GPUs": "gres/gpu",
    "Per-User Max Memory (GB)": "mem",
}
USER_MAXTRES_PERJOB = {              # combined into MaxTRESPerJob=
    "Per-Job Max CPUs": "cpu", "Per-Job Max GPUs": "gres/gpu",
}
USER_SCALAR = {
    "Per-User Max Running Jobs": "MaxJobs",
    "Per-User Max Submitted Jobs": "MaxSubmitJobs",
}
USER_WALL = "Per-User Max Walltime per Job (hours)"  # → MaxWallDurationPerJob

QOS_FIELD = "QOS"   # applied to both group and per-user

FRIENDLY_FIELDS = (
    set(GROUP_TRES) | set(GROUP_TRESMINS) | set(GROUP_SCALAR) | {GROUP_WALL}
    | set(USER_TRES) | set(USER_MAXTRES_PERJOB) | set(USER_SCALAR) | {USER_WALL}
    | {QOS_FIELD}
)
MANAGED_OUTPUTS = {SPECS_NAME, USER_SPECS_NAME}


def _val(allocation, name):
    a = AllocationAttribute.objects.filter(
        allocation=allocation, allocation_attribute_type__name=name).first()
    if not a or a.value in (None, ""):
        return None
    return str(a.value).strip()


def _write(allocation, type_name, values):
    att = AllocationAttributeType.objects.filter(name=type_name).first()
    if not att:
        logger.warning("cf_slurm_limits: missing attribute type %s", type_name)
        return
    AllocationAttribute.objects.filter(
        allocation=allocation, allocation_attribute_type=att).delete()
    for v in values:
        AllocationAttribute.objects.create(
            allocation=allocation, allocation_attribute_type=att, value=v)


def _tres(allocation, mapping):
    parts = []
    for field, key in mapping.items():
        v = _val(allocation, field)
        if v:
            parts.append(f"{key}={v}G" if key == "mem" else f"{key}={v}")
    return ",".join(parts)


def recompile(allocation):
    qos = _val(allocation, QOS_FIELD)

    # ----- GROUP (account) -----
    specs = []
    grp = _tres(allocation, GROUP_TRES)
    if grp:
        specs.append("GrpTRES=" + grp)
    mins = [f"{key}={int(float(_val(allocation, f)) * 60)}"
            for f, key in GROUP_TRESMINS.items() if _val(allocation, f)]
    if mins:
        specs.append("GrpTRESMins=" + ",".join(mins))
    for field, key in GROUP_SCALAR.items():
        v = _val(allocation, field)
        if v:
            specs.append(f"{key}={v}")
    gw = _val(allocation, GROUP_WALL)
    if gw:
        # Plain minutes — colons (HH:MM:SS) collide with the colon-delimited
        # sacctmgr load-file format.
        specs.append(f"GrpWall={int(float(gw) * 60)}")
    if qos:
        specs.append(f"QOS={qos}")
    _write(allocation, SPECS_NAME, specs)

    # ----- PER-USER (member) -----
    uspecs = []
    ut = _tres(allocation, USER_TRES)
    if ut:
        uspecs.append("GrpTRES=" + ut)
    mpj = _tres(allocation, USER_MAXTRES_PERJOB)
    if mpj:
        uspecs.append("MaxTRESPerJob=" + mpj)
    for field, key in USER_SCALAR.items():
        v = _val(allocation, field)
        if v:
            uspecs.append(f"{key}={v}")
    uw = _val(allocation, USER_WALL)
    if uw:
        uspecs.append(f"MaxWallDurationPerJob={int(float(uw) * 60)}")
    if qos:
        uspecs.append(f"QOS={qos}")
    _write(allocation, USER_SPECS_NAME, uspecs)

    logger.info("cf_slurm_limits: recompiled allocation %s", allocation.pk)


@receiver(post_save, sender=AllocationAttribute)
def _on_save(sender, instance, **kwargs):
    name = instance.allocation_attribute_type.name
    if name in MANAGED_OUTPUTS:
        return
    if name in FRIENDLY_FIELDS:
        recompile(instance.allocation)


@receiver(post_delete, sender=AllocationAttribute)
def _on_delete(sender, instance, **kwargs):
    try:
        name = instance.allocation_attribute_type.name
    except Exception:
        return
    if name in FRIENDLY_FIELDS:
        recompile(instance.allocation)
