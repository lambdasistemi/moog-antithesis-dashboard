#!/usr/bin/env bash
# Read one explicitly identified legacy MPFS container and its tokens endpoint.
set -euo pipefail
service=${MPFS_SERVICE_ID:?set MPFS_SERVICE_ID}
case $service in
collector-legacy-mpfs)
    name=mpfs-compose-mpfs-1
    used='["dashboard-collector"]'
    ;;
moog-role-legacy-mpfs)
    name=mpfs-mpfs-1
    used='["oracle","agent"]'
    ;;
*)
    echo 'mpfs: unknown service identity' >&2
    exit 1
    ;;
esac
probe_url=${MPFS_PROBE_URL:?set MPFS_PROBE_URL}
[[ $probe_url =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/tokens$ ]] || {
    echo 'mpfs: expected an unauthenticated tokens endpoint' >&2
    exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
socket=${DOCKER_SOCKET:-/var/run/docker.sock}
containers=$(curl -s --fail --max-time 15 --max-filesize 1048576 --unix-socket "$socket" 'http://localhost/containers/json?all=1') || {
    echo 'mpfs: container observation failed' >&2
    exit 1
}
container=$(jq -ec --arg name "$name" '
    [.[] | select(.Names | index("/" + $name))] as $matches
    | if ($matches | length) > 1 then error("ambiguous")
      elif ($matches | length) == 0 then {name:$name,image:null,status:"missing"}
      else $matches[0] | {name:$name,image:.Image,status:.State} end' <<<"$containers" 2>/dev/null) || {
    echo 'mpfs: invalid container observation' >&2
    exit 1
}
http=$(curl -s --max-time 15 --max-filesize 4194304 --output "$work/probe" --write-out '%{http_code}' "$probe_url") || http=000
if [[ $http =~ ^[1-5][0-9][0-9]$ ]]; then code=$((10#$http)); else code=null; fi
reachable=false
if [[ $code != null && $code -ge 200 && $code -lt 300 ]]; then reachable=true; fi
sync='{"status":"unmeasured","ready":null,"network_tip_slot":null,"indexer_tip_slot":null,"lag_slots":null}'
if [[ $reachable == true ]]; then
    observed=$(jq -ec '
        def slot: type=="number" and .>=0 and .<=9007199254740991 and floor==.;
        .indexerStatus | select(type=="object" and (.ready|type)=="boolean"
            and (.networkTip|slot) and (.indexerTip|slot) and .networkTip>=.indexerTip)
        | {status:"observed",ready,network_tip_slot:.networkTip,indexer_tip_slot:.indexerTip,lag_slots:(.networkTip-.indexerTip)}
    ' "$work/probe" 2>/dev/null) && sync=$observed
fi
jq -nc --arg service "$service" --argjson used "$used" --argjson container "$container" \
    --argjson code "$code" --argjson reachable "$reachable" --argjson sync "$sync" \
    --arg at "$(date -u +%FT%TZ)" \
    '{role:"mpfs",service_id:$service,used_by:$used,network:"preprod",container:$container,
      api:{reachable:$reachable,http_status:$code},synchronization:$sync,reported_at:$at}' |
    jq -ec --arg service "$service" --argjson now "$(date +%s)" \
        -f "$(dirname "${BASH_SOURCE[0]}")/../schema/mpfs.jq" 2>/dev/null || {
    echo 'mpfs: unsafe or invalid observation refused' >&2
    exit 1
}
