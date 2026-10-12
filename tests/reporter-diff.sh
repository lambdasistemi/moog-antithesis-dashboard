#!/usr/bin/env bash
set -euo pipefail
report_script=${REPORT_SCRIPT:-reporter/report.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
touch "$work/socket" "$work/token" "$work/requests"
printf 'fixture-token' >"$work/token"
export FIXTURE_WORK=$work
printf '#!%s\n' "$(command -v bash)" >"$work/bin/curl"
cat >>"$work/bin/curl" <<'CURL'
set -euo pipefail
if [[ $* == *containers/json* ]]; then
    cat "$FIXTURE_WORK/containers"
elif [[ $* == *'/logs?'* ]]; then
    printf '\001\000\000\000\000\000\000\006error\n'
    if [[ -f $FIXTURE_WORK/more-errors ]]; then
        printf '\001\000\000\000\000\000\000\006error\n'
    fi
else
    cat >/dev/null
    printf 'patch\n' >>"$FIXTURE_WORK/requests"
    [[ ! -f $FIXTURE_WORK/refuse ]]
fi
CURL
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" DOCKER_SOCKET="$work/socket"
export STATUS_TOKEN_FILE="$work/token" STATUS_ISSUE_NUMBER=123
export REPORT_STATE_FILE="$work/state.json" REPORT_HEARTBEAT_SECONDS=300
sample() {
    jq -n --arg status "$1" --arg image "${2:-moog:v1}" \
        '[{Id:"agent",Names:["/moog-agent"],Image:$image,Status:$status}]' >"$work/containers"
}
count() {
    [[ $(wc -l <"$work/requests") -eq $1 ]] || {
        echo "reporter-diff: $2 (expected $1 pushes)" >&2
        exit 1
    }
}
report() { bash "$report_script"; }
sample 'Up 1 minute'
report
count 1 'initial sample'
sample 'Up 2 minutes'
report
count 1 'uptime alone must not publish'
sample 'Up 2 minutes (unhealthy)'
report
count 2 'health change'
sample 'Up 2 minutes (unhealthy)' moog:v2
report
count 3 'image change'
jq '.reported_epoch -= 300' "$REPORT_STATE_FILE" >"$work/aged"
mv "$work/aged" "$REPORT_STATE_FILE"
report
count 4 'heartbeat after five minutes'
sample 'Exited (1) 1 minute ago' moog:v2
report
count 5 'exit change'
sample 'Exited (1) 2 minutes ago' moog:v2
report
count 5 'exit elapsed time alone'
sample 'Up 1 minute' moog:v3
touch "$work/refuse"
if report >/dev/null 2>&1; then
    echo 'reporter-diff: refusal reported success' >&2
    exit 1
fi
rm "$work/refuse"
report
count 7 'failed publication retried'
export REPORTER_ROLE=agent
report
count 8 'agent sample'
report
count 8 'unchanged agent counts'
touch "$work/more-errors"
report
count 9 'agent count change'
printf 'not-json' >"$REPORT_STATE_FILE"
report
count 10 'corrupt state recovered by publication'
# Sampling cadence includes collection time, rather than adding a minute.
printf '0' >"$work/clock"
for tool in date sleep cycle; do
    printf '#!%s\n' "$(command -v bash)" >"$work/bin/$tool"
done
cat >>"$work/bin/date" <<'DATE'
cat "$FIXTURE_WORK/clock"
DATE
cat >>"$work/bin/sleep" <<'SLEEP'
printf '%s\n' "$1" >>"$FIXTURE_WORK/delays"
SLEEP
cat >>"$work/bin/cycle" <<'CYCLE'
epoch=$(cat "$FIXTURE_WORK/clock")
printf '%s' "$((epoch + 27))" >"$FIXTURE_WORK/clock"
CYCLE
chmod +x "$work/bin/date" "$work/bin/sleep" "$work/bin/cycle"
REPORT_MAX_CYCLES=3 CYCLE_CMD="$work/bin/cycle" bash reporter/loop.sh
[[ $(cat "$work/delays") == $'33\n33' ]] || {
    echo 'reporter-diff: sampling interval excludes collection time' >&2
    exit 1
}
echo 'reporter diff ok'
