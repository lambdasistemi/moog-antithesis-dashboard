#!/usr/bin/env bash
# One-command reproduction evidence for the status-reporter epic (#11-#13).
#
# From a clean checkout: runs every new check green once, then per check one
# break of its subject, the targeted check observed red, restore via git, and
# the check green again. One line per item (name, command, red exit, green
# exit) goes to stdout plus an artifact file. Refuses to start on a dirty
# tree, aborts loudly if any restore leaves dirt, never pushes anything.
# Docker runs only inside the flake apps it invokes. Every step bounded.
#
# Usage: reproduce.sh [--list] [--out FILE]
set -euo pipefail

TMPDIR="${TMPDIR:-/tmp}"
OUT="${REPRODUCE_OUT:-}"
LIST=0
while [[ $# -gt 0 ]]; do
    case $1 in
    --list)
        LIST=1
        shift
        ;;
    --out)
        OUT=${2:?--out needs a value}
        shift 2
        ;;
    *)
        echo "reproduce: unknown argument $1" >&2
        exit 2
        ;;
    esac
done
[[ -n $OUT ]] || OUT="$TMPDIR/reproduce-evidence.txt"

HERE=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "reproduce: not inside a git checkout" >&2
    exit 2
}
cd "$HERE"

MATRIX=(reporter-smoke push-verdict-smoke schema-reject host-stale publish-gate site-check loop-runtime container-smoke image-clean secrets-gate)

if [[ $LIST -eq 1 ]]; then
    for name in "${MATRIX[@]}"; do
        printf '%s | nix run --quiet .#%s\n' "$name" "$name"
    done
    exit 0
fi

if [[ -n $(git status --porcelain) ]]; then
    echo "reproduce: refuses to start on a dirty tree" >&2
    git status --porcelain >&2
    exit 2
fi

WORK=$(mktemp -d)
log() { printf '%s\n' "$*" | tee -a "$OUT"; }

# fail_phase ROW PHASE CODE LOGFILE: every row-phase failure leaves evidence
# on stderr AND in the artifact: row name, phase, exit code, plus the last
# 15 lines of the phase log. Single file copy: stdout goes to stderr, never
# back into the outer tee.
fail_phase() {
    {
        printf '%s | %s FAILED | exit=%s\n' "$1" "$2" "$3"
        if [[ -f $4 ]]; then
            tail -n 15 "$4"
        else
            printf '(no log file)\n'
        fi
    } | tee -a "$OUT" >&2
}

# apply_break FILE OLD NEW: exact one-spot replacement or abort loudly.
apply_break() {
    if ! python3 - "$1" "$2" "$3" <<'PY'; then
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if src.count(old) != 1:
    print("reproduce: break anchor not unique/found in %s" % path, file=sys.stderr)
    sys.exit(2)
open(path, 'w').write(src.replace(old, new))
PY
        fail_phase "${ROW:-?}" "break-apply($1)" 2 "$WORK/no-log"
        return 1
    fi
}

# append_break FILE TEXT: append lines or abort loudly.
append_break() {
    printf '%s\n' "$2" >>"$1" || {
        fail_phase "${ROW:-?}" "break-append($1)" 2 "$WORK/no-log"
        return 1
    }
}

restore_files() {
    git checkout -- "$@"
    if [[ -n $(git status --porcelain) ]]; then
        git status --porcelain >"$WORK/restore-dirt.log"
        fail_phase "${ROW:-?}" "restore($*)" 2 "$WORK/restore-dirt.log"
        echo "reproduce: ABORT — restore left dirt:" >&2
        git status --porcelain >&2
        exit 2
    fi
}

green_check() {
    local code=0 phase=${3:-green}
    timeout "$2" nix run --quiet ".#$1" >"$WORK/$1.green.log" 2>&1 || code=$?
    if [[ $code -ne 0 ]]; then
        fail_phase "$ROW" "$phase($1)" "$code" "$WORK/$1.green.log"
        return 1
    fi
}

