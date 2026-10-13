#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export COMPOSE_FIXTURE="$work" DASHBOARD_CACHE="$work/cache" DASHBOARD_OUT="$work/out"
export ANTITHESIS_API_KEY_FILE="$work/key" GH_READ_TOKEN_FILE="$work/absent"
export MOOG_READ_ENV_FILE="$work/absent" MOOG_DIR="$work/bin" PROXY_URL=http://127.0.0.1:9/
export STATUS_ISSUE_ORACLE='' STATUS_ISSUE_AGENT='' STATUS_ISSUE_MONITOR=''
export STATUS_ISSUE_MPFS_COLLECTOR='' STATUS_ISSUE_MPFS_ROLES=''
printf fixture-key >"$work/key"
commit=0123456789012345678901234567890123456789
jq -n --arg commit "$commit" '{run_id:"compose-test",status:"completed",created_at:"2026-10-13T00:00:00Z",
  description:({testRun:{commitId:$commit,directory:"testnets/local",repository:{organization:"public-owner",repo:"public-repo"}}}|tojson),parameters:{}}' >"$work/run"
cat >"$work/source" <<'EOF'
services:
  node:
    image: example:1
    environment:
      INTERNAL_NETWORK: ${INTERNAL_NETWORK}
      OTHER_VALUE: ${OTHER_VALUE}
EOF
# shellcheck disable=SC2016
sed 's/${INTERNAL_NETWORK}/true/g' "$work/source" >"$work/expected"
printf yaml >"$work/mode"
printf '#!%s\n' "$(command -v bash)" >"$work/bin/curl"
cat >>"$work/bin/curl" <<'EOF'
set -eu
if [[ " $* " == *' -K '* ]]; then
    url=$(sed -n 's/^url = "\(.*\)"$/\1/p')
else
    url=${!#}
fi
case "$url" in
    *'/runs?limit='*) jq '{data:[.]}' "$COMPOSE_FIXTURE/run" ;;
    *'/properties'*) printf '{"data":[]}' ;;
    *'/runs/compose-test') cat "$COMPOSE_FIXTURE/run" ;;
    https://raw.githubusercontent.com/*)
        [[ " $* " != *' -K '* && " $* " != *' --header '* && " $* " != *' -H '* ]] || exit 1
        printf '%s\n' "$url" >>"$COMPOSE_FIXTURE/requests"
        mode=$(cat "$COMPOSE_FIXTURE/mode")
        [[ $mode != unavailable ]] || exit 22
        [[ $mode != yml || $url == *.yml ]] || exit 22
        cat "$COMPOSE_FIXTURE/source" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
collect() { bash collect/collect.sh >"$work/collection.log" 2>&1; }
collect
jq -e '.runs[0].compose.status=="available" and .runs[0].compose.internal_network==true and .runs[0].compose.url=="runs/compose-test/docker-compose.yaml"' "$work/out/data.json" >/dev/null || {
    echo 'Compose asset is absent from actual collector output' >&2
    exit 1
}
cmp "$work/expected" "$work/out/runs/compose-test/docker-compose.yaml"
jq -e --arg commit "$commit" '.compose.commit==$commit and .compose.source_url==("https://github.com/public-owner/public-repo/blob/"+$commit+"/testnets/local/docker-compose.yaml")' "$work/out/runs/compose-test.json" >/dev/null
collect
[[ $(wc -l <"$work/requests") == 1 ]]
jq -e --slurpfile snapshot "$work/out/data.json" '.compose==$snapshot[0].runs[0].compose' "$work/out/runs/compose-test.json" >/dev/null

export DASHBOARD_CACHE="$work/yml-cache"
printf yml >"$work/mode"
collect
jq -e '.runs[0].compose.source_url|endswith("docker-compose.yml")' "$work/out/data.json" >/dev/null
cmp "$work/expected" "$work/out/runs/compose-test/docker-compose.yaml"

export DASHBOARD_CACHE="$work/retry-cache"
printf unavailable >"$work/mode"
collect
jq -e '.runs[0].compose.status=="unavailable" and .runs[0].compose.url==null' "$work/out/data.json" >/dev/null
printf yaml >"$work/mode"
collect
jq -e '.runs[0].compose.status=="available"' "$work/out/data.json" >/dev/null

cp "$work/run" "$work/original"
for mutation in '.description="{}"' '.description|=fromjson|.description.testRun.directory="../escape"|.description|=tojson' '.description|=fromjson|.description.testRun.commitId="main"|.description|=tojson'; do
    jq "$mutation" "$work/original" >"$work/bad"
    cp "$work/bad" "$work/run"
    before=$(wc -l <"$work/requests")
    collect
    jq -e '.runs[0].compose.status=="unavailable" and .runs[0].compose.url==null' "$work/out/data.json" >/dev/null
    [[ $(wc -l <"$work/requests") == "$before" ]]
done
echo 'Per-run Compose assets preserve pinned provenance, substitutions, caching and recovery'
cp "$work/original" "$work/run"
export DASHBOARD_CACHE="$work/refused-cache"
printf '\n# auth=fixture-only\n' >>"$work/source"
collect
jq -e '.runs[0].compose.status=="unavailable" and .runs[0].compose.reason=="publication_refused"' "$work/out/data.json" >/dev/null
[[ ! -e "$work/out/runs/compose-test/docker-compose.yaml" ]]
echo 'A refused Compose source does not block the rest of the snapshot'
