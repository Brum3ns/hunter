"""Fail-closed executor configuration."""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass
from typing import Mapping
from urllib.parse import urlsplit, urlunsplit


class ConfigError(ValueError):
    """Raised when executor configuration is missing or unsafe."""


def normalize_token(value: str) -> str:
    """Trim whitespace and one matching layer of shell-style quotes."""
    token = value.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in {"'", '"'}:
        token = token[1:-1].strip()
    return token


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise ConfigError(f"{name} is required")
    return value


def _positive_float(env: Mapping[str, str], name: str, default: float) -> float:
    try:
        value = float(env.get(name, str(default)))
    except ValueError as error:
        raise ConfigError(f"{name} must be a number") from error
    if value <= 0:
        raise ConfigError(f"{name} must be positive")
    return value


def _positive_int(env: Mapping[str, str], name: str, default: int) -> int:
    try:
        value = int(env.get(name, str(default)))
    except ValueError as error:
        raise ConfigError(f"{name} must be an integer") from error
    if value <= 0:
        raise ConfigError(f"{name} must be positive")
    return value


def _parse_url(raw_url: str) -> str:
    parsed = urlsplit(raw_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ConfigError("HUNTER_URL must be an absolute HTTP(S) URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ConfigError("HUNTER_URL must not include credentials, query, or fragment")

    if parsed.scheme == "http":
        hostname = parsed.hostname
        try:
            development_host = ipaddress.ip_address(hostname).is_loopback
        except ValueError:
            development_host = hostname in {"web", "localhost"}
        if not development_host:
            raise ConfigError("HUNTER_URL requires HTTPS outside local development")

    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""))


@dataclass(frozen=True)
class Config:
    hunter_url: str
    runner_token: str
    allowed_cidrs: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]
    allowed_ports: tuple[int, ...]
    poll_seconds: float
    heartbeat_seconds: float
    lease_seconds: float
    max_event_batch: int
    max_buffer_bytes: int
    cancel_grace_seconds: float
    workspace_root: str
    max_forks: int
    allow_special_targets: bool

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "Config":
        hunter_url = _parse_url(_required(env, "HUNTER_URL"))
        runner_token = normalize_token(_required(env, "HUNTER_RUNNER_TOKEN"))
        if not runner_token:
            raise ConfigError("HUNTER_RUNNER_TOKEN is empty after normalization")

        try:
            allowed_cidrs = tuple(
                ipaddress.ip_network(value.strip(), strict=False)
                for value in _required(env, "ANSIBLE_ALLOWED_CIDRS").split(",")
                if value.strip()
            )
        except ValueError as error:
            raise ConfigError("ANSIBLE_ALLOWED_CIDRS contains an invalid network") from error
        if not allowed_cidrs:
            raise ConfigError("ANSIBLE_ALLOWED_CIDRS must contain at least one network")

        raw_ports = env.get("ANSIBLE_ALLOWED_PORTS", "22")
        try:
            allowed_ports = tuple(dict.fromkeys(int(value.strip()) for value in raw_ports.split(",") if value.strip()))
        except ValueError as error:
            raise ConfigError("ANSIBLE_ALLOWED_PORTS must contain integers") from error
        if not allowed_ports or any(port < 1 or port > 65535 for port in allowed_ports):
            raise ConfigError("ANSIBLE_ALLOWED_PORTS must contain valid TCP ports")

        allow_special = env.get("ANSIBLE_ALLOW_SPECIAL_TARGETS", "").strip().lower() in {"1", "true", "yes"}
        if allow_special and not _local_development_url(hunter_url):
            raise ConfigError("ANSIBLE_ALLOW_SPECIAL_TARGETS is restricted to local development")
        return cls(
            hunter_url=hunter_url,
            runner_token=runner_token,
            allowed_cidrs=allowed_cidrs,
            allowed_ports=allowed_ports,
            poll_seconds=_positive_float(env, "ANSIBLE_POLL_SECONDS", 2.0),
            heartbeat_seconds=_positive_float(env, "ANSIBLE_HEARTBEAT_SECONDS", 15.0),
            lease_seconds=_positive_float(env, "ANSIBLE_LEASE_SECONDS", 45.0),
            max_event_batch=_positive_int(env, "ANSIBLE_MAX_EVENT_BATCH", 100),
            max_buffer_bytes=_positive_int(env, "ANSIBLE_MAX_BUFFER_BYTES", 5 * 1024 * 1024),
            cancel_grace_seconds=_positive_float(env, "ANSIBLE_CANCEL_GRACE_SECONDS", 10.0),
            workspace_root=env.get("ANSIBLE_WORKSPACE_ROOT", "/runner").strip() or "/runner",
            max_forks=_positive_int(env, "ANSIBLE_MAX_FORKS", 5),
            allow_special_targets=allow_special,
        )


def _local_development_url(url: str) -> bool:
    parsed = urlsplit(url)
    if parsed.hostname in {"web", "localhost"}:
        return True
    try:
        return ipaddress.ip_address(parsed.hostname or "").is_loopback
    except ValueError:
        return False
