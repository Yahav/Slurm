from django.apps import AppConfig


class CfSlurmLimitsConfig(AppConfig):
    name = "cf_slurm_limits"
    verbose_name = "Slurm friendly limits"

    def ready(self):
        # Connect the signals that compile friendly limit fields into the
        # slurm_specs / slurm_user_specs attributes the Slurm plugin reads.
        from . import signals  # noqa: F401
