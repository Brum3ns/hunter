# Hunter assistant Ansible validator

This service serves only redacted terminal validation results over HTTP. It has
no Hunter API client or Hunter token. Each request is syntax-checked by a fixed
`ansible-playbook` invocation inside a fresh private directory and the
directory is removed afterward.

## Runtime contract

- Listen address: `0.0.0.0:8082`.
- Validation endpoint: `POST /validations`.
- Health endpoint: `GET /healthz`, returning status only.

The runtime expects its one machine credential, `ASSISTANT_VALIDATOR_INGRESS_TOKEN`,
as a plain environment variable — the token Rails presents on every
`POST /validations`. A missing or malformed value makes the process
`log.Fatal` at startup.

The container must receive `/work` as a bounded `tmpfs`; the hardened Compose
service and network policy are added in the later deployment-hardening task.

Run unit and race tests with:

```sh
go test -race ./...
```

Build the image with:

```sh
docker build -t hunter-assistant-validator:test .
```
