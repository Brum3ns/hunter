FROM golang:1.25.13-alpine3.23 AS build

WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/hunter-assistant-codex ./cmd/hunter-assistant-codex

FROM node:22-slim

RUN npm install -g @openai/codex@0.144.4 \
    && npm cache clean --force

# node:22-slim already provides uid/gid 1000. Reuse it for the service, keep
# the login/session home writable for its dedicated volume, and make the empty
# work root immutable to the non-root process.
RUN mkdir -p /home/codex/.codex /workspace \
    && chown -R 1000:1000 /home/codex \
    && chown root:root /workspace \
    && chmod 0555 /workspace

COPY --from=build --chown=1000:1000 /out/hunter-assistant-codex /hunter-assistant-codex

ENV HOME=/home/codex \
    CODEX_HOME=/home/codex/.codex
USER 1000:1000
WORKDIR /workspace

EXPOSE 8084
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["/hunter-assistant-codex", "-healthcheck"]
ENTRYPOINT ["/hunter-assistant-codex"]
