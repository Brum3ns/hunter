# Hunter MCP broker

`hunter-mcp` is Hunter's dedicated, fixed-catalog Model Context Protocol broker.
Its approved token-only external MCP boundary accepts authenticated streamable
HTTP requests from managed runners or trusted external clients and calls only
the dedicated `/api/v1/assistant/machine` routes. A valid shared client bearer
grants the full currently enabled reviewed catalog without a turn grant. It has
no generic HTTP, filesystem, shell, search, credential, send, or execution tool.

## Runtime contract

- Container listen address: `0.0.0.0:8080`; Compose publishes it with a loopback default
  of `127.0.0.1:8080`, configurable through `HUNTER_ASSISTANT_MCP_BIND_IP` and
  `HUNTER_ASSISTANT_MCP_PORT`.
- MCP endpoint: `POST /mcp` (the SDK also handles protocol-required methods).
- Health endpoint: `GET /healthz`, returning status only.
- Gateway credential: `ASSISTANT_GATEWAY_MCP_TOKEN`, a plain environment
  variable — checked against whatever bearer token the caller presents.
- Hunter credential: `ASSISTANT_MCP_HUNTER_TOKEN`, a plain environment
  variable — presented to Hunter's `/api/v1/assistant/machine` routes.

Both tokens must be present and pass the same validity checks (non-empty,
bounded length, no NUL/CR/LF/tab/space); a missing or malformed token makes
the process `log.Fatal` at startup.
- Hunter URL: `http://web:5000`, restricted by
  `ASSISTANT_HUNTER_ALLOWED_HOSTS` (default `web:5000`).
- Inbound authorization: every MCP request requires only
  `Authorization: Bearer <shared client token>`. The token is compared in
  constant time and is never logged or included in an error response. Host,
  Origin, `X-Hunter-Turn-Grant`, and proxy-supplied source headers do not grant
  or restrict application authority.
- The internal `ASSISTANT_MCP_HUNTER_TOKEN` is the separate broker-to-Rails
  identity. It is never a Codex client credential.

The loopback default is suitable for Codex on the Hunter host. WAN deployments
must use HTTPS or authenticated VPN ingress and a source-network firewall/proxy restriction
limited to the trusted Codex host; the bearer must never cross plaintext WAN.
All clients sharing the bearer are indistinguishable in Hunter audit, and
rotation interrupts all of them together.

## Verification

Run locally with Go 1.25:

```sh
go test -race ./...
go test -run=Fuzz -fuzz=FuzzToolInput -fuzztime=20s
docker build -t hunter-mcp:test .
```

The protocol target is MCP `2025-11-25`, served with
`github.com/modelcontextprotocol/go-sdk v1.6.0`. If a conformance tool cannot
inject an Authorization bearer, run it through a loopback-only test proxy that
injects a disposable client bearer. The proxy must never be part of a
deployment. The commands verified on 2026-07-26 were:

```sh
npx --yes @modelcontextprotocol/conformance@0.1.16 server \
  --url http://127.0.0.1:18081/mcp --scenario server-initialize \
  --spec-version 2025-11-25
npx --yes @modelcontextprotocol/conformance@0.1.16 server \
  --url http://127.0.0.1:18081/mcp --scenario tools-list \
  --spec-version 2025-11-25
npx --yes @modelcontextprotocol/conformance@0.1.16 server \
  --url http://127.0.0.1:18081/mcp --scenario ping \
  --spec-version 2025-11-25
```

All three scenarios passed. Hunter's own tests cover bearer authentication,
closed schemas, fixed-catalog and live-gate enforcement, secret/delete/
governance denials, receipt validation, and bounded result behavior that the
generic conformance suite cannot exercise.
