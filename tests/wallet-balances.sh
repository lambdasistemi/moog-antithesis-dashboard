#!/usr/bin/env bash
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CACHE="$WORK/cache"
mkdir -p "$CACHE/last"
declare -A SRC_STATUS SRC_ERR SRC_LAST
now() { date -u +%FT%TZ; }
source collect/wallets.sh
# Exercise the actual collector fallback function with this source.
source <(sed -n '/^run_source() {/,/^}/p' collect/collect.sh)
a=addr_test1vq04e6lvknx3ettppz5xq9x7nk8j87w5gaammke7z2ymyfqtkl4vv
b=addr_test1vzupzdprwu94m5xlurzcycy89dxcw45s43tw406dxqfl79cq3szdc
jq -n --arg a "$a" --arg b "$b" '{schema_version:1,wallets:[{id:"oracle",role:"oracle",network:"preprod",addresses:[$a,$b],scope_evidence:"fixture"}]}' >"$WORK/config.fixture"
jq -n --arg a "$a" --arg b "$b" '[{address:$a,balance:"9007199254740993"},{address:$b,balance:"2"}]' >"$WORK/response.fixture"
wallet_config() {
    cp "$WORK/config.fixture" "$WORK/wallet-config.json"
    printf '%040d' 1
}
wallet_query() {
    [[ ${query_fail:-0} == 0 ]] || return 1
    cat "$WORK/response.fixture"
}
run_source wallets src_wallets
[[ ${SRC_STATUS[wallets]} == ok ]]
jq -e '.accounts[0].balance_lovelace=="9007199254740995" and .chain_point==null and .history_status=="not_collected"' "$WORK/wallets.json" >/dev/null || {
    echo "wallet balance lost exact lovelace total" >&2
    exit 1
}
at=${SRC_LAST[wallets]}
query_fail=1
run_source wallets src_wallets
[[ ${SRC_STATUS[wallets]} == stale && ${SRC_LAST[wallets]} == "$at" ]]
jq -e '.accounts[0].balance_lovelace=="9007199254740995"' "$WORK/wallets.json" >/dev/null
query_fail=0
for bad in missing duplicate negative fractional native-token; do
    case $bad in
    missing) jq '.[0:1]' "$WORK/response.fixture" >"$WORK/bad.json" ;;
    duplicate) jq '.[1]=.[0]' "$WORK/response.fixture" >"$WORK/bad.json" ;;
    negative) jq '.[0].balance="-1"' "$WORK/response.fixture" >"$WORK/bad.json" ;;
    fractional) jq '.[0].balance="1.5"' "$WORK/response.fixture" >"$WORK/bad.json" ;;
    native-token) jq '.[0] |= (del(.balance) + {asset_list:[{quantity:"123"}]})' "$WORK/response.fixture" >"$WORK/bad.json" ;;
    esac
    wallet_query() { cat "$WORK/bad.json"; }
    if src_wallets >/dev/null 2>&1; then
        echo "wallets accepted $bad response" >&2
        exit 1
    fi
done
wallet_query() { cat "$WORK/response.fixture"; }
cp "$WORK/config.fixture" "$WORK/config.saved"
for bad in network duplicate-address unknown-key; do
    case $bad in
    network) jq '.wallets[0].network="preview"' "$WORK/config.saved" >"$WORK/config.fixture" ;;
    duplicate-address) jq '.wallets[0].addresses[1]=.wallets[0].addresses[0]' "$WORK/config.saved" >"$WORK/config.fixture" ;;
    unknown-key) jq '.wallets[0].private_key="planted"' "$WORK/config.saved" >"$WORK/config.fixture" ;;
    esac
    if src_wallets >/dev/null 2>&1; then
        echo "wallets accepted $bad configuration" >&2
        exit 1
    fi
done
cp "$WORK/config.saved" "$WORK/config.fixture"
run_source wallets src_wallets
[[ ${SRC_STATUS[wallets]} == ok ]]
rm "$CACHE/last/wallets.json" "$CACHE/last/wallets.at"
wallet_query() { return 1; }
run_source wallets src_wallets
[[ ${SRC_STATUS[wallets]} == error ]]
jq -e '.==null' "$WORK/wallets.json" >/dev/null
echo 'wallet balances exact, invalid responses refused, stale/recovery ok'
