FROM alpine:3

LABEL org.opencontainers.image.title="UniFi OS Server updater" \
      org.opencontainers.image.description="Keeps the UniFi OS Server container up to date, also on 'Update' in the UniFi OS console"

RUN apk add --no-cache bash coreutils curl findutils grep gzip jq sed tar tzdata \
        docker-cli docker-cli-compose nodejs

# UCP4 manager for "Update" in the UniFi OS console (needs the ws WebSocket library).
RUN apk add --no-cache --virtual .npm npm && \
    mkdir -p /opt/supervisor && cd /opt/supervisor && \
    npm init -y >/dev/null && npm install --omit=dev --no-audit --no-fund ws@8 && \
    apk del .npm
COPY supervisor.js /opt/supervisor/

COPY lib.sh entrypoint.sh update.sh console-update.sh restore.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/lib.sh /usr/local/bin/entrypoint.sh /usr/local/bin/update.sh /usr/local/bin/console-update.sh /usr/local/bin/restore.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
