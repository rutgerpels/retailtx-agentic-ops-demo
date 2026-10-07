import argparse

from retailtx.fault import backlog
from retailtx.settings import Settings
from retailtx.telemetry import configure


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Bounded local posting pause; no configuration damage"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--duration-seconds", type=int)
    group.add_argument("--undo", action="store_true")
    args = parser.parse_args()
    configure("backlog")
    settings = Settings.from_env()
    backlog(settings.erp_dsn, None if args.undo else args.duration_seconds)


if __name__ == "__main__":
    main()