red_check() {
    local code=0
    timeout "$2" nix run --quiet ".#$1" >"$WORK/$1.red.log" 2>&1 || code=$?
    if [[ $code -eq 0 ]]; then
        echo "expected exit 0, wanted red" >"$WORK/$1.red.log"
        fail_phase "$ROW" "red($1)" "$code" "$WORK/$1.red.log"
        echo "reproduce: expected red for $1, got exit 0" >&2
        return 1
    fi
    if ! grep -qF "$3" "$WORK/$1.red.log"; then
        fail_phase "$ROW" "red($1)" "$code" "$WORK/$1.red.log"
        echo "reproduce: red for $1 missed marker: $3" >&2
        return 1
    fi
    printf '%d' "$code"
}

row_reporter_smoke() {
    ROW=reporter-smoke
    green_check reporter-smoke 1500 || return 1
    apply_break reporter/report.sh '    while ((pos + 16 <= len)); do' '    while false; do' || return 1
    red=$(red_check reporter-smoke 1500 'agent dry-run counts wrong') || {
        restore_files reporter/report.sh
        return 1
    }
    restore_files reporter/report.sh || return 1
    green_check reporter-smoke 1500 restore-green || return 1
    log "reporter-smoke | nix run --quiet .#reporter-smoke | green-exit=0 | break=multiplex-loop-disabled red-exit=$red red='agent dry-run counts wrong' | restore=git-checkout-clean | green-exit=0"
}

row_push_verdict_smoke() {
    ROW=push-verdict-smoke
    green_check push-verdict-smoke 1200 || return 1
    apply_break reporter/push-verdict.sh "stripped=\$(printf '%s' \"\$line\" | sed 's/https\\?:[^ ]*//g')" "stripped=\$(printf '%s' \"\$line\" | sed 's/https\\?:NEVERMATCH-f43d[^ ]*//g')" || return 1
    red=$(red_check push-verdict-smoke 1200 'OK dry-run URL not stripped') || {
        restore_files reporter/push-verdict.sh
        return 1
    }
    restore_files reporter/push-verdict.sh || return 1
    green_check push-verdict-smoke 1200 restore-green || return 1
    log "push-verdict-smoke | nix run --quiet .#push-verdict-smoke | green-exit=0 | break=url-strip-noop red-exit=$red red='OK dry-run URL not stripped' | restore=git-checkout-clean | green-exit=0"
}

row_schema_reject() {
    ROW=schema-reject
    green_check schema-reject 600 || return 1
    apply_break collect/collect.sh '            or (.ok | type) != "boolean" or .ok != (.verdict | startswith("OK"))' '' || return 1
    red=$(red_check schema-reject 600 'monitor-ok-mismatch monitor accepted') || {
        restore_files collect/collect.sh
        return 1
    }
    restore_files collect/collect.sh || return 1
    green_check schema-reject 600 restore-green || return 1
    log "schema-reject | nix run --quiet .#schema-reject | green-exit=0 | break=ok-consistency-removed red-exit=$red red='monitor-ok-mismatch monitor accepted' | restore=git-checkout-clean | green-exit=0"
}

row_host_stale() {
    ROW=host-stale
    green_check host-stale 600 || return 1
    # shellcheck disable=SC2016
    apply_break collect/collect.sh '    if [[ $rep_epoch -lt $((now_epoch - 900)) ]]; then
        echo "$source status: stale payload" >&2
        return 1
    fi
' '' || return 1
    red=$(red_check host-stale 600 'stopped fixture not stale') || {
        restore_files collect/collect.sh
        return 1
    }
    restore_files collect/collect.sh || return 1
    green_check host-stale 600 restore-green || return 1
    log "host-stale | nix run --quiet .#host-stale | green-exit=0 | break=freshness-block-removed red-exit=$red red='stopped fixture not stale' | restore=git-checkout-clean | green-exit=0"
}

row_publish_gate() {
    ROW=publish-gate
    green_check publish-gate 600 || return 1
    apply_break deploy/publish.sh "if grep -rqE 'https?://' \"\$STAGE/status\"; then" "if grep -rqE 'https?://unmatched-sentinel-f43d' \"\$STAGE/status\"; then" || return 1
    red=$(red_check publish-gate 600 'let monitor URL through') || {
        restore_files deploy/publish.sh
        return 1
    }
    restore_files deploy/publish.sh || return 1
    green_check publish-gate 600 restore-green || return 1
    log "publish-gate | nix run --quiet .#publish-gate | green-exit=0 | break=url-gate-neutered red-exit=$red red='let monitor URL through' | restore=git-checkout-clean | green-exit=0"
}

