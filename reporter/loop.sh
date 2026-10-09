#!/usr/bin/env bash
# Loop the status reporter every REPORT_INTERVAL seconds (default 300).
# Same signal handling as deploy/loop.sh: a failing report logs one line
# and the loop continues; SIGTERM ends the loop promptly without starting
# another sleep.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
INTERVAL=${REPORT_INTERVAL:-300}
MAX_CYCLES=${REPORT_MAX_CYCLES:-0}
CYCLE=${CYCLE_CMD:-"$HERE/report.sh"}

shutdown=0
trap 'shutdown=1' TERM INT

cycles=0
while true; do
    if [[ $shutdown -eq 1 ]]; then
        break
    fi
    if "$CYCLE"; then
        :
    else
        echo "report failed at $(date -u +%FT%TZ), continuing" >&2
    fi
    cycles=$((cycles + 1))
    if [[ $MAX_CYCLES -gt 0 && $cycles -ge $MAX_CYCLES ]]; then
        break
    fi
    if [[ $shutdown -eq 1 ]]; then
        break
    fi
    sleep "$INTERVAL" &
    sleep_pid=$!
    wait "$sleep_pid" || true
done
