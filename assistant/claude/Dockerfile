FROM golang:1.25.12-alpine3.23 AS build

WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/hunter-assistant-claude ./cmd/hunter-assistant-claude

# The runtime base must be Node, not the distroless base the Go-only
# assistant services use: the official Claude Code CLI is a Node program and
# will not run on a distroless/static image. Pinned to the latest published
# version at the time this Dockerfile was written; bump deliberately.
FROM node:22-slim

RUN npm install -g @anthropic-ai/claude-code@2.1.220 \
    && npm cache clean --force

# node:22-slim already ships a `node` user and group at uid/gid 1000, so
# creating a second account there collides (groupadd exits 4 on a duplicate
# GID). Reuse that uid numerically and just provision the home directory the
# assistant_claude_home volume mounts over, owned by 1000 so the mounted volume
# inherits that ownership and the login credential is readable by the server.
RUN mkdir -p /home/claude && chown 1000:1000 /home/claude

COPY --from=build --chown=1000:1000 /out/hunter-assistant-claude /hunter-assistant-claude

ENV HOME=/home/claude
USER 1000:1000
WORKDIR /home/claude

EXPOSE 8083
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["/hunter-assistant-claude", "-healthcheck"]
ENTRYPOINT ["/hunter-assistant-claude"]
