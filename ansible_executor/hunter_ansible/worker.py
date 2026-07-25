"""Executor scheduling and bounded in-memory event buffering."""

from __future__ import annotations

import json
import threading
import time
from collections import deque
from typing import Any, Mapping

from .client import LeaseConflict, PermanentError, TransientError
from .execution import ExecutionError


class WorkerError(ExecutionError):
    pass


MAX_EVENT_BYTES = 64 * 1024
MAX_EVENT_BATCH_BYTES = 900 * 1024
EVENT_FIELDS = {
    "event_uuid", "parent_uuid", "counter", "event_type", "play", "task",
    "host", "event_time", "stdout", "event_data",
}


class FairClaimScheduler:
    def __init__(self, client, *, max_consecutive_tasks: int = 5) -> None:
        if max_consecutive_tasks < 1:
            raise ValueError("max_consecutive_tasks must be positive")
        self.client = client
        self.max_consecutive_tasks = max_consecutive_tasks
        self.consecutive_tasks = 0

    def claim(self):
        if self.consecutive_tasks < self.max_consecutive_tasks:
            task = self.client.claim_task()
            if task is not None:
                self.consecutive_tasks += 1
                return "task", task

        run = self.client.claim_run()
        if run is not None:
            self.consecutive_tasks = 0
            return "run", run

        task = self.client.claim_task()
        if task is not None:
            self.consecutive_tasks = 1
            return "task", task
        self.consecutive_tasks = 0
        return None


class EventBuffer:
    def __init__(self, *, max_bytes: int, max_batch: int, max_batch_bytes: int = MAX_EVENT_BATCH_BYTES) -> None:
        if max_bytes < 1 or max_batch < 1:
            raise ValueError("buffer limits must be positive")
        self.max_bytes = max_bytes
        self.max_batch = max_batch
        self.max_batch_bytes = max_batch_bytes
        self._events: deque[tuple[dict[str, Any], int]] = deque()
        self._bytes = 0

    def append(self, event: Mapping[str, Any]) -> None:
        normalized = dict(event)
        size = _json_bytes(normalized)
        if self._bytes + size > self.max_bytes:
            raise WorkerError("event buffer byte limit exceeded")
        self._events.append((normalized, size))
        self._bytes += size

    def pop_batch(self) -> list[dict[str, Any]]:
        batch = self.peek_batch()
        self.discard(len(batch))
        return batch

    def peek_batch(self) -> list[dict[str, Any]]:
        batch = []
        size = len(b'{"events":[]}')
        for event, event_size in self._events:
            separator = 1 if batch else 0
            if batch and size + separator + event_size > self.max_batch_bytes:
                break
            batch.append(event)
            size += separator + event_size
            if len(batch) >= self.max_batch:
                break
        return batch

    def discard(self, count: int) -> None:
        if count < 0 or count > len(self._events):
            raise ValueError("invalid event discard count")
        for _index in range(count):
            _event, size = self._events.popleft()
            self._bytes -= size

    def clear(self) -> None:
        self._events.clear()
        self._bytes = 0

    def __bool__(self) -> bool:
        return bool(self._events)

    def __len__(self) -> int:
        return len(self._events)


class EventSender:
    def __init__(
        self,
        client,
        run_id: int,
        lease: str,
        *,
        max_bytes: int,
        max_batch: int,
        cancel_event: threading.Event | None = None,
    ) -> None:
        self.client = client
        self.run_id = run_id
        self.lease = lease
        self.buffer = EventBuffer(max_bytes=max_bytes, max_batch=max_batch)
        self.cancel_event = cancel_event or threading.Event()

    def handle(self, event: Mapping[str, Any]) -> None:
        try:
            self.buffer.append(_bounded_event(event))
        except WorkerError:
            self.cancel_event.set()
            raise
        batch_is_byte_full = len(self.buffer.peek_batch()) < len(self.buffer)
        if len(self.buffer) >= self.buffer.max_batch or batch_is_byte_full:
            try:
                self.flush_once()
            except TransientError:
                pass

    def flush_once(self) -> bool:
        batch = self.buffer.peek_batch()
        if not batch:
            return True
        self.client.post_events(self.run_id, self.lease, batch)
        self.buffer.discard(len(batch))
        return not self.buffer

    def flush_all(
        self,
        *,
        retry_seconds: float = 45.0,
        sleep=time.sleep,
        monotonic=time.monotonic,
    ) -> None:
        deadline = monotonic() + retry_seconds
        delay = 0.25
        while self.buffer:
            try:
                self.flush_once()
                delay = 0.25
            except TransientError:
                remaining = deadline - monotonic()
                if remaining <= 0:
                    self.cancel_event.set()
                    raise WorkerError("event delivery exceeded the lease retry window")
                sleep(min(delay, remaining))
                delay = min(delay * 2, 5.0)


