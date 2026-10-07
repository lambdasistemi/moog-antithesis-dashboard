#!/usr/bin/env bash
# Collect the state of the moog + Antithesis pipeline into public JSON files.
#
# Each source is fetched independently. A failing source keeps its last good
# result, marked stale, so one outage never blanks the page. Immutable facts
# are cached forever: properties of completed Antithesis runs, per-run detail
# files, and receipts of concluded nightly runs.
#
# Secrets arrive as files: the Antithesis key, the GitHub read token and the
# moog read environment are read from /run/secrets and never appear in argv.
# Report URLs (they carry auth tokens) are dropped before publication.
# Host and monitor sources are interim stubs until the push reporters in
# #11 and #12 land; until then they report error.
set -uo pipefail

CACHE=${DASHBOARD_CACHE:-$HOME/.cache/moog-antithesis-dashboard}
OUT_DIR=${DASHBOARD_OUT:-$CACHE/out}
MOOG_DIR=${MOOG_DIR:-/opt/moog}
ANTI_KEY_FILE=${ANTITHESIS_API_KEY_FILE:-/run/secrets/antithesis-key}
GH_READ_TOKEN_FILE=${GH_READ_TOKEN_FILE:-/run/secrets/gh-read}
MOOG_ENV_FILE=${MOOG_READ_ENV_FILE:-/run/secrets/moog-read-env}
TENANT=${ANTITHESIS_TENANT:-amaru-cardano}
CNA_REPO=cardano-foundation/cardano-node-antithesis
REQUESTER=${MOOG_REQUESTER:-cfhal}
PROXY_URL=${PROXY_URL:-https://antithesis-proxy.plutimus.com/readyz}
RUNS_LIMIT=25
NIGHTLY_LIMIT=14

mkdir -p "$CACHE"/{props,details,nightly,last} "$OUT_DIR" "$OUT_DIR/runs"
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
    [[ -r "$ANTI_KEY_FILE" ]] || {
        echo "no Antithesis key file" >&2
        return 1
    }
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
    if [[ -s $cached ]]; then
        cat "$cached"
        return 0
    fi
    [[ $status == completed || $status == incomplete ]] || {
        echo null
        return 0
    }
    local summary
    summary=$(anti_get "runs/$rid/properties" | jq -c '
      [.data[] | select(.is_group | not)] as $p
      | { total: ($p | length),
          passing: ([$p[] | select(.status == "Passing")] | length),
          failing: [$p[] | select(.status != "Passing") | .name] }') || {
        echo null
        return 0
    }
    [[ $status == completed ]] && printf '%s\n' "$summary" >"$cached"
    printf '%s\n' "$summary"
}

