FROM alpine:3

LABEL org.opencontainers.image.title="UniFi OS Server updater" \
      org.opencontainers.image.description="Keeps the UniFi OS Server container on the latest release"

RUN apk add --no-cache bash coreutils curl findutils grep gzip jq sed tar tzdata \
        docker-cli docker-cli-compose

COPY entrypoint.sh update.sh restore.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/update.sh /usr/local/bin/restore.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
