#!/bin/bash
#
# Updates UniFi OS Server to the latest release of github.com/lemker/unifi-os-server
# (each release bundles one UniFi OS Server version extracted from the official installer).
#
#   docker exec unifi-os-updater update.sh                                  regular check
#   docker exec -e MIN_AGE_DAYS=0 unifi-os-updater update.sh                install a fresh release now
#   docker exec -e FORCE_TAG=v1.7.0 unifi-os-updater update.sh              switch to exactly this release
#   docker exec -e DRY_RUN=1 -e MIN_AGE_DAYS=0 unifi-os-updater update.sh   only report
#
# Steps: pull the new image while the current version runs -> stop UniFi OS -> back up the data ->
# start the new image -> wait until UniFi OS is up -> otherwise restore the backup and the old image.
# Apps inside UniFi OS (Network, ...) update themselves from the UniFi OS web interface.

UOS_DIR=${UOS_DIR:-/volume1/docker/unifi-os-server}
MIN_AGE_DAYS=${MIN_AGE_DAYS:-2}
KEEP_BACKUPS=${KEEP_BACKUPS:-5}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-900}
ROLLBACK_TIMEOUT=${ROLLBACK_TIMEOUT:-900}
DRY_RUN=${DRY_RUN:-0}

REPO=lemker/unifi-os-server
IMAGE=ghcr.io/lemker/unifi-os-server
SERVICE=unifi-os-server
CONTAINER=unifi-os-server

ENV_FILE="${UOS_DIR}/.env"
BACKUP_DIR="${UOS_DIR}/backups"
LOG_FILE="${UOS_DIR}/update.log"
LOCK_DIR="${UOS_DIR}/.update.lock"

# Data volumes as mounted into the updater (var-log is not backed up).
VOLUMES_DIR=/uos
DATA_VOLUMES=(persistent data srv var-lib-unifi var-lib-mongodb etc-rabbitmq-ssl)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

fail() {
    log "ERROR: $*"
    exit 1
}

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found - UOS_DIR in .env must be the real path of the project"
    exit 1
fi
cd "${UOS_DIR}" || exit 1

COMPOSE="docker compose --project-directory ${UOS_DIR}"
# Use the project name of the running server (Synology Container Manager names projects itself).
PROJECT_NAME="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${CONTAINER}" 2>/dev/null)"
[[ -n "${PROJECT_NAME}" ]] && COMPOSE="${COMPOSE} -p ${PROJECT_NAME}"

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    fail "another update is running (remove ${LOCK_DIR} if it is stale)"
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT

set_tag() {
    sed -i "s/^UOS_IMAGE_TAG=.*/UOS_IMAGE_TAG=$1/" "${ENV_FILE}"
}

# uos_version <image>: UniFi OS Server version bundled in the image
uos_version() {
    docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null |
        sed -n 's/^APP_VERSION=//p'
}