moog_env() {
    export PATH="$MOOG_DIR:$PATH"
    [[ -r $MOOG_ENV_FILE ]] || {
        echo "no moog read environment file in $MOOG_ENV_FILE" >&2
        return 1
    }
    local line name value
    while IFS= read -r line; do
        if [[ $line == export\ * ]]; then
            line=${line#export }
        fi
        [[ $line == *=* ]] || continue
        name=${line%%=*}
        value=${line#*=}
        if [[ ${#value} -ge 2 ]]; then
            if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
                value=${value:1:-1}
            elif [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
                value=${value:1:-1}
            fi
        fi
        [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        export "$name=$value"
    done <"$MOOG_ENV_FILE"
}

# GitHub reads with a file-mounted token: GH_TOKEN lives only in the
# environment of that single gh process, never exported, never in argv.
gh_auth() {
    [[ -r $GH_READ_TOKEN_FILE ]] || {
        echo "no GitHub read token file in $GH_READ_TOKEN_FILE" >&2
        return 1
    }
    GH_TOKEN=$(cat "$GH_READ_TOKEN_FILE") gh "$@"
}

# On-chain test-run facts. The url field carries a report auth token: dropped.
src_chain() {
    (
        moog_env
        moog facts test-runs --whose "$REQUESTER" --no-pretty
    ) | jq '
      [ .[] | { directory: .key.directory, commit: .key.commitId, try: .key.try,
                phase: .value.phase, outcome: (.value.outcome // null),
                duration: (.value.duration // null), slot } ] as $f
      | { phases: ($f | group_by(.phase) | map({ (.[0].phase): length }) | add // {}),
          recent: ($f | sort_by(.slot) | reverse | .[:30]) }'
}

src_token() {
    (
        moog_env
        moog token --no-pretty
    ) | jq '{ pending_requests: (.requests | length) }'
}

# Interim: host and monitor status arrive via push reporters (#11, #12),
# which do not exist yet. Until then these sources fail so the page shows
# `error` instead of silently serving stale numbers. The container carries
# no ssh client and no journal access.
src_hosts() {
    echo "host reporters not yet available (see #11)" >&2
    return 1
}

src_proxy() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROXY_URL") || code=000
    jq -n --arg c "$code" '{ ready: ($c == "200"), http_code: ($c | tonumber) }'
}

src_monitor() {
    echo "monitor reporter not yet available (see #12)" >&2
    return 1
}

# Nightly runs and their receipts; concluded receipts are cached forever.
receipt_for() {
    local id=$1 conclusion=$2
    local cached="$CACHE/nightly/$id.json"
    if [[ -s $cached ]]; then
        cat "$cached"
        return 0
    fi
    local url dir
    url=$(gh_auth api "repos/$CNA_REPO/actions/runs/$id/artifacts" \
        --jq '.artifacts[] | select(.name | startswith("daily-amaru-receipt")) | .archive_download_url' \
        2>/dev/null | head -1)
    [[ -n $url ]] || {
        echo null
        return 0
    }
    dir=$(mktemp -d -p "$WORK")
    if ! gh_auth api "$url" >"$dir/r.zip" 2>/dev/null; then
        echo null
        return 0
    fi
    if ! unzip -q -o "$dir/r.zip" -d "$dir" 2>/dev/null; then
        echo null
        return 0
    fi
    local summary
    summary=$(grep -E '^(day|stage|outcome|error|upstream_sha|bootstrap_candidate_sha)=' "$dir"/receipt 2>/dev/null |
        jq -R 'capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}' | jq -s 'add // {}')
    [[ -n $conclusion && $conclusion != null ]] && printf '%s\n' "$summary" >"$cached"
    printf '%s\n' "$summary"
}

# Full detail of one run for the click-through view; cached forever once the
# run stops changing. The run object's links carry report access tokens, so
# they are dropped here and never reach the published files.
detail_unavailable() {
    jq -n --arg rid "$1" --arg st "$2" \
        '{run_id: $rid, status: $st, unavailable: true,
          properties: [], chain: null, nightly: []}'
}

# Descriptions repeat verbatim across runs, so they are published once in
# property-descriptions.json and stripped from the per-run files. The
# collector still reads them from every response to rebuild the shared
# map; first text wins when a name drifts between runs.
detail_for() {
    local rid=$1 status=$2
    local cached="$CACHE/details/$rid.json"
    local full
    if [[ -s $cached ]]; then
        full=$(cat "$cached")
    else
        local run props detail st
        run=$(anti_get "runs/$rid") || {
            detail_unavailable "$rid" "$status"
            return 0
        }
        props=$(anti_get "runs/$rid/properties") || {
            detail_unavailable "$rid" "$status"
            return 0
        }
        st=$(jq -r '.status // ""' <<<"$run")
        [[ -n $st ]] || st=$status
        detail=$(jq -n --arg rid "$rid" --arg st "$st" \
            --argjson run "$run" --argjson props "$props" \
            --slurpfile chain "$WORK/chain.json" --slurpfile nightly "$WORK/nightly.json" '
        ($run.description | fromjson? | .testRun // {}) as $t
        | ($t.directory // null) as $dir
        | ($t.commitId // null) as $c
        | ($t.try // null) as $t_try
        | (($chain[0] | .recent?) // []) as $facts
        | (($nightly[0] // []) | if type == "array" then . else [] end) as $ns
        | (($run.created_at // "")[0:10]) as $day
        | { run_id: $rid, status: $st,
            created_at: ($run.created_at // null),
            started_at: ($run.started_at // null),
            completed_at: ($run.completed_at // null),
            test_name: ($run.parameters["antithesis.test_name"] // null),
            duration_minutes: (($run.parameters["antithesis.duration"] // "0") | tonumber? // null),
            directory: $dir, commit: $c, try: $t_try,
            requester: ($t.requester // null),
            repository: (if $t.repository then "\($t.repository.organization)/\($t.repository.repo)" else null end),
            parameters: ($run.parameters // {}),
            properties: [$props.data[]? | { name, description, status,
              is_group, is_event: (.is_event // null),
              example_count: (.example_count // null),
              counterexample_count: (.counterexample_count // null),
              counterexamples: (.counterexamples // []) }],
            chain: (if $c == null then null else
              ($facts | map(select(.directory == $dir and .commit == $c and .try == $t_try)) | .[0]
                 | if . == null then null else {phase, outcome, slot} end) end),
            nightly: (if $dir == "testnets/cardano_amaru" then
              [$ns[] | select(((.createdAt // "")[0:10]) == $day)
                 | { day: (.receipt.day // null), url, conclusion, status,
                     stage: (.receipt.stage // null), error: (.receipt.error // null) }]
              else [] end) }') ||
            {
                detail_unavailable "$rid" "$status"
                return 0
            }
        if [[ $st == completed || $st == incomplete ]]; then
            printf '%s\n' "$detail" >"$cached"
        fi
        full=$detail
    fi
    jq -c '.properties[] | select(.description) | {name, description}' <<<"$full" >>"$WORK/descriptions.jsonl"
    jq '.properties |= map(del(.description))' <<<"$full"
}

src_nightly() {
    local runs
    runs=$(gh_auth run list -R "$CNA_REPO" -w daily-amaru.yaml -e schedule -L "$NIGHTLY_LIMIT" \
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

# Per-run detail files beside data.json. Completed runs are served from the
# cache; runs still in progress are refetched every cycle.
if [[ $(jq 'type' "$WORK/runs.json") == '"array"' ]]; then
    jq -c '.[]' "$WORK/runs.json" | while read -r r; do
        rid=$(jq -r .run_id <<<"$r")
        st=$(jq -r .status <<<"$r")
        detail_for "$rid" "$st" >"$OUT_DIR/runs/$rid.json"
    done
    if [[ -s $WORK/descriptions.jsonl ]]; then
        jq -s 'reverse | map({(.name): .description}) | add // {}' \
            "$WORK/descriptions.jsonl" >"$OUT_DIR/property-descriptions.json"
    else
        echo '{}' >"$OUT_DIR/property-descriptions.json"
    fi
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
         "launch-cap", "launch"] }' >"$OUT_DIR/data.json.new" &&
    mv "$OUT_DIR/data.json.new" "$OUT_DIR/data.json"

echo "collected: $(for s in runs chain token hosts proxy monitor nightly; do printf '%s=%s ' "$s" "${SRC_STATUS[$s]}"; done)"
