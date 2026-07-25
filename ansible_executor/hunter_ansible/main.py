"""Command-line entry point for the Hunter Ansible executor."""

from __future__ import annotations

import logging
import os
import signal
import sys
import threading

from .client import HunterClient, PermanentError
from .config import Config, ConfigError
from .target_policy import TargetPolicy
from .worker import ExecutorWorker
from .workspace import Workspace


LOGGER = logging.getLogger("hunter_ansible")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        config = Config.from_env(os.environ)
    except ConfigError as error:
        LOGGER.error("executor configuration rejected: %s", error)
        return 2

    stop_event = threading.Event()

    client = HunterClient(config.hunter_url, config.runner_token)
    target_policy = TargetPolicy(
        config.allowed_cidrs,
        config.allowed_ports,
        allow_special=config.allow_special_targets,
    )
    worker = ExecutorWorker(
        config=config,
        client=client,
        target_policy=target_policy,
        workspace=Workspace(config.workspace_root),
        stop_event=stop_event,
    )

    def stop(_signum, _frame):
        worker.request_stop()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    LOGGER.info("Hunter Ansible executor started")
    try:
        worker.run_forever()
    except PermanentError as error:
        LOGGER.error("executor protocol stopped: %s", error)
        return 3
    finally:
        LOGGER.info("Hunter Ansible executor stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