class LeaseMonitor:
    def __init__(
        self,
        client,
        work_kind: str,
        work_id: int,
        lease: str,
        *,
        cancel_event: threading.Event,
        heartbeat_seconds: float = 15.0,
        lease_seconds: float = 45.0,
        monotonic=time.monotonic,
    ) -> None:
        if work_kind not in {"run", "task"}:
            raise ValueError("work_kind must be run or task")
        self.client = client
        self.work_kind = work_kind
        self.work_id = work_id
        self.lease = lease
        self.cancel_event = cancel_event
        self.heartbeat_seconds = heartbeat_seconds
        self.lease_seconds = lease_seconds
        self.monotonic = monotonic
        self.last_success = monotonic()
        self.error: Exception | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def tick(self) -> None:
        try:
            if self.work_kind == "run":
                self.client.heartbeat_run(self.work_id, self.lease)
                state = self.client.run_state(self.work_id, self.lease) or {}
                if state.get("cancel_requested"):
                    self.cancel_event.set()
            else:
                self.client.heartbeat_task(self.work_id, self.lease)
            self.last_success = self.monotonic()
        except (LeaseConflict, PermanentError):
            self.cancel_event.set()
            raise
        except TransientError:
            if self.monotonic() - self.last_success >= self.lease_seconds:
                self.cancel_event.set()
                raise

    def __enter__(self) -> "LeaseMonitor":
        self._thread = threading.Thread(target=self._run, name=f"ansible-{self.work_kind}-lease", daemon=True)
        self._thread.start()
        return self

    def __exit__(self, _type, _value, _traceback) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=max(1.0, self.heartbeat_seconds + 1.0))
        self.raise_if_failed()

    def raise_if_failed(self) -> None:
        if self.error:
            raise self.error

    def _run(self) -> None:
        while not self._stop.wait(self.heartbeat_seconds):
            try:
                self.tick()
            except (LeaseConflict, PermanentError, TransientError) as error:
                self.error = error
                return


class RetryingProtocolClient:
    """Retry only idempotent protocol writes within one lease window."""

    def __init__(self, client, *, retry_seconds: float, sleep=time.sleep, monotonic=time.monotonic) -> None:
        self.client = client
        self.retry_seconds = retry_seconds
        self.sleep = sleep
        self.monotonic = monotonic

    def __getattr__(self, name):
        return getattr(self.client, name)

    def finish_run(self, run_id, lease, result):
        return self._retry(lambda: self.client.finish_run(run_id, lease, result))

    def finish_task(self, task_id, lease, result):
        return self._retry(lambda: self.client.finish_task(task_id, lease, result))

    def start_run(self, run_id, lease):
        return self._retry(lambda: self.client.start_run(run_id, lease))

    def _retry(self, operation):
        deadline = self.monotonic() + self.retry_seconds
        delay = 0.25
        while True:
            try:
                return operation()
            except TransientError:
                remaining = deadline - self.monotonic()
                if remaining <= 0:
                    raise
                self.sleep(min(delay, remaining))
                delay = min(delay * 2, 5.0)


