{ pkgs, src }:
let
  scripts = {
    shellcheck = {
      runtimeInputs = [ pkgs.shellcheck ];
      text = ''
        shellcheck collect/collect.sh deploy/cycle.sh deploy/publish.sh deploy/loop.sh reporter/report.sh reporter/loop.sh
      '';
    };

    format-check = {
      runtimeInputs = [ pkgs.shfmt ];
      text = ''
        shfmt -i 4 -d collect/collect.sh deploy/cycle.sh deploy/publish.sh deploy/loop.sh reporter/report.sh reporter/loop.sh
      '';
    };

    syntax = {
      runtimeInputs = [ pkgs.bash ];
      text = ''
        bash -n collect/collect.sh
        bash -n deploy/cycle.sh
        bash -n deploy/publish.sh
        bash -n deploy/loop.sh
        bash -n reporter/report.sh
        bash -n reporter/loop.sh
        echo "syntax ok"
      '';
    };

    secrets-gate = {
      runtimeInputs = [ pkgs.ripgrep pkgs.coreutils ];
      text = ''
        # Mirror deploy/publish.sh: the published artifact is site/ plus the
        # collected data. CI has no data.json, so gate the static artifact.
        # Gate definitions in deploy/ and nix/ legitimately name these
        # patterns, so they are out of scope here.
        if rg -n 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' site preview-sample README.md justfile flake.nix compose.yaml; then
          echo "secrets gate: match found" >&2
          exit 1
        fi
        echo "secrets gate ok"
      '';
    };

    publish-gate = {
      runtimeInputs = [ pkgs.bash pkgs.git pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
      text = ''
        # Behavioural test of deploy/publish.sh against a local bare remote.
        # Every mounted secret must refuse the whole publication from each
        # staged location, without pushing; a clean tree (even with blank
        # lines and short values in the secret inputs) must publish.
        set -euo pipefail
        fixture="$TMPDIR/publish-fixture"
        remote="$TMPDIR/publish-remote.git"
        rm -rf "$fixture" "$remote"
        mkdir -p "$fixture/runs" "$fixture/status"
        git init -q --bare "$remote"
        key_value='fixture-antithesis-key-K1x'
        push_value='fixture-push-token-P1x'
        moog_value='fixture-moog-value-M1x'
        moog_qd='fixture-moog-quoted-D1x'
        moog_qs='fixture-moog-quoted-S1x'
        printf '%s' "$key_value" >"$TMPDIR/fixture.key"
        mkdir -p "$TMPDIR/fixture.secrets"
        printf '%s' "$push_value" >"$TMPDIR/fixture.secrets/pages-push"
        printf '\n\nqq7x\n\n' >"$TMPDIR/fixture.secrets/extra"
        printf 'PROVIDER_URL=https://moog-read-fixture.invalid/unit\nEMPTY=\nSHORT=ab\nREAD_NAME=%s\n' \
          "$moog_value" >"$TMPDIR/fixture.moogenv"
        printf '%s\n' "QUOTED_DQ=\"$moog_qd\"" >>"$TMPDIR/fixture.moogenv"
        printf '%s\n' "export QUOTED_SQ='$moog_qs'" >>"$TMPDIR/fixture.moogenv"
        export DASHBOARD_OUT="$fixture" DASHBOARD_REMOTE="$remote" \
          ANTITHESIS_API_KEY_FILE="$TMPDIR/fixture.key" \
          PAGES_PUSH_TOKEN_FILE="$TMPDIR/fixture.secrets/pages-push" \
          MOOG_READ_ENV_FILE="$TMPDIR/fixture.moogenv" \
          DASHBOARD_SECRETS_DIR="$TMPDIR/fixture.secrets"
        write_clean() {
          printf '{"generated_at":"2026-01-01T00:00:00Z","runs":[],"note":"crab sample"}' \
            >"$fixture/data.json"
          printf '{"run_id":"probe","status":"completed","properties":[]}' \
            >"$fixture/runs/probe.json"
          printf '{"reporter":"probe","verdict":"ok"}' \
            >"$fixture/status/probe.json"
          rm -f "$fixture/runs/case.json" "$fixture/runs/evil.json" "$fixture/status/case.json"
        }
        pushed_ref() {
          git --git-dir="$remote" rev-parse gh-pages 2>/dev/null || echo none
        }
        try_refuse() {
          write_clean
          printf '%s' "$2" >>"$fixture/$3"
          ref_before=$(pushed_ref)
          if bash deploy/publish.sh; then
            echo "publish gate let $1 through ($3)" >&2
            exit 1
          else
            code=$?
            if [[ $code -ne 2 ]]; then
              echo "publish gate exit $code, want 2 ($1 in $3)" >&2
              exit 1
            fi
          fi
          if [[ $(pushed_ref) != "$ref_before" ]]; then
            echo "publish gate pushed $1 ($3)" >&2
            exit 1
          fi
        }
        try_refuse 'planted push-token literal' "$push_value" data.json
        try_refuse 'planted push-token literal' "$push_value" runs/case.json
        try_refuse 'planted push-token literal' "$push_value" status/case.json
        try_refuse 'planted moog-env value' "$moog_value" data.json
        try_refuse 'planted moog-env value' "$moog_value" runs/case.json
        try_refuse 'planted moog-env value' "$moog_value" status/case.json
        try_refuse 'planted double-quoted moog-env value' "$moog_qd" data.json
        try_refuse 'planted single-quoted moog-env value' "$moog_qs" data.json
        try_refuse 'planted key literal' "$key_value" data.json
        try_refuse 'planted key literal' "$key_value" runs/case.json
        try_refuse 'planted key literal' "$key_value" status/case.json
        try_refuse 'planted report link' \
          'https://x.antithesis.com/report/a.html?auth=v2.public_probe' runs/evil.json
        write_clean
        bash deploy/publish.sh
        git --git-dir="$remote" show gh-pages:data.json | grep -q generated_at
        git --git-dir="$remote" show gh-pages:runs/probe.json | grep -q probe
        git --git-dir="$remote" show gh-pages:status/probe.json | grep -q probe
        ref_before=$(pushed_ref)
        if PAGES_PUSH_TOKEN_FILE="$TMPDIR/fixture.missing" bash deploy/publish.sh; then
          echo "publish gate pushed without a token file" >&2
          exit 1
        fi
        if [[ $(pushed_ref) != "$ref_before" ]]; then
          echo "publish gate pushed without a token file" >&2
          exit 1
        fi
        # Dry run: same staging and full gate, commit locally, no push,
        # no token needed. A clean tree prints the file count and list;
        # a planted secret still refuses with exit 2 and never pushes.
        write_clean
        ref_before=$(pushed_ref)
        dry_out=$(DASHBOARD_DRY_RUN=1 PAGES_PUSH_TOKEN_FILE="$TMPDIR/fixture.missing" bash deploy/publish.sh)
        echo "$dry_out" | grep -q '^dry run: would publish .* files, generated_at '
        echo "$dry_out" | grep -q data.json
        echo "$dry_out" | grep -q runs/probe.json
        if [[ $(pushed_ref) != "$ref_before" ]]; then
          echo "publish gate dry run pushed" >&2
          exit 1
        fi
        write_clean
        printf '%s' "$push_value" >>"$fixture/data.json"
        ref_before=$(pushed_ref)
        if DASHBOARD_DRY_RUN=1 PAGES_PUSH_TOKEN_FILE="$TMPDIR/fixture.missing" bash deploy/publish.sh; then
          echo "publish gate dry run let planted secret through" >&2
          exit 1
        else
          code=$?
          if [[ $code -ne 2 ]]; then
            echo "publish gate dry run exit $code, want 2" >&2
            exit 1
          fi
        fi
        if [[ $(pushed_ref) != "$ref_before" ]]; then
          echo "publish gate dry run pushed a secret" >&2
          exit 1
        fi
        echo "publish gate ok"
      '';
    };

    image-clean = {
      runtimeInputs = [ pkgs.docker pkgs.gnutar pkgs.gnugrep pkgs.coreutils pkgs.bash ];
      text = ''
        # Both images must carry no secret: build each, export its
        # filesystem and grep for key/token/bearer shapes, then check that a
        # dry run exposes no credential-shaped variable. Only match counts
        # and file paths are reported, never matched values.
        #
        # Scoping, measured 2026-10-07 against the pinned base plus our
        # packages: `v2.public`, `github_pat_` and the canary occur nowhere
        # benign, so they are scanned across the whole exported filesystem.
        # `Bearer `, `auth=` and `ghp_` occur in tool help text and binaries
        # (curl, gh, libcurl) outside our control, so they are scanned only
        # under /app -- the sole paths we add -- where every occurrence must
        # be a gate definition (mirroring the secrets-gate scope).
        #
        # The ARG/ENV ban lives in the image-source-shape check, not here.
        set -euo pipefail
        canary="''${IMAGE_CLEAN_CANARY:-}"
        check_one() {
          local tag=$1 dockerfile=$2
          local cid work fail leak_paths canary_paths app_files env_out env_hits
          if [[ "$dockerfile" == "Dockerfile" ]]; then
            docker build -q -t "$tag" .
          else
            docker build -q -f "$dockerfile" -t "$tag" .
          fi
          cid=$(docker create "$tag")
          work=$(mktemp -d)
          fail=0
          docker export "$cid" | tar -x -C "$work"
          leak_paths=$(grep -a -r -l -E -e 'v2\.public' -e 'github_pat_' "$work" || true)
          if [[ -n "$leak_paths" ]]; then
            echo "image-clean ($tag): key-shaped strings in these image paths:" >&2
            printf '%s\n' "$leak_paths" >&2
            fail=1
          fi
          if [[ -n "$canary" ]]; then
            canary_paths=$(grep -a -r -l -F -e "$canary" "$work" || true)
            if [[ -n "$canary_paths" ]]; then
              echo "image-clean ($tag): canary found in these image paths:" >&2
              printf '%s\n' "$canary_paths" >&2
              fail=1
            fi
          fi
          app_files=$(grep -a -r -l -E -e 'Bearer ' -e 'auth=' -e 'ghp_' "$work/app" || true)
          if [[ -n "$app_files" ]]; then
            while IFS= read -r f; do
              rest=$(grep -a -E -e 'Bearer ' -e 'auth=' -e 'ghp_' "$f" | grep -v -c -F \
                -e 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' \
                -e 'Authorization: Bearer %s' || true)
              if [[ "$rest" -ne 0 ]]; then
                echo "image-clean ($tag): unexpected key-shaped line(s) under /app in ''${f#"$work"/}" >&2
                fail=1
              fi
            done <<< "$app_files"
          fi
          env_out=$(docker run --rm "$tag" env)
          env_hits=$(printf '%s\n' "$env_out" | grep -E -c -e '^(.*_)?(KEY|TOKEN|SECRET|PASSWORD|BEARER)(_.*)?=[^[:space:]]' -e 'ghp_' -e 'github_pat_' -e 'Bearer ' -e 'v2\.public' -e 'auth=' || true)
          if [[ "$env_hits" -ne 0 ]]; then
            echo "image-clean ($tag): credential-shaped variable in 'docker run env'" >&2
            fail=1
          fi
          if [[ -n "$canary" ]] && printf '%s\n' "$env_out" | grep -q -F -e "$canary"; then
            echo "image-clean ($tag): canary found in 'docker run env'" >&2
            fail=1
          fi
          docker rm -f "$cid" >/dev/null
          rm -rf "$work"
          [[ "$fail" -eq 0 ]]
        }
        check_one "moog-collector:image-clean" "Dockerfile"
        check_one "moog-reporter:image-clean" "Dockerfile.reporter"
        echo "image clean ok"
      '';
    };

    container-smoke = {
      runtimeInputs = [ pkgs.docker pkgs.gnugrep pkgs.coreutils pkgs.bash ];
      text = ''
        # End-to-end run of the collector image under the compose
        # restrictions (uid 1000, read-only rootfs, tmpfs /tmp, cap_drop
        # ALL, named cache volume, 0400 secret files): one clean cycle must
        # publish with none of the fake secret literals in the pushed tree,
        # the logs, or the run env; a planted literal must refuse without
        # pushing. Only paths and counts are reported, never values.
        # A second build from a throwaway context copy with all group/other
        # permission bits stripped proves mode normalisation is independent
        # of the build context.
        #
        # No host bind mount anywhere: some daemons cannot see the
        # invoker's filesystem, so every fixture lives in named volumes,
        # written by helper containers of this same image (fake values are
        # generated inside the setup helper, never in host argv), and
        # results are read back the same way. The guard below fails the
        # run if a bind mount ever reappears in this script.
        set -euo pipefail
        self="$0"
        bind_start='-v "'
        bind_end='$'
        mount_start='--mount'
        mount_end=' type=bind'
        if grep -qF -e "$bind_start$bind_end" "$self" \
          || grep -qF -e "$mount_start$mount_end" "$self"; then
          echo "container-smoke: host bind mount in smoke script" >&2
          exit 1
        fi
        tag="moog-collector:container-smoke"
        docker build -q -t "$tag" .
        assert_modes() {
          local t bad
          t=$1
          bad=$(docker run --rm --user 1000:1000 "$t" find /app ! -readable -print)
          if [[ -n $bad ]]; then
            echo "smoke: not readable by uid 1000 in $t:" >&2
            printf '%s\n' "$bad" >&2
            return 1
          fi
          bad=$(docker run --rm --user 1000:1000 "$t" find /app -type d ! -executable -print)
          if [[ -n $bad ]]; then
            echo "smoke: directory not traversable by uid 1000 in $t:" >&2
            printf '%s\n' "$bad" >&2
            return 1
          fi
          bad=$(docker run --rm --user 1000:1000 "$t" \
            find /app/collect /app/deploy -name '*.sh' ! -executable -print)
          if [[ -n $bad ]]; then
            echo "smoke: scripts not executable by uid 1000 in $t:" >&2
            printf '%s\n' "$bad" >&2
            return 1
          fi
        }
        assert_modes "$tag" || exit 1
        secvol="smoke-secrets-$$-$RANDOM"
        vol="smoke-cache-$$-$RANDOM"
        remvol="smoke-remote-$$-$RANDOM"
        cyc="smoke-cycle-$$-$RANDOM"
        ctx=""
        cleanup() {
          docker rm -f "$cyc" "$cyc-plant" "$cyc-env" >/dev/null 2>&1 || true
          docker volume rm "$secvol" "$vol" "$remvol" >/dev/null 2>&1 || true
          [[ -n $ctx ]] && rm -rf "$ctx"
        }
        trap cleanup EXIT
        m_sec="--mount=type=volume,src=$secvol,dst=/s"
        m_secrets="--mount=type=volume,src=$secvol,dst=/run/secrets,readonly"
        m_cache="--mount=type=volume,src=$vol,dst=/cache"
        m_cachec="--mount=type=volume,src=$vol,dst=/c"
        m_remote="--mount=type=volume,src=$remvol,dst=/remote.git"
        m_remroot="--mount=type=volume,src=$remvol,dst=/r"
        docker run --rm --user 0:0 "$m_sec" "$m_remroot" "$m_cachec" "$tag" bash -c '
          set -euo pipefail
          r=$RANDOM$RANDOM
          printf "%s" "smoke-antithesis-$r" >/s/antithesis-key
          printf "%s" "smoke-ghread-$r" >/s/gh-read
          printf "%s" "smoke-push-$r" >/s/pages-push
          printf "PROVIDER_URL=https://moog-smoke-fixture.invalid/unit-%s\n" "$r" >/s/moog-read-env
          printf "%s\n" "smoke-antithesis-$r" "smoke-ghread-$r" "smoke-push-$r" \
            "https://moog-smoke-fixture.invalid/unit-$r" >/s/patterns
          chmod 400 /s/antithesis-key /s/gh-read /s/pages-push /s/moog-read-env /s/patterns
          chown 1000:1000 /s /s/antithesis-key /s/gh-read /s/pages-push /s/moog-read-env /s/patterns /r /c
          git init -q --bare /r
          chown -R 1000:1000 /r
        '
        mapfile -t lits < <(docker run --rm "$m_sec" "$tag" cat /s/patterns)
        lits_text=$(printf '%s\n' "''${lits[@]}")
        redact() {
          local text lit
          text=$(cat)
          while IFS= read -r lit; do
            [[ -n $lit ]] || continue
            text=''${text//"$lit"/'<fake-secret>'}
          done <<<"$lits_text"
          printf '%s\n' "$text"
        }
        base=(--user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL
          "$m_secrets" "$m_cache" "$m_remote"
          -e DASHBOARD_CACHE=/cache
          -e DASHBOARD_REMOTE=file:///remote.git
          -e DASHBOARD_MAX_CYCLES=1)
        probe_flags=(--rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL
          "$m_secrets" "$m_cache" "$m_remote")
        diag_cycle() {
          echo "smoke: $1" >&2
          code=$(docker inspect --format='{{.State.ExitCode}}' "$2" 2>/dev/null || echo unknown)
          echo "smoke: container $2 exit code: $code" >&2
          echo "smoke: last 40 lines of cycle output (fake secrets redacted):" >&2
          printf '%s\n' "$3" | tail -n 40 | redact >&2
          echo "smoke: container-side probe (id, mounts, uid):" >&2
          docker run "''${probe_flags[@]}" "$tag" bash -c 'id; ls -ld /cache /run/secrets /tmp; id -u' 2>&1 | redact >&2 || true
          docker run --rm --entrypoint ls "$tag" -l /app /app/deploy /app/collect 2>&1 | redact >&2 || true
        }
        gitr() {
          docker run --rm "$m_remroot" "$m_sec" "$tag" git --git-dir=/r "$@"
        }
        absent_from() {
          printf '%s\n' "$1" | grep -qF -e "$2" && return 1
          return 0
        }
        if out=$(docker run --name "$cyc" "''${base[@]}" "$tag" 2>&1); then
          :
        else
          diag_cycle "clean cycle failed" "$cyc" "$out"
          exit 1
        fi
        gitr show gh-pages:data.json | grep -q generated_at || {
          diag_cycle "clean cycle published nothing" "$cyc" "$out"
          exit 1
        }
        hits=$(gitr grep -F -l -f /s/patterns gh-pages -- 2>/dev/null || true)
        if [[ -n "$hits" ]]; then
          diag_cycle "secret literal published in: $hits" "$cyc" "$out"
          exit 1
        fi
        while IFS= read -r lit; do
          absent_from "$out" "$lit" || {
            diag_cycle "secret literal in cycle logs" "$cyc" "$out"
            exit 1
          }
        done <<<"$lits_text"
        env_out=$(docker run --name "$cyc-env" "''${base[@]}" "$tag" env)
        while IFS= read -r lit; do
          absent_from "$env_out" "$lit" || {
            diag_cycle "secret literal in run env" "$cyc-env" "$env_out"
            exit 1
          }
        done <<<"$lits_text"
        docker run --rm --user 0:0 "$m_sec" "$m_cachec" "$tag" bash -c '
          set -euo pipefail
          printf "{\"reporter\":\"evil\",\"note\":\"%s\"}" "$(cat /s/antithesis-key)" \
            >/c/out/runs/evil.json
          chown 1000:1000 /c/out/runs/evil.json
        '
        ref_before=$(gitr rev-parse gh-pages)
        out2=$(docker run --name "$cyc-plant" "''${base[@]}" "$tag" 2>&1)
        printf '%s\n' "$out2" | grep -q 'evil.json' || {
          diag_cycle "plant refusal names no file" "$cyc-plant" "$out2"
          exit 1
        }
        while IFS= read -r lit; do
          absent_from "$out2" "$lit" || {
            diag_cycle "secret literal in refusal logs" "$cyc-plant" "$out2"
            exit 1
          }
        done <<<"$lits_text"
        if [[ $(gitr rev-parse gh-pages) != "$ref_before" ]]; then
          diag_cycle "planted cycle pushed" "$cyc-plant" "$out2"
          exit 1
        fi
        ctx=$(mktemp -d)
        mkdir -p "$ctx/collect" "$ctx/deploy" "$ctx/site"
        cp -r collect deploy site Dockerfile "$ctx/"
        chmod -R go-rwx "$ctx"
        tag2="moog-collector:container-smoke-modes"
        docker build -q -t "$tag2" "$ctx"
        assert_modes "$tag2" || exit 1
        echo "container smoke ok"
      '';
    };

    reporter-smoke = {
      runtimeInputs = [ pkgs.docker pkgs.jq pkgs.gnugrep pkgs.coreutils pkgs.bash ];
      text = ''
        # End-to-end run of the reporter image under the compose
        # restrictions (uid 1000, read-only rootfs, tmpfs /tmp, cap_drop
        # ALL): the dry run must print exactly the schema (role, filtered
        # moog containers with registry prefixes dropped, reported_at) and
        # make no outward request; a real run against a fake GitHub endpoint
        # must send the body with the token only in the Authorization header
        # read from the file, never in the process list or logs. Only paths
        # and counts are reported, never token values. A second build from a
        # throwaway context copy with all group/other permission bits
        # stripped proves mode normalisation is independent of the build
        # context.
        #
        # No host bind mount anywhere: some daemons cannot see the
        # invoker's filesystem, so the fake Docker API (unix socket) and the
        # fake GitHub endpoint both live in helper containers, fixtures in
        # named volumes, and results are read back the same way. The guard
        # below fails the run if a bind mount ever reappears in this script.
        # Every docker step is bounded with timeout (30s) and every fake has
        # a readiness probe; nothing waits forever.
        set -euo pipefail
        self="$0"
        bind_start='-v "'
        bind_end='$'
        mount_start='--mount'
        mount_end=' type=bind'
        if grep -qF -e "$bind_start$bind_end" "$self" \
          || grep -qF -e "$mount_start$mount_end" "$self"; then
          echo "reporter-smoke: host bind mount in smoke script" >&2
          exit 1
        fi
        tag="moog-reporter:reporter-smoke"
        timeout 120 docker build -q -f Dockerfile.reporter -t "$tag" . >/dev/null \
          || { echo "reporter-smoke: build timed out or failed" >&2; exit 1; }
        assert_modes() {
          local t bad
          t=$1
          bad=$(timeout 30 docker run --rm --user 1000:1000 "$t" find /app ! -readable -print) \
            || { echo "reporter-smoke: find timed out ($t)" >&2; return 1; }
          if [[ -n $bad ]]; then
            echo "reporter-smoke: not readable by uid 1000 in $t:" >&2
            printf '%s\n' "$bad" >&2
            return 1
          fi
          bad=$(timeout 30 docker run --rm --user 1000:1000 "$t" find /app -type d ! -executable -print) \
            || { echo "reporter-smoke: find timed out ($t)" >&2; return 1; }
          if [[ -n $bad ]]; then
            echo "reporter-smoke: directory not traversable by uid 1000 in $t:" >&2
            printf '%s\n' "$bad" >&2
            return 1
          fi
          bad=$(timeout 30 docker run --rm --user 1000:1000 "$t" \
            find /app/reporter -name '*.sh' ! -executable -print) \
            || { echo "reporter-smoke: find timed out ($t)" >&2; return 1; }
          if [[ -n $bad ]]; then
            echo "reporter-smoke: scripts not executable by uid 1000 in $t:" >&2
            printf '%s\n' "$bad" >&2
            return 1
          fi
        }
        assert_modes "$tag" || exit 1
        sockvol="reporter-smoke-sock-$$-$RANDOM"
        secvol="reporter-smoke-sec-$$-$RANDOM"
        recvol="reporter-smoke-rec-$$-$RANDOM"
        net="reporter-smoke-net-$$-$RANDOM"
        dock="reporter-smoke-dock-$$-$RANDOM"
        gh="reporter-smoke-gh-$$-$RANDOM"
        rname="reporter-smoke-rep-$$-$RANDOM"
        ctx=""
        cleanup() {
          timeout 20 docker rm -f "$dock" "$gh" "$rname" >/dev/null 2>&1 || true
          timeout 20 docker volume rm "$sockvol" "$secvol" "$recvol" >/dev/null 2>&1 || true
          timeout 20 docker network rm "$net" >/dev/null 2>&1 || true
          [[ -n $ctx ]] && rm -rf "$ctx"
        }
        trap cleanup EXIT
        m_sock="--mount=type=volume,src=$sockvol,dst=/sock"
        m_sec="--mount=type=volume,src=$secvol,dst=/s"
        m_secrets="--mount=type=volume,src=$secvol,dst=/run/secrets,readonly"
        timeout 30 docker volume create "$sockvol" >/dev/null \
          || { echo "reporter-smoke: sock volume" >&2; exit 1; }
        timeout 30 docker volume create "$secvol" >/dev/null \
          || { echo "reporter-smoke: sec volume" >&2; exit 1; }
        timeout 30 docker volume create "$recvol" >/dev/null \
          || { echo "reporter-smoke: rec volume" >&2; exit 1; }
        timeout 30 docker network create "$net" >/dev/null \
          || { echo "reporter-smoke: network" >&2; exit 1; }
        # The single-quoted helper below must keep $RANDOM expanding
        # inside the container, never in host argv.
        # shellcheck disable=SC2016
        timeout 30 docker run --rm --user 0:0 "$m_sec" "$tag" bash -c '
          # $RANDOM expands inside the helper: the token never reaches host argv.
          set -euo pipefail
          r=$RANDOM$RANDOM
          printf "%s" "smoke-reporter-$r" >/s/status-token
          printf "%s\n" "smoke-reporter-$r" >/s/pattern
          chmod 400 /s/status-token /s/pattern
          chown 1000:1000 /s /s/status-token /s/pattern
        ' || { echo "reporter-smoke: token setup" >&2; exit 1; }
        timeout 30 docker run -d --name "$dock" "$m_sock" python:3.12-slim python3 -c '
import json, os, socket
p="/sock/docker.sock"
try: os.unlink(p)
except: pass
os.makedirs("/sock", exist_ok=True)
payload=[
  {"Names": ["/oracle-moog-oracle-1"], "Image": "ghcr.io/lambdasistemi/moog-oracle:v0.5.1.5", "Status": "Up 5 days"},
  {"Names": ["/some-nginx"], "Image": "nginx:latest", "Status": "Up 2 hours"},
  {"Names": ["/agent-moog-agent-1"], "Image": "moog-agent:v0.5.1.5", "Status": "Exited (0) 1 hour ago"},
]
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
os.chmod(p, 0o777)
s.listen(5)
print("docker fake ready", flush=True)
while True:
  c,_=s.accept()
  try:
    c.recv(8192)
    b=json.dumps(payload)
    c.sendall(("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+str(len(b))+"\r\n\r\n"+b).encode())
  finally: c.close()
' >/dev/null || { echo "reporter-smoke: fake dock start" >&2; exit 1; }
        timeout 30 docker run -d --name "$gh" --network "$net" --network-alias fake-gh \
          --mount=type=volume,src="$recvol",dst=/rec python:3.12-slim python3 -c '
import json, time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
  def do_GET(self):
    r=b"ok"
    self.send_response(200)
    self.send_header("Content-Length",str(len(r)))
    self.end_headers()
    self.wfile.write(r)
  def do_PATCH(self):
    n=int(self.headers.get("Content-Length",0))
    body=self.rfile.read(n).decode()
    auth=self.headers.get("Authorization","")
    open("/rec/last.json","w").write(json.dumps({"auth":auth,"body":body,"path":self.path}))
    time.sleep(3)
    r=b"{}"
    self.send_response(200)
    self.send_header("Content-Type","application/json")
    self.send_header("Content-Length",str(len(r)))
    self.end_headers()
    self.wfile.write(r)
  def log_message(self,*a): pass
print("gh fake ready", flush=True)
HTTPServer(("0.0.0.0",8080),H).serve_forever()
' >/dev/null || { echo "reporter-smoke: fake github start" >&2; exit 1; }
        ready=0
        for _ in $(seq 1 30); do
          if timeout 10 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
              --mount=type=volume,src="$sockvol",dst=/sock \
              "$tag" curl -sS --max-time 5 --unix-socket /sock/docker.sock http://localhost/containers/json 2>/dev/null \
              | grep -q oracle-moog-oracle-1; then ready=1; break; fi
          sleep 1
        done
        [[ $ready -eq 1 ]] || { echo "reporter-smoke: fake dock never ready" >&2; exit 1; }
        ready=0
        for _ in $(seq 1 30); do
          if timeout 10 docker run --rm --network "$net" python:3.12-slim \
              python3 -c 'import urllib.request; urllib.request.urlopen("http://fake-gh:8080/", timeout=5).read()' 2>/dev/null; then
            ready=1; break; fi
          sleep 1
        done
        [[ $ready -eq 1 ]] || { echo "reporter-smoke: fake github never ready" >&2; exit 1; }
        dry_out=$(timeout 30 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
          --mount=type=volume,src="$sockvol",dst=/sock \
          -e DOCKER_SOCKET=/sock/docker.sock -e REPORTER_ROLE=oracle -e REPORT_DRY_RUN=1 \
          "$tag" /app/reporter/report.sh) || { echo "reporter-smoke: dry run" >&2; exit 1; }
        printf '%s' "$dry_out" | jq -e '.role=="oracle" and (.containers|length==2) and (.reported_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' >/dev/null \
          || { echo "reporter-smoke: dry-run payload is not exactly the schema" >&2; exit 1; }
        if printf '%s' "$dry_out" | grep -q nginx; then
          echo "reporter-smoke: dry run did not filter non-moog" >&2
          exit 1
        fi
        printf '%s' "$dry_out" \
          | jq -e '.containers[]|select(.name=="oracle-moog-oracle-1")|.image=="lambdasistemi/moog-oracle:v0.5.1.5"' >/dev/null \
          || { echo "reporter-smoke: dry run did not drop the registry prefix" >&2; exit 1; }
        if timeout 10 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
            python:3.12-slim ls /rec/last.json 2>/dev/null; then
          echo "reporter-smoke: dry run made an outward request" >&2
          exit 1
        fi
        timeout 30 docker run -d --name "$rname" --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
          --network "$net" --mount=type=volume,src="$sockvol",dst=/sock "$m_secrets" \
          -e DOCKER_SOCKET=/sock/docker.sock -e REPORTER_ROLE=oracle -e REPORT_REPOSITORY=owner/repo \
          -e STATUS_ISSUE_NUMBER=123 -e STATUS_TOKEN_FILE=/run/secrets/status-token \
          -e REPORT_API_BASE=http://fake-gh:8080 \
          "$tag" /app/reporter/report.sh >/dev/null \
          || { echo "reporter-smoke: real run start" >&2; exit 1; }
        sleep 1
        top_out=$(timeout 15 docker top "$rname" 2>/dev/null || true)
        pat=$(timeout 15 docker run --rm "$m_sec" "$tag" cat /s/pattern) \
          || { echo "reporter-smoke: read pattern" >&2; exit 1; }
        if printf '%s' "$top_out" | grep -qF "$pat"; then
          echo "reporter-smoke: token in process list" >&2
          exit 1
        fi
        timeout 30 docker wait "$rname" >/dev/null \
          || { echo "reporter-smoke: real run hung" >&2; exit 1; }
        logs=$(timeout 15 docker logs "$rname" 2>&1 || true)
        if printf '%s' "$logs" | grep -qF "$pat"; then
          echo "reporter-smoke: token in logs" >&2
          exit 1
        fi
        rec_out=$(timeout 15 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
          python:3.12-slim cat /rec/last.json) \
          || { echo "reporter-smoke: no recorded request" >&2; exit 1; }
        printf '%s' "$rec_out" | jq -e --arg p "$pat" '.auth==("Bearer "+$p)' >/dev/null \
          || { echo "reporter-smoke: token not only in header" >&2; exit 1; }
        if printf '%s' "$rec_out" | jq -r .body | grep -qF "$pat"; then
          echo "reporter-smoke: token in body" >&2
          exit 1
        fi
        printf '%s' "$rec_out" | jq -e '.path=="/repos/owner/repo/issues/123"' >/dev/null \
          || { echo "reporter-smoke: wrong issue path" >&2; exit 1; }
        printf '%s' "$rec_out" | jq -r .body | jq -r .body \
          | jq -e '.role=="oracle" and (.containers|length==2)' >/dev/null \
          || { echo "reporter-smoke: recorded body is not the payload" >&2; exit 1; }
        ctx=$(mktemp -d)
        mkdir -p "$ctx/reporter"
        cp -r reporter Dockerfile.reporter "$ctx/"
        chmod -R go-rwx "$ctx"
        tag2="moog-reporter:reporter-smoke-modes"
        timeout 120 docker build -q -f "$ctx/Dockerfile.reporter" -t "$tag2" "$ctx" >/dev/null \
          || { echo "reporter-smoke: stripped build" >&2; exit 1; }
        assert_modes "$tag2" || exit 1
        echo "reporter smoke ok"
      '';
    };

    image-publish = {
      runtimeInputs = [ pkgs.docker pkgs.coreutils pkgs.bash ];
      text = ''
        # Build the collector image tagged with the commit SHA and `main`,
        # and push both tags only when PUBLISH=1. Repository and SHA come
        # from the environment with failing defaults; the push token travels
        # via GH_TOKEN through --password-stdin, never argv or script text.
        set -euo pipefail
        repo="''${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
        sha="''${GITHUB_SHA:?GITHUB_SHA must be set}"
        sha_tag="ghcr.io/$repo:$sha"
        main_tag="ghcr.io/$repo:main"
        docker build -q -t "$sha_tag" -t "$main_tag" .
        if [[ "''${PUBLISH:-0}" == "1" ]]; then
          actor="''${GH_ACTOR:?GH_ACTOR must be set for PUBLISH=1}"
          printf '%s\n' "''${GH_TOKEN:?GH_TOKEN must be set for PUBLISH=1}" \
            | docker login ghcr.io -u "$actor" --password-stdin
          docker push "$sha_tag"
          docker push "$main_tag"
        fi
        echo "image publish ok ($sha_tag)"
      '';
    };

    reporter-publish = {
      runtimeInputs = [ pkgs.docker pkgs.coreutils pkgs.bash ];
      text = ''
        # Build the reporter image (Dockerfile.reporter) tagged with the
        # commit SHA and `main` as ghcr.io/<repo>-reporter, and push both
        # tags only when PUBLISH=1. Same shape as image-publish: repository
        # and SHA from the environment, token via --password-stdin.
        set -euo pipefail
        repo="''${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
        sha="''${GITHUB_SHA:?GITHUB_SHA must be set}"
        sha_tag="ghcr.io/$repo-reporter:$sha"
        main_tag="ghcr.io/$repo-reporter:main"
        docker build -q -f Dockerfile.reporter -t "$sha_tag" -t "$main_tag" .
        if [[ "''${PUBLISH:-0}" == "1" ]]; then
          actor="''${GH_ACTOR:?GH_ACTOR must be set for PUBLISH=1}"
          printf '%s\n' "''${GH_TOKEN:?GH_TOKEN must be set for PUBLISH=1}" \
            | docker login ghcr.io -u "$actor" --password-stdin
          docker push "$sha_tag"
          docker push "$main_tag"
        fi
        echo "reporter publish ok ($sha_tag)"
      '';
    };

    loop-runtime = {
      runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
      text = ''
        # Behavioural test of deploy/loop.sh with a stub cycle: three runs
        # with the middle one failing must all happen in order with one log
        # line for the failure, and SIGTERM during a long sleep must end the
        # loop promptly with exit 0.
        set -euo pipefail
        count="$TMPDIR/loop-count"
        events="$TMPDIR/loop-events"
        : >"$count"
        : >"$events"
        export LOOP_COUNT="$count" LOOP_EVENTS="$events"
        cat >"$TMPDIR/loop-cycle.sh" <<'EOF'
#!/bin/sh
# Quoted heredoc: nothing expands at creation; the stub reads LOOP_COUNT
# and LOOP_EVENTS from its environment at run time.
echo run >>"$LOOP_COUNT"
if [ "$(wc -l <"$LOOP_COUNT")" -eq 2 ]; then
  echo failed >>"$LOOP_EVENTS"
  exit 3
fi
echo ok >>"$LOOP_EVENTS"
exit 0
EOF
        chmod +x "$TMPDIR/loop-cycle.sh"
        log="$TMPDIR/loop.log"
        DASHBOARD_INTERVAL=0 DASHBOARD_MAX_CYCLES=3 CYCLE_CMD="$TMPDIR/loop-cycle.sh" \
          bash deploy/loop.sh >"$log" 2>&1
        [[ $(wc -l <"$count") -eq 3 ]] || {
          echo "loop ran $(wc -l <"$count"), want 3" >&2
          exit 1
        }
        [[ $(cat "$events") == $'ok\nfailed\nok' ]] || {
          echo "bad run order" >&2
          exit 1
        }
        [[ $(grep -c 'cycle failed' "$log") -eq 1 ]] || {
          echo "want one failure line" >&2
          exit 1
        }
        DASHBOARD_INTERVAL=600 DASHBOARD_MAX_CYCLES=1000000 CYCLE_CMD=true \
          bash deploy/loop.sh >"$TMPDIR/loop-term.log" 2>&1 &
        loop_pid=$!
        sleep 2
        ( sleep 30; kill -KILL "$loop_pid" 2>/dev/null ) &
        watchdog_pid=$!
        kill -TERM "$loop_pid"
        start=$SECONDS
        code=0
        wait "$loop_pid" || code=$?
        elapsed=$((SECONDS - start))
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        [[ $code -eq 0 ]] || {
          echo "loop exit $code after TERM, want 0" >&2
          exit 1
        }
        [[ $elapsed -lt 30 ]] || {
          echo "loop took ''${elapsed}s after TERM" >&2
          exit 1
        }
        echo "loop runtime ok"
      '';
    };

    site-check = {
      runtimeInputs = [ pkgs.python3 pkgs.nodejs ];
      text = ''
        js_out="$TMPDIR/inline.js"
        python3 - "$js_out" <<'PY'
import os, re, sys
html = open('site/index.html').read()
inline = [m.group(1) for m in re.finditer(r'<script>(.*?)</script>', html, re.S)]
open(sys.argv[1], 'w').write('\n'.join(inline))
PY
        node --check "$js_out"
        python3 -c "
import html.parser, sys

class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.err = None
    def handle_starttag(self, tag, attrs):
        if tag not in ('meta', 'link', 'br', 'img', 'input', 'hr'):
            self.stack.append((tag, self.getpos()))
    def handle_endtag(self, tag):
        if tag in ('meta', 'link', 'br', 'img', 'input', 'hr'):
            return
        if not self.stack:
            self.err = f'stray </{tag}> at {self.getpos()}'
            return
        open_tag, pos = self.stack.pop()
        if open_tag != tag:
            self.err = f'<{open_tag}> opened at {pos} closed by </{tag}> at {self.getpos()}'

p = P()
p.feed(open('site/index.html').read())
if p.err:
    print(p.err)
    sys.exit(1)
if p.stack:
    print(f'unclosed: {p.stack}')
    sys.exit(1)
print('site ok')
"
      '';
    };

    schema-reject = {
      runtimeInputs = [ pkgs.bash pkgs.jq pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
      text = ''
        # Strict oracle schema: extra keys are dropped (still ok); wrong
        # types, missing keys, future reported_at, oversize lists and
        # overlong strings are refused. Refusal errors never include body
        # text (each bad fixture plants a marker that must not leak).
        set -euo pipefail
        TMPDIR="''${TMPDIR:-/tmp}"
        MARKER='REJECTMARK_7h3q9z'
        run_collect() {
          local cache out
          cache=$(mktemp -d -p "$TMPDIR")
          out="$cache/out"
          mkdir -p "$out"
          DASHBOARD_CACHE="$cache" DASHBOARD_OUT="$out" PROXY_URL=http://127.0.0.1:9/ \
            STATUS_BODY_CMD="cat $TMPDIR/body.json" STATUS_ISSUE_ORACLE=1 \
            bash collect/collect.sh >"$cache/log" 2>&1 || true
          printf '%s' "$cache"
        }
        expect_ok() {
          local cache=$1 want_reported=$2
          jq -e '.sources.oracle.status=="ok"' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $3 not ok" >&2; return 1; }
          [[ $(jq -r .sources.oracle.last_success "$cache/out/data.json") == "$want_reported" ]] \
            || { echo "schema-reject: $3 last_success is not reported_at" >&2; return 1; }
          jq -e '.sources.oracle.error==null' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $3 error not null" >&2; return 1; }
        }
        expect_refused() {
          local cache=$1
          [[ $(jq -r .sources.oracle.status "$cache/out/data.json") != "ok" ]] \
            || { echo "schema-reject: $2 accepted" >&2; return 1; }
          jq -e '.sources.oracle.error|test("invalid payload")' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $2 wrong error" >&2; return 1; }
          jq -e '.hosts.oracle==[]' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $2 hosts not empty" >&2; return 1; }
          if grep -q "$MARKER" "$cache/out/data.json" "$cache/log"; then
            echo "schema-reject: $2 leaked body text" >&2
            return 1
          fi
        }
        NOW=$(date -u +%FT%TZ)
        jq -n -c --arg t "$NOW" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 5 days"}],reported_at:$t}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_ok "$c" "$NOW" valid || exit 1
        jq -e '.hosts.oracle==[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 5 days"}]' "$c/out/data.json" >/dev/null \
          || { echo "schema-reject: valid hosts shape" >&2; exit 1; }
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"oracle",containers:[{name:"a",image:"b",status:"c",zzz:$m}],reported_at:$t,aaa:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_ok "$c" "$NOW" extra-keys || exit 1
        jq -e '.hosts.oracle[0]|keys==["image","name","status"]' "$c/out/data.json" >/dev/null \
          || { echo "schema-reject: extra keys not dropped" >&2; exit 1; }
        if grep -q "$MARKER" "$c/out/data.json"; then
          echo "schema-reject: extra keys leaked into data" >&2
          exit 1
        fi
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"oracle",containers:$m,reported_at:$t,note:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_refused "$c" wrong-types || exit 1
        jq -n -c --arg m "$MARKER" '{role:"oracle",containers:[],note:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_refused "$c" missing-keys || exit 1
        FUT=$(date -u -d "+10 minutes" +%FT%TZ)
        jq -n -c --arg t "$FUT" --arg m "$MARKER" '{role:"oracle",containers:[],reported_at:$t,note:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_refused "$c" future-reported-at || exit 1
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"oracle",containers:[range(51)|{name:"c",image:"i",status:"s"}],reported_at:$t,note:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_refused "$c" oversize-list || exit 1
        LONG=$(printf 'x%.0s' $(seq 1 201))
        jq -n -c --arg t "$NOW" --arg n "$LONG" --arg m "$MARKER" '{role:"oracle",containers:[{name:$n,image:"i",status:"s"}],reported_at:$t,note:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_refused "$c" overlong-string || exit 1
        jq -n -c --arg m "$MARKER" '{role:"oracle",containers:[],reported_at:$m}' >"$TMPDIR/body.json"
        c=$(run_collect)
        expect_refused "$c" bad-date-format || exit 1
        echo "schema reject ok"
      '';
    };

    host-stale = {
      runtimeInputs = [ pkgs.bash pkgs.jq pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
      text = ''
        # Oracle staleness: a fixture that stops updating turns the source
        # stale with the payload's reported_at as last_success (last good
        # served); the next fresh fixture recovers to ok with no manual step.
        set -euo pipefail
        TMPDIR="''${TMPDIR:-/tmp}"
        cache=$(mktemp -d -p "$TMPDIR")
        out="$cache/out"
        mkdir -p "$out"
        collect_once() {
          DASHBOARD_CACHE="$cache" DASHBOARD_OUT="$out" PROXY_URL=http://127.0.0.1:9/ \
            STATUS_BODY_CMD="cat $TMPDIR/body.json" STATUS_ISSUE_ORACLE=1 \
            bash collect/collect.sh >"$cache/log" 2>&1 || true
        }
        T1=$(date -u +%FT%TZ)
        jq -n -c --arg t "$T1" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 1 min"}],reported_at:$t}' >"$TMPDIR/body.json"
        collect_once
        [[ $(jq -r .sources.oracle.status "$out/data.json") == "ok" ]] \
          || { echo "host-stale: fresh run not ok" >&2; exit 1; }
        [[ $(jq -r .sources.oracle.last_success "$out/data.json") == "$T1" ]] \
          || { echo "host-stale: last_success is not reported_at" >&2; exit 1; }
        jq -e '.hosts.oracle==[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 1 min"}]' "$out/data.json" >/dev/null \
          || { echo "host-stale: hosts.oracle shape" >&2; exit 1; }
        OLD=$(date -u -d "-20 minutes" +%FT%TZ)
        jq -n -c --arg t "$OLD" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 1 min"}],reported_at:$t}' >"$TMPDIR/body.json"
        collect_once
        [[ $(jq -r .sources.oracle.status "$out/data.json") == "stale" ]] \
          || { echo "host-stale: stopped fixture not stale" >&2; exit 1; }
        [[ $(jq -r .sources.oracle.last_success "$out/data.json") == "$T1" ]] \
          || { echo "host-stale: stale last_success moved" >&2; exit 1; }
        jq -e '.hosts.oracle==[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 1 min"}]' "$out/data.json" >/dev/null \
          || { echo "host-stale: stale hosts not last good" >&2; exit 1; }
        T3=$(date -u +%FT%TZ)
        jq -n -c --arg t "$T3" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.6",status:"Up 2 min"}],reported_at:$t}' >"$TMPDIR/body.json"
        collect_once
        [[ $(jq -r .sources.oracle.status "$out/data.json") == "ok" ]] \
          || { echo "host-stale: no recovery on next update" >&2; exit 1; }
        [[ $(jq -r .sources.oracle.last_success "$out/data.json") == "$T3" ]] \
          || { echo "host-stale: recovered last_success wrong" >&2; exit 1; }
        jq -e '.hosts.oracle==[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.6",status:"Up 2 min"}]' "$out/data.json" >/dev/null \
          || { echo "host-stale: recovered hosts wrong" >&2; exit 1; }
        jq -e '(.sources|has("oracle") and has("agent") and (has("hosts")|not))' "$out/data.json" >/dev/null \
          || { echo "host-stale: sources still has hosts" >&2; exit 1; }
        [[ $(jq -r .sources.agent.status "$out/data.json") == "error" ]] \
          || { echo "host-stale: agent not interim error" >&2; exit 1; }
        jq -e '.hosts.agent==[] and .hosts.agent_errors_6h==null and .hosts.agent_published_24h==null' "$out/data.json" >/dev/null \
          || { echo "host-stale: agent interim shape" >&2; exit 1; }
        echo "host stale ok"
      '';
    };
  };

  mkApp = name: { runtimeInputs, text }:
    pkgs.writeShellApplication {
      inherit name text runtimeInputs;
    };

  mkCheck = name: spec:
    let app = mkApp name spec;
    in pkgs.runCommand name {
      nativeBuildInputs = [ pkgs.glibcLocales ];
      LANG = "C.UTF-8";
      LC_ALL = "C.UTF-8";
    } ''
      set -euo pipefail
      cd ${src}
      ${pkgs.lib.getExe app}
      touch $out
    '';

  apps = builtins.mapAttrs mkApp scripts;

  # The image-clean app needs the docker daemon, which the nix build users
  # cannot reach, so it cannot run as a sandboxed check. This check pins the
  # static source shape (Dockerfile hygiene, CI publish shape) while the app
  # performs the build, export and env scan. The gate runs both. The ARG/ENV
  # ban lives here, not in the app.
  image-source-shape = pkgs.runCommand "image-source-shape" {
    nativeBuildInputs = [ pkgs.glibcLocales ];
    LANG = "C.UTF-8";
    LC_ALL = "C.UTF-8";
  } ''
    set -euo pipefail
    cd ${src}
    [[ -f Dockerfile ]] || { echo "image-source-shape: Dockerfile missing" >&2; exit 1; }
    [[ -f Dockerfile.reporter ]] || { echo "image-source-shape: Dockerfile.reporter missing" >&2; exit 1; }
    if grep -E '^ADD[[:space:]]' Dockerfile Dockerfile.reporter; then
      echo "image-source-shape: image must not use ADD" >&2
      exit 1
    fi
    if grep -E '^(ARG|ENV)[[:space:]]' Dockerfile Dockerfile.reporter; then
      echo "image-source-shape: image must not use ARG or ENV" >&2
      exit 1
    fi
    [[ $(grep -cE '^COPY[[:space:]]' Dockerfile) -eq 3 ]] || {
      echo "image-source-shape: Dockerfile must copy exactly three sources" >&2
      exit 1
    }
    for dir in collect deploy site; do
      grep -qE "^COPY[[:space:]]+$dir[[:space:]]" Dockerfile || {
        echo "image-source-shape: Dockerfile does not copy $dir" >&2
        exit 1
      }
    done
    [[ $(grep -cE '^COPY[[:space:]]' Dockerfile.reporter) -eq 1 ]] || {
      echo "image-source-shape: Dockerfile.reporter must copy exactly one source" >&2
      exit 1
    }
    grep -qE '^COPY[[:space:]]+reporter[[:space:]]' Dockerfile.reporter || {
      echo "image-source-shape: Dockerfile.reporter does not copy only reporter/" >&2
      exit 1
    }
    # The publish pipeline is split: the workflow gates and authenticates,
    # the image-publish app (in this file) owns the registry and tag shape.
    grep -q 'packages: write' .github/workflows/ci.yml || {
      echo "image-source-shape: CI lacks packages: write" >&2
      exit 1
    }
    grep -q 'GH_TOKEN' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not pass the token via env" >&2
      exit 1
    }
    grep -q 'github.token' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not authenticate with GITHUB_TOKEN" >&2
      exit 1
    }
    grep -q 'PUBLISH' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not gate the push on PUBLISH" >&2
      exit 1
    }
    grep -q 'image-publish' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not call image-publish" >&2
      exit 1
    }
    grep -q 'reporter-publish' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not call reporter-publish" >&2
      exit 1
    }
    grep -q 'reporter-smoke' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not run reporter-smoke" >&2
      exit 1
    }
    grep -q 'ghcr.io/' nix/checks.nix || {
      echo "image-source-shape: image-publish does not target GHCR" >&2
      exit 1
    }
    grep -q 'GITHUB_SHA' nix/checks.nix || {
      echo "image-source-shape: image-publish does not tag the commit SHA" >&2
      exit 1
    }
    grep -q 'GITHUB_REPOSITORY' nix/checks.nix || {
      echo "image-source-shape: image-publish does not read the repository" >&2
      exit 1
    }
    grep -q ':main' nix/checks.nix || {
      echo "image-source-shape: image-publish does not tag main" >&2
      exit 1
    }
    grep -q -- '--password-stdin' nix/checks.nix || {
      echo "image-source-shape: image-publish does not use password-stdin" >&2
      exit 1
    }
    grep -q 'Dockerfile.reporter' nix/checks.nix || {
      echo "image-source-shape: reporter-publish does not use Dockerfile.reporter" >&2
      exit 1
    }
    grep -q '\-reporter:' nix/checks.nix || {
      echo "image-source-shape: reporter image has no -reporter tag" >&2
      exit 1
    }
    touch $out
  '';
in
{
  shellcheck = mkCheck "shellcheck" scripts.shellcheck;
  format-check = mkCheck "format-check" scripts.format-check;
  syntax = mkCheck "syntax" scripts.syntax;
  secrets-gate = mkCheck "secrets-gate" scripts.secrets-gate;
  publish-gate = mkCheck "publish-gate" scripts.publish-gate;
  site-check = mkCheck "site-check" scripts.site-check;
  loop-runtime = mkCheck "loop-runtime" scripts.loop-runtime;
  schema-reject = mkCheck "schema-reject" scripts.schema-reject;
  host-stale = mkCheck "host-stale" scripts.host-stale;
  image-source-shape = image-source-shape;

  inherit apps;
}
