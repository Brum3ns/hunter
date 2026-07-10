FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates ruby \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY runner/curl_command.rb runner/token.rb runner/agent.rb ./

USER nobody
CMD ["ruby", "agent.rb"]
