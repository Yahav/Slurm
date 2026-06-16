# CLAUDE.md

This repo is a fully simulated **Slurm + LDAP + ColdFront + Open OnDemand** HPC
management lab running in Docker (no real GPUs).

## 📖 Read this first

**[PROJECT_KNOWLEDGE.md](PROJECT_KNOWLEDGE.md)** is the deep context for this
project — architecture, the three-plane mental model, a Slurm/ColdFront concept
reference, the full file map, a runbook, and a **GOTCHAS section** documenting
bugs that already cost real debugging time. Read it before changing the stack.

[README.md](README.md) is the user-facing quick start.

## Critical reminders (full detail in PROJECT_KNOWLEDGE.md §9)

- **Don't trust `docker compose build`** for the shared `slurm-lab:local` tag —
  it can serve a stale image. Use `docker build -t slurm-lab:local .`, then
  rebuild `ood-lab` (it's `FROM slurm-lab`), then `up -d --force-recreate`, and
  verify image IDs match.
- **Never re-add `import_field_of_science_data`** to the ColdFront entrypoint —
  it wipes all projects on every boot (cascade delete via `FieldOfScience`).
- Three separate planes: **LDAP** = identity only, **ColdFront** = intent,
  **Slurm** = enforcement. They're bridged by SSSD and `scripts/sync-coldfront.sh`.
- Use `su - <user>` inside containers, **not** `docker exec --user <user>`
  (Docker can't resolve LDAP users).
- ColdFront friendly limit fields → compiled to Slurm specs by the
  `cf_slurm_limits` hook; `configure_attributes.py` curates attribute types at
  boot; `seed_scenario.py` is sample data only.
