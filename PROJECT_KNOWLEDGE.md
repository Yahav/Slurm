# Project Knowledge Base — Slurm + LDAP + ColdFront + Open OnDemand lab

> A knowledge dump for future agents/maintainers. Read this before changing the
> stack. It captures the architecture, the *why* behind decisions, a Slurm/
> ColdFront concept reference, and — most importantly — the **gotchas** that
> already cost real debugging time. `README.md` is the user-facing quick start;
> this file is the deep context.

---

## 1. What this project is

A **fully simulated HPC management stack** running entirely in Docker on one
machine, for experimenting with the Slurm ecosystem — **no real GPUs/hardware**.
GPUs are faked; cgroups are off; everything runs in containers.

Four logical layers:

1. **LDAP/AD** (OpenLDAP) — identity & authentication (users only).
2. **Slurm** — scheduling + limit enforcement (3 fake-GPU compute nodes).
3. **ColdFront** — web portal where admins/PIs manage projects, groups, quotas.
4. **Open OnDemand** — browser portal for users (shell, files, jobs, Jupyter).

The point of the lab is to model the *architecture and behavior* (identity flow,
group/per-user quotas, QOS tiers, coordinator delegation, GUI→scheduler
pipeline, the user portal) — everything you'd design and test before touching a
real cluster.

---

## 2. The core mental model: three separate planes

The single most important concept. These are **three separate databases**, wired
together by two bridges:

```
┌─ IDENTITY ───────────────────────────────────────────────┐
│ OpenLDAP holds users. SSSD on every node resolves them,   │
│ so `id alice` → uid 7001 identically cluster-wide.        │
└───────────────────────────────────────────────────────────┘
┌─ MANAGEMENT ─────────────────────────────────────────────┐
│ ColdFront (its own Postgres) = INTENT: "alice is in CS101,│
│ which has 2 GPUs." Admins/PIs edit this in the GUI.       │
└───────────────────────────────────────────────────────────┘
┌─ ENFORCEMENT ────────────────────────────────────────────┐
│ Slurm (MariaDB) = TRUTH the scheduler reads: accounts,    │
│ limits, QOS. slurmctld enforces on every job.             │
└───────────────────────────────────────────────────────────┘
```

- **LDAP does not know about quotas.** It only provides identity (uid/gid/home).
- **ColdFront does not enforce anything.** It records intent and *pushes* it down.
- **Slurm does not read LDAP for limits.** Limits live in its own accounting DB.

The two bridges:
- **SSSD** = identity → every node (so jobs run as the user).
- **`scripts/sync-coldfront.sh`** = ColdFront intent → Slurm enforcement
  (`slurm_dump` → `sacctmgr load`).

Whenever something seems wrong, ask *which plane* owns it.

---

## 3. Container inventory (12 services, `docker-compose.yml`)

| Service | Image | Role |
|---------|-------|------|
| `openldap` | osixia/openldap:1.5.0 | Directory (AD stand-in). Seeded from `ldap/bootstrap.ldif`. |
| `phpldapadmin` | osixia/phpldapadmin | Directory web UI — http://localhost:8443 |
| `mysql` | mariadb:11 | Slurm accounting DB |
| `slurmdbd` | slurm-lab:local | Slurm accounting daemon (authorizes sacctmgr) |
| `slurmctld` | slurm-lab:local | Controller / scheduler |
| `c1`,`c2`,`c3` | slurm-lab:local | Compute nodes (`slurmd`), 2 fake GPUs each |
| `login` | slurm-lab:local | Submit host (+ sshd for the OOD shell) |
| `coldfront-db` | postgres:16 | ColdFront's own DB |
| `coldfront` | coldfront-lab:local | ColdFront portal — http://localhost:8000 |
| `ondemand` | ood-lab:local | Open OnDemand portal — http://localhost:8050 |

**Two shared images built from source:**
- `slurm-lab:local` (root `Dockerfile`) — Slurm compiled from source + munge +
  SSSD + openssh + jupyterlab. Used by all Slurm nodes. `ood-lab` is built
  `FROM slurm-lab:local` (so it inherits the Slurm client, munge key, SSSD).
