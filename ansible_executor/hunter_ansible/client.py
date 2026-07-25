"""Small standard-library client for Hunter's executor protocol."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Mapping, Sequence

from .config import normalize_token


class ClientError(RuntimeError):
    pass


class PermanentError(ClientError):
    pass


class TransientError(ClientError):
    pass


class LeaseConflict(PermanentError):
    pass


class HunterClient:
    def __init__(self, base_url: str, token: str, *, opener=None, timeout: float = 10.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = normalize_token(token)
        self.opener = opener or urllib.request.build_opener()
        self.timeout = timeout

    def claim_run(self) -> dict[str, Any] | None:
        return self._request("POST", "/api/v1/ansible_executor/runs/claim")

    def claim_task(self) -> dict[str, Any] | None:
        return self._request("POST", "/api/v1/ansible_executor/tasks/claim")

    def heartbeat_run(self, run_id: int, lease: str) -> dict[str, Any] | None:
        return self._request("POST", f"/api/v1/ansible_executor/runs/{run_id}/heartbeat", lease=lease)

    def start_run(self, run_id: int, lease: str) -> dict[str, Any] | None:
        return self._request("POST", f"/api/v1/ansible_executor/runs/{run_id}/start", lease=lease)

    def heartbeat_task(self, task_id: int, lease: str) -> dict[str, Any] | None:
        return self._request("POST", f"/api/v1/ansible_executor/tasks/{task_id}/heartbeat", lease=lease)

    def run_state(self, run_id: int, lease: str) -> dict[str, Any] | None:
        return self._request("GET", f"/api/v1/ansible_executor/runs/{run_id}/control", lease=lease)

    def post_events(self, run_id: int, lease: str, events: Sequence[Mapping[str, Any]]) -> dict[str, Any] | None:
        return self._request(
            "POST",
            f"/api/v1/ansible_executor/runs/{run_id}/events",
            lease=lease,
            body={"events": list(events)},
        )

    def finish_run(self, run_id: int, lease: str, result: Mapping[str, Any]) -> dict[str, Any] | None:
        return self._request("POST", f"/api/v1/ansible_executor/runs/{run_id}/result", lease=lease, body=result)

    def finish_task(self, task_id: int, lease: str, result: Mapping[str, Any]) -> dict[str, Any] | None:
        return self._request("POST", f"/api/v1/ansible_executor/tasks/{task_id}/result", lease=lease, body=result)

    def _request(
        self,
        method: str,
        path: str,
        *,
        lease: str | None = None,
        body: Mapping[str, Any] | None = None,
    ) -> dict[str, Any] | None:
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if lease:
            headers["X-Ansible-Lease"] = lease
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                if response.status == 204:
                    return None
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            if error.code == 409:
                raise LeaseConflict("executor lease is stale or conflicting") from error
            if error.code in {401, 403, 404, 422}:
                raise PermanentError(f"Hunter rejected executor request with HTTP {error.code}") from error
            if error.code == 429 or error.code >= 500:
                raise TransientError(f"Hunter request failed with HTTP {error.code}") from error
            raise PermanentError(f"Hunter request failed with HTTP {error.code}") from error
        except (OSError, TimeoutError, json.JSONDecodeError) as error:
            raise TransientError("Hunter request failed") from error
