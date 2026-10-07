#!/usr/bin/env bash
# Reporter for the moog Antithesis dashboard (oracle host, slice 1).
#
# Lists containers through the Docker Engine API on the unix socket,
# keeps those whose name matches `moog`, and PATCHes the body of one
# status issue through the GitHub API. Only bash, curl and jq are used:
# no docker CLI, no shell access beyond the socket, raw logs never leave
# the host, only name/image/status counts.
#
# Configuration (environment):
#   REPORTER_ROLE        oracle (agent is accepted but refused until slice 2)
#   DOCKER_SOCKET        default /var/run/docker.sock
#   REPORT_REPOSITORY    default lambdasistemi/moog-antithesis-dashboard
#   STATUS_ISSUE_NUMBER  issue number to PATCH (not needed in dry-run)
#   STATUS_TOKEN_FILE    default /run/secrets/status-token
#   REPORT_DRY_RUN=1     print the payload and exit 0, no token, no issue
#                        number and no outward request
#   REPORT_API_BASE      default https://api.github.com (test seam for the
#                        smoke; production uses the default and nothing else)
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

if [[ $ROLE == "agent" ]]; then
    echo "reporter: agent role not yet supported (slice 2)" >&2
    exit 1
fi
if [[ $ROLE != "oracle" ]]; then
    echo "reporter: unsupported REPORTER_ROLE: $ROLE (want oracle)" >&2
    exit 1
fi

[[ -S $DOCKER_SOCKET || -e $DOCKER_SOCKET ]] || {
    echo "reporter: no Docker socket in $DOCKER_SOCKET" >&2
    exit 1
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

payload=$(jq -c --arg role "$ROLE" --arg reported_at "$reported_at" '
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
    ] | sort_by(.name) as $cs
    | {role: $role, containers: $cs, reported_at: $reported_at}
' <<<"$docker_json") || {
    echo "reporter: failed to build payload from Docker API output" >&2
    exit 1
}

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
