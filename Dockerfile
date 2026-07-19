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
      curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install && gem install foreman

COPY web/ ./

COPY --from=whiterabbit-build /out/whiterabbit /usr/local/bin/whiterabbit
ENV WHITERABBIT_BIN=/usr/local/bin/whiterabbit

COPY --from=scope-build /out/scope /usr/local/bin/scope
ENV SCOPE_BIN=/usr/local/bin/scope

RUN if [ "$RAILS_ENV" = "production" ]; then \
      SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile; \
    fi

EXPOSE 3000

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
