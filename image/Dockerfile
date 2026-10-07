# UniFi OS Server image for Docker.
#
# BASE_IMAGE is the original "uosserver" image extracted from the official UniFi OS Server
# installer by .github/workflows/build.yml (the installer runs it with Podman). Only the
# container entrypoint with the Synology patches is added on top.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG UOS_VERSION
ARG SOURCE_URL=""

LABEL org.opencontainers.image.title="UniFi OS Server" \
      org.opencontainers.image.description="UniFi OS Server (Ubiquiti) extracted from the official installer, for Docker and Synology" \
      org.opencontainers.image.version="${UOS_VERSION}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="Ubiquiti Inc. (UniFi OS Server), packaging: SinitsaDA"

ENV container="docker" \
    APP_VERSION="${UOS_VERSION}" \
    APP_MODEL="UOSSERVER" \
    PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

COPY uos-entrypoint.sh /root/uos-entrypoint.sh
RUN chmod +x /root/uos-entrypoint.sh

ENTRYPOINT ["/root/uos-entrypoint.sh"]
