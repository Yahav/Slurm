# Slurm + LDAP + ColdFront lab

A fully simulated HPC management stack in Docker — no real hardware needed.
It mirrors a production design:

- **LDAP/AD** → identity & authentication (users only)
- **Slurm** → scheduling + limit enforcement (3 fake-GPU nodes)
- **ColdFront** → web portal where admins/PIs manage projects, groups & quotas,
  which sync down into Slurm
- **Open OnDemand** → browser portal for users: shell, file manager, job
  composer, and interactive apps (JupyterLab) — all authenticated via LDAP

It's the concrete, runnable version of this architecture:

```
                 ┌─────────────────────┐
                 │  OpenLDAP (≈ AD)    │  identity: students, researchers, admin
                 └──┬─────────┬──────┬──┘
   SSSD on nodes │  Dex(OIDC) │      │ LDAP login + user search
   ┌─────────────┘            │      └──────────────┐
   ▼                          ▼                      ▼
┌──────────────────────────┐ ┌──────────────────┐ ┌────────────────────────────┐
│ SLURM                    │ │ OPEN ONDEMAND    │ │ COLDFRONT (Django + Postgres)│
│  slurmctld / slurmdbd    │◄│  apache + dex    │ │  projects = Slurm accounts   │
│  c1,c2,c3 (2 fake GPUs ea)│ │  shell/files/jobs│ │  allocations = limits        │
│  MariaDB, munge          │◄│  jupyter (bc app)│ │  slurm_dump → sacctmgr load  │
└──────────────────────────┘ └──────────────────┘ └──────────────┬─────────────┘
        ▲                                                         │
        └─────────────────── sacctmgr load ◄──────────────────────┘
```

## Containers

| Service | Role |
|---------|------|
| `openldap` | Directory (users/groups). The AD stand-in. |
| `phpldapadmin` | Web UI for the directory — http://localhost:8443 |
| `mysql` | Slurm accounting database (MariaDB) |
| `slurmdbd` | Slurm accounting daemon |
| `slurmctld` | Slurm controller / scheduler |
| `c1`, `c2`, `c3` | Compute nodes, 2 fake GPUs each |
| `login` | Submit host |
| `coldfront-db` | ColdFront's own database (Postgres) |
| `coldfront` | ColdFront web portal — http://localhost:8000 |
| `ondemand` | Open OnDemand portal (Apache + Dex) — http://localhost:8050 |

Every Slurm node runs **SSSD** (LDAP provider, *no* domain join — authenticates
against the directory's LDAP, exactly as you'd point it at real AD).

## Quick start

```bash
docker compose build      # first run compiles Slurm + builds ColdFront + OnDemand (several minutes)
docker compose up -d
# wait ~30s for LDAP seed, SSSD, and ColdFront migrations
bash scripts/sync-coldfront.sh   # push ColdFront projects → Slurm
```

> If you edit the shared `Dockerfile`, rebuild with `docker build -t slurm-lab:local .`
> (plain `docker build`, not `docker compose build`) — compose's build cache can
> serve a stale image for the shared tag. Rebuild `ood-lab:local` afterward since
> it's `FROM slurm-lab:local`, then `docker compose up -d --force-recreate`.

Web UIs:
- **Open OnDemand** (user portal): http://localhost:8050 — log in as any
  directory user (e.g. `smith` / `password` or `alice` / `password`).
- **ColdFront** (admin/PI management): http://localhost:8000 — `admin` / `admin`,
  or any directory user.
- **phpLDAPadmin** (directory): http://localhost:8443 — `cn=admin,dc=cluster,dc=local` / `adminpassword`.

## Directory users (password: `password`)

| User | Role | Notes |
|------|------|-------|
| `hpcadmin` | admin | |
| `smith` | researcher / PI | research lab + teaches CS101 |
| `jones` | researcher / PI | teaches ML200 |
| `alice`, `bob` | students | in Smith's CS101 |
| `carol` | student | in Jones's ML200 |

## The scenario (managed in ColdFront, enforced by Slurm)

`coldfront/seed_scenario.py` builds this; `scripts/sync-coldfront.sh` pushes it
into Slurm:

| ColdFront project | Slurm account | Group cap (GrpTRES) | Per-user limit | QOS | Coordinator |
|-------------------|---------------|---------------------|----------------|-----|-------------|
| Smith Lab (research) | `smith_lab` | 6 GPUs | smith: 4 GPUs/job | research | smith |
| Smith CS101 (class) | `smith_cs101` | 2 GPUs | each: 1 GPU, 2 jobs | student | smith |
| Jones ML200 (class) | `jones_ml200` | 2 GPUs | each: 1 GPU, 2 jobs | student | jones |

