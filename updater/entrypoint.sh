#!/bin/bash
#
# Runs the updates:
#  - AUTO_UPDATE=1:    update.sh on start and every day at UPDATE_TIME (container time zone, TZ);
#  - CONSOLE_UPDATE=1: supervisor.js plays the "UOS Server Manager" for UniFi OS; "Update" in the
#                      UniFi OS console makes it write /uos/boot/uos-update.json, which
#                      console-update.sh carries out (checked every 15 seconds, retried every
#                      15 minutes while the image is not published yet).

UPDATE_TIME=${UPDATE_TIME:-04:30}
AUTO_UPDATE=${AUTO_UPDATE:-1}
CONSOLE_UPDATE=${CONSOLE_UPDATE:-1}
CONSOLE_RETRY=900

trap 'exit 0' SIGINT SIGTERM

next_daily() {
    local now next
    now=$(date +%s)
    next=$(date -d "today ${UPDATE_TIME}" +%s) || { echo "Invalid UPDATE_TIME: ${UPDATE_TIME}"; exit 1; }
    (( next <= now )) && next=$(date -d "tomorrow ${UPDATE_TIME}" +%s)
    echo "${next}"
}

echo "UniFi OS updater started ($(date +%Z)): daily update $([[ "${AUTO_UPDATE}" == "1" ]] && echo "at ${UPDATE_TIME}" || echo "off"), update from the UniFi OS console $([[ "${CONSOLE_UPDATE}" == "1" ]] && echo "on" || echo "off")"

if [[ "${AUTO_UPDATE}" == "1" ]]; then
    update.sh
    NEXT_DAILY=$(next_daily)
    echo "Next daily check: $(date -d "@${NEXT_DAILY}" '+%Y-%m-%d %H:%M %Z')"
fi

NEXT_CONSOLE=0

if [[ "${CONSOLE_UPDATE}" == "1" ]]; then
    ( while true; do node /opt/supervisor/supervisor.js; sleep 5; done ) &
fi

while true; do
    # sleep in the background, so SIGTERM is handled immediately
    sleep 15 & wait $!

    if [[ "${CONSOLE_UPDATE}" == "1" && -f /uos/boot/uos-update.json && $(date +%s) -ge ${NEXT_CONSOLE} ]]; then
        console-update.sh
        if [[ $? -eq 2 ]]; then
            NEXT_CONSOLE=$(( $(date +%s) + CONSOLE_RETRY ))
        else
            NEXT_CONSOLE=0
        fi
    fi

    if [[ "${AUTO_UPDATE}" == "1" && $(date +%s) -ge ${NEXT_DAILY} ]]; then
        update.sh
        NEXT_DAILY=$(next_daily)
        echo "Next daily check: $(date -d "@${NEXT_DAILY}" '+%Y-%m-%d %H:%M %Z')"
    fi
done
