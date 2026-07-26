# Hunter assistant Ansible validator

This service consumes only the non-durable validation queue and publishes only
redacted terminal validation events. It has no Hunter API client or Hunter
token. Each request is syntax-checked by a fixed `ansible-playbook` invocation
inside a fresh private directory and the directory is removed afterward.

The runtime expects the RabbitMQ password in the regular, non-symlink file
`/run/secrets/assistant_validator_amqp_password` with target mode `0400` (or a
standalone Compose host source at mode `0600` whose container mount rejects
writes). The
container must receive `/work` as a bounded `tmpfs`; the hardened Compose
service and network policy are added in the later deployment-hardening task.

Run unit and race tests with:

```sh
go test -race ./...
```

Build the image with:

```sh
docker build -t hunter-assistant-validator:test .
```
