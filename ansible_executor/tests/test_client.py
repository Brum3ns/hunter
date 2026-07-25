import io
import json
import unittest
import urllib.error

from ansible_executor.hunter_ansible.client import HunterClient, LeaseConflict, PermanentError, TransientError


class Response(io.BytesIO):
    def __init__(self, status, body=b""):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class ClientTest(unittest.TestCase):
    def test_sends_normalized_bearer_and_lease_headers_without_query_secrets(self):
        opener = FakeOpener([Response(200, b'{"id":1,"lease":"lease-value"}')])
        client = HunterClient("http://web:5000", ' "runner-token" ', opener=opener)

        body = client.claim_run()

        request, _timeout = opener.requests[0]
        self.assertEqual("Bearer runner-token", request.headers["Authorization"])
        self.assertNotIn("runner-token", request.full_url)
        self.assertEqual(1, body["id"])

    def test_maps_no_content_lease_conflict_auth_and_transient_failures(self):
        self.assertIsNone(HunterClient("http://web", "token", opener=FakeOpener([Response(204)])).claim_run())

        conflict = urllib.error.HTTPError("http://web", 409, "Conflict", {}, io.BytesIO(b'{"error":"lease_conflict"}'))
        with self.assertRaises(LeaseConflict):
            HunterClient("http://web", "token", opener=FakeOpener([conflict])).heartbeat_run(1, "lease")

        unauthorized = urllib.error.HTTPError("http://web", 401, "Unauthorized", {}, io.BytesIO(b"{}"))
        with self.assertRaises(PermanentError):
            HunterClient("http://web", "token", opener=FakeOpener([unauthorized])).claim_run()

        with self.assertRaises(TransientError):
            HunterClient("http://web", "token", opener=FakeOpener([OSError("offline")])).claim_run()

    def test_posts_bounded_event_batches_with_lease_header(self):
        opener = FakeOpener([Response(200, b'{"accepted":1}')])
        client = HunterClient("http://web:5000", "token", opener=opener)

        client.post_events(7, "lease-value", [{"event_uuid": "one", "counter": 1, "event_type": "ok"}])

        request, _timeout = opener.requests[0]
        self.assertEqual("lease-value", request.headers["X-ansible-lease"])
        self.assertEqual(1, len(json.loads(request.data)["events"]))


if __name__ == "__main__":
    unittest.main()
