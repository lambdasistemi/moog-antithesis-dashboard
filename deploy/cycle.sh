#!/usr/bin/env bash
# One collection and publication cycle; overlapping cycles are skipped.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${DASHBOARD_CACHE:-$HOME/.cache/moog-antithesis-dashboard}
mkdir -p "$CACHE"
exec 9>"$CACHE/cycle.lock"
flock -n 9 || { echo "previous cycle still running, skipping"; exit 0; }
"$HERE/collect/collect.sh"
"$HERE/deploy/publish.sh"
