#!/usr/bin/env bash
# Publish site/ plus the collected data.json to the gh-pages branch.
#
# The branch is a single orphan commit, force-pushed each cycle, so history
# never grows. A secrets gate refuses to publish anything that looks like a
# credential or an authenticated report link.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${DASHBOARD_CACHE:-$HOME/.cache/moog-antithesis-dashboard}
OUT_DIR=${DASHBOARD_OUT:-$CACHE/out}
ANTI_KEY_FILE=${ANTITHESIS_API_KEY_FILE:-$HOME/.secrets/antithesis-api-key}
REMOTE=${DASHBOARD_REMOTE:-git@github.com:lambdasistemi/moog-antithesis-dashboard.git}

[[ -s $OUT_DIR/data.json ]] || {
    echo "no data.json in $OUT_DIR" >&2
    exit 1
}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$HERE"/site/* "$STAGE"/
cp "$OUT_DIR/data.json" "$STAGE"/
touch "$STAGE/.nojekyll"

# Secrets gate: authenticated report links, bearer tokens, basic-auth
# arguments, and the literal Antithesis key (matched from the file, never argv).
if grep -rEq 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' "$STAGE"; then
    echo "secrets gate: refusing to publish" >&2
    grep -rEl 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' "$STAGE" >&2
    exit 2
fi
if [[ -s $ANTI_KEY_FILE ]] && grep -rqF -f "$ANTI_KEY_FILE" "$STAGE"; then
    echo "secrets gate: Antithesis key found, refusing to publish" >&2
    exit 2
fi

cd "$STAGE"
git init -q -b gh-pages
git add -A
git -c user.name="moog-antithesis-dashboard" -c user.email="noreply@lambdasistemi.net" \
    commit -q -m "data $(jq -r .generated_at data.json)"
git push -q -f "$REMOTE" gh-pages
echo "published $(jq -r .generated_at data.json)"