The split (a research account *and* a class account per professor) keeps a
class crunch from eating research budget, and lets the same person have large
limits as a researcher and strict limits as a student.

## What you can demonstrate

```bash
# Identity: an LDAP user resolves on every node and runs jobs as themselves
docker compose exec login bash -lc 'su - alice -c "id; srun -w c3 hostname"'

# Group/role limits (synced from ColdFront): SAME request, different outcome
docker compose exec login bash -lc 'su - alice -c "srun -p gpu --gres=gpu:2 --account=smith_cs101 hostname"'  # REJECTED (student cap 1)
docker compose exec login bash -lc 'su - smith -c "srun -p gpu --gres=gpu:2 --account=smith_lab  hostname"'  # RUNS (researcher cap 4)

# Coordinator: a researcher manages their students without being admin
docker compose exec login bash -lc 'su - smith -c "sacctmgr -i modify user alice where account=smith_cs101 set MaxJobs=1"'  # allowed (tightening)
docker compose exec login bash -lc 'su - alice -c "sacctmgr -i modify user bob   where account=smith_cs101 set MaxJobs=9"'  # DENIED (not a coordinator)
```

A coordinator can **tighten** limits and manage members, but Slurm refuses to
let them raise a limit **beyond the account budget the admin granted** — the
governance boundary you want.

## The management workflow (how it works in production)

1. Admin/PI creates or edits a **project + allocation** in the ColdFront GUI
   (or via `coldfront/seed_scenario.py` for reproducible setup).
2. Run the sync: `bash scripts/sync-coldfront.sh`. It:
   - ensures the `student`/`research` QOS tiers exist,
   - runs `coldfront slurm_dump` → `/shared/lab.cfg`,
   - `sacctmgr load`s it into slurmdbd,
   - sets each project's PI as the Slurm **coordinator** of its account.
3. Slurm enforces immediately (limits live in the accounting DB; the controller
   updates its in-memory cache).

In production this sync runs on a cron. **ColdFront is the source of truth** —
re-running the sync overwrites manual `sacctmgr` edits (e.g. the coordinator
tweak above reverts to the ColdFront value on next sync).

> Tip: to make ColdFront *fully* authoritative (remove Slurm accounts that
> aren't in ColdFront), change the load to `sacctmgr load file=... clean` in
> `scripts/sync-coldfront.sh`.

### Setting limits: friendly fields, not raw sacctmgr strings

Out of the box, ColdFront limits are raw `sacctmgr` text in a `slurm_specs`
attribute (e.g. `GrpTRES=cpu=4,gres/gpu=2`). This lab adds a nicer layer:

- An admin sets **simple per-limit fields** on an allocation — `Max GPUs`,
  `Max CPUs`, `Max Memory (GB)`, `Max GPU-hours`, `QOS`, `Per-User Max GPUs`,
  `Per-User Max Jobs`, `Per-User Max Walltime (hours)`.
- The **`cf_slurm_limits`** hook (`coldfront/cf_slurm_limits/`, a tiny Django
  app) listens for changes and **auto-compiles** them into the
  `Slurm Group Limits` / `Slurm Per-User Limits` attributes (the renamed
  `slurm_specs`/`slurm_user_specs`) that the Slurm plugin reads. Those are
  marked private — nobody hand-edits them.
- The clutter of ColdFront's example attribute types (cloud/storage/billing)
  is removed by `seed_scenario.py`, leaving just this curated set.

So an admin types `Max GPUs = 2` and the cluster ends up enforcing
`GrpTRES=gres/gpu=2` — no raw Slurm syntax in the UI. The attribute *names* are
configurable via `SLURM_*_ATTRIBUTE_NAME` in `coldfront/local_settings.py`.

### What configures what (ColdFront)

| Concern | Where |
|---------|-------|
| Sample scenario data only (cluster resource, users, projects, allocations, friendly limit values, memberships) | `coldfront/seed_scenario.py` (run manually) |
| Curated attribute types + collapse Field of Science to one option (re-applied every boot) | `coldfront/configure_attributes.py` (run by entrypoint) |
| Settings: LDAP login, friendly attr names, disabled modules (Grants/Publications/Research Output), app registration | `coldfront/local_settings.py` |
| Friendly fields → `slurm_specs` compile logic | `coldfront/cf_slurm_limits/` app |
| QOS tiers + PI→coordinator | `scripts/sync-coldfront.sh` |

> Trimmed modules: Grants, Publications, Research Output, and the project-review
> nag are disabled. Field of Science can't be removed (it's a required Project
> field), so it's collapsed to a single `N/A` option.

### Storage allocations (modelled only — NOT enforced)

Storage quotas are **not** a Slurm function — Slurm schedules compute, not disk.
Real quotas are enforced by the filesystem (`lfs setquota` on Lustre,
`mmsetquota` on GPFS, `setquota` on Linux), managed separately.

