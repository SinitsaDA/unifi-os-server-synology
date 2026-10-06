#!/bin/bash
#
# Runs update.sh once on start and then every day at UPDATE_TIME (container time zone, TZ).

UPDATE_TIME=${UPDATE_TIME:-04:30}

trap 'exit 0' SIGINT SIGTERM

echo "UniFi OS updater started, daily check at ${UPDATE_TIME} ($(date +%Z))"

update.sh

while true; do
    now=$(date +%s)
    next=$(date -d "today ${UPDATE_TIME}" +%s) || { echo "Invalid UPDATE_TIME: ${UPDATE_TIME}"; exit 1; }
    (( next <= now )) && next=$(date -d "tomorrow ${UPDATE_TIME}" +%s)

    echo "Next check: $(date -d "@${next}" '+%Y-%m-%d %H:%M %Z')"

    # sleep in the background, so SIGTERM is handled immediately
    sleep $(( next - now )) & wait $!

    update.sh
done
