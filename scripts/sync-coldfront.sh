#!/usr/bin/env bash
# Sync ColdFront -> Slurm. This is what ColdFront's plugin does in production
# (typically on a cron): export the allocation/association data and load it
# into slurmdbd via sacctmgr.
#
#   1. ensure the QOS tiers referenced by allocations exist (student/research)
#   2. coldfront slurm_dump  -> /shared/<cluster>.cfg
#   3. sacctmgr load that file on the controller
#   4. set each project's PI as the Slurm *coordinator* of its account
#      (so researchers can monitor/manage their students) — driven by ColdFront
#
# Usage:  ./scripts/sync-coldfront.sh
set -euo pipefail
DC="docker compose"

echo ">> [1/4] ensuring QOS tiers exist"
$DC exec -T slurmctld bash -lc '
  sacctmgr -i add qos research Priority=1000 MaxWallDurationPerJob=2-00:00:00 2>/dev/null || true
  sacctmgr -i add qos student  Priority=100  MaxWallDurationPerJob=04:00:00 Flags=DenyOnLimit 2>/dev/null || true
  echo "   qos: $(sacctmgr -n show qos format=name%-12 | tr "\n" " ")"
'

echo ">> [2/4] exporting ColdFront allocations (slurm_dump)"
$DC exec -T coldfront bash -lc 'rm -f /shared/*.cfg; coldfront slurm_dump -o /shared >/dev/null; echo "   wrote: $(ls /shared/*.cfg)"'

echo ">> [3/4] loading associations into slurmdbd (sacctmgr load)"
# Load every cluster file ColdFront produced. (Additive; add the word "clean"
# to make ColdFront fully authoritative and remove accounts not in the file.)
for f in $($DC exec -T coldfront bash -lc 'ls /shared/*.cfg'); do
  f=$(echo "$f" | tr -d "\r")
  echo "   loading $f"
  $DC exec -T slurmctld bash -lc "sacctmgr -i load file=$f" || true
done

echo ">> [4/4] setting PIs as account coordinators (from ColdFront projects)"
# Ask ColdFront which user is PI of each slurm account, then grant coordinator.
# Sentinel-prefix each pair so shell_plus import noise doesn't get parsed.
PAIRS=$($DC exec -T coldfront coldfront shell -c "
from coldfront.core.allocation.models import AllocationAttribute
seen=set()
for a in AllocationAttribute.objects.filter(allocation_attribute_type__name='Slurm Account Name'):
    acct=a.value; pi=a.allocation.project.pi.username
    if (acct,pi) not in seen:
        seen.add((acct,pi)); print('COORD', acct, pi)
" 2>/dev/null | grep -E "^COORD " || true)

# Note the `< /dev/null` on the exec: otherwise docker exec swallows the loop's
# stdin and only the first iteration runs.
while read -r _ acct pi; do
  [ -z "${acct:-}" ] && continue
  echo "   coordinator: $pi -> $acct"
  $DC exec -T slurmctld bash -lc "sacctmgr -i add coordinator account=$acct names=$pi" </dev/null >/dev/null 2>&1 || true
done <<< "$PAIRS"

echo ">> done. Verify with:  docker compose exec slurmctld sacctmgr show assoc format=Account,User,QOS,GrpTRES,MaxTRESPU tree"