This lab **models** storage in ColdFront so the portal can express it, but does
**not** enforce it (there's no quota-capable filesystem — `/home` is a Docker
volume):

- a separate **`lab-storage`** Resource (no `slurm_cluster` attr, so `slurm_dump`
  ignores it — storage never touches the Slurm sync);
- a **`Storage Quota GB (not enforced)`** allocation field — the label says it
  plainly;
- **`scripts/sync-storage.sh`** — a STUB that only *prints* the `lfs setquota`
  command a real sync would run.

**In production:** replace the stub's `echo` with the real quota command for
your filesystem, run on a host that can administer it (on a cron) — exactly
mirroring how `sync-coldfront.sh` pushes compute limits to Slurm.
>
> **Gotcha fixed:** ColdFront's `import_field_of_science_data` does
> `FieldOfScience.objects.all().delete()` on every run, and `Project.field_of_science`
> is `on_delete=CASCADE` — so leaving it in the boot sequence silently wiped all
> projects on every container restart. It's removed from the entrypoint.

## Open OnDemand (the user-facing portal)

http://localhost:8050 — log in as any directory user (`smith`/`password`,
`alice`/`password`, …). What you get:

| App | What it does | How it works here |
|-----|--------------|-------------------|
| **Dashboard** | Landing page | Auth via Dex (OIDC) → LDAP connector → maps `uid` to the Linux user |
| **Files** | Browse/upload in `/home` | The per-user nginx (PUN) runs as the logged-in user on the shared `/home` |
| **Job Composer / Active Jobs** | Build, submit, monitor `sbatch` jobs | OOD's Slurm adapter (`clusters.d/lab.yml`) runs the source-built client as the user, authed by the shared munge key |
| **Clusters → Shell** | In-browser shell on the login node | PUN SSHes to `login` using a shared key baked into every home's `~/.ssh` |
| **Interactive Apps → Jupyter Lab** | Launch JupyterLab as a Slurm job, open it in the browser | batch_connect app submits to the `gpu`/`normal` partition; OOD reverse-proxies to the node via `/rnode/<host>/<port>/` |

**Auth flow:** browser → Apache (`mod_auth_openidc`) → **Dex** (bundled OIDC
provider) → **LDAP** bind against `openldap`. Dex maps the directory `uid` to
`REMOTE_USER`, so the portal user *is* the Linux user — and jobs submit and run
as them, subject to the same ColdFront-synced limits. Try the contrast live:
launch Jupyter as `alice` requesting 2 GPUs (rejected — student cap 1) vs.
`smith` on `smith_lab` (runs).

The OOD image is built `FROM slurm-lab:local`, so it already has the Slurm
client, munge key, and SSSD. Config is bind-mounted from `ondemand/` for fast
iteration; `ondemand/apps/jupyter/` is the interactive app.

> Lab shortcut: served over **plain HTTP** with Dex `insecureNoSSL`. In
> production OOD runs over HTTPS (real cert) and Dex uses `ldaps://`.

## Adding a new student / class

- **In the GUI**: log in as `admin`, add the user to a project (ColdFront's LDAP
  user-search finds them in the directory), then `bash scripts/sync-coldfront.sh`.
- **Reproducibly**: edit `coldfront/seed_scenario.py`, then
  `docker compose exec -T coldfront coldfront shell < coldfront/seed_scenario.py`
  and re-run the sync.

New directory users go in `ldap/bootstrap.ldif` (wipe `ldap_data`/`ldap_config`
volumes to re-seed, or add them live via phpLDAPadmin).

## Layers & where things live (the mental model)

| Concern | Lives in | Managed by |
|---------|----------|------------|
| Who exists, uid/gid, login | LDAP/AD | directory admins |
| uid resolution on nodes | SSSD (per node) | baked config |
| Projects, members, allocations | ColdFront DB | admins + PIs (GUI) |
| Accounts, limits, QOS, fairshare, job history | Slurm DB (MariaDB) | sync from ColdFront / sacctmgr |
| Which nodes, partitions | `slurm/slurm.conf` | sysadmin |

## Tear down

```bash
docker compose down        # stop, keep data
docker compose down -v     # also wipe LDAP, both DBs, and /home
```

## Caveats (lab vs production)

- OpenLDAP stands in for AD; SSSD is in `ldap` provider mode (no realm join).
  Against real AD: point `ldap_uri` at the DCs, use `ldaps://`, drop the
  `ldap_auth_disable_tls...` line, and adjust `ldap_schema`.
- Munge key and all passwords are baked/plaintext — lab only.
- GPUs are fake device nodes; cgroups are disabled (see `slurm/cgroup.conf`).
- ColdFront runs Django's dev server — fine for a lab, not for production.
