#!/usr/bin/env bash
set -euo pipefail

run=$1 cache=$2 out=$3
unavailable() {
    jq -n --arg reason "$1" '{status:"unavailable",reason:$reason,url:null,
      source_url:null,commit:null,internal_network:true}'
}
if ! jq -e '
  (.run_id | type == "string" and test("^[A-Za-z0-9_-]{1,200}$")) and
  (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and
    (split("/") | all(. != "." and . != ".."))) and
  (.commit | type == "string" and test("^[0-9a-fA-F]{40}$")) and
  (.directory | type == "string" and length > 0 and
    (split("/") | all(. != "" and . != "." and . != ".." and test("^[A-Za-z0-9_. -]+$"))))
' <<<"$run" >/dev/null 2>&1; then
    unavailable missing_or_invalid_coordinates
    exit 0
fi
rid=$(jq -r .run_id <<<"$run")
repo=$(jq -r .repository <<<"$run")
commit=$(jq -r .commit <<<"$run")
directory=$(jq -r '.directory | split("/") | map(@uri) | join("/")' <<<"$run")
key=$(printf '%s\n' "$repo" "$commit" "$directory" | sha256sum | cut -d' ' -f1)
mkdir -p "$cache/compose" "$out/runs/$rid"
cached="$cache/compose/$key"
if [[ ! -s $cached.yaml || ! -s $cached.json ]]; then
    temp=$(mktemp -d)
    trap 'rm -rf "$temp"' EXIT
    found=false
    for filename in docker-compose.yaml docker-compose.yml; do
        # Public raw GitHub reads deliberately have no credential header.
        if curl --fail --silent --show-error --proto '=https' --connect-timeout 5 --max-time 10 \
            --max-filesize 1048576 "https://raw.githubusercontent.com/$repo/$commit/$directory/$filename" \
            >"$temp/source" 2>/dev/null && [[ -s $temp/source ]]; then
            # Match the placeholder literally, independently of the host environment.
            # shellcheck disable=SC2016
            sed 's/${INTERNAL_NETWORK}/true/g' "$temp/source" >"$temp/local.yaml"
            if grep -Eq 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' "$temp/local.yaml"; then
                rm -f "$out/runs/$rid/docker-compose.yaml"
                unavailable publication_refused
                exit 0
            fi
            jq -n --arg commit "$commit" --arg source "https://github.com/$repo/blob/$commit/$directory/$filename" \
                '{status:"available",reason:null,source_url:$source,commit:$commit,internal_network:true}' >"$temp/meta.json"
            mv "$temp/local.yaml" "$cached.yaml"
            mv "$temp/meta.json" "$cached.json"
            found=true
            break
        fi
    done
    if [[ $found != true ]]; then
        rm -f "$out/runs/$rid/docker-compose.yaml"
        unavailable source_unavailable
        exit 0
    fi
fi
cp "$cached.yaml" "$out/runs/$rid/docker-compose.yaml"
jq --arg url "runs/$rid/docker-compose.yaml" '. + {url:$url}' "$cached.json"
