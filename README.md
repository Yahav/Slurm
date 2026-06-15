# Slurm lab cluster (Docker Compose)

A fully simulated Slurm cluster for experimenting with the Slurm ecosystem —
no real GPUs or compute hardware required. Everything (controller, accounting,
login host, compute nodes, fake GPUs) runs as containers on one machine.

## Topology

| Service     | Role                              | Daemon      |
|-------------|-----------------------------------|-------------|
| `mysql`     | Accounting database (MariaDB)     | mariadbd    |
| `slurmdbd`  | Accounting daemon                 | `slurmdbd`  |
| `slurmctld` | Controller / scheduler            | `slurmctld` |
| `login`     | Submit host (run jobs here)       | client only |
| `c1`, `c2`  | Compute nodes, 2 CPUs + 2 fake GPUs each | `slurmd` |

All Slurm containers run the **same image** (Slurm built from source) and share
the same `munge` key and `slurm.conf`. `/home` is a shared volume, mimicking a
cluster's shared filesystem.

## Start it

```bash
docker compose build      # first time: compiles Slurm from source (~minutes)
docker compose up -d
```

Watch it come up:

```bash
docker compose logs -f slurmctld
```

## Use it

Hop onto the login node and submit work as the unprivileged `lab` user:

```bash
docker compose exec --user lab login bash

# inside the container:
sinfo                              # show partitions/nodes
sinfo -N -l                        # per-node detail (see the fake GPUs)
srun -N1 hostname                  # run a trivial job
srun --gres=gpu:2 nvidia-smi || true   # GPU alloc works; no real device

cat > job.sh <<'EOF'
#!/bin/bash
#SBATCH --job-name=hello
#SBATCH --partition=gpu
#SBATCH --gres=gpu:1
#SBATCH --output=hello-%j.out
echo "running on $(hostname)"
echo "GPUs allocated: $CUDA_VISIBLE_DEVICES"
sleep 20
EOF

sbatch job.sh
squeue
sacct                              # accounting history (powered by slurmdbd)
```

## Things to experiment with

- **Scheduling**: submit more jobs than slots and watch `squeue` queue/backfill.
- **GRES/GPU**: `--gres=gpu:N`, see how nodes fill up via `scontrol show node c1`.
- **Accounting**: `sacct`, `sreport cluster utilization`, `sacctmgr show assoc`.
- **Accounts & fairshare**: `sacctmgr add account ...`, add users, set shares.
- **QOS / limits**: `sacctmgr add qos ...`, attach to a partition.
- **Reconfig**: edit any file in `slurm/`, then restart the affected services
  so the entrypoint re-copies them, e.g. `docker compose restart slurmctld c1 c2`.
  (Configs are copied into each container at startup, so `scontrol reconfigure`
  alone won't pick up host edits.)
- **Node states**: `scontrol update nodename=c1 state=down reason=test`.

## Customizing

- **Slurm version**: change `SLURM_VERSION` in `docker-compose.yml` (must exist
  at <https://download.schedmd.com/slurm/>), then `docker compose build`.
- **More nodes**: copy the `c2` service to `c3`, add a matching `NodeName=c3`
  line in `slurm/slurm.conf` and `gres.conf`, update the partitions, rebuild
  is not needed — just `docker compose up -d c3` and `scontrol reconfigure`.
- **Real cgroups**: switch `ProctrackType`/`TaskPlugin` to the cgroup plugins in
  `slurm.conf`, add a `cgroup.conf`, and mark the compute services `privileged: true`.

## Tear down

```bash
docker compose down            # stop, keep data volumes
docker compose down -v         # also wipe the accounting DB + /home
```

## Notes / caveats

- The munge key is baked into the image for simplicity. That's fine for a local
  lab but **never** acceptable in production (it'd be readable in the image).
- Fake GPUs are dummy device nodes (`/dev/fakegpu0/1`) created by the entrypoint;
  `gres.conf` points `File=` at them. `CUDA_VISIBLE_DEVICES` gets set to the
  allocated indices but the devices aren't real — great for scheduling behavior,
  useless for actual CUDA.
- cgroups are disabled (`slurm/cgroup.conf`) so the cluster runs in unprivileged
  containers on cgroup-v2 Docker Desktop hosts. See that file to re-enable them.
- Declared `RealMemory`/`CPUs` are virtual numbers Slurm schedules against; they
  don't have to match the host's real resources.
