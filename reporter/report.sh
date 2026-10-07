#!/usr/bin/env bash
# Reporter for the moog Antithesis dashboard (oracle and agent hosts).
#
# Lists containers through the Docker Engine API on the unix socket,
# keeps those whose name matches `moog`, and PATCHes the body of one
# status issue through the GitHub API. Only bash, curl and jq drive it
# (plus coreutils byte tools for the log stream); no docker CLI, no shell
# access beyond the socket, raw logs never leave the host, only
# name/image/status and two integers.
#
# Configuration (environment):
#   REPORTER_ROLE        oracle or agent
#   DOCKER_SOCKET        default /var/run/docker.sock
#   REPORT_REPOSITORY    default lambdasistemi/moog-antithesis-dashboard
#   STATUS_ISSUE_NUMBER  issue number to PATCH (not needed in dry-run)
#   STATUS_TOKEN_FILE    default /run/secrets/status-token
#   REPORT_DRY_RUN=1     print the payload and exit 0, no token, no issue
#                        number and no outward request
#   REPORT_API_BASE      default https://api.github.com (test seam for the
#                        smoke; production uses the default and nothing else)
#
# Agent role: same container list as oracle plus `errors_6h` (log lines
# matching `exception|error`, case-insensitive, over the last 6 hours) and
# `published_24h` (lines matching `Published result` over the last 24 hours)
# of the first container whose name matches `moog-agent`, read through
# `GET /containers/<id>/logs`. The log stream is multiplexed (8-byte
# frames); it is demultiplexed in memory and pipes only, counted line by
# line, and never written to disk, printed, or included in any output,
# error or payload. If no moog-agent container exists or the logs call
# fails, the reporter exits non-zero and the previous issue body stays.
#
# The token travels via curl's stdin config, never argv. Failures leave
# the previous issue body and exit non-zero with a message that never
# contains the token.
set -euo pipefail

