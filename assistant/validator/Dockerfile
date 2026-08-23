FROM golang:1.25.13-alpine3.23 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/hunter-assistant-validator ./cmd/hunter-assistant-validator

FROM alpine:3.23.5

RUN apk add --no-cache ansible-core=2.20.0-r0 ca-certificates=20260611-r0 \
    && addgroup -S -g 1000 validator \
    && adduser -S -D -H -u 1000 -G validator validator \
    && mkdir -p /etc/ansible /work \
    && chown 1000:1000 /work \
    && chmod 0700 /work

COPY --from=build --chown=1000:1000 --chmod=0555 /out/hunter-assistant-validator /hunter-assistant-validator
COPY --chown=0:0 --chmod=0444 ansible.cfg /etc/ansible/ansible.cfg

USER 1000:1000
EXPOSE 8082
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["/hunter-assistant-validator", "-healthcheck"]
ENTRYPOINT ["/hunter-assistant-validator"]
