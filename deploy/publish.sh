#!/usr/bin/env bash
# Publish site/ plus the collected data.json, per-run detail files and status
# payloads to the gh-pages branch over HTTPS.
#
# The branch is a single orphan commit, force-pushed each cycle, so history
# never grows. A secrets gate refuses to publish anything that holds a
# credential, an authenticated report link, or the literal content of any
# mounted secret. The push token reaches git through a credential helper
# that reads it from a file; it never appears in argv, the remote URL, git
# config on disk or any message.
#
# DASHBOARD_DRY_RUN=1 stages the same files, runs the full gate, commits
# locally in the staging directory and prints what would be published,
# without pushing and without needing a token file.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${DASHBOARD_CACHE:-$HOME/.cache/moog-antithesis-dashboard}
OUT_DIR=${DASHBOARD_OUT:-$CACHE/out}
ANTI_KEY_FILE=${ANTITHESIS_API_KEY_FILE:-/run/secrets/antithesis-key}
SECRETS_DIR=${DASHBOARD_SECRETS_DIR:-/run/secrets}
MOOG_ENV_FILE=${MOOG_READ_ENV_FILE:-/run/secrets/moog-read-env}
PAGES_PUSH_TOKEN_FILE=${PAGES_PUSH_TOKEN_FILE:-/run/secrets/pages-push}
REMOTE=${DASHBOARD_REMOTE:-https://github.com/lambdasistemi/moog-antithesis-dashboard.git}
export PAGES_PUSH_TOKEN_FILE

[[ -s $OUT_DIR/data.json ]] || {
    echo "no data.json in $OUT_DIR" >&2
    exit 1
}
if [[ ${DASHBOARD_DRY_RUN:-0} != "1" ]]; then
    [[ -s $PAGES_PUSH_TOKEN_FILE ]] || {
        echo "no push token file in $PAGES_PUSH_TOKEN_FILE" >&2
        exit 1
    }
fi

STAGE=$(mktemp -d)
PATTERNS=$(mktemp)
PUSH_HELPER=$(mktemp)
trap 'rm -rf "$STAGE" "$PATTERNS" "$PUSH_HELPER"' EXIT
cp "$HERE"/site/* "$STAGE"/
cp "$OUT_DIR/data.json" "$STAGE"/
[[ -s $OUT_DIR/property-descriptions.json ]] && cp "$OUT_DIR/property-descriptions.json" "$STAGE"/
if compgen -G "$OUT_DIR/runs/*.json" >/dev/null; then
    mkdir -p "$STAGE/runs"
    cp "$OUT_DIR"/runs/*.json "$STAGE"/runs/
fi
if compgen -G "$OUT_DIR/status/*.json" >/dev/null; then
    mkdir -p "$STAGE/status"
    cp "$OUT_DIR"/status/*.json "$STAGE"/status/
fi
touch "$STAGE/.nojekyll"

# Secrets gate: authenticated report links, bearer tokens and basic-auth
# arguments. Mounted-secret literals follow below.
if grep -rEq 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' "$STAGE"; then
    echo "secrets gate: refusing to publish" >&2
    (cd "$STAGE" && grep -rEl 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' .) >&2
    exit 2
fi

# Secrets gate: the literal content of every mounted secret file, the key
# file, and every long-enough value of the moog read environment. A leading
# `export ` is accepted and one pair of surrounding quotes is removed before
# measuring. Blank
# lines are filtered out: as fixed-string patterns they would match every
# file. Moog values shorter than 8 characters are skipped for the same
# reason.
: >"$PATTERNS"
if [[ -d $SECRETS_DIR ]]; then
    while IFS= read -r -d '' secret_file; do
        grep -v '^[[:space:]]*$' "$secret_file" >>"$PATTERNS" || true
    done < <(find "$SECRETS_DIR" -maxdepth 1 -type f -print0)
fi
if [[ -s $ANTI_KEY_FILE ]]; then
    grep -v '^[[:space:]]*$' "$ANTI_KEY_FILE" >>"$PATTERNS" || true
fi
if [[ -s $MOOG_ENV_FILE ]]; then
    while IFS= read -r line; do
        if [[ $line == export\ * ]]; then
            line=${line#export }
        fi
        [[ $line == *=* ]] || continue
        value=${line#*=}
        if [[ ${#value} -ge 2 ]]; then
            if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
                value=${value:1:-1}
            elif [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
                value=${value:1:-1}
            fi
        fi
        [[ ${#value} -ge 8 ]] || continue
        printf '%s\n' "$value" >>"$PATTERNS"
    done <"$MOOG_ENV_FILE"
fi
if [[ -s $PATTERNS ]] && grep -rqF -f "$PATTERNS" "$STAGE"; then
    echo "secrets gate: mounted secret found, refusing to publish" >&2
    (cd "$STAGE" && grep -rlF -f "$PATTERNS" .) >&2
    exit 2
fi

# URL gate (monitor payloads): the reporter strips URLs before sending, so
# a URL in a status payload or in data.json's monitor subtree is a leak or
# a hand edit: refuse. Run and detail URLs (runs/, nightly links) stay
# legal and are out of scope here; only file names are reported, never
# matched text.
if compgen -G "$STAGE/status/*.json" >/dev/null; then
    if grep -rqE 'https?://' "$STAGE/status"; then
        echo "secrets gate: URL in status payload, refusing to publish" >&2
        (cd "$STAGE/status" && grep -rEl 'https?://' .) >&2
        exit 2
    fi
fi
if jq -e '.monitor | .. | strings | select(test("https?://"))' "$STAGE/data.json" >/dev/null; then
    echo "secrets gate: URL in monitor payload, refusing to publish" >&2
    echo "data.json" >&2
    exit 2
fi

# Credential helper: git calls this for the HTTPS push. The username is
# fixed; the token is read from its file at request time, so it never lands
# in argv, the remote URL, git config on disk or any message.
if [[ ${DASHBOARD_DRY_RUN:-0} == "1" ]]; then
    cd "$STAGE"
    git init -q -b gh-pages
    git add -A
    git -c user.name="moog-antithesis-dashboard" -c user.email="noreply@lambdasistemi.net" \
        commit -q -m "data $(jq -r .generated_at data.json)"
    n=$(git ls-files | wc -l | tr -d ' ')
    t=$(jq -r .generated_at data.json)
    echo "dry run: would publish $n files, generated_at $t"
    git ls-files
    exit 0
fi
cat >"$PUSH_HELPER" <<'HELPER_EOF'
#!/usr/bin/env bash
printf 'username=x-access-token\npassword=%s\n' "$(cat "$PAGES_PUSH_TOKEN_FILE")"
HELPER_EOF
chmod +x "$PUSH_HELPER"

cd "$STAGE"
git init -q -b gh-pages
git add -A
git -c user.name="moog-antithesis-dashboard" -c user.email="noreply@lambdasistemi.net" \
    commit -q -m "data $(jq -r .generated_at data.json)"
GIT_TERMINAL_PROMPT=0 git -c credential.helper="$PUSH_HELPER" push -q -f "$REMOTE" gh-pages
echo "published $(jq -r .generated_at data.json)"
