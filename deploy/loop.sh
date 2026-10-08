#!/usr/bin/env bash
# Run deploy/cycle.sh in a loop, sleeping DASHBOARD_INTERVAL seconds between
# cycles (default 600). A failing cycle logs one line and the loop continues.
# DASHBOARD_MAX_CYCLES bounds the loop for checks (default 0 = unlimited);
# CYCLE_CMD names the cycle command (default deploy/cycle.sh). Exits
# promptly on SIGTERM (container stop), without starting another sleep.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
INTERVAL=${DASHBOARD_INTERVAL:-600}
MAX_CYCLES=${DASHBOARD_MAX_CYCLES:-0}
CYCLE=${CYCLE_CMD:-"$HERE/cycle.sh"}

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
        echo "cycle failed at $(date -u +%FT%TZ), continuing" >&2
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
