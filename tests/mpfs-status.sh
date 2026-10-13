#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
touch "$work/socket" "$work/requests"
printf fixture-token >"$work/token"
export FIXTURE_WORK=$work
printf '#!%s\n' "$(command -v bash)" >"$work/bin/curl"
cat >>"$work/bin/curl" <<'CURL'
set -euo pipefail
if [[ $* == *containers/json* ]]; then
    cat "$FIXTURE_WORK/containers"
elif [[ $* == *'/tokens'* ]]; then
    output=''
    while (($#)); do
        if [[ $1 == --output ]]; then output=$2; shift; fi
        shift
    done
    cat "$FIXTURE_WORK/probe" >"$output"
    cat "$FIXTURE_WORK/http"
else
    # Authorization must travel on stdin, never in command arguments.
    [[ $* != *fixture-token* ]]
    cat >/dev/null
    printf 'patch\n' >>"$FIXTURE_WORK/requests"
    [[ ! -f $FIXTURE_WORK/refuse ]]
fi
CURL
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" DOCKER_SOCKET="$work/socket"
export REPORTER_ROLE=mpfs MPFS_SERVICE_ID=collector-legacy-mpfs
export MPFS_PROBE_URL=http://fixture/tokens
export STATUS_TOKEN_FILE="$work/token" STATUS_ISSUE_NUMBER=30
export REPORT_STATE_FILE="$work/state.json" REPORT_HEARTBEAT_SECONDS=300
sample() {
    jq -n --arg uptime "$1" --arg state "${2:-running}" '
      [{Names:["/unrelated-mpfs"],Image:"private-image",State:"running"},
       {Names:["/mpfs-compose-mpfs-1"],Image:"ghcr.io/cardano-foundation/mpfs/mpfs:v1.3.0",State:$state,Status:$uptime}]' >"$work/containers"
}
probe() {
    printf '%s' "${1:-200}" >"$work/http"
    if [[ $# -ge 2 ]]; then
        printf '%s' "$2" >"$work/probe"
    else
        printf '%s' '{"tokens":["private-probe-material"],"indexerStatus":{"ready":true,"networkTip":100,"indexerTip":98}}' >"$work/probe"
    fi
}
report() { bash reporter/report.sh; }
count() {
    [[ $(wc -l <"$work/requests") -eq $1 ]] || {
        echo "mpfs: $2 (expected $1 writes)" >&2
        exit 1
    }
}
sample 'Up 1 minute'
probe
REPORT_DRY_RUN=1 report >"$work/payload"
jq -e '.role=="mpfs" and .service_id=="collector-legacy-mpfs"
 and .container.name=="mpfs-compose-mpfs-1" and .container.status=="running"
 and .api=={reachable:true,http_status:200} and .synchronization.lag_slots==2' "$work/payload" >/dev/null
if rg -q 'private-probe-material|private-image|fixture-token|http://' "$work/payload"; then
    echo 'mpfs: private material escaped the payload boundary' >&2
    exit 1
fi
report
count 1 initial
sample 'Up 2 minutes'
report
count 1 'uptime alone suppressed'
jq '.reported_epoch-=300' "$REPORT_STATE_FILE" >"$work/aged"
mv "$work/aged" "$REPORT_STATE_FILE"
report
count 2 heartbeat
sample 'Exited (1) 1 minute ago' exited
report
count 3 'container state change'
probe 503 '{}'
report
count 4 'API failure change'
REPORT_DRY_RUN=1 report >"$work/payload"
jq -e '.api=={reachable:false,http_status:503} and .synchronization.status=="unmeasured"' "$work/payload" >/dev/null
probe
cp "$REPORT_STATE_FILE" "$work/before-refusal"
touch "$work/refuse"
if report >/dev/null 2>&1; then
    echo 'mpfs: refused write reported success' >&2
    exit 1
fi
cmp "$REPORT_STATE_FILE" "$work/before-refusal"
rm "$work/refuse"
report
count 6 'failed write retried'
for body in '{"indexerStatus":{"ready":true,"networkTip":90,"indexerTip":100}}' \
    '{"indexerStatus":{"ready":true,"networkTip":100.5,"indexerTip":99}}' \
    '{"indexerStatus":{"ready":"true","networkTip":100,"indexerTip":99}}' 'not-json'; do
    probe 200 "$body"
    REPORT_DRY_RUN=1 report >"$work/payload"
    jq -e '.synchronization=={status:"unmeasured",ready:null,network_tip_slot:null,indexer_tip_slot:null,lag_slots:null}' "$work/payload" >/dev/null
done
echo '[]' >"$work/containers"
REPORT_DRY_RUN=1 report >"$work/payload"
jq -e '.container.status=="missing" and .container.image==null' "$work/payload" >/dev/null
sample 'Up 3 minutes'
jq '.[1].Image="private/credential?token=fixture-token"' "$work/containers" >"$work/bad-image"
mv "$work/bad-image" "$work/containers"
if REPORT_DRY_RUN=1 report >"$work/payload" 2>/dev/null; then
    echo 'mpfs: private image accepted' >&2
    exit 1
fi
test ! -s "$work/payload"
sample 'Up 3 minutes'
jq '.[1].Image="ghcr.io/cardano-foundation/mpfs/mpfs:fixture-token"' "$work/containers" >"$work/bad-image"
mv "$work/bad-image" "$work/containers"
if REPORT_DRY_RUN=1 report >"$work/payload" 2>/dev/null; then
    echo 'mpfs: mounted credential published' >&2
    exit 1
fi
test ! -s "$work/payload"
echo 'MPFS reporter payload, cadence, retry and privacy controls pass'