# healthy: systemd is up, the UniFi OS core service is active and the web server answers
healthy() {
    [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" == "true" ]] || return 1
    [[ "$(docker exec "${CONTAINER}" systemctl is-active unifi-core 2>/dev/null)" == "active" ]] || return 1
    local code
    code="$(docker exec "${CONTAINER}" curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/ 2>/dev/null)"
    [[ "${code}" =~ ^(200|301|302)$ ]]
}

# wait_healthy <timeout>
wait_healthy() {
    local deadline=$((SECONDS + $1))
    while (( SECONDS < deadline )); do
        sleep 15
        healthy && return 0
    done
    return 1
}

# restore_backup <archive>: replaces the contents of the data volumes with the archive
restore_backup() {
    local volume
    for volume in "${DATA_VOLUMES[@]}"; do
        find "${VOLUMES_DIR}/${volume}" -mindepth 1 -delete || return 1
    done
    tar -xzf "$1" --numeric-owner -C "${VOLUMES_DIR}"
}

# ---------- Target release ----------

CURRENT="$(sed -n 's/^UOS_IMAGE_TAG=//p' "${ENV_FILE}" | tr -d '[:space:]')"
[[ -n "${CURRENT}" ]] || fail "UOS_IMAGE_TAG is not set in ${ENV_FILE}"

if [[ -n "${FORCE_TAG}" ]]; then
    TARGET="${FORCE_TAG}"
    log "Forced release: ${TARGET}"
else
    RELEASE="$(curl -fsSL --max-time 30 "https://api.github.com/repos/${REPO}/releases/latest")" ||
        fail "unable to get the latest release of ${REPO}"
    TARGET="$(echo "${RELEASE}" | jq -r '.tag_name // empty')"
    PUBLISHED="$(echo "${RELEASE}" | jq -r '.published_at // empty')"
    [[ -n "${TARGET}" ]] || fail "unable to parse the latest release"

    if [[ "${TARGET}" == "${CURRENT}" ]]; then
        log "UniFi OS Server image ${CURRENT} is up to date"
        exit 0
    fi

    NEWEST="$(printf '%s\n%s\n' "${CURRENT#v}" "${TARGET#v}" | sort -V | tail -n 1)"
    if [[ "v${NEWEST}" != "${TARGET}" && "${NEWEST}" != "${TARGET}" ]]; then
        log "Installed ${CURRENT} is newer than the latest release ${TARGET}, nothing to do"
        exit 0
    fi

    AGE_DAYS=$(( ($(date +%s) - $(date -d "${PUBLISHED}" +%s)) / 86400 ))
    if (( AGE_DAYS < MIN_AGE_DAYS )); then
        log "Release ${TARGET} is ${AGE_DAYS} day(s) old, it will be installed when it is ${MIN_AGE_DAYS} day(s) old"
        exit 0
    fi
fi

[[ "${TARGET}" =~ ^v?[0-9]+(\.[0-9]+)+$ ]] || fail "unexpected release tag: ${TARGET}"

if [[ "${TARGET}" == "${CURRENT}" ]]; then
    log "Release ${CURRENT} is already installed"
    exit 0
fi

if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: would update ${CURRENT} -> ${TARGET}"
    exit 0
fi

# ---------- Pull while the current version keeps running ----------

if ! UOS_IMAGE_TAG="${TARGET}" ${COMPOSE} pull --quiet "${SERVICE}" >>"${LOG_FILE}" 2>&1; then
    fail "unable to pull ${IMAGE}:${TARGET}, staying on ${CURRENT}"
fi
log "Updating ${CURRENT} -> ${TARGET} (UniFi OS Server $(uos_version "${IMAGE}:${CURRENT}") -> $(uos_version "${IMAGE}:${TARGET}"))"

# ---------- Backup ----------

log "Stopping UniFi OS Server"
${COMPOSE} stop "${SERVICE}" >>"${LOG_FILE}" 2>&1

mkdir -p "${BACKUP_DIR}"
BACKUP="${BACKUP_DIR}/data_${CURRENT}_$(date +%Y-%m-%d_%H-%M-%S).tar.gz"
log "Backing up the data volumes to ${BACKUP}"
if ! tar -I 'gzip -1' --numeric-owner -cf "${BACKUP}" -C "${VOLUMES_DIR}" "${DATA_VOLUMES[@]}"; then
    rm -f "${BACKUP}"
    ${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1
    fail "backup failed, ${CURRENT} started again"
fi
log "Backup done ($(du -h "${BACKUP}" | cut -f1))"

ls -1t "${BACKUP_DIR}"/data_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f

# ---------- Start the new version ----------

set_tag "${TARGET}"
${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1

log "Waiting up to ${HEALTH_TIMEOUT}s for UniFi OS to start"
if wait_healthy "${HEALTH_TIMEOUT}"; then
    log "UniFi OS Server ${TARGET} is up and running"
else
    log "ERROR: UniFi OS Server ${TARGET} did not start in ${HEALTH_TIMEOUT}s, rolling back to ${CURRENT}"
    docker logs --tail 40 "${CONTAINER}" >>"${LOG_FILE}" 2>&1
    ${COMPOSE} stop "${SERVICE}" >>"${LOG_FILE}" 2>&1

    restore_backup "${BACKUP}" || fail "unable to restore ${BACKUP}, restore it manually"

    set_tag "${CURRENT}"
    ${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1
    if wait_healthy "${ROLLBACK_TIMEOUT}"; then
        fail "rolled back to ${CURRENT}"
    else
        fail "rolled back to ${CURRENT}, but it is not healthy either - check the server"
    fi
fi

# ---------- Cleanup: keep the running image and the previous one ----------

docker images "${IMAGE}" --format '{{.Tag}}' | grep -vxE "${TARGET}|${CURRENT}|<none>" |
    while read -r tag; do
        docker rmi "${IMAGE}:${tag}" >>"${LOG_FILE}" 2>&1 && log "Removed image ${IMAGE}:${tag}"
    done
docker image prune -f >>"${LOG_FILE}" 2>&1

exit 0