row_site_check() {
    ROW=site-check
    green_check site-check 300 || return 1
    apply_break nix/checks.nix "indexOf('stale') < 0" "indexOf('stale') >= 0" || return 1
    red=$(red_check site-check 300 'not marked stale') || {
        restore_files nix/checks.nix
        return 1
    }
    restore_files nix/checks.nix || return 1
    green_check site-check 300 restore-green || return 1
    log "site-check | nix run --quiet .#site-check | green-exit=0 | break=render-assertion-inverted red-exit=$red red='not marked stale' | restore=git-checkout-clean | green-exit=0"
}

row_loop_runtime() {
    ROW=loop-runtime
    green_check loop-runtime 300 || return 1
    apply_break deploy/loop.sh 'cycle failed at' 'cycle borked at' || return 1
    red=$(red_check loop-runtime 300 'want one failure line') || {
        restore_files deploy/loop.sh
        return 1
    }
    restore_files deploy/loop.sh || return 1
    green_check loop-runtime 300 restore-green || return 1
    log "loop-runtime | nix run --quiet .#loop-runtime | green-exit=0 | break=failure-line-renamed red-exit=$red red='want one failure line' | restore=git-checkout-clean | green-exit=0"
}

row_container_smoke() {
    ROW=container-smoke
    green_check container-smoke 1500 || return 1
    apply_break deploy/cycle.sh 'set -euo pipefail' 'set -euo pipefail
exit 3' || return 1
    red=$(red_check container-smoke 1500 'clean cycle published nothing') || {
        restore_files deploy/cycle.sh
        return 1
    }
    restore_files deploy/cycle.sh || return 1
    green_check container-smoke 1500 restore-green || return 1
    log "container-smoke | nix run --quiet .#container-smoke | green-exit=0 | break=cycle-exits-3 red-exit=$red red='clean cycle published nothing' | restore=git-checkout-clean | green-exit=0"
}

row_image_clean() {
    ROW=image-clean
    green_check image-clean 900 || return 1
    append_break Dockerfile 'ENV GH_TOKEN=fake-break-f43d' || return 1
    red=$(red_check image-clean 900 'credential-shaped variable') || {
        restore_files Dockerfile
        return 1
    }
    restore_files Dockerfile || return 1
    green_check image-clean 900 restore-green || return 1
    log "image-clean | nix run --quiet .#image-clean | green-exit=0 | break=token-env-baked red-exit=$red red='credential-shaped variable' | restore=git-checkout-clean | green-exit=0"
}

row_secrets_gate() {
    ROW=secrets-gate
    green_check secrets-gate 300 || return 1
    append_break README.md 'password fake-break-f43d' || return 1
    red=$(red_check secrets-gate 300 'match found') || {
        restore_files README.md
        return 1
    }
    restore_files README.md || return 1
    green_check secrets-gate 300 restore-green || return 1
    log "secrets-gate | nix run --quiet .#secrets-gate | green-exit=0 | break=password-planted-in-readme red-exit=$red red='match found' | restore=git-checkout-clean | green-exit=0"
}

{
    printf '# reproduce evidence %s base=%s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)"
    fail=0
    for name in "${MATRIX[@]}"; do
        fn="row_${name//-/_}"
        "$fn" || fail=1
    done
    leftovers=$(timeout 20 docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'reporter-smoke-|push-verdict-smoke-|^smoke-' || true)
    leftovers_vol=$(timeout 20 docker volume ls --format '{{.Name}}' 2>/dev/null | grep -iE 'reporter-smoke-|push-verdict-smoke-|^smoke-' || true)
    if [[ -n $leftovers || -n $leftovers_vol ]]; then
        printf 'leftover containers/volumes:\n%s\n%s\n' "$leftovers" "$leftovers_vol" >&2
        fail=1
    else
        printf '# no leftover smoke containers or volumes\n'
    fi
    if [[ -n $(git status --porcelain) ]]; then
        printf 'ABORT: tree dirty at end\n' >&2
        git status --porcelain >&2
        fail=1
    else
        printf '# tree clean at end\n'
    fi
    exit "$fail"
} | tee "$OUT"