ROLE=${REPORTER_ROLE:-oracle}
DOCKER_SOCKET=${DOCKER_SOCKET:-/var/run/docker.sock}
REPORT_REPOSITORY=${REPORT_REPOSITORY:-lambdasistemi/moog-antithesis-dashboard}
STATUS_TOKEN_FILE=${STATUS_TOKEN_FILE:-/run/secrets/status-token}
REPORT_API_BASE=${REPORT_API_BASE:-https://api.github.com}

agent_mode=0
if [[ $ROLE == "agent" ]]; then
    agent_mode=1
elif [[ $ROLE != "oracle" ]]; then
    echo "reporter: unsupported REPORTER_ROLE: $ROLE (want oracle or agent)" >&2
    exit 1
fi

[[ -S $DOCKER_SOCKET || -e $DOCKER_SOCKET ]] || {
    echo "reporter: no Docker socket in $DOCKER_SOCKET" >&2
    exit 1
}

# Demultiplex one Docker container log window to stdout as text.
# Arguments: container id, `since` epoch. The /logs stream is a sequence of
# 8-byte-header frames (1 type byte, 3 padding, 4 big-endian size bytes)
# framing arbitrary chunks of the text, so headers can split lines; frames
# are reassembled here before any line is examined. Everything stays in
# memory and pipes: logs never touch disk. Streams over 2 MiB are refused
# rather than decoded. Fails on fetch, corrupt or oversize streams.
fetch_logs_text() {
    local id=$1 since=$2 hex payload_hex="" pos len size
    hex=$(curl -sS --fail --max-time 30 --unix-socket "$DOCKER_SOCKET" \
        "http://localhost/containers/$id/logs?stdout=1&stderr=1&since=$since" |
        od -An -tx1 -v | tr -d ' \n') || return 1
    len=${#hex}
    if ((len > 4194304)); then
        return 1
    fi
    pos=0
    while ((pos + 16 <= len)); do
        size=$((16#${hex:$pos+8:8})) || return 1
        if ((size < 0 || size > 16777216)); then
            return 1
        fi
        pos=$((pos + 16))
        if ((size > 0)); then
            if ((pos + size * 2 > len)); then
                break
            fi
            payload_hex+=${hex:$pos:$((size * 2))}
            pos=$((pos + size * 2))
        fi
    done
    if [[ -z $payload_hex ]]; then
        return 0
    fi
    local esc
    esc=$(printf '%s' "$payload_hex" | fold -w2 | sed 's/^/\\x/' | tr -d '\n') || return 1
    printf '%b' "$esc"
}

reported_at=$(date -u +%FT%TZ)

# Docker Engine API on the unix socket: GET /containers/json.
# Names look like ["/oracle-moog-oracle-1"]; Image like
# "ghcr.io/org/moog-oracle:main" or "moog-oracle:v0.5.1.5"; Status like
# "Up 5 days". Keep those whose name matches `moog`, drop the registry
# prefix from the image, keep the API Status string verbatim.
docker_json=$(curl -sS --max-time 15 --unix-socket "$DOCKER_SOCKET" http://localhost/containers/json) || {
    echo "reporter: failed to list containers from $DOCKER_SOCKET" >&2
    exit 1
}

payload=$(jq -c --arg reported_at "$reported_at" '
    def strip_registry:
        if test("/") and ((split("/")[0] | test("[.:]"))) then
            (split("/")[1:] | join("/"))
        else
            .
        end;
    [ (. // [])[]
      | select((.Names // []) | map(test("moog")) | any)
      | {
          name: ((.Names[0] // "") | ltrimstr("/")),
          image: ((.Image // "") | strip_registry),
          status: (.Status // "")
        }
      | select(.name != "" and (.name | length <= 200)
               and (.image | length <= 200) and (.status | length <= 200))
    ] | sort_by(.name)
' <<<"$docker_json") || {
    echo "reporter: failed to build payload from Docker API output" >&2
    exit 1
}

if ((agent_mode)); then
    agent_id=$(jq -r '[.[] | select((((.Names[0] // "") | ltrimstr("/")) | test("moog-agent")))] | .[0].Id // empty' <<<"$docker_json") || {
        echo "reporter: failed to read containers from Docker API output" >&2
        exit 1
    }
    [[ -n $agent_id ]] || {
        echo "reporter: no moog-agent container" >&2
        exit 1
    }
    now_epoch=$(date +%s)
    log6=$(fetch_logs_text "$agent_id" "$((now_epoch - 21600))") || {
        echo "reporter: failed to fetch agent logs" >&2
        exit 1
    }
    errors_6h=0
    while IFS= read -r line; do
        lower=${line,,}
        if [[ $lower == *error* || $lower == *exception* ]]; then
            errors_6h=$((errors_6h + 1))
        fi
    done <<<"$log6"
    log24=$(fetch_logs_text "$agent_id" "$((now_epoch - 86400))") || {
        echo "reporter: failed to fetch agent logs" >&2
        exit 1
    }
    published_24h=0
    while IFS= read -r line; do
        if [[ $line == *"Published result"* ]]; then
            published_24h=$((published_24h + 1))
        fi
    done <<<"$log24"
    payload=$(jq -n -c --arg role "$ROLE" --arg reported_at "$reported_at" \
        --argjson errors_6h "$errors_6h" --argjson published_24h "$published_24h" \
        --argjson containers "$payload" \
        '{role: $role, containers: $containers, errors_6h: $errors_6h, published_24h: $published_24h, reported_at: $reported_at}') || {
        echo "reporter: failed to build payload from Docker API output" >&2
        exit 1
    }
else
    payload=$(jq -n -c --arg role "$ROLE" --arg reported_at "$reported_at" \
        --argjson containers "$payload" \
        '{role: $role, containers: $containers, reported_at: $reported_at}') || {
        echo "reporter: failed to build payload from Docker API output" >&2
        exit 1
    }
fi

if [[ ${REPORT_DRY_RUN:-0} == "1" ]]; then
    printf '%s\n' "$payload"
    exit 0
fi

[[ -n ${STATUS_ISSUE_NUMBER:-} ]] || {
    echo "reporter: no STATUS_ISSUE_NUMBER" >&2
    exit 1
}
[[ -r $STATUS_TOKEN_FILE ]] || {
    echo "reporter: no token file in $STATUS_TOKEN_FILE" >&2
    exit 1
}

api_url="$REPORT_API_BASE/repos/$REPORT_REPOSITORY/issues/$STATUS_ISSUE_NUMBER"
patch_json=$(jq -n -c --arg body "$payload" '{body: $body}')

# Token via curl's stdin config, never argv. The patch body holds only the
# public payload, never the token. Any failure message below is generic on
# purpose: it must never contain the token.
if ! printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' \
    "$(cat "$STATUS_TOKEN_FILE")" |
    curl -K - -sS --max-time 30 -X PATCH \
        -H "Content-Type: application/json" \
        --data "$patch_json" "$api_url" >/dev/null; then
    echo "reporter: failed to update status issue $STATUS_ISSUE_NUMBER in $REPORT_REPOSITORY" >&2
    exit 1
fi
