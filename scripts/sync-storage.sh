#!/usr/bin/env bash
# Storage quota sync — STUB.
#
# Storage quotas are NOT a Slurm function; they're enforced by the filesystem
# (Lustre `lfs setquota`, GPFS `mmsetquota`, or Linux `setquota`). This lab has
# no quota-capable filesystem (/home is a plain Docker volume), so this script
# only PRINTS the commands a real sync would run — it does not change anything.
#
# In production: replace the echo below with the actual quota command for your
# filesystem, run on a host that can administer it, on a cron.
set -euo pipefail
DC="docker compose"

echo ">> Reading storage allocations from ColdFront ..."
PAIRS=$($DC exec -T coldfront coldfront shell -c "
from coldfront.core.allocation.models import Allocation
for a in Allocation.objects.filter(resources__name='lab-storage'):
    gb = a.get_attribute('Storage Quota GB (not enforced)')
    if gb:
        print('STORAGE', a.project.title.split('(')[0].strip().replace(' ','_'), gb)
" 2>/dev/null | grep '^STORAGE ' || true)

if [ -z "$PAIRS" ]; then
  echo "   (no storage allocations found)"
  exit 0
fi

echo "$PAIRS" | while read -r _ group gb; do
  echo "   [STUB — not executed] lfs setquota -g ${group} -B ${gb}G /projects/${group}"
done
echo ">> Done (stub). No filesystem was touched. Wire this to your real quota"
echo "   tool (lfs/mmsetquota/setquota) in production."
