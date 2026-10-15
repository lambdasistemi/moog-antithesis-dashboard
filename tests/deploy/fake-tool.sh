#!/usr/bin/env bash
# Disposable stand-in for gh, docker and curl, driven by the files in
# $FIXTURE. Run by a stub named for each tool (FAKE_TOOL); it records every call and
# answers from fixture state, applying a rollout the way Compose would.
set -euo pipefail
tool=${FAKE_TOOL:?}
printf '%s %s\n' "$tool" "$*" >>"$FIXTURE/calls.log"

image_of_override() {
    sed -n 's/^ *image: *//p' "$FIXTURE/stack/deployed-image.yaml" | head -1
}
digest_of() { sed -n 's/.*@\(sha256:[0-9a-f]*\).*/\1/p' <<<"$1"; }
behavior() { sed -n "s/^$2=//p" "$FIXTURE/images/$1/behavior" | head -1; }
now() { date -u +%FT%TZ; }

gh_api() {
    [[ ${GH_TOKEN:-} == "$(cat "$FIXTURE/token")" ]] || exit 1
    path=$1
    case $path in
    */branches/*)
        head=$(head -1 "$FIXTURE/heads")
        [[ $(wc -l <"$FIXTURE/heads") -le 1 ]] || sed -i 1d "$FIXTURE/heads"
        printf '{"commit":{"sha":"%s"}}\n' "$head"
        ;;
    */workflows/*/runs*) cat "$FIXTURE/runs.json" ;;
    */actions/runs/*/jobs*) cat "$FIXTURE/jobs.json" ;;
    */contents/data.json*) cat "$FIXTURE/snapshot.json" ;;
    */pages/builds/latest) cat "$FIXTURE/pages-build.json" ;;
    *) exit 1 ;;
    esac
}

docker_cmd() {
    case $1 in
    pull)
        tag=${*: -1}
        [[ -f "$FIXTURE/registry/${tag##*:}" ]] || exit 1
        ;;
    image)
        # image inspect --format FORMAT REF
        ref=${*: -1}
        digest=$(digest_of "$ref")
        [[ -n $digest ]] || digest=$(cat "$FIXTURE/registry/${ref##*:}")
        id="sha256:image-${digest#sha256:}"
        if [[ $4 == "{{.Id}}" ]]; then
            printf '%s\n' "$id"
        else
            printf '%s ["%s@%s"]\n' "$id" "${ref%%[:@]*}" "$digest"
        fi
        ;;
    compose) compose_cmd "${@:2}" ;;
    inspect)
        cat "$FIXTURE/container"
        ;;
    logs)
        if [[ $(behavior "sha256:$(cut -d' ' -f1 "$FIXTURE/container" | sed 's/^sha256:image-//')" cycle) == fail ]]; then
            echo 'cycle failed at 2026-10-15T00:00:00Z , continuing' >&2
        fi
        ;;
    ps) cat "$FIXTURE/containers" ;;
    run)
        # run ... --entrypoint CMD IMAGE ARG
        image=${*: -2:1}
        arg=${*: -1}
        digest=$(digest_of "$image")
        if [[ $arg == /app/site ]]; then
            ls "$FIXTURE/images/$digest/site"
        else
            printf '%s  %s\n' "$(sha256sum "$FIXTURE/images/$digest/site/${arg##*/}" | cut -d' ' -f1)" "$arg"
        fi
        ;;
    *) exit 1 ;;
    esac
}

compose_cmd() {
    args=("$@")
    sub=
    for ((i = 0; i < ${#args[@]}; i++)); do
        case ${args[i]} in
        config | ps | up | down) sub=${args[i]} && break ;;
        esac
    done
    case $sub in
    config) [[ ! -f "$FIXTURE/invalid-config" ]] ;;
    ps)
        if [[ -f "$FIXTURE/container" ]]; then echo collector-container; fi
        ;;
    up) rollout ;;
    *) exit 1 ;;
    esac
}

# What Compose does on `up -d`: the pinned image becomes the one container,
# and a healthy image completes a cycle that publishes snapshot and page.
rollout() {
    ref=$(image_of_override)
    digest=$(digest_of "$ref")
    id="sha256:image-${digest#sha256:}"
    if [[ $(behavior "$digest" startup) == crash ]]; then
        printf '%s exited 1\n' "$id" >"$FIXTURE/container"
        return 0
    fi
    printf '%s running 0\n' "$id" >"$FIXTURE/container"
    [[ $(behavior "$digest" cycle) == ok ]] || return 0
    sed "s/@GENERATED@/$(now)/" "$FIXTURE/images/$digest/snapshot.json" >"$FIXTURE/snapshot.json"
    case $(behavior "$digest" pages) in
    ok)
        cp "$FIXTURE/images/$digest/site/"* "$FIXTURE/public/"
        cp "$FIXTURE/snapshot.json" "$FIXTURE/public/data.json"
        ;;
    failed) printf '{"status":"errored","updated_at":"%s"}\n' "$(now)" >"$FIXTURE/pages-build.json" ;;
    *) printf '{"status":"building","updated_at":"%s"}\n' "$(now)" >"$FIXTURE/pages-build.json" ;;
    esac
}

curl_cmd() {
    out=
    url=
    while (($#)); do
        case $1 in
        -o)
            out=$2
            shift
            ;;
        http*) url=$1 ;;
        esac
        shift
    done
    name=${url##*/}
    [[ -f "$FIXTURE/public/$name" ]] || exit 22
    cp "$FIXTURE/public/$name" "$out"
}

case $tool in
gh) gh_api "${@:2}" ;;
docker) docker_cmd "$@" ;;
curl) curl_cmd "$@" ;;
*) exit 1 ;;
esac
