#!/usr/bin/env bash
# An HTTP refusal must fail the hook so the monitor can retry it.
set -euo pipefail
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
printf 'synthetic-monitor-token\n' >"$fixture/token"
printf '#!%s\n' "$(command -v bash)" >"$fixture/bin/curl"
cat >>"$fixture/bin/curl" <<'CURL'
cat >/dev/null
for arg in "$@"; do
    if [[ $arg == --fail || $arg == --fail-with-body ]]; then
        exit 22
    fi
done
# curl without --fail returns success for a 403 response.
exit 0
CURL
chmod +x "$fixture/bin/curl"
if printf 'OK all checks passed\n' | PATH="$fixture/bin:$PATH" \
    STATUS_TOKEN_FILE="$fixture/token" STATUS_ISSUE_NUMBER=1 \
    bash reporter/push-verdict.sh >"$fixture/out" 2>&1; then
    echo 'monitor hook reported an HTTP refusal as success' >&2
    exit 1
fi
echo 'monitor HTTP refusal correctly fails'
