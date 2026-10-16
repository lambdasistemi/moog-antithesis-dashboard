#!/usr/bin/env bash
# Disposable stand-in for gh, docker and curl, driven by the files in
# $FIXTURE. Run by a stub named for each tool (FAKE_TOOL); it records every call and
# answers from fixture state, applying a rollout the way Compose would.
# A file $FIXTURE/fail/NAME makes the lookup NAME fail, so discovery errors
# are executed, not imagined.
set -euo pipefail
tool=${FAKE_TOOL:?}
printf '%s %s\n' "$tool" "$*" >>"$FIXTURE/calls.log"

# A failure file containing "once" fails a single lookup, then clears.
fails() {
    [[ -e "$FIXTURE/fail/$1" ]] || return 1
    if [[ $(cat "$FIXTURE/fail/$1") == once ]]; then rm "$FIXTURE/fail/$1"; fi
    return 0
}
image_of_override() {
    sed -n 's/^ *image: *//p' "$FIXTURE/stack/deployed-image.yaml" | head -1
}
# A reference by digest, or by image id, names a digest directly.
digest_of() {
    sed -n -e 's/.*@\(sha256:[0-9a-f]*\).*/\1/p' -e 's/^sha256:image-\([0-9a-f]*\)$/sha256:\1/p' <<<"$1" | head -1
}
# What an image reference resolves to now: a digest pin or an id is itself;
# a moved tag resolves through $FIXTURE/tags.
digest_now() {
    local ref=$1 digest
    digest=$(digest_of "$ref")
    if [[ -n $digest ]]; then
        printf '%s\n' "$digest"
    elif [[ -f "$FIXTURE/tags/${ref##*:}" ]]; then
        cat "$FIXTURE/tags/${ref##*:}"
    else
        cat "$FIXTURE/registry/${ref##*:}"
    fi
}
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
        ! fails image-inspect || exit 1
        if [[ $ref == *unrelated* ]]; then
            printf '["docker.io/library/alpine:latest"] []\n'
            exit 0
        fi
        digest=$(digest_now "$ref")
        id="sha256:image-${digest#sha256:}"
        # Images are known by the repository they came from, except the
        # unrelated one used as a control.
        repo=${ref%%[:@]*}
        [[ $repo != sha256 ]] || repo=ghcr.io/lambdasistemi/moog-antithesis-dashboard
        [[ $id != *unrelated* ]] || repo=docker.io/library/alpine
        case $4 in
        "{{.Id}}") printf '%s\n' "$id" ;;
        "{{.Id}} {{json .RepoDigests}}") printf '%s ["%s@%s"]\n' "$id" "$repo" "$digest" ;;
        *) printf '["%s:tag"] ["%s@%s"]\n' "$repo" "$repo" "$digest" ;;
        esac
        ;;
    compose) compose_cmd "${@:2}" ;;
    inspect)
        ! fails inspect || exit 1
        if [[ $3 == *Config.Image* ]]; then
            grep -F "$4" "$FIXTURE/containers" | head -1
        else
            cat "$FIXTURE/container"
        fi
        ;;
    logs)
        ! fails logs || exit 1
        cat "$FIXTURE/container.log"
        ;;
    ps)
        ! fails ps || exit 1
        cut -f1 "$FIXTURE/containers"
        ;;
    run) docker_run "$@" ;;
    *) exit 1 ;;
    esac
}

# run ... --entrypoint CMD IMAGE ARG...: read-only questions about an image.
docker_run() {
    local args=("$@") i cmd image rest
    for ((i = 0; i < ${#args[@]}; i++)); do
        [[ ${args[i]} == --entrypoint ]] && break
    done
    cmd=${args[i + 1]}
    image=${args[i + 2]}
    rest=("${args[@]:i+3}")
    digest=$(digest_of "$image")
    site="$FIXTURE/images/$digest/site"
    case $cmd in
    /bin/ls) ls "$site" ;;
    /bin/cat) cat "$site/${rest[0]##*/}" ;;
    /bin/sha256sum)
        ! fails sha256sum || exit 1
        for path in "${rest[@]}"; do
            printf '%s  %s\n' "$(sha256sum "$site/${path##*/}" | cut -d' ' -f1)" "$path"
        done
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
        ! fails compose-ps || exit 1
        if [[ -f "$FIXTURE/container" ]]; then echo collector-container; fi
        ;;
    up)
        ! fails compose-up || exit 1
        rollout
        # A deployment that dies right after Compose applied the rollout.
        if [[ -f "$FIXTURE/die-after-up" ]]; then
            rm "$FIXTURE/die-after-up"
            kill -KILL "$PPID"
        fi
        ;;
    *) exit 1 ;;
    esac
}

# What Compose does on `up -d`: the pinned image becomes the one container
# with a fresh log, and a healthy image completes a cycle that publishes
# snapshot and page.
rollout() {
    ref=$(image_of_override)
    digest=$(digest_now "$ref")
    id="sha256:image-${digest#sha256:}"
    : >"$FIXTURE/container.log"
    if [[ $(behavior "$digest" startup) == crash ]]; then
        printf '%s exited 1\n' "$id" >"$FIXTURE/container"
        return 0
    fi
    printf '%s running 0\n' "$id" >"$FIXTURE/container"
    case $(behavior "$digest" cycle) in
    fail)
        echo 'cycle failed at 2026-10-15T00:00:00Z , continuing' >>"$FIXTURE/container.log"
        return 0
        ;;
    stale) return 0 ;;
    esac
    generated=$(now)
    [[ $(behavior "$digest" cycle) != badtime ]] || generated=not-a-time
    sed "s/@GENERATED@/$generated/" "$FIXTURE/images/$digest/snapshot.json" >"$FIXTURE/snapshot.json"
    [[ $(behavior "$digest" cycle) != invalid ]] || sed -i '/"tenant"/d' "$FIXTURE/snapshot.json"
    [[ $(behavior "$digest" cycle) == unpublished ]] || echo "published $generated" >>"$FIXTURE/container.log"
    case $(behavior "$digest" pages) in
    ok)
        cp "$FIXTURE/images/$digest/site/"* "$FIXTURE/public/"
        cp "$FIXTURE/snapshot.json" "$FIXTURE/public/data.json"
        ;;
    partial)
        cp "$FIXTURE/images/$digest/site/index.html" "$FIXTURE/public/"
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