- `coldfront-lab:local` (`coldfront/Dockerfile`).

All Slurm containers share one **munge key** (baked into the image) and the
**`slurm/` config** (bind-mounted to `/etc/slurm-host`, copied to `/etc/slurm`
at boot by the entrypoint).

---

## 4. Slurm concept reference

### Accounts, associations, QOS, partitions — what differs

| Concept | Answers | Defined in | Managed by |
|---------|---------|-----------|------------|
| **Partition** | *where* (which nodes) + queue policy | `slurm.conf` (file) | sysadmin |
| **Account / association** | *who* — group/user identity + budget | slurmdbd DB | `sacctmgr` / ColdFront |
| **QOS** | *what class* — service tier | slurmdbd DB | `sacctmgr` / ColdFront |

A job is governed by **all of**: partition + its QOS + its user association +
its account association. The **most restrictive** wins.

- **Partition ⊅ QOS and QOS ⊅ Partition** — they overlap (time, priority,
  preemption, some access control) but each has exclusive powers. Only a
  partition selects *hardware* (`Nodes=`) and gates by POSIX group
  (`AllowGroups`). Only a QOS does cumulative budgets, per-user-within-group
  caps, billing multipliers, rich preemption. **QOS *is* a superset of
  associations**, not of partitions.

### The limit matrix (group vs per-user)

- **`Grp*` limits on an account** apply to the *sum of all members* → group cap.
- **`Max*` limits on a user association** apply to that one user → per-user cap.
- TRES = trackable resources (cpu, mem, gres/gpu, node, …). `GrpTRES=gres/gpu=8`,
  `GrpTRESMins` (cumulative budget, e.g. GPU-minutes), `MaxTRESPerJob`, etc.

### Where limits live / how they enforce

- Stored in slurmdbd's **MariaDB**, table `<cluster>_assoc_table` (one row per
  association, one column per limit). TRES limits stored as id-keyed strings
  (`1=16,1001=2`) referencing `tres_table`.
- **`slurmctld` enforces from an in-memory cache**, not per-job DB queries. It
  loads associations at startup and gets live updates from slurmdbd. So changes
  apply immediately, but if slurmdbd is down you can't *change* limits.
- **Never write the MySQL tables directly** — bypasses the cache, the TRES
  translation, the txn audit log, and validation. Always go through `sacctmgr`
  (or slurmrestd).

### Enforcement switch
`slurm/slurm.conf` has `AccountingStorageEnforce=associations,limits,qos,safe`.
The `associations` token is what makes "no association → no job". Without it, an
LDAP user with no Slurm account could still submit. (Verified: an unprovisioned
LDAP user can *log in* but cannot run jobs — "Invalid account".)

