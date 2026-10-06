#!/bin/bash
#
# Restores UniFi OS Server from a backup made by update.sh and starts the image release the backup
# was made with (taken from the file name: data_<release>_<date>.tar.gz).
#
#   docker exec unifi-os-updater restore.sh                          list the backups
#   docker exec unifi-os-updater restore.sh <archive>                restore (name or path)

UOS_DIR=${UOS_DIR:-/volume1/docker/unifi-os-server}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-900}

SERVICE=unifi-os-server
CONTAINER=unifi-os-server
ENV_FILE="${UOS_DIR}/.env"
BACKUP_DIR="${UOS_DIR}/backups"
VOLUMES_DIR=/uos
DATA_VOLUMES=(persistent data srv var-lib-unifi var-lib-mongodb etc-rabbitmq-ssl)

cd "${UOS_DIR}" || exit 1

if [[ -z "$1" ]]; then
    echo "Backups in ${BACKUP_DIR}:"
    find "${BACKUP_DIR}" -maxdepth 1 -name 'data_*.tar.gz' -printf '%T@ %f\n' | sort -rn | cut -d' ' -f2
    echo "Usage: restore.sh <archive>"
    exit 0
fi

ARCHIVE="$1"
[[ -f "${ARCHIVE}" ]] || ARCHIVE="${BACKUP_DIR}/$1"
[[ -f "${ARCHIVE}" ]] || { echo "Backup not found: $1"; exit 1; }

TAG="$(basename "${ARCHIVE}" | sed -n 's/^data_\(v[0-9.]*\)_.*/\1/p')"
[[ -n "${TAG}" ]] || { echo "Unable to get the release from the file name: ${ARCHIVE}"; exit 1; }

COMPOSE="docker compose --project-directory ${UOS_DIR}"
PROJECT_NAME="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${CONTAINER}" 2>/dev/null)"
[[ -n "${PROJECT_NAME}" ]] && COMPOSE="${COMPOSE} -p ${PROJECT_NAME}"

echo "Restoring ${ARCHIVE} (release ${TAG})"
${COMPOSE} stop "${SERVICE}"

for volume in "${DATA_VOLUMES[@]}"; do
    find "${VOLUMES_DIR}/${volume}" -mindepth 1 -delete || exit 1
done
tar -xzf "${ARCHIVE}" --numeric-owner -C "${VOLUMES_DIR}" || { echo "Unable to extract ${ARCHIVE}"; exit 1; }

sed -i "s/^UOS_IMAGE_TAG=.*/UOS_IMAGE_TAG=${TAG}/" "${ENV_FILE}"
${COMPOSE} up -d --no-deps "${SERVICE}"

echo "Waiting up to ${HEALTH_TIMEOUT}s for UniFi OS to start..."
deadline=$((SECONDS + HEALTH_TIMEOUT))
while (( SECONDS < deadline )); do
    sleep 15
    if [[ "$(docker exec "${CONTAINER}" systemctl is-active unifi-core 2>/dev/null)" == "active" ]]; then
        echo "Restored: UniFi OS Server ${TAG} is running."
        exit 0
    fi
done

echo "UniFi OS did not start in ${HEALTH_TIMEOUT}s, check: docker logs ${CONTAINER}"
exit 1
