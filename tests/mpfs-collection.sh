#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '#!%s\nexit 1\n' "$(command -v bash)" >"$work/bin/curl"
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" DASHBOARD_CACHE="$work/cache"
export ANTITHESIS_API_KEY_FILE="$work/absent" GH_READ_TOKEN_FILE="$work/absent"
export MOOG_READ_ENV_FILE="$work/absent"
export STATUS_BODY_CMD_MPFS_COLLECTOR="cat '$work/collector'"
export STATUS_BODY_CMD_MPFS_ROLES="cat '$work/roles'"
now=$(date -u +%FT%TZ)
sample() {
    jq -n --arg t "$now" --arg id "$1" --arg name "$2" --argjson used "$3" '
      {role:"mpfs",service_id:$id,used_by:$used,network:"preprod",
       container:{name:$name,image:"ghcr.io/cardano-foundation/mpfs/mpfs:v1.3.1@sha256:7ae4f6dbadde0f823371a0aba6173807e89d7d2167de5db9bfd72951e9df524b",status:"running"},
       api:{reachable:true,http_status:200},
       synchronization:{status:"observed",ready:true,network_tip_slot:100,indexer_tip_slot:100,lag_slots:0},reported_at:$t}'
}
sample collector-legacy-mpfs mpfs-compose-mpfs-1 '["dashboard-collector"]' >"$work/collector"
sample moog-role-legacy-mpfs mpfs-mpfs-1 '["oracle","agent"]' >"$work/roles"
collect() { bash collect/collect.sh >/dev/null 2>"$work/errors"; }
check() { jq -e "$1" "$DASHBOARD_CACHE/out/data.json" >/dev/null; }
collect
check '.sources.mpfs_collector.status=="ok" and .sources.mpfs_roles.status=="ok" and .mpfs.collector.synchronization.lag_slots==0'
cp "$work/collector" "$work/valid"
for mutation in '.extra="private-probe-material"' '.api.extra="private-probe-material"' \
    '.service_id="moog-role-legacy-mpfs"' '.container.name="another-mpfs"' \
    '.container.image="private?token=secret"' '.synchronization.lag_slots=1' \
    '.synchronization.indexer_tip_slot=100.5' '.reported_at="2099-01-01T00:00:00Z"' \
    '.reported_at="2020-01-01T00:00:00Z"'; do
    jq "$mutation" "$work/valid" >"$work/collector"
    collect
    check '.sources.mpfs_collector.status=="stale" and .mpfs.collector.synchronization.lag_slots==0 and .sources.mpfs_roles.status=="ok"'
    jq -e --arg at "$now" '.sources.mpfs_collector.last_success==$at' "$DASHBOARD_CACHE/out/data.json" >/dev/null
    check '.sources.mpfs_collector.error|test("invalid|expired")'
    if rg -q 'private-probe-material' "$DASHBOARD_CACHE/out/data.json"; then
        echo 'mpfs: refused body escaped into public snapshot' >&2
        exit 1
    fi
done
printf not-json >"$work/collector"
collect
check '.sources.mpfs_collector.status=="stale"'
cp "$work/valid" "$work/collector"
jq '.api={reachable:false,http_status:503} | .synchronization={status:"unmeasured",ready:null,network_tip_slot:null,indexer_tip_slot:null,lag_slots:null}' "$work/valid" >"$work/collector"
collect
check '.sources.mpfs_collector.status=="ok" and .mpfs.collector.api.reachable==false and .mpfs.collector.synchronization.status=="unmeasured"'
export DASHBOARD_CACHE="$work/empty-cache"
printf not-json >"$work/collector"
collect
check '.sources.mpfs_collector.status=="error" and .mpfs.collector==null and .sources.mpfs_roles.status=="ok"'
echo 'MPFS independent validation, stale retention and recovery controls pass'
