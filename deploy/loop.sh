#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec bb --config "$HERE/bb.edn" --main dashboard.main loop "$@"
