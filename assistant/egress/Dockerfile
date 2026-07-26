FROM alpine:3.23

RUN apk add --no-cache squid=7.6-r0 ca-certificates=20260611-r0 \
    && mkdir -p /var/cache/squid /var/run/squid \
    && chown -R 31:31 /var/cache/squid /var/run/squid

COPY --chown=31:31 squid.conf /etc/squid/squid.conf

USER 31:31
EXPOSE 3128
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD ["/usr/sbin/squid", "-k", "check", "-f", "/etc/squid/squid.conf"]
ENTRYPOINT ["/usr/sbin/squid", "-N", "-f", "/etc/squid/squid.conf"]
