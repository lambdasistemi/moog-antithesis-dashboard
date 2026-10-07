#!/usr/bin/env bash
# Compare a fresh local collector snapshot with the live published page.
#
# Environment and mounts (operator context; all secret mounts read-only):
#   LIVE_URL      default https://lambdasistemi.github.io/moog-antithesis-dashboard/data.json
#   IMAGE         default ghcr.io/lambdasistemi/moog-antithesis-dashboard:main
#   SECRETS_DIR   default /srv/moog-antithesis-dashboard (host dir holding
#                 antithesis-key, gh-read, moog-read-env, each mode 0400)
#   MOOG_DIR      default /opt/moog (host dir with the moog binaries, ro)
#   OUT_DIR       default a fresh mktemp dir (bind-mounted at /out)
# The collector container runs with --read-only, --cap-drop ALL and a tmpfs
# /tmp; DASHBOARD_CACHE points at /tmp so nothing persists. It runs only
# collect.sh: no publish step, no push, no push token needed, and no token
# of any kind is required by this script itself (missing read secrets only
# turn their sources to error/stale in the snapshot being compared).
#
# Volatile fields ignored on both sides (named once, right here):
# generated_at, started_at, refresh_seconds, every sources.* status/error/
# last_success, the whole monitor verdict, and per-run progress fields
# (runs[].status transitions and duration_minutes).
#
# Exit 2: the live page (or the local snapshot) could not be fetched/built.
# Exit 1: structural mismatch (missing top-level section, type change, host
# list difference). Value-only differences are reported field by field with
# exit 0. Only public snapshot values are ever printed; no secret is read
# except by the collector container itself, and none is printed.
set -euo pipefail

LIVE_URL=${LIVE_URL:-https://lambdasistemi.github.io/moog-antithesis-dashboard/data.json}
IMAGE=${IMAGE:-ghcr.io/lambdasistemi/moog-antithesis-dashboard:main}
SECRETS_DIR=${SECRETS_DIR:-/srv/moog-antithesis-dashboard}
MOOG_DIR=${MOOG_DIR:-/opt/moog}
OUT_DIR=${OUT_DIR:-$(mktemp -d)}
mkdir -p "$OUT_DIR"

WORK=$(mktemp -d)
live="$WORK/live-raw.json"
trap 'rm -rf "$WORK"' EXIT
if ! curl -sS --fail --max-time 30 "$LIVE_URL" -o "$live"; then
    echo "compare-live: cannot fetch live page at $LIVE_URL" >&2
    exit 2
fi
if ! jq -e . "$live" >/dev/null 2>&1; then
    echo "compare-live: live page is not JSON" >&2
    exit 2
fi

# Local snapshot from the collector image: collect only, never publish.
if ! timeout 570 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
    -v "$SECRETS_DIR/antithesis-key:/run/secrets/antithesis-key:ro" \
    -v "$SECRETS_DIR/gh-read:/run/secrets/gh-read:ro" \
    -v "$SECRETS_DIR/moog-read-env:/run/secrets/moog-read-env:ro" \
    -v "$MOOG_DIR:/opt/moog:ro" \
    -v "$OUT_DIR:/out" \
    -e DASHBOARD_OUT=/out -e DASHBOARD_CACHE=/tmp/cache \
    "$IMAGE" /app/collect/collect.sh >/dev/null 2>&1; then
    echo "compare-live: local collection failed" >&2
    exit 2
fi
[[ -s $OUT_DIR/data.json ]] || {
    echo "compare-live: local collection produced no data.json" >&2
    exit 2
}

strip_volatile() {
    jq 'del(.generated_at, .started_at, .refresh_seconds)
        | .sources |= (if type == "object" then with_entries(.value = {}) else . end)
        | del(.monitor)
        | .runs |= (if type == "array" then map(del(.status, .duration_minutes)) else . end)'
}
strip_volatile <"$live" >"$WORK/live.json" || {
    echo "compare-live: live snapshot shape unreadable" >&2
    exit 2
}
strip_volatile <"$OUT_DIR/data.json" >"$WORK/local.json" || {
    echo "compare-live: local snapshot shape unreadable" >&2
    exit 2
}

# Structural gates first: sections, types, host lists.
structural=0
for section in runs chain token hosts proxy nightly sources; do
    if ! jq -e --arg s "$section" 'has($s)' "$WORK/live.json" >/dev/null; then
        printf 'structural: live snapshot lacks section %s\n' "$section"
        structural=1
    fi
    if ! jq -e --arg s "$section" 'has($s)' "$WORK/local.json" >/dev/null; then
        printf 'structural: local snapshot lacks section %s\n' "$section"
        structural=1
    fi
done
for section in runs chain token hosts proxy nightly sources; do
    a=$(jq -r --arg s "$section" '.[$s] | type' "$WORK/live.json")
    b=$(jq -r --arg s "$section" '.[$s] | type' "$WORK/local.json")
    if [[ $a != "$b" ]]; then
        printf 'structural: type change at %s: live=%s local=%s\n' "$section" "$a" "$b"
        structural=1
    fi
done
for side in oracle agent; do
    a=$(jq -r --arg s "$side" '.hosts[$s] // [] | map(.name) | sort | join(",")' "$WORK/live.json")
    b=$(jq -r --arg s "$side" '.hosts[$s] // [] | map(.name) | sort | join(",")' "$WORK/local.json")
    if [[ $a != "$b" ]]; then
        printf 'structural: host list difference at hosts.%s: live=[%s] local=[%s]\n' "$side" "$a" "$b"
        structural=1
    fi
done

# Field-by-field value report over the stripped snapshots.
jq --slurpfile live "$WORK/live.json" --slurpfile local "$WORK/local.json" -n '
    def walk($a; $b; $p):
      if ($a | type) != ($b | type) then empty
      elif ($a | type) == "object" then
        ((($a | keys) + ($b | keys) | unique)[] | . as $k
          | walk($a[$k]; $b[$k]; ($p + "." + $k)))
      elif ($a | type) == "array" then
        (range(0; ([$a | length, $b | length] | max)) | . as $i
          | walk($a[$i]; $b[$i]; ($p + "[" + ($i | tostring) + "]")))
      elif $a != $b then "\($p): live=\($a | tojson) local=\($b | tojson)"
      else empty end;
    [walk($live[0]; $local[0]; "$")] | .[]
  ' >"$WORK/diffs.txt"
if [[ -s $WORK/diffs.txt ]]; then
    printf 'value differences (stripped snapshots):\n'
    cat "$WORK/diffs.txt"
fi
if [[ $structural -ne 0 ]]; then
    exit 1
fi
printf 'compare-live: no structural mismatch\n'
exit 0