### Account Coordinators (the "researcher manages their students" feature)
`sacctmgr add coordinator account=X names=Y`. A coordinator can view/modify the
users and limits **within their account** without being a cluster admin — but
**cannot raise a limit beyond the account budget the admin granted** (verified:
coordinator can *tighten* a student, can't exceed parent). ColdFront PI →
mapped to Slurm coordinator by `sync-coldfront.sh`.

### Fake GPUs
Slurm's `gpu` GRES plugin **ignores file-less GPUs**. So `gres.conf` points
`File=` at dummy device nodes the entrypoint creates (`/dev/fakegpu[0-1]` via
`mknod`, which works unprivileged because Docker grants `MKNOD`). Declared
`Gres=gpu:2` per node. `CUDA_VISIBLE_DEVICES` gets set but points at nothing —
fine for scheduling, useless for real CUDA. `AccountingStorageTRES=gres/gpu`
makes GPUs limitable.

---

## 5. Identity layer (LDAP + SSSD)

- **OpenLDAP** seeded by `ldap/bootstrap.ldif`: base `dc=cluster,dc=local`,
  `ou=people`, `ou=groups`. Users have POSIX `uidNumber`/`gidNumber` (primary
  group only — `researchers` gid 5000, `students` gid 5001). Password for all:
  `password`. Admin bind: `cn=admin,dc=cluster,dc=local` / `adminpassword`.
- **The LDAP group is just the POSIX primary group** — it gives a valid gid and
  group-owns files the user creates. It does **not** drive Slurm limits/access
  (that's accounts, via ColdFront) and is **not** what makes someone a PI.
- **SSSD** (`sssd/sssd.conf`) runs on every Slurm node + OOD. Mode: `id_provider
  = ldap` / `auth_provider = ldap` (**NOT `ad`**) — "authenticate against AD's
  LDAP without joining the domain", per the design requirement. `nsswitch.conf`
  routes passwd/group/shadow → `sss`. `ldap_auth_disable_tls_never_use_in_production
  = true` because we use plain `ldap://`.
- **Every node that runs OR authorizes work needs SSSD** — including **slurmdbd**
  (it authorizes sacctmgr requests, e.g. the coordinator check, and must resolve
  the caller's uid→name). This was a real bug (coordinator edits silently denied
  until SSSD was added to slurmdbd).
- **`docker exec --user alice` does NOT work for LDAP users** — Docker resolves
  `--user` against the container's `/etc/passwd`, not NSS/SSSD. Inside the
  container use `su - alice` / `runuser -u alice` (those use NSS).
- Home dirs for LDAP users are pre-created on the shared `/home` volume by the
  login entrypoint (`create_ldap_homes`) — slurmd doesn't go through PAM, so
  homes must exist for jobs. `/etc/skel/.ssh` holds a shared keypair so the OOD
  Shell app can SSH `login` passwordlessly.

---

## 6. ColdFront

### Object model
```
Resource          a grantable thing (the "lab" cluster; also "lab-storage")
   ▲
Project           a PI's container (a lab or a class)
   │ owns
Allocation        "this project gets this resource, these limits, these users"
   ├─ AllocationAttribute(s)   typed key/values (the limits + slurm mapping)
   └─ AllocationUser(s)        members on the allocation
```
An **Allocation** maps 1:1 to a **Slurm account**. `slurm_dump` reads specific
attributes off it.

### What decides roles (NOT the LDAP group)
- **`UserProfile.is_pi`** (a ColdFront DB flag, admin-set) → can own projects.
  We set it for smith/jones in the seed. There's no built-in LDAP→is_pi sync.
- **`ProjectUser.role`** (`Manager`/`User`) → per-project role. PI = Manager.
- "Student" is not a role — it's just a `User`-role member of a class project.

### The Slurm plugin
- Commands: `slurm_dump` (export to a sacctmgr flat file), `slurm_check`,
  `slurm_import`. Enabled via `PLUGIN_SLURM=True` (compose env).
- It reads attribute **names from settings** (`SLURM_*_ATTRIBUTE_NAME`), so we
  renamed them to friendly labels.
- The plugin **produces a file**; it does **not** push to slurmdbd itself. In our
  split-container setup ColdFront has no slurm client/munge, so we `slurm_dump`
  to a shared volume and `sacctmgr load` from the controller (that's what
  `sync-coldfront.sh` does). The plugin also does NOT create QOS or set
  coordinators — the sync script handles those.

### The friendly-limits design (our addition)
ColdFront's native limit UX is raw `sacctmgr` text in a `slurm_specs` attribute.
We added a friendlier layer:

- **Friendly input fields** an admin fills (all `AllocationAttributeType`s):
  group — `Max CPUs/GPUs/Memory (GB)/Nodes`, `Max CPU-hours/GPU-hours`,
  `Max Running Jobs`, `Max Submitted Jobs`, `Max Total Walltime (hours)`,
  `Fairshare Shares`, `QOS`; per-user — `Per-User Max CPUs/GPUs/Memory (GB)`,
  `Per-Job Max CPUs/GPUs`, `Per-User Max Running/Submitted Jobs`,
  `Per-User Max Walltime per Job (hours)`.
- **`coldfront/cf_slurm_limits/`** — a tiny Django app (signal hook). On any
  AllocationAttribute save/delete it **recompiles** the friendly fields into the
  two holder attributes the plugin reads:
  - `Slurm Group Limits (Generated)` (renamed `slurm_specs`)
  - `Slurm Per-User Limits (Generated)` (renamed `slurm_user_specs`)
  Marked `is_private` (PIs don't see them); `(Generated)` in the label so admins
  know not to hand-edit (the hook overwrites them).
- Holder names are read from `SLURM_*_ATTRIBUTE_NAME` settings in *both* the hook
  and `configure_attributes.py` — **one source of truth**.

### Setup vs data — separation of concerns
- **`coldfront/configure_attributes.py`** (run at **every boot** from the
  entrypoint): curates the `AllocationAttributeType` set (creates the curated
  ones, **prunes everything else** — ColdFront's cloud/storage/billing examples
  re-appear each boot because `add_allocation_defaults` recreates them);
  collapses **Field of Science** to one `N/A` option; creates the `lab-storage`
  Resource; and **recompiles all allocations** so the `(Generated)` holders are
  always current (also self-heals after a rename).
- **`coldfront/seed_scenario.py`** (run **manually**): sample data only — cluster
  resource, users, projects, allocations, friendly-field values, memberships,
  the demo storage allocation. Safe to re-run (idempotent, keyed by project +
  resource).
- **`coldfront/local_settings.py`**: DB, LDAP login (`django-auth-ldap`),
  friendly `SLURM_*_ATTRIBUTE_NAME`, `AUTHENTICATION_BACKENDS` (incl.
  `django_su.backends.SuBackend`!), disabled modules, `INSTALLED_APPS +=
  cf_slurm_limits`.

### Disabled / trimmed modules
`GRANT_ENABLE`, `PUBLICATION_ENABLE`, `RESEARCH_OUTPUT_ENABLE`,
`PROJECT_ENABLE_PROJECT_REVIEW` = `False`. **Field of Science can't be disabled**
(required FK on Project), so it's collapsed to a single `N/A` option.

### Storage (modelled only — NOT enforced)
Storage quotas are **not** a Slurm function (Slurm schedules compute). Real
quotas are filesystem-enforced (`lfs setquota`/`mmsetquota`/`setquota`). We model
a `lab-storage` Resource + `Storage Quota GB (not enforced)` field, and
`scripts/sync-storage.sh` is a **stub** that only prints the command it would
run. No quota-capable FS exists in the lab (`/home` is a Docker volume).

### Login & LDAP search dependencies
- Login auth = `django-auth-ldap` (needs `python-ldap`).
- The GUI "add users" search uses ColdFront's `ldap_user_search` plugin which
  imports **`ldap3`** (separate package!) and respects `LDAP_USER_SEARCH_USE_SSL`
  (must be `False` for our plain `ldap://`).

---

## 7. Open OnDemand

- Built `FROM slurm-lab:local` → already has slurm client, munge key, SSSD.
- Runs **Apache + Dex** as foreground processes (no systemd needed; the per-user
  nginx PUNs are spawned by Apache via sudo).
- **Auth**: browser → Apache `mod_auth_openidc` → **Dex** (bundled OIDC) →
  **LDAP** connector against `openldap`. Dex maps the directory `uid` to
  `preferred_username` → `REMOTE_USER`, so the portal user *is* the Linux user
  and jobs run as them under the same ColdFront-synced limits.
- **Port discipline**: internal port == external port (**8050**) so OIDC redirect
  URIs / Dex issuer line up. `ood_portal.yml` `port: 8050`; the entrypoint adds
  `Listen 8050` to apache `ports.conf` (update_ood_portal generates the vhost on
  `*:8050` but does NOT add the Listen directive).
- **Slurm adapter**: `ondemand/config/clusters.d/lab.yml` (adapter slurm, cluster
  lab, bin `/usr/local/bin`). OOD runs the slurm client locally as the user.
- **Shell app**: SSHes to `login` host. Needs sshd on login (started by login
  entrypoint) + the shared `/etc/skel/.ssh` key + `openssh-client` in the OOD
  image (the *client* — easy to miss with `--no-install-recommends`).
- **Jupyter interactive app**: `ondemand/apps/jupyter/` (batch_connect). Submits
  a Slurm job that runs `jupyter lab` bound to `$host:$port` under base_url
  `/rnode/$host/$port/`; OOD reverse-proxies the browser to it. JupyterLab is
  installed in `slurm-lab:local` so compute nodes can run it.
- Login as any directory user (`smith`/`password`, etc.). **No separate OOD
  admin** — OOD has no user DB; admin privileges would be granted via
  `OOD_ADMINS` (currently unset).

---

## 8. The sync (`scripts/sync-coldfront.sh`)

What ColdFront's plugin can't do itself; runs on a cron in production:
1. Ensure QOS tiers exist (`student`, `research`) — the dump references them.
2. `coldfront slurm_dump -o /shared` → `/shared/lab.cfg`.
3. `sacctmgr load file=/shared/lab.cfg` on the controller (additive; add `clean`
   to make ColdFront fully authoritative — removes accounts not in the file).
4. Set each project's PI as Slurm **coordinator** of its account (queries
   ColdFront for the `Slurm Account Name` → PI mapping).

`scripts/sync-storage.sh` is the storage analogue — **stub only**.

---

## 9. ⚠️ GOTCHAS — read before debugging (these already bit us)

### Docker / build
- **`docker compose build` can serve a STALE cached image for a shared tag.**
  Symptom: containers run an old image lacking your changes even after a
  "successful" build. **Fix: use plain `docker build -t slurm-lab:local .`**
  (authoritative), rebuild `ood-lab` after (it's `FROM slurm-lab`), then
  `docker compose up -d --force-recreate`, and **verify image IDs match**:
  `docker inspect <ctr> --format '{{.Image}}'` vs `docker image inspect <tag>`.
- Editing the entrypoint/Dockerfile requires a **rebuild** (it's baked in), not
  just a restart.
- Editing bind-mounted config (`slurm/*`, `ondemand/config/*`,
  `coldfront/local_settings.py` is baked though) → restart the service; the
  entrypoint re-copies/regenerates.

### Slurm
- **GPU GRES needs `File=`** — file-less GPUs are silently ignored.
- **cgroup v2**: the source build doesn't include the cgroup/v2 plugin (no dbus
  dev libs), and Docker Desktop is cgroup v2 → `slurm/cgroup.conf` sets
  `CgroupPlugin=disabled` + `proctrack/linuxproc` + `task/none` (unprivileged).
- **`create-munge-key` doesn't exist on Ubuntu 22.04** (it's `mungekey`) — we
  generate the key with `dd if=/dev/urandom`.
- **`MaxTRESPerUser` is a QOS-only option** — invalid on a user association
  (use `GrpTRES` on the user assoc for a per-user concurrent cap).
- **Walltime in the sacctmgr LOAD FILE must be plain minutes**, not `HH:MM:SS` —
  the colons collide with the colon-delimited load format. `GrpWall`/
  `MaxWallDurationPerJob` are emitted as minutes by the hook. (On the CLI,
  `HH:MM:SS` is fine; only the load file breaks.)
- slurmdbd needs SSSD (coordinator auth). slurmctld needs SSSD (loads
  associations by name→uid).
- `slurmdbd.conf` must be mode 0600 owned by `slurm`; we copy configs from a
  read-only bind mount into image-local `/etc/slurm` to set perms (also dodges
  Windows bind-mount perm quirks).

### ColdFront
- **`import_field_of_science_data` WIPES ALL PROJECTS on every boot.** It runs
  `FieldOfScience.objects.all().delete()` and `Project.field_of_science` is
  `on_delete=CASCADE`. It is **removed** from the entrypoint loop;
  `configure_attributes.py` ensures one default FoS instead. *Do not re-add it.*
- **`coldfront initial_setup` is interactive** (`input()` prompt) **and
  all-or-nothing**. With no TTY it raises `EOFError` and does nothing. We run its
  idempotent sub-commands directly (`add_default_project_choices`,
  `add_allocation_defaults`, …) — but NOT `import_field_of_science_data`.
- **`local_settings.py` was being loaded twice** (ColdFront includes both the
  package-config copy and the `COLDFRONT_CONFIG` path) → non-idempotent lines
  like `INSTALLED_APPS += [...]` caused "Application labels aren't unique". Fix:
  don't double-copy (only `/etc/coldfront/local_settings.py` via
  `COLDFRONT_CONFIG`) **and** guard the append (`if not in INSTALLED_APPS`).
- **Overriding `AUTHENTICATION_BACKENDS` dropped `django_su.backends.SuBackend`**
  → ColdFront only wires the `su/` URLs when that backend is present, so
  `/admin/auth/user/` 500'd with `NoReverseMatch: su_login`. Keep SuBackend.
- `ldap_user_search` needs the **`ldap3`** package (separate from `python-ldap`)
  and `LDAP_USER_SEARCH_USE_SSL=False` for plain ldap://.
- `add_allocation_defaults` recreates ColdFront's example attribute types **every
  boot** → `configure_attributes.py` prunes them back every boot (a one-time
  cleanup won't stick).
- Static assets: run `collectstatic` (in the entrypoint) or the UI is unstyled /
  Vite manifest warnings.

### Open OnDemand
- **`set -u` + sourcing `/etc/apache2/envvars`** → apache dies silently
  (envvars references unset vars). The OOD entrypoint uses `set -eo pipefail`
  (no `-u`) and `set +e` around apache.
- Apache logs to files, not stdout — a silent container exit hides the real
  error; check `/var/log/apache2/*.log` or send them to stdout when debugging.
- `update_ood_portal` generates the `*:8050` vhost but no `Listen 8050` → add it.
- `openssh-client` (the `ssh` binary) isn't pulled by `openssh-server` under
  `--no-install-recommends`; the OOD image needs it for the Shell app.

---

## 10. File reference

```
Dockerfile                     slurm-lab image: Slurm from source + munge + SSSD
                               + openssh + jupyterlab + skel ssh key
docker-entrypoint.sh           per-role boot: munge → sssd → stage config → daemon;
                               login also: homes + sshd; compute: fake GPUs
docker-compose.yml             all 12 services, volumes, network
slurm/slurm.conf               nodes, partitions, enforce on, GPU TRES, cgroup off
slurm/gres.conf                fake GPU File= device nodes
slurm/cgroup.conf              CgroupPlugin=disabled
slurm/slurmdbd.conf            accounting daemon → MariaDB
ldap/bootstrap.ldif            seeded directory users/groups
sssd/sssd.conf                 LDAP provider, no domain join
sssd/nsswitch.conf             route NSS → sss
coldfront/Dockerfile           coldfront + django-auth-ldap + python-ldap + ldap3
                               + psycopg2; copies local_settings, app, configure
coldfront/local_settings.py    DB, LDAP auth, friendly names, disabled modules, app
coldfront/entrypoint.sh        collectstatic, migrate, lookup sub-commands (NO FoS
                               import), configure_attributes, ensure admin, runserver
coldfront/configure_attributes.py  boot: curate attr types, FoS→1, storage resource,
                                   recompile all allocations
coldfront/cf_slurm_limits/     Django app: friendly fields → Generated holders (hook)
coldfront/seed_scenario.py     sample data only (run manually)
ondemand/Dockerfile            OOD FROM slurm-lab + ondemand + dex + openssh-client
ondemand/entrypoint.sh         munge → sssd → stage slurm.conf → update_ood_portal
                               → Listen 8050 → dex → apache
ondemand/config/ood_portal.yml Dex LDAP connector + OIDC remote-user mapping
ondemand/config/clusters.d/lab.yml  Slurm job adapter
ondemand/apps/jupyter/         batch_connect Jupyter interactive app
scripts/sync-coldfront.sh      ColdFront → Slurm (QOS, dump, load, coordinators)
scripts/sync-storage.sh        storage quota STUB (prints, does not enforce)
```

---

## 11. Runbook / common operations

```bash
# First build (compiles Slurm, builds ColdFront + OnDemand — several minutes)
docker compose build
docker compose up -d
# wait ~30s for LDAP seed, SSSD, ColdFront migrations

# Seed ColdFront sample data, then push to Slurm
docker compose exec -T coldfront coldfront shell < coldfront/seed_scenario.py
bash scripts/sync-coldfront.sh

# Rebuilding the shared Slurm image (do NOT trust `docker compose build`):
docker build -t slurm-lab:local .
docker build -t ood-lab:local ./ondemand        # FROM slurm-lab
docker compose up -d --force-recreate

# Rebuilding ColdFront only:
docker build -t coldfront-lab:local ./coldfront
docker compose up -d --force-recreate coldfront

# Run a job as an LDAP user (note: su, NOT docker exec --user)
docker compose exec login bash -lc 'su - alice -c "srun -w c3 hostname"'

# Inspect Slurm state
docker compose exec slurmctld sacctmgr show assoc format=Account,User,QOS,GrpTRES,MaxJobs tree
docker compose exec login sinfo

# Teardown
docker compose down        # keep data
docker compose down -v     # wipe LDAP + both DBs + /home
```

**Web UIs:** OnDemand http://localhost:8050 · ColdFront http://localhost:8000
(`admin`/`admin` or any directory user) · phpLDAPadmin http://localhost:8443.

---

## 12. The example scenario

| ColdFront project | Slurm account | Group cap | Per-user | QOS | Coordinator | Storage |
|---|---|---|---|---|---|---|
| Smith Lab (research) | `smith_lab` | 6 GPUs, 12 CPUs | smith: 4 GPUs | research | smith | 500 GB (stub) |
| Smith CS101 (class) | `smith_cs101` | 2 GPUs, 4 CPUs | 1 GPU, 2 jobs | student | smith | — |
| Jones ML200 (class) | `jones_ml200` | 2 GPUs, 4 CPUs | 1 GPU, 2 jobs | student | jones | — |

Two accounts per professor (research vs class) so a class crunch can't eat
research budget, and the same person has large limits as a researcher and strict
limits as a student.

Directory users (all password `password`): `hpcadmin` (admin), `smith`/`jones`
(researchers/PIs), `alice`/`bob` (students in CS101), `carol` (student in ML200).

---

## 13. Lab vs production (what's faked)

- **OpenLDAP** stands in for AD; SSSD is `ldap` provider (no realm join). For real
  AD: point `ldap_uri` at the DCs, use `ldaps://`, drop the
  `ldap_auth_disable_tls...` line, adjust `ldap_schema`.
- **Munge key + all passwords baked/plaintext** — lab only.
- **GPUs are fake** device nodes; **cgroups disabled**; jobs do no real compute.
- **ColdFront/OOD run dev servers** over plain HTTP; Dex uses `insecureNoSSL`.
  Production = real WSGI/ASGI + HTTPS + real certs.
- **Storage quotas are modelled, not enforced** — no quota-capable filesystem.
- **Single host** — controller, dbd, db, nodes, portals all co-located.

---

## 14. Design decisions (the "why", from the build conversation)

- **LDAP = users only; groups/quotas in ColdFront.** The user explicitly wanted
  central IT's AD to stay identity-only, with HPC-team-managed grouping. Hence
  Slurm accounts are decoupled from LDAP groups, and `is_pi`/project membership
  live in ColdFront.
- **No shared dirs** (each user isolated) → AD needs no POSIX project groups;
  field-of-science/grants/etc. trimmed as irrelevant to a compute portal.
- **Friendly limit fields + hook** chosen over raw `slurm_specs` so admins never
  hand-write sacctmgr syntax; "full friendly fields" coverage was requested over
  a raw escape-hatch.
- **Decoupled ColdFront↔Slurm** (dump→load over a shared volume) instead of
  co-locating the slurm client in ColdFront — cleaner container boundaries, at
  the cost of the small `sync-coldfront.sh` glue.
```
