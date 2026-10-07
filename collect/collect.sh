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
# The oracle, agent and monitor sources read their status issues (#11,
# #12); nothing is read from the host journal.
# The container carries no ssh client and no journal access.
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
STATUS_REPOSITORY=${STATUS_REPOSITORY:-lambdasistemi/moog-antithesis-dashboard}
STATUS_ISSUE_ORACLE=${STATUS_ISSUE_ORACLE:-}
STATUS_ISSUE_AGENT=${STATUS_ISSUE_AGENT:-}
STATUS_ISSUE_MONITOR=${STATUS_ISSUE_MONITOR:-}
# Test seams for checks only: STATUS_BODY_CMD_ORACLE (else legacy
# STATUS_BODY_CMD) and STATUS_BODY_CMD_AGENT supply the issue bodies instead
# of calling the GitHub API. Production leaves them unset and uses gh_auth.
# Nothing else uses them.

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
# A source that emits a top-level .reported_at (status reporters) supplies
# its own last-success time; every other source falls back to now, so an
# unchanged old payload can never look fresh.
run_source() {
    local name=$1 fn=$2
    local out="$WORK/$name.json" err="$WORK/$name.err"
    if "$fn" >"$out" 2>"$err" && jq -e . "$out" >/dev/null 2>&1; then
        cp "$out" "$CACHE/last/$name.json"
        reported=$(jq -r '.reported_at // empty' "$out" 2>/dev/null || true)
        if [[ -n $reported ]]; then
            printf '%s\n' "$reported" >"$CACHE/last/$name.at"
        else
            now >"$CACHE/last/$name.at"
        fi
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

# Oracle, agent and monitor status from their GitHub issues (#11, #12).
# One shared strict jq schema: known keys only (role, containers,
# reported_at, plus errors_6h and published_24h for the agent, verdict and
# ok for the monitor), types, every string at most 200 characters, at most
# 50 containers, reported_at UTC ISO 8601 and not more than 2 minutes in
# the future. The monitor verdict is a non-empty string with no http(s)
# URL and ok equals `verdict | startswith("OK")`; counts are non-negative
# integers. Unknown keys are dropped; missing keys or wrong types fail. A
# payload older than 15 minutes fails as stale so the last good value is
# served. Error messages never include body text.
# Fetch seams for checks only: STATUS_BODY_CMD_ORACLE (else legacy
# STATUS_BODY_CMD), STATUS_BODY_CMD_AGENT and STATUS_BODY_CMD_MONITOR supply
# the issue bodies instead of calling the GitHub API. Production leaves them
# unset and uses gh_auth; nothing else uses them.
status_body_default() {
    local source=$1 issue=$2
    [[ -n $issue ]] || {
        echo "$source status: no issue number" >&2
        return 1
    }
    [[ -r $GH_READ_TOKEN_FILE ]] || {
        echo "$source status: no GitHub read token file" >&2
        return 1
    }
    gh_auth api "repos/$STATUS_REPOSITORY/issues/$issue" --jq .body
}

validate_status_payload() {
    local role=$1 now_epoch=$2
    jq -e --arg role "$role" --argjson now "$now_epoch" '
        if type != "object" then error("bad")
        elif $role == "monitor" and (has("role") and has("verdict") and has("ok") and has("reported_at") | not) then error("bad")
        elif $role != "monitor" and (has("role") and has("containers") and has("reported_at") | not) then error("bad")
        elif (.role | type) != "string" or .role != $role or (.role | length) > 200 then error("bad")
        elif $role != "monitor" and ((.containers | type) != "array" or (.containers | length) > 50) then error("bad")
        elif (.reported_at | type) != "string" or (.reported_at | length) > 200 then error("bad")
        elif (.reported_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then error("bad")
        elif $role != "monitor" and ([.containers[] | select(type != "object"
            or (has("name") and has("image") and has("status") | not)
            or (.name | type) != "string" or (.image | type) != "string" or (.status | type) != "string"
            or (.name | length) > 200 or (.image | length) > 200 or (.status | length) > 200)] | length) > 0 then error("bad")
        elif $role == "agent" and ((has("errors_6h") and has("published_24h") | not)
            or (.errors_6h | type) != "number" or (.published_24h | type) != "number"
            or .errors_6h < 0 or .published_24h < 0
            or (.errors_6h | floor) != .errors_6h or (.published_24h | floor) != .published_24h) then error("bad")
        elif $role == "monitor" and ((has("verdict") and has("ok") | not)
            or (.verdict | type) != "string" or (.verdict | length) == 0 or (.verdict | length) > 200
            or (.verdict | test("https?://"))
            or (.ok | type) != "boolean" or .ok != (.verdict | startswith("OK"))) then error("bad")
        else
            (.reported_at | fromdateiso8601) as $rep
            | if $rep > ($now + 120) then error("bad")
              elif $role == "agent" then {role, containers: [.containers[] | {name, image, status}], errors_6h, published_24h, reported_at}
              elif $role == "monitor" then {role, verdict, ok, reported_at}
              else {role, containers: [.containers[] | {name, image, status}], reported_at}
              end
        end
    '
}

fetch_status() {
    local source=$1 issue=$2 role=$3 seam_cmd=$4
    local body cleaned now_epoch rep_epoch
    if [[ -n $seam_cmd ]]; then
        body=$(bash -c "$seam_cmd") || {
            echo "$source status: fetch failed" >&2
            return 1
        }
    else
        body=$(status_body_default "$source" "$issue") || return 1
    fi
    now_epoch=$(date -u +%s)
    cleaned=$(printf "%s" "$body" | validate_status_payload "$role" "$now_epoch" 2>/dev/null) || {
        echo "$source status: invalid payload" >&2
        return 1
    }
    rep_epoch=$(jq -r '.reported_at | fromdateiso8601' <<<"$cleaned") || {
        echo "$source status: invalid payload" >&2
        return 1
    }
    if [[ $rep_epoch -lt $((now_epoch - 900)) ]]; then
        echo "$source status: stale payload" >&2
        return 1
    fi
    printf "%s\n" "$cleaned"
}

src_oracle() {
    fetch_status oracle "$STATUS_ISSUE_ORACLE" oracle "${STATUS_BODY_CMD_ORACLE:-${STATUS_BODY_CMD:-}}"
}

src_agent() {
    fetch_status agent "$STATUS_ISSUE_AGENT" agent "${STATUS_BODY_CMD_AGENT:-}"
}

src_proxy() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$PROXY_URL") || code=000
    jq -n --arg c "$code" '{ ready: ($c == "200"), http_code: ($c | tonumber) }'
}

src_monitor() {
    local payload
    payload=$(fetch_status monitor "$STATUS_ISSUE_MONITOR" monitor "${STATUS_BODY_CMD_MONITOR:-}") || return 1
    jq -c '{last: .verdict, ok, reported_at}' <<<"$payload"
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

for s in runs chain token oracle agent proxy monitor nightly; do
    run_source "$s" "src_$s"
done

# data.json.hosts keeps today's shape, assembled from each side's last good.
# WORK/oracle.json and WORK/agent.json hold the last good payloads (or null).
jq -n --slurpfile oracle "$WORK/oracle.json" --slurpfile agent "$WORK/agent.json" '
    ($oracle[0] | try .containers catch [] // []) as $oc
    | ($agent[0] | if type == "object"
        then {c: (.containers // []), e: .errors_6h, p: .published_24h}
        else {c: [], e: null, p: null} end) as $a
    | {oracle: ($oc // []), agent: ($a.c // []),
       agent_errors_6h: $a.e, agent_published_24h: $a.p}
' >"$WORK/hosts.json"

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

sources=$(for s in runs chain token oracle agent proxy monitor nightly; do
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
       proxy: $proxy[0],
       monitor: ($monitor[0] | if type == "object" then {last, ok} else . end),
       nightly: $nightly[0],
       nightly_stages: ["head-resolution", "runner-preflight", "day-claim", "resolve-upstream",
         "launch-attempt", "bootstrap-proposal", "bootstrap-checks", "image-resolution",
         "consumer-repin", "consumer-checks", "producer-check", "supervised-integration",
         "launch-cap", "launch"] }' >"$OUT_DIR/data.json.new" &&
    mv "$OUT_DIR/data.json.new" "$OUT_DIR/data.json"

echo "collected: $(for s in runs chain token oracle agent proxy monitor nightly; do printf '%s=%s ' "$s" "${SRC_STATUS[$s]}"; done)"
