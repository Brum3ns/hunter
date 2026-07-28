FROM golang:1.25.12-alpine3.23 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/hunter-mcp ./cmd/hunter-mcp

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build --chown=1000:1000 /out/hunter-mcp /hunter-mcp
USER 1000:1000
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["/hunter-mcp", "-healthcheck"]
ENTRYPOINT ["/hunter-mcp"]
