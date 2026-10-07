#!/bin/bash
#
# Handles "Update" pressed in the UniFi OS console.
#
# supervisor.js (the "UOS Server Manager" for UniFi OS) writes the request with the requested
# UniFi OS Server version to /uos/boot/uos-update.json. It is carried out as a regular update
# (backup, health check, rollback) to the image of that version. If the image is not built yet,
# its build is started on GitHub (when GITHUB_TOKEN is set) and the request is retried.
#
# Exit codes: 0 - nothing to do or done, 1 - failed, 2 - not possible yet (retry later).

# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

[[ -f "${REQUEST_FILE}" ]] || exit 0

REQUESTED="$(jq -r '.version // empty' "${REQUEST_FILE}" 2>/dev/null | sed 's/^v//')"
CURRENT="$(current_version)"

if [[ ! "${REQUESTED}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    log "Invalid console update request ${REQUEST_FILE}, removing it"
    rm -f "${REQUEST_FILE}"
    exit 1
fi

if ! version_newer "${REQUESTED}" "${CURRENT}"; then
    log "Console update to ${REQUESTED} requested, but UniFi OS Server ${CURRENT} is installed, ignoring"
    rm -f "${REQUEST_FILE}"
    exit 0
fi

if ! image_exists "${REQUESTED}"; then
    if [[ ! -f "${REQUEST_FILE}.build" ]] && request_build "${REQUESTED}"; then
        touch "${REQUEST_FILE}.build"
        log "Console update to ${REQUESTED}: the image is not built yet, its build has been started on GitHub, will retry"
    else
        log "Console update to ${REQUESTED}: the image ${UOS_IMAGE}:${REQUESTED} is not published yet, will retry"
    fi
    exit 2
fi

if [[ -d "${LOCK_DIR}" ]]; then
    log "Console update to ${REQUESTED}: another update is running, will retry"
    exit 2
fi

log "Update to UniFi OS Server ${REQUESTED} requested from the UniFi OS console"
rm -f "${REQUEST_FILE}" "${REQUEST_FILE}.build"

FORCE_VERSION="${REQUESTED}" update.sh
