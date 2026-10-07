#!/bin/bash
#
# Restores UniFi OS Server from a backup made by update.sh and starts the UniFi OS Server version
# the backup was made with (taken from the file name: data_<version>_<date>.tar.gz).
#
#   docker exec unifi-os-updater restore.sh                          list the backups
#   docker exec unifi-os-updater restore.sh <archive>                restore (name or path)

# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-900}

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

VERSION="$(basename "${ARCHIVE}" | sed -n 's/^data_\([0-9][0-9.]*[0-9]\)_.*/\1/p')"
[[ -n "${VERSION}" ]] || { echo "Unable to get the version from the file name: ${ARCHIVE}"; exit 1; }

if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    echo "An update is running (remove ${LOCK_DIR} if it is stale)"
    exit 1
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT

COMPOSE="$(compose_cmd)"

log "Restoring ${ARCHIVE} (UniFi OS Server ${VERSION})"
${COMPOSE} stop "${SERVICE}"
restore_backup "${ARCHIVE}" || fail "unable to restore ${ARCHIVE}"
set_version "${VERSION}"
${COMPOSE} up -d --no-deps "${SERVICE}"

echo "Waiting up to ${HEALTH_TIMEOUT}s for UniFi OS to start..."
if wait_healthy "${HEALTH_TIMEOUT}"; then
    log "Restored: UniFi OS Server ${VERSION} is running"
else
    fail "UniFi OS did not start in ${HEALTH_TIMEOUT}s, check: docker logs ${CONTAINER}"
fi
