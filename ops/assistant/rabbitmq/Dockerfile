FROM rabbitmq:4-management

RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y jq \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0555 entrypoint.sh /usr/local/bin/hunter-assistant-rabbitmq-entrypoint
COPY --chmod=0555 hash_password.sh /usr/local/bin/hunter-assistant-rabbitmq-hash-password

ENTRYPOINT ["/usr/local/bin/hunter-assistant-rabbitmq-entrypoint"]
CMD ["rabbitmq-server"]
