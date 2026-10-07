#!/bin/bash
# Shared helpers for update.sh, console-update.sh and restore.sh.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

UOS_DIR=${UOS_DIR:-/volume1/docker/unifi-os-server}
UOS_IMAGE=${UOS_IMAGE:-ghcr.io/sinitsada/unifi-os-server}
GITHUB_REPO=${GITHUB_REPO:-SinitsaDA/unifi-os-server-synology}

SERVICE=unifi-os-server
CONTAINER=unifi-os-server
ENV_FILE="${UOS_DIR}/.env"
BACKUP_DIR="${UOS_DIR}/backups"
LOG_FILE="${UOS_DIR}/update.log"
LOCK_DIR="${UOS_DIR}/.update.lock"
REQUEST_FILE=/uos/boot/uos-update.json

# Data volumes as mounted into the updater (var-log is not backed up).
VOLUMES_DIR=/uos
DATA_VOLUMES=(persistent data srv var-lib-unifi var-lib-mongodb etc-rabbitmq-ssl)

FW_API="https://fw-update.ui.com/api"
FW_FILTER="filter=eq~~product~~unifi-os-server&filter=eq~~platform~~linux-x64"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE}"
}

fail() {
    log "ERROR: $*"
    exit 1
}

compose_cmd() {
    local cmd="docker compose --project-directory ${UOS_DIR}" project
    # Use the project name of the running server (Synology Container Manager names projects itself).
    project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${CONTAINER}" 2>/dev/null)"
    [[ -n "${project}" ]] && cmd="${cmd} -p ${project}"
    echo "${cmd}"
}

current_version() {
    sed -n 's/^UOS_VERSION=//p' "${ENV_FILE}" | tr -d '[:space:]'
}

set_version() {
    sed -i "s/^UOS_VERSION=.*/UOS_VERSION=$1/" "${ENV_FILE}"
}

# version_newer <a> <b>: true when a > b
version_newer() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# latest_release: "<version> <created>" of the latest UniFi OS Server release
latest_release() {
    curl -fsSL --max-time 30 "${FW_API}/firmware-latest?${FW_FILTER}&filter=eq~~channel~~release" |
        jq -r '._embedded.firmware[0] | "\(.version | sub("^v"; "")) \(.created)"'
}

# image_exists <version>: the image is published in the registry
image_exists() {
    local registry="${UOS_IMAGE%%/*}" repo="${UOS_IMAGE#*/}" token
    token="$(curl -fsSL --max-time 30 "https://${registry}/token?scope=repository:${repo}:pull" | jq -r '.token // empty')"
    curl -fsS --max-time 30 -o /dev/null -I \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json" \
        "https://${registry}/v2/${repo}/manifests/$1"
}

# request_build <version>: starts the image build on GitHub (needs GITHUB_TOKEN with actions:write)
request_build() {
    [[ -n "${GITHUB_TOKEN}" ]] || return 1
    curl -fsS --max-time 30 -X POST \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPO}/actions/workflows/build.yml/dispatches" \
        -d "{\"ref\":\"main\",\"inputs\":{\"version\":\"$1\"}}"
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
