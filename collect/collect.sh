#!/usr/bin/env bash
# Collect the state of the moog + Antithesis pipeline into one public JSON file.
#
# Each source is fetched independently. A failing source keeps its last good
# result, marked stale, so one outage never blanks the page. Immutable facts
# are cached forever: properties of completed Antithesis runs and receipts of
# concluded nightly runs.
#
# Nothing secret leaves this script: report URLs (they carry auth tokens) are
# dropped, agent logs are reduced to counts on the host.
set -uo pipefail

CACHE=${DASHBOARD_CACHE:-$HOME/.cache/moog-antithesis-dashboard}
OUT_DIR=${DASHBOARD_OUT:-$CACHE/out}
MOOG_DIR=${MOOG_DIR:-/code/moog}
ANTI_KEY_FILE=${ANTITHESIS_API_KEY_FILE:-$HOME/.secrets/antithesis-api-key}
TENANT=${ANTITHESIS_TENANT:-amaru-cardano}
CNA_REPO=cardano-foundation/cardano-node-antithesis
REQUESTER=${MOOG_REQUESTER:-cfhal}
AGENT_HOST=${AGENT_HOST:-agent}
ORACLE_HOST=${ORACLE_HOST:-oracle}
PROXY_URL=${PROXY_URL:-https://antithesis-proxy.plutimus.com/readyz}
MONITOR_UNIT=${MONITOR_UNIT:-antithesis-run-freshness-monitor.service}
RUNS_LIMIT=25
NIGHTLY_LIMIT=14

mkdir -p "$CACHE"/{props,nightly,last} "$OUT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

now() { date -u +%FT%TZ; }
STARTED=$(now)

declare -A SRC_STATUS SRC_ERR SRC_LAST

# run_source NAME FUNC
#   ok    → output saved as last good
#   fail  → last good served, marked stale
#   never → null, marked error
run_source() {
    local name=$1 fn=$2
    local out="$WORK/$name.json" err="$WORK/$name.err"
    if "$fn" >"$out" 2>"$err" && jq -e . "$out" >/dev/null 2>&1; then
        cp "$out" "$CACHE/last/$name.json"
        now >"$CACHE/last/$name.at"
        SRC_STATUS[$name]=ok
        SRC_ERR[$name]=""
    elif [[ -s "$CACHE/last/$name.json" ]]; then
        cp "$CACHE/last/$name.json" "$out"
        SRC_STATUS[$name]=stale
        SRC_ERR[$name]=$(tail -c 300 "$err" | tr -d '\000')
    else
        echo 'null' >"$out"
        SRC_STATUS[$name]=error
        SRC_ERR[$name]=$(tail -c 300 "$err" | tr -d '\000')
    fi
    SRC_LAST[$name]=$(cat "$CACHE/last/$name.at" 2>/dev/null || echo "")
}

# The key goes through curl's stdin config, never argv.
anti_get() {
    [[ -r "$ANTI_KEY_FILE" ]] || { echo "no Antithesis key file" >&2; return 1; }
    printf 'header = "Authorization: Bearer %s"\nurl = "https://%s.antithesis.com/api/v0/%s"\nsilent\nshow-error\nfail\n' \
        "$(cat "$ANTI_KEY_FILE")" "$TENANT" "$1" | curl -K - --max-time 60
}

# Antithesis runs, newest first, with the moog test-run key parsed out.
src_runs() {
    anti_get "runs?limit=$RUNS_LIMIT" | jq '
      [.data[] | . as $r
       | ((.description | fromjson? | .testRun) // {}) as $t
       | { run_id, status, created_at, started_at,
           test_name: (.parameters["antithesis.test_name"] // null),
           duration_minutes: ((.parameters["antithesis.duration"] // "0") | tonumber? // null),
           directory: ($t.directory // null),
           commit: ($t.commitId // null),
           try: ($t.try // null),
           requester: ($t.requester // null),
           repository: (if $t.repository then "\($t.repository.organization)/\($t.repository.repo)" else null end) } ]'
}

# Property summary of one run; cached forever once the run is completed.
props_for() {
    local rid=$1 status=$2
    local cached="$CACHE/props/$rid.json"
    if [[ -s $cached ]]; then cat "$cached"; return 0; fi
    [[ $status == completed || $status == incomplete ]] || { echo null; return 0; }
    local summary
    summary=$(anti_get "runs/$rid/properties" | jq -c '
      [.data[] | select(.is_group | not)] as $p
      | { total: ($p | length),
          passing: ([$p[] | select(.status == "Passing")] | length),
          failing: [$p[] | select(.status != "Passing") | .name] }') || { echo null; return 0; }
    [[ $status == completed ]] && printf '%s\n' "$summary" >"$cached"
    printf '%s\n' "$summary"
}

moog_env() {
    export PATH="$MOOG_DIR/tmp:$PATH"
    # shellcheck disable=SC1091
    source "$MOOG_DIR/tmp/prod-setup.sh" >/dev/null 2>&1
}

# On-chain test-run facts. The url field carries a report auth token: dropped.
src_chain() {
    ( moog_env
      moog facts test-runs --whose "$REQUESTER" --no-pretty ) | jq '
      [ .[] | { directory: .key.directory, commit: .key.commitId, try: .key.try,
                phase: .value.phase, outcome: (.value.outcome // null),
                duration: (.value.duration // null), slot } ] as $f
      | { phases: ($f | group_by(.phase) | map({ (.[0].phase): length }) | add // {}),
          recent: ($f | sort_by(.slot) | reverse | .[:30]) }'
}

src_token() {
    ( moog_env
      moog token --no-pretty ) | jq '{ pending_requests: (.requests | length) }'
}

# Containers and agent log counts. Agent logs embed credentials, so only
# counts are computed on the host and leave it.
src_hosts() {
    local oracle agent counts
    oracle=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ORACLE_HOST" \
        'docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}"') || return 1
    agent=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$AGENT_HOST" \
        'docker ps --format "{{.Names}}|{{.Image}}|{{.Status}}"') || return 1
    counts=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$AGENT_HOST" '
        c=$(docker ps --format "{{.Names}}" | grep moog-agent | head -1)
        e=$(docker logs --since 6h "$c" 2>&1 | grep -ciE "exception|error" || true)
        p=$(docker logs --since 24h "$c" 2>&1 | grep -c "Published result" || true)
        echo "$e $p"') || return 1
    jq -n --arg o "$oracle" --arg a "$agent" --arg c "$counts" '
      def parse: split("\n") | map(select(length > 0) | split("|")
        | { name: .[0], image: (.[1] | sub("^.*/"; "")), status: .[2] })
        | map(select(.name | test("moog")));
      { oracle: ($o | parse), agent: ($a | parse),
        agent_errors_6h: ($c | split(" ")[0] | tonumber),
        agent_published_24h: ($c | split(" ")[1] | tonumber) }'
}

src_proxy() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROXY_URL") || code=000
    jq -n --arg c "$code" '{ ready: ($c == "200"), http_code: ($c | tonumber) }'
}

src_monitor() {
    local line
    line=$(journalctl -u "$MONITOR_UNIT" -n 200 --no-pager -o cat 2>/dev/null \
        | grep -E '^(OK|FAIL|STALE)' | tail -1 | sed 's/https\?:[^ ]*//g')
    [[ -n $line ]] || { echo "no verdict in journal" >&2; return 1; }
    jq -n --arg l "$line" '{ last: $l, ok: ($l | startswith("OK")) }'
}

# Nightly runs and their receipts; concluded receipts are cached forever.
receipt_for() {
    local id=$1 conclusion=$2
    local cached="$CACHE/nightly/$id.json"
    if [[ -s $cached ]]; then cat "$cached"; return 0; fi
    local url dir
    url=$(gh api "repos/$CNA_REPO/actions/runs/$id/artifacts" \
        --jq '.artifacts[] | select(.name | startswith("daily-amaru-receipt")) | .archive_download_url' \
        2>/dev/null | head -1)
    [[ -n $url ]] || { echo null; return 0; }
    dir=$(mktemp -d -p "$WORK")
    gh api "$url" >"$dir/r.zip" 2>/dev/null && unzip -q -o "$dir/r.zip" -d "$dir" 2>/dev/null \
        || { echo null; return 0; }
    local summary
    summary=$(cat "$dir"/receipt 2>/dev/null | grep -E '^(day|stage|outcome|error|upstream_sha|bootstrap_candidate_sha)=' \
        | jq -R 'capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}' | jq -s 'add // {}')
    [[ -n $conclusion && $conclusion != null ]] && printf '%s\n' "$summary" >"$cached"
    printf '%s\n' "$summary"
}

src_nightly() {
    local runs
    runs=$(gh run list -R "$CNA_REPO" -w daily-amaru.yaml -e schedule -L "$NIGHTLY_LIMIT" \
        --json databaseId,conclusion,status,event,createdAt,url) || return 1
    printf '%s' "$runs" | jq -c '.[]' | while read -r r; do
        local id conclusion
        id=$(jq -r .databaseId <<<"$r")
        conclusion=$(jq -r '.conclusion // ""' <<<"$r")
        jq -c --argjson rc "$(receipt_for "$id" "$conclusion")" '. + { receipt: $rc }' <<<"$r"
    done | jq -s .
}

for s in runs chain token hosts proxy monitor nightly; do
    run_source "$s" "src_$s"
done

# Attach property summaries to runs.
if [[ $(jq 'type' "$WORK/runs.json") == '"array"' ]]; then
    jq -c '.[]' "$WORK/runs.json" | while read -r r; do
        rid=$(jq -r .run_id <<<"$r")
        st=$(jq -r .status <<<"$r")
        jq -c --argjson p "$(props_for "$rid" "$st")" '. + { properties: $p }' <<<"$r"
    done | jq -s . >"$WORK/runs.with-props.json" && mv "$WORK/runs.with-props.json" "$WORK/runs.json"
fi

sources=$(for s in runs chain token hosts proxy monitor nightly; do
    jq -n --arg n "$s" --arg st "${SRC_STATUS[$s]}" --arg e "${SRC_ERR[$s]}" --arg at "${SRC_LAST[$s]}" \
        '{ ($n): { status: $st, error: (if $e == "" then null else $e end),
                   last_success: (if $at == "" then null else $at end) } }'
done | jq -s add)

jq -n \
    --arg generated_at "$(now)" --arg started_at "$STARTED" \
    --argjson sources "$sources" \
    --slurpfile runs "$WORK/runs.json" --slurpfile chain "$WORK/chain.json" \
    --slurpfile token "$WORK/token.json" --slurpfile hosts "$WORK/hosts.json" \
    --slurpfile proxy "$WORK/proxy.json" --slurpfile monitor "$WORK/monitor.json" \
    --slurpfile nightly "$WORK/nightly.json" \
    '{ generated_at: $generated_at, started_at: $started_at, refresh_seconds: 600,
       tenant: "'"$TENANT"'", repository: "'"$CNA_REPO"'",
       sources: $sources,
       runs: $runs[0], chain: $chain[0], token: $token[0], hosts: $hosts[0],
       proxy: $proxy[0], monitor: $monitor[0], nightly: $nightly[0],
       nightly_stages: ["head-resolution", "runner-preflight", "day-claim", "resolve-upstream",
         "launch-attempt", "bootstrap-proposal", "bootstrap-checks", "image-resolution",
         "consumer-repin", "consumer-checks", "producer-check", "supervised-integration",
         "launch-cap", "launch"] }' >"$OUT_DIR/data.json.new" \
    && mv "$OUT_DIR/data.json.new" "$OUT_DIR/data.json"

echo "collected: $(for s in runs chain token hosts proxy monitor nightly; do printf '%s=%s ' "$s" "${SRC_STATUS[$s]}"; done)"
