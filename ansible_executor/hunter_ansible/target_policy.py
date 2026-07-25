"""DNS rebinding-resistant target authorization."""

from __future__ import annotations

import ipaddress
import socket
from dataclasses import dataclass
from typing import Callable, Iterable, Mapping


class TargetPolicyError(ValueError):
    """Raised when an inventory target is not explicitly authorized."""


@dataclass(frozen=True)
class ApprovedTarget:
    host: str
    address: str
    port: int
    resolved_addresses: tuple[str, ...]


class TargetPolicy:
    def __init__(
        self,
        allowed_cidrs: Iterable[str | ipaddress.IPv4Network | ipaddress.IPv6Network],
        allowed_ports: Iterable[int],
        *,
        resolver: Callable = socket.getaddrinfo,
        allow_special: bool = False,
    ) -> None:
        self.allowed_cidrs = tuple(
            network if isinstance(network, (ipaddress.IPv4Network, ipaddress.IPv6Network)) else ipaddress.ip_network(network)
            for network in allowed_cidrs
        )
        self.allowed_ports = frozenset(allowed_ports)
        self.resolver = resolver
        self.allow_special = allow_special
        if not self.allowed_cidrs or not self.allowed_ports:
            raise TargetPolicyError("target policy cannot be empty")

    def approve(self, target: Mapping[str, object]) -> ApprovedTarget:
        host = str(target.get("host", "")).strip()
        address = str(target.get("address", "")).strip()
        try:
            port = int(target.get("port", 22))
        except (TypeError, ValueError) as error:
            raise TargetPolicyError("target port must be an integer") from error
        if not host or not address:
            raise TargetPolicyError("target host and address are required")
        if port not in self.allowed_ports:
            raise TargetPolicyError(f"target port {port} is not allowed")

        try:
            answers = self.resolver(address, port, type=socket.SOCK_STREAM)
        except OSError as error:
            raise TargetPolicyError(f"target {host} could not be resolved") from error

        resolved = []
        for answer in answers:
            try:
                candidate = ipaddress.ip_address(answer[4][0].split("%", 1)[0])
            except (IndexError, ValueError, TypeError) as error:
                raise TargetPolicyError(f"target {host} returned an invalid address") from error
            canonical = str(candidate)
            if canonical not in resolved:
                resolved.append(canonical)
            if not any(candidate in network for network in self.allowed_cidrs):
                raise TargetPolicyError(f"target {host} resolved outside the allowed networks")
            if self._special(candidate) and not self.allow_special:
                raise TargetPolicyError(f"target {host} resolved to a special-use address")

        if not resolved:
            raise TargetPolicyError(f"target {host} returned no usable addresses")
        return ApprovedTarget(host, resolved[0], port, tuple(resolved))

    @staticmethod
    def _special(address: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
        metadata = address in ipaddress.ip_network("169.254.169.254/32")
        return (
            address.is_loopback
            or address.is_link_local
            or address.is_multicast
            or address.is_unspecified
            or metadata
        )
