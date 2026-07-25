import threading
import unittest
import json
from types import SimpleNamespace

from ansible_executor.hunter_ansible.client import LeaseConflict, TransientError
from ansible_executor.hunter_ansible.worker import (
    EventBuffer,
    EventSender,
    ExecutorWorker,
    FairClaimScheduler,
    LeaseMonitor,
    WorkerError,
)


class FakeClient:
    def __init__(self, tasks, runs):
        self.tasks = list(tasks)
        self.runs = list(runs)
        self.calls = []

    def claim_task(self):
        self.calls.append("task")
        return self.tasks.pop(0) if self.tasks else None

    def claim_run(self):
        self.calls.append("run")
        return self.runs.pop(0) if self.runs else None


class WorkerTest(unittest.TestCase):
    def test_fairness_checks_a_run_after_five_consecutive_tasks(self):
        client = FakeClient(tasks=[{"id": i} for i in range(6)], runs=[{"id": 99}])
        scheduler = FairClaimScheduler(client, max_consecutive_tasks=5)

        claimed = [scheduler.claim() for _ in range(6)]

        self.assertEqual(["task"] * 5 + ["run"], [kind for kind, _work in claimed])
        self.assertEqual(99, claimed[-1][1]["id"])

    def test_event_buffer_batches_and_fails_closed_at_byte_limit(self):
        buffer = EventBuffer(max_bytes=100, max_batch=2)
        buffer.append({"event_uuid": "1", "counter": 1, "event_type": "ok"})
        buffer.append({"event_uuid": "2", "counter": 2, "event_type": "ok"})
        self.assertEqual(2, len(buffer.pop_batch()))

        with self.assertRaises(WorkerError):
            buffer.append({"event_uuid": "large", "counter": 3, "event_type": "ok", "stdout": "x" * 200})

    def test_event_sender_keeps_a_batch_until_hunter_accepts_it(self):
        class Client:
            calls = 0

            def post_events(self, _run_id, _lease, _events):
                self.calls += 1
                if self.calls == 1:
                    raise TransientError("offline")

        client = Client()
        sender = EventSender(client, 7, "lease", max_bytes=1024, max_batch=1)
        sender.handle({"event_uuid": "one", "counter": 1, "event_type": "ok"})

        self.assertEqual(1, len(sender.buffer))
        sender.flush_once()
        self.assertEqual(0, len(sender.buffer))

    def test_event_sender_caps_individual_events_and_http_batches(self):
        class Client:
            def __init__(self):
                self.batches = []

            def post_events(self, _run_id, _lease, _events):
                self.batches.append(list(_events))

        client = Client()
        sender = EventSender(client, 7, "lease", max_bytes=5 * 1024 * 1024, max_batch=100)
        for counter in range(20):
            sender.handle({
                "event_uuid": str(counter),
                "counter": counter,
                "event_type": "verbose",
                "stdout": "x" * 70_000,
                "event_data": {"large": "y" * 70_000},
            })

        batches = [*client.batches, sender.buffer.peek_batch()]
        self.assertTrue(client.batches, "byte-full batches should flush before the count limit")
        self.assertTrue(all(len(json.dumps({"events": batch}).encode()) <= 1024 * 1024 for batch in batches))
        self.assertTrue(all(len(json.dumps(event).encode()) <= 64 * 1024 for batch in batches for event in batch))

    def test_lease_monitor_cancels_immediately_on_stale_lease_or_control_request(self):
        class Client:
            def __init__(self, conflict=False):
                self.conflict = conflict

            def heartbeat_run(self, _run_id, _lease):
                if self.conflict:
                    raise LeaseConflict("stale")

            def run_state(self, _run_id, _lease):
                return {"cancel_requested": True}

        cancel = threading.Event()
        monitor = LeaseMonitor(Client(), "run", 7, "lease", cancel_event=cancel)
        monitor.tick()
        self.assertTrue(cancel.is_set())

        cancel = threading.Event()
        monitor = LeaseMonitor(Client(conflict=True), "run", 7, "lease", cancel_event=cancel)
        with self.assertRaises(LeaseConflict):
            monitor.tick()
        self.assertTrue(cancel.is_set())

    def test_stop_request_propagates_to_active_work_for_workspace_cleanup(self):
        config = SimpleNamespace(lease_seconds=45)
        worker = ExecutorWorker(config=config, client=object(), target_policy=object(), workspace=object())
        active = threading.Event()
        worker._active_cancel_event = active

        worker.request_stop()

        self.assertTrue(worker.stop_event.is_set())
        self.assertTrue(active.is_set())


if __name__ == "__main__":
    unittest.main()
