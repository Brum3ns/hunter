# Hunter assistant gateway

The gateway is Hunter's bounded agent loop. It consumes versioned turn jobs,
calls exactly the provider and model pinned in the conversation profile, maps
native provider function calls to the six fixed MCP tools, and publishes closed
assistant-message or validated-draft events. It contains no shell, generic HTTP
tool, filesystem tool, hosted provider tool, or provider fallback.

The remote OpenAI and Anthropic models do not run in this image. This service is
the only provider client.

## Runtime contract

- Listen address: `0.0.0.0:8081`.
- Turn endpoint: `POST /turns`.
- Health endpoint: `GET /healthz`, returning status only.

All credentials arrive as plain environment variables — there is no secrets
volume or mounted file:

- `ASSISTANT_ANTHROPIC_API_KEY` — Anthropic provider key.
- `ASSISTANT_OPENAI_API_KEY` — OpenAI provider key.
- `ASSISTANT_GATEWAY_MCP_TOKEN` — the gateway-to-MCP credential presented to
  `hunter-mcp`.
- `ASSISTANT_GATEWAY_INGRESS_TOKEN` — the credential Rails presents on every
  `POST /turns`.

A missing or malformed machine credential (`ASSISTANT_GATEWAY_MCP_TOKEN` or
`ASSISTANT_GATEWAY_INGRESS_TOKEN`) makes the process `log.Fatal` at startup. A
provider key that is absent, empty, oversize, or a placeholder value just
drops that one provider out of the gateway's available profiles — the process
keeps running idle rather than exiting, since idling is the default state on
a fresh `compose up` before any key is configured.

The gateway has the gateway-to-MCP token but never the MCP-to-Hunter token. It
has no route or client for Hunter's Rails API.

## Verification

With Go 1.25:

```sh
go test -race ./...
go vet ./...
CGO_ENABLED=0 go build ./cmd/hunter-assistant-gateway
docker build -t hunter-assistant-gateway:test .
```

All provider tests use local TLS mocks and disposable values, never live API
keys.
