FROM ruby:3.3.6-slim

ARG RAILS_ENV=development
ARG BUNDLE_WITHOUT=""

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

RUN if [ "$RAILS_ENV" = "production" ]; then \
      SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile; \
    fi

EXPOSE 5000

CMD ["foreman", "start", "-f", "Procfile.dev"]
