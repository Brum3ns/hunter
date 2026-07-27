# Hunter MCP broker

`hunter-mcp` is Hunter's dedicated, fixed-catalog Model Context Protocol broker.
It accepts only authenticated streamable HTTP MCP requests from the assistant
gateway, rechecks each short-lived turn grant against Rails, and calls only the
dedicated `/api/v1/assistant/machine` routes. It has no generic HTTP, filesystem,
shell, search, write, send, or execution tool.

## Runtime contract

- Listen address: `0.0.0.0:8080` on an internal Compose network only.
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
- Accepted `Host` values: `ASSISTANT_MCP_ALLOWED_HOSTS` (default
  `hunter-mcp:8080`).
- Accepted browser-style origins: `ASSISTANT_MCP_ALLOWED_ORIGINS`. An absent
  `Origin` is accepted for service-to-service traffic; any present origin must
  exactly match the allowlist. This is the explicit cross-origin protection for
  Go SDK v1.6.0.

Every MCP request requires both `Authorization: Bearer <gateway token>` and
`X-Hunter-Turn-Grant: <opaque grant>`. Neither value is logged or included in an
error response.

## Verification

Run locally with Go 1.25:

```sh
go test -race ./...
go test -run=Fuzz -fuzz=FuzzToolInput -fuzztime=20s
docker build -t hunter-mcp:test .
```

The protocol target is MCP `2025-11-25`, served with
`github.com/modelcontextprotocol/go-sdk v1.6.0`. The official conformance CLI
does not accept custom headers, so run it through a loopback-only test proxy that
injects disposable gateway and turn-grant values. The proxy must never be part
of a deployment. The commands verified on 2026-07-26 were:

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

All three scenarios passed. Hunter's own tests cover the authentication,
origin, host, closed-schema, grant-scope, and denial behavior that the generic
conformance suite cannot exercise.
