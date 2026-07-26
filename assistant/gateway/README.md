# Hunter assistant gateway

The gateway is Hunter's bounded agent loop. It consumes versioned turn jobs,
calls exactly the provider and model pinned in the conversation profile, maps
native provider function calls to the six fixed MCP tools, and publishes closed
assistant-message or validated-draft events. It contains no shell, generic HTTP
tool, filesystem tool, hosted provider tool, or provider fallback.

The remote OpenAI and Anthropic models do not run in this image. This service is
the only provider client. Its Internet traffic must traverse
`http://assistant-egress:3128`; the transport refuses direct connections and
destinations other than `api.openai.com:443` and `api.anthropic.com:443`.

Runtime credentials are regular, non-symlink files mounted mode `0400`. For
standalone Compose file sources, host mode `0600` is accepted only when the
in-container mount rejects write access:

- `/run/secrets/assistant_openai_api_key`
- `/run/secrets/assistant_anthropic_api_key`
- `/run/secrets/assistant_gateway_mcp_token`
- `/run/secrets/assistant_gateway_amqp_password`

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
