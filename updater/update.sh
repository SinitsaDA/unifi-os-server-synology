#!/bin/bash
#
# Updates UniFi OS Server to another version of the image ghcr.io/sinitsada/unifi-os-server
# (built from the official installer by .github/workflows/build.yml, tag = UniFi OS Server version).
#
#   docker exec unifi-os-updater update.sh                                    regular check
#   docker exec -e MIN_AGE_DAYS=0 unifi-os-updater update.sh                  install a fresh release now
#   docker exec -e FORCE_VERSION=5.1.42 unifi-os-updater update.sh            switch to exactly this version
#   docker exec -e DRY_RUN=1 -e MIN_AGE_DAYS=0 unifi-os-updater update.sh     only report
#
# Steps: pull the new image while the current version runs -> stop UniFi OS -> back up the data ->
# start the new image -> wait until UniFi OS is up -> otherwise restore the backup and the old image.
# Apps inside UniFi OS (Network, ...) update themselves from the UniFi OS web interface.

# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

MIN_AGE_DAYS=${MIN_AGE_DAYS:-2}
KEEP_BACKUPS=${KEEP_BACKUPS:-5}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-900}
ROLLBACK_TIMEOUT=${ROLLBACK_TIMEOUT:-900}
DRY_RUN=${DRY_RUN:-0}

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found - UOS_DIR in .env must be the real path of the project"
    exit 1
fi
cd "${UOS_DIR}" || exit 1
COMPOSE="$(compose_cmd)"

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    fail "another update is running (remove ${LOCK_DIR} if it is stale)"
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT

# ---------- Target version ----------

CURRENT="$(current_version)"
[[ -n "${CURRENT}" ]] || fail "UOS_VERSION is not set in ${ENV_FILE}"

if [[ -n "${FORCE_VERSION}" ]]; then
    TARGET="${FORCE_VERSION#v}"
    log "Forced version: ${TARGET}"
else
    read -r TARGET CREATED < <(latest_release) || true
    [[ -n "${TARGET}" ]] || fail "unable to get the latest UniFi OS Server release from ${FW_API}"

    if ! version_newer "${TARGET}" "${CURRENT}"; then
        log "UniFi OS Server ${CURRENT} is up to date"
        exit 0
    fi

    AGE_DAYS=$(( ($(date +%s) - $(date -d "${CREATED}" +%s)) / 86400 ))
    if (( AGE_DAYS < MIN_AGE_DAYS )); then
        log "UniFi OS Server ${TARGET} is ${AGE_DAYS} day(s) old, it will be installed when it is ${MIN_AGE_DAYS} day(s) old"
        exit 0
    fi
fi

[[ "${TARGET}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "unexpected version: ${TARGET}"

if [[ "${TARGET}" == "${CURRENT}" ]]; then
    log "UniFi OS Server ${CURRENT} is already installed"
    exit 0
fi

if ! image_exists "${TARGET}"; then
    log "Image ${UOS_IMAGE}:${TARGET} is not published yet, staying on ${CURRENT}"
    exit 0
fi

if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: would update UniFi OS Server ${CURRENT} -> ${TARGET}"
    exit 0
fi

# ---------- Pull while the current version keeps running ----------

if ! UOS_VERSION="${TARGET}" ${COMPOSE} pull --quiet "${SERVICE}" >>"${LOG_FILE}" 2>&1; then
    fail "unable to pull ${UOS_IMAGE}:${TARGET}, staying on ${CURRENT}"
fi
log "Updating UniFi OS Server ${CURRENT} -> ${TARGET}"

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

find "${BACKUP_DIR}" -maxdepth 1 -name 'data_*.tar.gz' -printf '%T@ %p\n' | sort -rn |
    tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2- | xargs -r rm -f

# ---------- Start the new version ----------

set_version "${TARGET}"
${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1

log "Waiting up to ${HEALTH_TIMEOUT}s for UniFi OS to start"
if wait_healthy "${HEALTH_TIMEOUT}"; then
    log "UniFi OS Server ${TARGET} is up and running"
else
    log "ERROR: UniFi OS Server ${TARGET} did not start in ${HEALTH_TIMEOUT}s, rolling back to ${CURRENT}"
    docker logs --tail 40 "${CONTAINER}" >>"${LOG_FILE}" 2>&1
    ${COMPOSE} stop "${SERVICE}" >>"${LOG_FILE}" 2>&1
    restore_backup "${BACKUP}" || fail "unable to restore ${BACKUP}, restore it manually"
    set_version "${CURRENT}"
    ${COMPOSE} up -d --no-deps "${SERVICE}" >>"${LOG_FILE}" 2>&1
    if wait_healthy "${ROLLBACK_TIMEOUT}"; then
        fail "rolled back to ${CURRENT}"
    else
        fail "rolled back to ${CURRENT}, but it is not healthy either - check the server"
    fi
fi

# ---------- Cleanup: keep the running image and the previous one ----------

docker images "${UOS_IMAGE}" --format '{{.Tag}}' | grep -vxE "${TARGET//./\\.}|${CURRENT//./\\.}|latest|<none>" |
    while read -r tag; do
        docker rmi "${UOS_IMAGE}:${tag}" >>"${LOG_FILE}" 2>&1 && log "Removed image ${UOS_IMAGE}:${tag}"
    done
docker image prune -f >>"${LOG_FILE}" 2>&1

exit 0