class ExecutorWorker:
    def __init__(self, *, config, client, target_policy, workspace, stop_event: threading.Event | None = None) -> None:
        self.config = config
        self.raw_client = client
        self.client = RetryingProtocolClient(client, retry_seconds=config.lease_seconds)
        self.target_policy = target_policy
        self.workspace = workspace
        self.stop_event = stop_event or threading.Event()
        self.scheduler = FairClaimScheduler(client, max_consecutive_tasks=5)
        self._active_lock = threading.RLock()
        self._active_cancel_event: threading.Event | None = None

    def request_stop(self) -> None:
        self.stop_event.set()
        with self._active_lock:
            if self._active_cancel_event:
                self._active_cancel_event.set()

    def run_once(self) -> bool:
        claimed = self.scheduler.claim()
        if claimed is None:
            return False
        kind, work = claimed
        cancel_event = threading.Event()
        with self._active_lock:
            self._active_cancel_event = cancel_event
        monitor = LeaseMonitor(
            self.raw_client,
            kind,
            int(work["id"]),
            str(work["lease"]),
            cancel_event=cancel_event,
            heartbeat_seconds=self.config.heartbeat_seconds,
            lease_seconds=self.config.lease_seconds,
        )
        try:
            with monitor:
                if kind == "task":
                    self._task_processor(cancel_event).process(work)
                else:
                    sender = EventSender(
                        self.raw_client,
                        int(work["id"]),
                        str(work["lease"]),
                        max_bytes=self.config.max_buffer_bytes,
                        max_batch=self.config.max_event_batch,
                        cancel_event=cancel_event,
                    )
                    self._run_processor(cancel_event, sender).process(work)
        except LeaseConflict:
            cancel_event.set()
        finally:
            with self._active_lock:
                if self._active_cancel_event is cancel_event:
                    self._active_cancel_event = None
        return True

    def run_forever(self) -> None:
        delay = self.config.poll_seconds
        while not self.stop_event.is_set():
            try:
                worked = self.run_once()
                delay = self.config.poll_seconds
                if not worked:
                    self.stop_event.wait(self.config.poll_seconds)
            except TransientError:
                self.stop_event.wait(delay)
                delay = min(delay * 2, self.config.lease_seconds)

    def _task_processor(self, cancel_event):
        from .execution import AnsibleRunner
        from .tasks import TaskProcessor

        return TaskProcessor(
            client=self.client,
            target_policy=self.target_policy,
            workspace=self.workspace,
            runner=AnsibleRunner(
                max_forks=self.config.max_forks,
                cancel_grace_seconds=self.config.cancel_grace_seconds,
            ),
            cancel_event=cancel_event,
        )

    def _run_processor(self, cancel_event, sender):
        from .execution import AnsibleRunner, RunProcessor, SyntaxChecker

        return RunProcessor(
            client=self.client,
            target_policy=self.target_policy,
            workspace=self.workspace,
            syntax_checker=SyntaxChecker(cancel_grace_seconds=self.config.cancel_grace_seconds),
            runner=AnsibleRunner(
                max_forks=self.config.max_forks,
                cancel_grace_seconds=self.config.cancel_grace_seconds,
            ),
            cancel_event=cancel_event,
            event_handler=sender.handle,
            event_flusher=lambda: sender.flush_all(retry_seconds=self.config.lease_seconds),
        )


def _bounded_event(event: Mapping[str, Any]) -> dict[str, Any]:
    bounded = dict(event)
    if _json_bytes(bounded) <= MAX_EVENT_BYTES:
        return bounded

    bounded = {key: value for key, value in bounded.items() if key in EVENT_FIELDS}
    bounded["event_data"] = {}
    bounded["stdout"] = _truncate_utf8(bounded.get("stdout"), 48 * 1024)
    for field in ("event_uuid", "parent_uuid", "event_type", "play", "task", "host", "event_time"):
        bounded[field] = _truncate_utf8(bounded.get(field), 2 * 1024)
    if _json_bytes(bounded) > MAX_EVENT_BYTES:
        bounded["stdout"] = _truncate_utf8(bounded.get("stdout"), 32 * 1024)
    if _json_bytes(bounded) > MAX_EVENT_BYTES:
        raise WorkerError("event cannot be represented within the byte limit")
    return bounded


def _truncate_utf8(value: object, limit: int):
    if not isinstance(value, str):
        return value
    return value.encode("utf-8")[:limit].decode("utf-8", errors="ignore")


def _json_bytes(value: object) -> int:
    return len(json.dumps(value, separators=(",", ":")).encode("utf-8"))
