FROM golang:1.23-bookworm AS whiterabbit-build
WORKDIR /src
COPY tmp/whiterabbit/go.mod tmp/whiterabbit/go.sum ./
RUN go mod download
COPY tmp/whiterabbit/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/whiterabbit ./cmd/whiterabbit

FROM golang:1.24-bookworm AS scope-build
WORKDIR /src
COPY tmp/scope/go.mod tmp/scope/go.sum ./
RUN go mod download
COPY tmp/scope/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/scope ./cmd/scope

FROM ruby:3.3.6-slim

# Defaults produce the production image (what CI builds and pushes); the dev
# docker-compose overrides both args and the command for live-reload work.
ARG RAILS_ENV=production
ARG BUNDLE_WITHOUT=development:test

ENV BUNDLE_APP_CONFIG=/usr/local/bundle \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=${BUNDLE_WITHOUT} \
    RAILS_ENV=${RAILS_ENV} \
    LANG=C.UTF-8

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      libpq-dev \
      libyaml-dev \
      postgresql-client \
      git \
      curl \
      openssl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install && gem install foreman

COPY web/ ./
# The whole ops/assistant tree, not just the provisioner: assistant-secrets-init
# and assistant-token-init execute bootstrap.sh and bootstrap_service_token.rb
# from this path. bootstrap.sh is mode 0755 in Git, so COPY preserves its exec bit.
COPY ops/assistant/ /app/ops/assistant/

# Docker seeds a fresh named volume from the image's directory at the mount
# point. assistant-secrets-init runs as 1000:1000 and must create files here, so
# the directory has to exist in the image already owned by that uid — otherwise
# Docker creates it root:root 0755, mktemp fails EACCES, and no other service can
# repair it because they all mount the volume read-only.
RUN mkdir -p /run/assistant/secrets && \
    chown -R 1000:1000 /run/assistant && \
    chmod 0700 /run/assistant/secrets

COPY --from=whiterabbit-build /out/whiterabbit /usr/local/bin/whiterabbit
ENV WHITERABBIT_BIN=/usr/local/bin/whiterabbit

COPY --from=scope-build /out/scope /usr/local/bin/scope
ENV SCOPE_BIN=/usr/local/bin/scope

RUN if [ "$RAILS_ENV" = "production" ]; then \
      SECRET_KEY_BASE_DUMMY=1 \
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=build-only-primary-key \
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=build-only-deterministic-key \
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=build-only-key-derivation-salt \
      bundle exec rails assets:precompile; \
    fi

EXPOSE 5000

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
