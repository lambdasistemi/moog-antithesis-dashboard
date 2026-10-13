#!/usr/bin/env bash
# Public GitHub coordinates select queries against an app-owned provider URL.
wallet_config() {
    local revision
    revision=$(gh_auth api "repos/$STATUS_REPOSITORY/commits/${WALLET_CONFIG_REF:-main}" --jq .sha 2>/dev/null) || return 1
    [[ $revision =~ ^[0-9a-f]{40}$ ]] || return 1
    gh_auth api "repos/$STATUS_REPOSITORY/contents/config/wallets.json?ref=$revision" --jq .content 2>/dev/null |
        base64 -d >"$WORK/wallet-config.json" || return 1
    printf '%s' "$revision"
}

wallet_query() {
    curl -sS --fail --max-time 45 --max-filesize 5242880 \
        -H 'Content-Type: application/json' \
        --data "$(jq -nc --argjson addresses "$1" '{_addresses:$addresses}')" \
        https://preprod.koios.rest/api/v1/address_info 2>/dev/null
}

src_wallets() {
    local revision config addresses response wallet address amount total observed
    revision=$(wallet_config) || {
        echo 'wallets: GitHub coordinates unavailable' >&2
        return 1
    }
    config="$WORK/wallet-config.json"
    jq -e '
        type == "object" and (keys|sort) == ["schema_version","wallets"]
        and .schema_version == 1 and (.wallets|type) == "array"
        and (.wallets|length) > 0 and (.wallets|length) <= 20
        and ([.wallets[].id]|unique|length) == (.wallets|length)
        and all(.wallets[];
            type == "object" and (keys|sort) == ["addresses","id","network","role","scope_evidence"]
            and (.id|type) == "string" and (.id|test("^[a-z][a-z0-9_-]{0,39}$"))
            and (.role == "oracle" or .role == "agent" or .role == "requester")
            and .network == "preprod"
            and (.scope_evidence|type) == "string" and (.scope_evidence|length) <= 300
            and (.addresses|type) == "array" and (.addresses|length) > 0 and (.addresses|length) <= 20
            and (.addresses|unique|length) == (.addresses|length)
            and all(.addresses[]; type == "string" and test("^addr_test1[0-9a-z]{20,120}$"))
        )
    ' "$config" >/dev/null 2>&1 || {
        echo 'wallets: invalid coordinates' >&2
        return 1
    }
    addresses=$(jq -c '[.wallets[].addresses[]]|unique' "$config")
    response="$WORK/wallet-response.json"
    wallet_query "$addresses" >"$response" || {
        echo 'wallets: Koios unavailable' >&2
        return 1
    }
    jq -e --argjson wanted "$addresses" '
        type == "array" and (map(.address)|sort) == ($wanted|sort)
        and all(.[]; (.balance|type) == "string" and (.balance|test("^(0|[1-9][0-9]{0,17})$")))
    ' "$response" >/dev/null 2>&1 || {
        echo 'wallets: invalid or incomplete Koios response' >&2
        return 1
    }
    observed=$(date -u +%FT%TZ)
    : >"$WORK/wallet-balances.jsonl"
    while IFS= read -r wallet; do
        total=0
        while IFS= read -r address; do
            amount=$(jq -r --arg address "$address" '.[]|select(.address==$address)|.balance' "$response")
            # Each amount is at most 18 digits; check the signed sum before adding.
            if ((amount > 9223372036854775807 - total)); then
                echo 'wallets: balance exceeds supported integer range' >&2
                return 1
            fi
            total=$((total + amount))
        done < <(jq -r '.addresses[]' <<<"$wallet")
        jq -c --arg total "$total" --arg observed "$observed" '
            {id,role,network,addresses,balance_lovelace:$total,observed_at:$observed}
        ' <<<"$wallet" >>"$WORK/wallet-balances.jsonl"
    done < <(jq -c '.wallets[]' "$config")
    jq -s --arg revision "$revision" --arg observed "$observed" '
        {config_revision:$revision,provider:"Koios",network:"preprod",
         reported_at:$observed,chain_point:null,history_status:"not_collected",accounts:.}
    ' "$WORK/wallet-balances.jsonl"
}
