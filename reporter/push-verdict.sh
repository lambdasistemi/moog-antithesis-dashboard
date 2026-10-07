#!/usr/bin/env bash
# Push step for the freshness monitor verdict (issue #12).
#
# Reads ONE verdict line from stdin or from the file named by $1, strips
# every http(s) URL with the collector rule `sed 's/https\?:[^ ]*//g'`,
# and PATCHes `{role:"monitor", verdict, ok, reported_at}` as the body of
# one status issue over HTTPS. ok is true when the stripped line starts
# with "OK". It never touches the Docker socket.
#
# Configuration (environment, same names as reporter/report.sh):
#   STATUS_ISSUE_NUMBER  issue number to PATCH (not needed in dry-run)
#   REPORT_REPOSITORY    default lambdasistemi/moog-antithesis-dashboard
#   STATUS_TOKEN_FILE    default /run/secrets/status-token
#   REPORT_DRY_RUN=1     print the payload and exit 0, no token file needed
#                        and no outward request
#   REPORT_API_BASE      default https://api.github.com (test seam for the
#                        smoke; production uses the default and nothing else)
#
# An empty verdict line exits non-zero and sends nothing. The token travels
# via curl's stdin config, never argv. Failure messages never contain the
# token or the verdict's URL (URLs are stripped before anything is printed
# or sent).
set -euo pipefail

REPORT_REPOSITORY=${REPORT_REPOSITORY:-lambdasistemi/moog-antithesis-dashboard}
STATUS_TOKEN_FILE=${STATUS_TOKEN_FILE:-/run/secrets/status-token}
REPORT_API_BASE=${REPORT_API_BASE:-https://api.github.com}

if [[ $# -ge 1 ]]; then
    [[ -r $1 ]] || {
        echo "push-verdict: cannot read $1" >&2
        exit 1
    }
    if IFS= read -r line <"$1" || [[ -n ${line:-} ]]; then
        :
    else
        echo "push-verdict: empty verdict line" >&2
        exit 1
    fi
else
    if IFS= read -r line || [[ -n ${line:-} ]]; then
        :
    else
        echo "push-verdict: empty verdict line" >&2
        exit 1
    fi
fi

stripped=$(printf '%s' "$line" | sed 's/https\?:[^ ]*//g')
if [[ -z ${stripped//[[:space:]]/} ]]; then
    echo "push-verdict: empty verdict line" >&2
    exit 1
fi

ok=false
if [[ $stripped == OK* ]]; then
    ok=true
fi
reported_at=$(date -u +%FT%TZ)

payload=$(jq -n -c --arg verdict "$stripped" --argjson ok "$ok" --arg reported_at "$reported_at" \
    '{role: "monitor", verdict: $verdict, ok: $ok, reported_at: $reported_at}') || {
    echo "push-verdict: failed to build payload" >&2
    exit 1
}

if [[ ${REPORT_DRY_RUN:-0} == "1" ]]; then
    printf '%s\n' "$payload"
    exit 0
fi

[[ -n ${STATUS_ISSUE_NUMBER:-} ]] || {
    echo "push-verdict: no STATUS_ISSUE_NUMBER" >&2
    exit 1
}
[[ -r $STATUS_TOKEN_FILE ]] || {
    echo "push-verdict: no token file in $STATUS_TOKEN_FILE" >&2
    exit 1
}

api_url="$REPORT_API_BASE/repos/$REPORT_REPOSITORY/issues/$STATUS_ISSUE_NUMBER"
patch_json=$(jq -n -c --arg body "$payload" '{body: $body}')

# Token via curl's stdin config, never argv. The patch body holds only the
# public payload, never the token. Any failure message below is generic on
# purpose: it must never contain the token or a verdict URL.
if ! printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' \
    "$(cat "$STATUS_TOKEN_FILE")" |
    curl -K - -sS --max-time 30 -X PATCH \
        -H "Content-Type: application/json" \
        --data "$patch_json" "$api_url" >/dev/null; then
    echo "push-verdict: failed to update status issue $STATUS_ISSUE_NUMBER in $REPORT_REPOSITORY" >&2
    exit 1
fi
