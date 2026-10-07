{ pkgs, src }:
let
  scripts = {
    shellcheck = {
      runtimeInputs = [ pkgs.shellcheck ];
      text = ''
        shellcheck collect/collect.sh deploy/cycle.sh deploy/publish.sh deploy/loop.sh reporter/report.sh reporter/loop.sh reporter/push-verdict.sh
      '';
    };

    format-check = {
      runtimeInputs = [ pkgs.shfmt ];
      text = ''
        shfmt -i 4 -d collect/collect.sh deploy/cycle.sh deploy/publish.sh deploy/loop.sh reporter/report.sh reporter/loop.sh reporter/push-verdict.sh
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
        bash -n reporter/push-verdict.sh
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
          printf '{"generated_at":"2026-01-01T00:00:00Z","runs":[{"run_id":"probe","url":"https://github.com/owner/repo/actions/runs/42"}],"monitor":{"last":"OK all green","ok":true},"note":"crab sample"}' \
            >"$fixture/data.json"
          printf '{"run_id":"probe","status":"completed","properties":[],"nightly":[{"url":"https://github.com/owner/repo/actions/runs/42"}]}' \
            >"$fixture/runs/probe.json"
          printf '{"reporter":"probe","verdict":"ok"}' \
            >"$fixture/status/probe.json"
          rm -f "$fixture/runs/case.json" "$fixture/runs/evil.json" "$fixture/status/case.json" "$fixture/status/monitor.json"
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
        git --git-dir="$remote" show gh-pages:data.json | grep -q '"last":"OK all green"'
        git --git-dir="$remote" show gh-pages:runs/probe.json | grep -q actions/runs/42
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
        # Monitor payload: a planted URL in the monitor body (status file or
        # data.json monitor subtree) refuses with exit 2 and never pushes;
        # run/detail URLs stay legal (the clean baseline above carries them
        # and publishes). A mounted-secret literal in the monitor body
        # refuses through the literal gate; the clean monitor body publishes.
        write_clean
        printf '{"role":"monitor","verdict":"see https://example.invalid/v","ok":false,"reported_at":"2026-01-01T00:00:00Z"}' \
          >"$fixture/status/monitor.json"
        ref_before=$(pushed_ref)
        if bash deploy/publish.sh; then
          echo "publish gate let monitor URL through (status file)" >&2
          exit 1
        else
          code=$?
          if [[ $code -ne 2 ]]; then
            echo "publish gate monitor URL exit $code, want 2" >&2
            exit 1
          fi
        fi
        if [[ $(pushed_ref) != "$ref_before" ]]; then
          echo "publish gate pushed monitor URL (status file)" >&2
          exit 1
        fi
        write_clean
        jq '.monitor={last:"see https://example.invalid/v",ok:false}' "$fixture/data.json" >"$fixture/data.json.new" \
          && mv "$fixture/data.json.new" "$fixture/data.json"
        ref_before=$(pushed_ref)
        if bash deploy/publish.sh; then
          echo "publish gate let monitor URL through (data.json)" >&2
          exit 1
        else
          code=$?
          if [[ $code -ne 2 ]]; then
            echo "publish gate monitor URL exit $code, want 2" >&2
            exit 1
          fi
        fi
        if [[ $(pushed_ref) != "$ref_before" ]]; then
          echo "publish gate pushed monitor URL (data.json)" >&2
          exit 1
        fi
        write_clean
        printf '{"role":"monitor","verdict":"%s here","ok":false,"reported_at":"2026-01-01T00:00:00Z"}' \
          "$push_value" >"$fixture/status/monitor.json"
        ref_before=$(pushed_ref)
        if bash deploy/publish.sh; then
          echo "publish gate let monitor secret through" >&2
          exit 1
        else
          code=$?
          if [[ $code -ne 2 ]]; then
            echo "publish gate monitor secret exit $code, want 2" >&2
            exit 1
          fi
        fi
        if [[ $(pushed_ref) != "$ref_before" ]]; then
          echo "publish gate pushed monitor secret" >&2
          exit 1
        fi
        write_clean
        printf '{"role":"monitor","verdict":"OK all green","ok":true,"reported_at":"2026-01-01T00:00:00Z"}' \
          >"$fixture/status/monitor.json"
        bash deploy/publish.sh
        git --git-dir="$remote" show gh-pages:status/monitor.json | grep -q 'OK all green'
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
        dockb="reporter-smoke-dockb-$$-$RANDOM"
        gh="reporter-smoke-gh-$$-$RANDOM"
        rname="reporter-smoke-rep-$$-$RANDOM"
        aname="reporter-smoke-agent-$$-$RANDOM"
        nname="reporter-smoke-noagent-$$-$RANDOM"
        ctx=""
        cleanup() {
          timeout 20 docker rm -f "$dock" "$dockb" "$gh" "$rname" "$aname" "$nname" >/dev/null 2>&1 || true
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
          # $RANDOM expands inside the helper: secrets never reach host argv.
          set -euo pipefail
          r=$RANDOM$RANDOM
          printf "%s" "smoke-reporter-$r" >/s/status-token
          printf "%s\n" "smoke-reporter-$r" >/s/pattern
          printf "%s" "ghp_fakesmoke_$r" >/s/cred
          printf "%s\n" "ghp_fakesmoke_$r" >/s/credpat
          chmod 400 /s/status-token /s/pattern /s/cred /s/credpat
          chown 1000:1000 /s /s/status-token /s/pattern /s/cred /s/credpat
        ' || { echo "reporter-smoke: token setup" >&2; exit 1; }
        # Fake Docker API: container list (with Ids) plus a log endpoint that
        # honours `since` and serves a real 8-byte-multiplexed stream split
        # mid-line into 17-byte frames. One log line carries a planted
        # credential-shaped literal read from /s/cred at request time.
        start_fake_dock() {
          timeout 30 docker run -d --name "$1" "$m_sock" "$m_sec" \
            -e SOCK_PATH="$2" -e AGENTLESS="$3" python:3.12-slim python3 -c '
import json, os, socket, time, urllib.parse
p=os.environ.get("SOCK_PATH", "/sock/docker.sock")
agentless=os.environ.get("AGENTLESS", "0") == "1"
try: os.unlink(p)
except: pass
os.makedirs(os.path.dirname(p), exist_ok=True)
containers=[
  {"Id": "oracle-id-1", "Names": ["/oracle-moog-oracle-1"], "Image": "ghcr.io/lambdasistemi/moog-oracle:v0.5.1.5", "Status": "Up 5 days"},
  {"Id": "nginx-id-9", "Names": ["/some-nginx"], "Image": "nginx:latest", "Status": "Up 2 hours"},
]
if not agentless:
  containers.append({"Id": "agent-id-1", "Names": ["/agent-moog-agent-1"], "Image": "moog-agent:v0.5.1.5", "Status": "Up 5 days"})
logdefs=[
  ("worker quux-logline-9 ERROR dial failed", 3600),
  ("handler exception in poll loop", 18000),
  ("Error: stale run evicted", 25200),
  ("Published result for try 14", 7200),
  ("Published result for try 3", 90000),
]
def logbody(since):
  try:
    with open("/s/cred") as f: cred=f.read().strip()
  except: cred="ghp_missing"
  lines=[t for (t, age) in logdefs if time.time()-age >= since]
  lines.append("uploader credential rotated "+cred)
  raw="".join(l+"\n" for l in lines).encode()
  out=b""
  for i in range(0, max(len(raw),1), 17):
    chunk=raw[i:i+17]
    out+=b"\x01\x00\x00\x00"+len(chunk).to_bytes(4,"big")+chunk
  return out
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
os.chmod(p, 0o777)
s.listen(5)
print("docker fake ready", flush=True)
while True:
  c,_=s.accept()
  try:
    req=c.recv(8192).decode(errors="ignore")
    line=(req.split("\r\n")[0] if req else "")
    parts=line.split(" ")
    path=parts[1] if len(parts) > 1 else "/"
    u=urllib.parse.urlparse(path)
    q=urllib.parse.parse_qs(u.query)
    if u.path == "/containers/json":
      b=json.dumps(containers)
      c.sendall(("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+str(len(b))+"\r\n\r\n"+b).encode())
    elif u.path.startswith("/containers/") and u.path.endswith("/logs"):
      since=float(q.get("since", ["0"])[0])
      b=logbody(since)
      c.sendall(("HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: "+str(len(b))+"\r\n\r\n").encode()+b)
    else:
      c.sendall(b"HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
  finally: c.close()
' >/dev/null \
          || { echo "reporter-smoke: fake dock start ($1)" >&2; return 1; }
        }
        start_fake_dock "$dock" /sock/docker.sock 0 || exit 1
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
        # Agent role: same container list plus log-count integers from the
        # moog-agent container, parsed from the multiplexed log stream.
        cred=$(timeout 15 docker run --rm "$m_sec" "$tag" cat /s/credpat) \
          || { echo "reporter-smoke: read cred" >&2; exit 1; }
        timeout 30 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
          python:3.12-slim rm -f /rec/last.json \
          || { echo "reporter-smoke: clear recording" >&2; exit 1; }
        adry_out=$(timeout 30 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
          --mount=type=volume,src="$sockvol",dst=/sock \
          -e DOCKER_SOCKET=/sock/docker.sock -e REPORTER_ROLE=agent -e REPORT_DRY_RUN=1 \
          "$tag" /app/reporter/report.sh) || { echo "reporter-smoke: agent dry run" >&2; exit 1; }
        printf '%s' "$adry_out" | jq -e '.role=="agent" and (.containers|length==2) and .errors_6h==2 and .published_24h==1' >/dev/null \
          || { echo "reporter-smoke: agent dry-run counts wrong" >&2; exit 1; }
        if printf '%s' "$adry_out" | grep -qF "$cred"; then
          echo "reporter-smoke: agent dry run leaked the log credential" >&2
          exit 1
        fi
        if printf '%s' "$adry_out" | grep -q quux-logline-9; then
          echo "reporter-smoke: agent dry run leaked log text" >&2
          exit 1
        fi
        if timeout 10 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
            python:3.12-slim ls /rec/last.json 2>/dev/null; then
          echo "reporter-smoke: agent dry run made an outward request" >&2
          exit 1
        fi
        timeout 30 docker run -d --name "$aname" --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
          --network "$net" --mount=type=volume,src="$sockvol",dst=/sock "$m_secrets" \
          -e DOCKER_SOCKET=/sock/docker.sock -e REPORTER_ROLE=agent -e REPORT_REPOSITORY=owner/repo \
          -e STATUS_ISSUE_NUMBER=124 -e STATUS_TOKEN_FILE=/run/secrets/status-token \
          -e REPORT_API_BASE=http://fake-gh:8080 \
          "$tag" /app/reporter/report.sh >/dev/null \
          || { echo "reporter-smoke: agent real run start" >&2; exit 1; }
        sleep 1
        atop_out=$(timeout 15 docker top "$aname" 2>/dev/null || true)
        if printf '%s' "$atop_out" | grep -qF "$pat"; then
          echo "reporter-smoke: agent token in process list" >&2
          exit 1
        fi
        timeout 30 docker wait "$aname" >/dev/null \
          || { echo "reporter-smoke: agent real run hung" >&2; exit 1; }
        alogs=$(timeout 15 docker logs "$aname" 2>&1 || true)
        if printf '%s' "$alogs" | grep -qF "$pat"; then
          echo "reporter-smoke: agent token in logs" >&2
          exit 1
        fi
        if printf '%s' "$alogs" | grep -qF "$cred"; then
          echo "reporter-smoke: agent logs leaked the log credential" >&2
          exit 1
        fi
        arec_out=$(timeout 15 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
          python:3.12-slim cat /rec/last.json) \
          || { echo "reporter-smoke: no recorded agent request" >&2; exit 1; }
        printf '%s' "$arec_out" | jq -e --arg p "$pat" '.auth==("Bearer "+$p)' >/dev/null \
          || { echo "reporter-smoke: agent token not only in header" >&2; exit 1; }
        printf '%s' "$arec_out" | jq -e '.path=="/repos/owner/repo/issues/124"' >/dev/null \
          || { echo "reporter-smoke: wrong agent issue path" >&2; exit 1; }
        abody=$(printf '%s' "$arec_out" | jq -r .body | jq -r .body)
        printf '%s' "$abody" | jq -e '.role=="agent" and (.containers|length==2) and .errors_6h==2 and .published_24h==1' >/dev/null \
          || { echo "reporter-smoke: recorded agent body counts wrong" >&2; exit 1; }
        if printf '%s' "$abody" | grep -qF "$cred"; then
          echo "reporter-smoke: agent body leaked the log credential" >&2
          exit 1
        fi
        if printf '%s' "$abody" | grep -q quux-logline-9; then
          echo "reporter-smoke: agent body leaked log text" >&2
          exit 1
        fi
        # No moog-agent container: non-zero exit and no PATCH.
        start_fake_dock "$dockb" /sock/docker-noagent.sock 1 || exit 1
        ready=0
        for _ in $(seq 1 30); do
          if timeout 10 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
              --mount=type=volume,src="$sockvol",dst=/sock \
              "$tag" curl -sS --max-time 5 --unix-socket /sock/docker-noagent.sock http://localhost/containers/json 2>/dev/null \
              | grep -q oracle-moog-oracle-1; then ready=1; break; fi
          sleep 1
        done
        [[ $ready -eq 1 ]] || { echo "reporter-smoke: agentless dock never ready" >&2; exit 1; }
        timeout 30 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
          python:3.12-slim rm -f /rec/last.json \
          || { echo "reporter-smoke: clear recording" >&2; exit 1; }
        if timeout 30 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
          --network "$net" --mount=type=volume,src="$sockvol",dst=/sock "$m_secrets" \
          -e DOCKER_SOCKET=/sock/docker-noagent.sock -e REPORTER_ROLE=agent -e REPORT_REPOSITORY=owner/repo \
          -e STATUS_ISSUE_NUMBER=125 -e STATUS_TOKEN_FILE=/run/secrets/status-token \
          -e REPORT_API_BASE=http://fake-gh:8080 \
          "$tag" /app/reporter/report.sh >/dev/null 2>&1; then
          echo "reporter-smoke: no-agent run unexpectedly patched" >&2
          exit 1
        fi
        if timeout 10 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
            python:3.12-slim ls /rec/last.json 2>/dev/null; then
          echo "reporter-smoke: no-agent run patched" >&2
          exit 1
        fi
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

    push-verdict-smoke = {
      runtimeInputs = [ pkgs.docker pkgs.jq pkgs.gnugrep pkgs.coreutils pkgs.bash ];
      text = ''
        # End-to-end run of reporter/push-verdict.sh in the reporter image
        # (no Docker socket anywhere): dry runs print exactly the payload
        # (ok true for OK, false for FAIL/STALE, URL stripped) and make no
        # outward request with no token needed; a real run against a fake
        # GitHub endpoint records exactly the payload with the token only in
        # the Authorization header; an empty verdict line exits non-zero with
        # no request. A planted credential-shaped literal in the verdict
        # survives (operator input, not a secret) while the token never
        # leaves the header. Only paths are reported, never token values.
        #
        # No host bind mount anywhere: fixtures live in named volumes,
        # written by helper containers, results read back the same way. The
        # guard below fails the run if a bind mount ever reappears here.
        # Every docker step is bounded with timeout (30s) and the fake has
        # a readiness probe; nothing waits forever.
        set -euo pipefail
        self="$0"
        bind_start='-v "'
        bind_end='$'
        mount_start='--mount'
        mount_end=' type=bind'
        if grep -qF -e "$bind_start$bind_end" "$self" \
          || grep -qF -e "$mount_start$mount_end" "$self"; then
          echo "push-verdict-smoke: host bind mount in smoke script" >&2
          exit 1
        fi
        tag="moog-reporter:push-verdict-smoke"
        timeout 120 docker build -q -f Dockerfile.reporter -t "$tag" . >/dev/null \
          || { echo "push-verdict-smoke: build timed out or failed" >&2; exit 1; }
        bad=$(timeout 30 docker run --rm --user 1000:1000 "$tag" find /app/reporter -name '*.sh' ! -executable -print) \
          || { echo "push-verdict-smoke: find timed out" >&2; exit 1; }
        if [[ -n $bad ]]; then
          echo "push-verdict-smoke: reporter scripts not executable:" >&2
          printf '%s\n' "$bad" >&2
          exit 1
        fi
        ls_out=$(timeout 30 docker run --rm --user 1000:1000 "$tag" ls /app/reporter/push-verdict.sh) \
          || { echo "push-verdict-smoke: push-verdict.sh missing from image" >&2; exit 1; }
        [[ $ls_out == *push-verdict.sh ]] || { echo "push-verdict-smoke: push-verdict.sh missing from image" >&2; exit 1; }
        secvol="push-verdict-smoke-sec-$$-$RANDOM"
        recvol="push-verdict-smoke-rec-$$-$RANDOM"
        net="push-verdict-smoke-net-$$-$RANDOM"
        gh="push-verdict-smoke-gh-$$-$RANDOM"
        vname="push-verdict-smoke-rep-$$-$RANDOM"
        cleanup() {
          timeout 20 docker rm -f "$gh" "$vname" >/dev/null 2>&1 || true
          timeout 20 docker volume rm "$secvol" "$recvol" >/dev/null 2>&1 || true
          timeout 20 docker network rm "$net" >/dev/null 2>&1 || true
        }
        trap cleanup EXIT
        m_sec="--mount=type=volume,src=$secvol,dst=/s"
        m_secrets="--mount=type=volume,src=$secvol,dst=/run/secrets,readonly"
        timeout 30 docker volume create "$secvol" >/dev/null \
          || { echo "push-verdict-smoke: sec volume" >&2; exit 1; }
        timeout 30 docker volume create "$recvol" >/dev/null \
          || { echo "push-verdict-smoke: rec volume" >&2; exit 1; }
        timeout 30 docker network create "$net" >/dev/null \
          || { echo "push-verdict-smoke: network" >&2; exit 1; }
        # shellcheck disable=SC2016
        # shellcheck disable=SC2016
        timeout 30 docker run --rm --user 0:0 "$m_sec" "$tag" bash -c '
          # $RANDOM expands inside the helper: secrets never reach host argv.
          set -euo pipefail
          r=$RANDOM$RANDOM
          printf "%s" "smoke-push-$r" >/s/status-token
          printf "%s\n" "smoke-push-$r" >/s/pattern
          printf "%s" "ghp_pushm0ke_$r" >/s/cred
          printf "%s\n" "ghp_pushm0ke_$r" >/s/credpat
          printf "OK %s all green https://x.antithesis.com/report/b.html?auth=v2.public_probe\n" "$(cat /s/cred)" >/s/verdict
          chmod 400 /s/status-token /s/pattern /s/cred /s/credpat /s/verdict
          chown 1000:1000 /s /s/status-token /s/pattern /s/cred /s/credpat /s/verdict
        ' || { echo "push-verdict-smoke: token setup" >&2; exit 1; }
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
    open("/rec/last.json","w").write(json.dumps({
      "auth": self.headers.get("Authorization",""),
      "headers": dict(self.headers),
      "body": body, "path": self.path}))
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
' >/dev/null || { echo "push-verdict-smoke: fake github start" >&2; exit 1; }
        ready=0
        for _ in $(seq 1 30); do
          if timeout 10 docker run --rm --network "$net" python:3.12-slim \
              python3 -c 'import urllib.request; urllib.request.urlopen("http://fake-gh:8080/", timeout=5).read()' 2>/dev/null; then
            ready=1; break; fi
          sleep 1
        done
        [[ $ready -eq 1 ]] || { echo "push-verdict-smoke: fake github never ready" >&2; exit 1; }
        pat=$(timeout 15 docker run --rm "$m_sec" "$tag" cat /s/pattern) \
          || { echo "push-verdict-smoke: read pattern" >&2; exit 1; }
        cred=$(timeout 15 docker run --rm "$m_sec" "$tag" cat /s/credpat) \
          || { echo "push-verdict-smoke: read cred" >&2; exit 1; }
        run_dry() {
          timeout 30 docker run --rm -i --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
            -e DOCKER_SOCKET=/nonexistent.sock -e REPORT_DRY_RUN=1 \
            "$tag" /app/reporter/push-verdict.sh
        }
        ok_line="OK run_id=abc age=100s maximum=200s see https://x.antithesis.com/report/a.html?auth=v2.public_probe"
        ok_out=$(printf '%s\n' "$ok_line" | run_dry) \
          || { echo "push-verdict-smoke: OK dry run" >&2; exit 1; }
        printf '%s' "$ok_out" | jq -e '.role=="monitor" and .ok==true' >/dev/null \
          || { echo "push-verdict-smoke: OK dry-run ok wrong" >&2; exit 1; }
        printf '%s' "$ok_out" | jq -e '.verdict=="OK run_id=abc age=100s maximum=200s see "' >/dev/null \
          || { echo "push-verdict-smoke: OK dry-run URL not stripped" >&2; exit 1; }
        printf '%s' "$ok_out" | jq -e '.reported_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null \
          || { echo "push-verdict-smoke: OK dry-run reported_at" >&2; exit 1; }
        if printf '%s' "$ok_out" | grep -E 'https?://|auth='; then
          echo "push-verdict-smoke: OK dry run leaked URL" >&2
          exit 1
        fi
        fail_out=$(printf 'FAIL age 30000s exceeds maximum 20000s\n' | run_dry) \
          || { echo "push-verdict-smoke: FAIL dry run" >&2; exit 1; }
        printf '%s' "$fail_out" | jq -e '.role=="monitor" and .ok==false and .verdict=="FAIL age 30000s exceeds maximum 20000s"' >/dev/null \
          || { echo "push-verdict-smoke: FAIL dry-run payload" >&2; exit 1; }
        stale_out=$(printf 'STALE no recent runs\n' | run_dry) \
          || { echo "push-verdict-smoke: STALE dry run" >&2; exit 1; }
        printf '%s' "$stale_out" | jq -e '.role=="monitor" and .ok==false' >/dev/null \
          || { echo "push-verdict-smoke: STALE dry-run payload" >&2; exit 1; }
        if timeout 10 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
            python:3.12-slim ls /rec/last.json 2>/dev/null; then
          echo "push-verdict-smoke: dry run made an outward request" >&2
          exit 1
        fi
        timeout 30 docker run -d --name "$vname" --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
          --network "$net" "$m_secrets" "$m_sec" \
          -e DOCKER_SOCKET=/nonexistent.sock -e REPORT_REPOSITORY=owner/repo \
          -e STATUS_ISSUE_NUMBER=77 -e STATUS_TOKEN_FILE=/run/secrets/status-token \
          -e REPORT_API_BASE=http://fake-gh:8080 \
          "$tag" /app/reporter/push-verdict.sh /s/verdict \
          >/dev/null || { echo "push-verdict-smoke: real run start" >&2; exit 1; }
        sleep 1
        vtop_out=$(timeout 15 docker top "$vname" 2>/dev/null || true)
        if printf '%s' "$vtop_out" | grep -qF "$pat"; then
          echo "push-verdict-smoke: token in process list" >&2
          exit 1
        fi
        timeout 30 docker wait "$vname" >/dev/null \
          || { echo "push-verdict-smoke: real run hung" >&2; exit 1; }
        vlogs=$(timeout 15 docker logs "$vname" 2>&1 || true)
        if printf '%s' "$vlogs" | grep -qF "$pat"; then
          echo "push-verdict-smoke: token in logs" >&2
          exit 1
        fi
        if printf '%s' "$vlogs" | grep -E 'https?://'; then
          echo "push-verdict-smoke: logs leaked URL" >&2
          exit 1
        fi
        vrec_out=$(timeout 15 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
          python:3.12-slim cat /rec/last.json) \
          || { echo "push-verdict-smoke: no recorded request" >&2; exit 1; }
        printf '%s' "$vrec_out" | jq -e --arg p "$pat" '.auth==("Bearer "+$p)' >/dev/null \
          || { echo "push-verdict-smoke: token not only in header" >&2; exit 1; }
        if printf '%s' "$vrec_out" | jq -r .path | grep -q '?'; then
          echo "push-verdict-smoke: query token in path" >&2
          exit 1
        fi
        printf '%s' "$vrec_out" | jq -e '.path=="/repos/owner/repo/issues/77"' >/dev/null \
          || { echo "push-verdict-smoke: wrong issue path" >&2; exit 1; }
        if printf '%s' "$vrec_out" | jq -r '.headers | to_entries[] | select(.key != "Authorization") | .value' \
          | grep -qF "$pat"; then
          echo "push-verdict-smoke: token outside Authorization" >&2
          exit 1
        fi
        vbody=$(printf '%s' "$vrec_out" | jq -r .body | jq -r .body)
        printf '%s' "$vbody" | jq -e --arg c "$cred" '.role=="monitor" and .ok==true and (.verdict | contains($c))' >/dev/null \
          || { echo "push-verdict-smoke: recorded body wrong" >&2; exit 1; }
        if printf '%s' "$vbody" | grep -E 'https?://|auth='; then
          echo "push-verdict-smoke: recorded body leaked URL" >&2
          exit 1
        fi
        if printf '%s' "$vbody" | grep -qF "$pat"; then
          echo "push-verdict-smoke: recorded body leaked token" >&2
          exit 1
        fi
        timeout 30 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
          python:3.12-slim rm -f /rec/last.json \
          || { echo "push-verdict-smoke: clear recording" >&2; exit 1; }
        if printf "" | timeout 30 docker run --rm --user 1000:1000 --read-only --tmpfs /tmp --cap-drop ALL \
            --network "$net" "$m_secrets" \
            -e DOCKER_SOCKET=/nonexistent.sock -e REPORT_REPOSITORY=owner/repo \
            -e STATUS_ISSUE_NUMBER=78 -e STATUS_TOKEN_FILE=/run/secrets/status-token \
            -e REPORT_API_BASE=http://fake-gh:8080 \
            -i "$tag" /app/reporter/push-verdict.sh >/dev/null 2>&1; then
          echo "push-verdict-smoke: empty verdict unexpectedly sent" >&2
          exit 1
        fi
        if timeout 10 docker run --rm --mount=type=volume,src="$recvol",dst=/rec \
            python:3.12-slim ls /rec/last.json 2>/dev/null; then
          echo "push-verdict-smoke: empty verdict patched" >&2
          exit 1
        fi
        echo "push verdict smoke ok"
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
        cat >"$TMPDIR/render-test.js" <<'DRIVER_EOF'
const fs = require('fs');
const html = fs.readFileSync('site/index.html', 'utf8');
const m = html.match(/<script>([\s\S]*)<\/script>/);
if (!m) { console.error('render test: no inline script'); process.exit(1); }
const captured = {};
function stubEl(id) {
  return {
    set innerHTML(v) { captured[id] = v; },
    get innerHTML() { return captured[id] || ""; },
    set textContent(v) { captured[id] = v; },
    get textContent() { return captured[id] || ""; },
    set title(v) { this._title = v; },
    get title() { return this._title || ""; },
    classList: { add: function () {}, remove: function () {} },
    addEventListener: function () {},
    value: ""
  };
}
global.document = {
  getElementById: function (id) { return stubEl(id); },
  querySelectorAll: function () { return []; },
  querySelector: function () { return null; }
};
global.location = { hash: "" };
global.window = { addEventListener: function () {} };
global.fetch = function () { return Promise.reject(new Error('stub')); };
global.setInterval = function () { return 0; };
const driver =
  'var agots = new Date(Date.now() - 10*60*1000).toISOString();' +
  'var nownow = new Date().toISOString();' +
  'var d = { generated_at: nownow, refresh_seconds: 600,' +
  ' sources: { runs: {status:"ok",error:null,last_success:nownow},' +
  '  chain: {status:"ok",error:null,last_success:nownow},' +
  '  token: {status:"ok",error:null,last_success:nownow},' +
  '  oracle: {status:"ok",error:null,last_success:nownow},' +
  '  agent: {status:"stale",error:"agent status: stale payload",last_success:agots},' +
  '  proxy: {status:"ok",error:null,last_success:nownow},' +
  '  monitor: {status:"error",error:"x",last_success:null},' +
  '  nightly: {status:"ok",error:null,last_success:nownow} },' +
  ' runs: [], chain: {phases:{}}, token: {pending_requests:0},' +
  ' hosts: {oracle:[],agent:[{name:"agent-moog-agent-1",image:"moog-agent:v0.6",status:"Up 3 days"}],' +
  '  agent_errors_6h:4,agent_published_24h:9},' +
  ' proxy: {ready:true,http_code:200}, monitor: null };' +
  'renderChain(d); renderHeader(d);' +
  'globalThis.__chain = captured.chain || "";' +
  'globalThis.__banner = captured.banner || "";';
eval(m[1] + driver);
function fail(msg) { console.error('render test: ' + msg); process.exit(1); }
if (global.__chain.indexOf('stale') < 0) fail('agent card not marked stale');
if (global.__chain.indexOf('10 min ago') < 0) fail('agent card lacks last success');
if (global.__chain.indexOf('9 results published in 24 h') < 0) fail('agent card lacks last good published count');
if (global.__chain.indexOf('4 errors in 6 h') < 0) fail('agent card lacks last good error count');
if (global.__banner.indexOf('agent') < 0) fail('banner does not name agent');
console.log('render test ok');
DRIVER_EOF
        node "$TMPDIR/render-test.js"
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
            STATUS_BODY_CMD="cat $TMPDIR/body.json" STATUS_BODY_CMD_AGENT="cat $TMPDIR/abody.json" \
            STATUS_BODY_CMD_MONITOR="cat $TMPDIR/mbody.json" \
            STATUS_ISSUE_ORACLE=1 STATUS_ISSUE_AGENT=2 STATUS_ISSUE_MONITOR=3 \
            bash collect/collect.sh >"$cache/log" 2>&1 || true
          printf '%s' "$cache"
        }
        monitor_ok() {
          local cache=$1 want_reported=$2 want_verdict=$3 want_ok=$4
          jq -e '.sources.monitor.status=="ok"' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $5 monitor not ok" >&2; return 1; }
          [[ $(jq -r .sources.monitor.last_success "$cache/out/data.json") == "$want_reported" ]] \
            || { echo "schema-reject: $5 monitor last_success is not reported_at" >&2; return 1; }
          jq -e '.sources.monitor.error==null' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $5 monitor error not null" >&2; return 1; }
          jq -e --arg v "$want_verdict" --argjson o "$want_ok" '.monitor=={last:$v,ok:$o}' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $5 monitor page shape wrong" >&2; return 1; }
        }
        monitor_refused() {
          local cache=$1
          [[ $(jq -r .sources.monitor.status "$cache/out/data.json") != "ok" ]] \
            || { echo "schema-reject: $2 monitor accepted" >&2; return 1; }
          jq -e '.sources.monitor.error|test("invalid payload")' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $2 monitor wrong error" >&2; return 1; }
          jq -e '.monitor==null' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $2 monitor not null" >&2; return 1; }
          if grep -q "$MARKER" "$cache/out/data.json" "$cache/log"; then
            echo "schema-reject: $2 monitor leaked body text" >&2
            return 1
          fi
        }
        seed_sources() {
          jq -n -c --arg t "$NOW" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 5 days"}],reported_at:$t}' >"$TMPDIR/body.json"
          jq -n -c --arg t "$NOW" '{role:"agent",containers:[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 5 days"}],errors_6h:0,published_24h:0,reported_at:$t}' >"$TMPDIR/abody.json"
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
        # Agent source: same strictness plus role-specific integer counts.
        agent_ok() {
          local cache=$1 want_reported=$2
          jq -e '.sources.agent.status=="ok"' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $3 agent not ok" >&2; return 1; }
          [[ $(jq -r .sources.agent.last_success "$cache/out/data.json") == "$want_reported" ]] \
            || { echo "schema-reject: $3 agent last_success is not reported_at" >&2; return 1; }
          jq -e '.sources.agent.error==null' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $3 agent error not null" >&2; return 1; }
        }
        agent_refused() {
          local cache=$1
          [[ $(jq -r .sources.agent.status "$cache/out/data.json") != "ok" ]] \
            || { echo "schema-reject: $2 agent accepted" >&2; return 1; }
          jq -e '.sources.agent.error|test("invalid payload")' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $2 agent wrong error" >&2; return 1; }
          jq -e '.hosts.agent==[] and .hosts.agent_errors_6h==null and .hosts.agent_published_24h==null' "$cache/out/data.json" >/dev/null \
            || { echo "schema-reject: $2 agent hosts not empty" >&2; return 1; }
          if grep -q "$MARKER" "$cache/out/data.json" "$cache/log"; then
            echo "schema-reject: $2 agent leaked body text" >&2
            return 1
          fi
        }
        seed_oracle() {
          jq -n -c --arg t "$NOW" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.5",status:"Up 5 days"}],reported_at:$t}' >"$TMPDIR/body.json"
        }
        seed_oracle
        jq -n -c --arg t "$NOW" '{role:"agent",containers:[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 5 days"}],errors_6h:2,published_24h:7,reported_at:$t}' >"$TMPDIR/abody.json"
        c=$(run_collect)
        agent_ok "$c" "$NOW" agent-valid || exit 1
        jq -e '.hosts.agent==[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 5 days"}] and .hosts.agent_errors_6h==2 and .hosts.agent_published_24h==7' "$c/out/data.json" >/dev/null \
          || { echo "schema-reject: agent valid hosts shape" >&2; exit 1; }
        seed_oracle
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"agent",containers:[{name:"a",image:"b",status:"c",zzz:$m}],errors_6h:0,published_24h:0,reported_at:$t,aaa:$m}' >"$TMPDIR/abody.json"
        c=$(run_collect)
        agent_ok "$c" "$NOW" agent-extra-keys || exit 1
        jq -e '.hosts.agent[0]|keys==["image","name","status"]' "$c/out/data.json" >/dev/null \
          || { echo "schema-reject: agent extra keys not dropped" >&2; exit 1; }
        if grep -q "$MARKER" "$c/out/data.json"; then
          echo "schema-reject: agent extra keys leaked into data" >&2
          exit 1
        fi
        seed_oracle
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"agent",containers:[],errors_6h:"2",published_24h:0,reported_at:$t,note:$m}' >"$TMPDIR/abody.json"
        c=$(run_collect)
        agent_refused "$c" agent-string-counts || exit 1
        seed_oracle
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"agent",containers:[],errors_6h:-1,published_24h:0,reported_at:$t,note:$m}' >"$TMPDIR/abody.json"
        c=$(run_collect)
        agent_refused "$c" agent-negative-counts || exit 1
        seed_oracle
        jq -n -c --arg t "$FUT" --arg m "$MARKER" '{role:"agent",containers:[],errors_6h:0,published_24h:0,reported_at:$t,note:$m}' >"$TMPDIR/abody.json"
        c=$(run_collect)
        agent_refused "$c" agent-future-reported-at || exit 1
        # Monitor source: verdict vocabulary OK|FAIL|STALE with matching ok.
        seed_sources
        jq -n -c --arg t "$NOW" '{role:"monitor",verdict:"OK run_id=abc age=100s maximum=200s",ok:true,reported_at:$t}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_ok "$c" "$NOW" "OK run_id=abc age=100s maximum=200s" true monitor-valid-ok || exit 1
        seed_sources
        jq -n -c --arg t "$NOW" '{role:"monitor",verdict:"FAIL age 30000s exceeds maximum 20000s",ok:false,reported_at:$t}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_ok "$c" "$NOW" "FAIL age 30000s exceeds maximum 20000s" false monitor-valid-fail || exit 1
        seed_sources
        jq -n -c --arg t "$NOW" '{role:"monitor",verdict:"STALE no recent runs",ok:false,reported_at:$t}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_ok "$c" "$NOW" "STALE no recent runs" false monitor-valid-stale || exit 1
        seed_sources
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"monitor",verdict:"OK x",ok:false,reported_at:$t,note:$m}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_refused "$c" monitor-ok-mismatch || exit 1
        seed_sources
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"monitor",verdict:"see https://example.invalid/v",ok:false,reported_at:$t,note:$m}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_refused "$c" monitor-url-in-verdict || exit 1
        seed_sources
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"monitor",verdict:"OK x",ok:"true",reported_at:$t,note:$m}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_refused "$c" monitor-string-ok || exit 1
        seed_sources
        jq -n -c --arg t "$NOW" --arg m "$MARKER" '{role:"monitor",verdict:"OK x",ok:true,reported_at:$t,zzz:$m}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_ok "$c" "$NOW" "OK x" true monitor-extra-keys || exit 1
        jq -e '.monitor|keys==["last","ok"]' "$c/out/data.json" >/dev/null \
          || { echo "schema-reject: monitor extra keys not dropped" >&2; exit 1; }
        if grep -q "$MARKER" "$c/out/data.json"; then
          echo "schema-reject: monitor extra keys leaked into data" >&2
          exit 1
        fi
        seed_sources
        jq -n -c --arg t "$FUT" --arg m "$MARKER" '{role:"monitor",verdict:"OK x",ok:true,reported_at:$t,note:$m}' >"$TMPDIR/mbody.json"
        c=$(run_collect)
        monitor_refused "$c" monitor-future-reported-at || exit 1
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
            STATUS_BODY_CMD="cat $TMPDIR/body.json" STATUS_BODY_CMD_AGENT="cat $TMPDIR/abody.json" \
            STATUS_BODY_CMD_MONITOR="cat $TMPDIR/mbody.json" \
            STATUS_ISSUE_ORACLE=1 STATUS_ISSUE_AGENT=2 STATUS_ISSUE_MONITOR=3 \
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
        # Agent staleness: same contract with counts from the last good value.
        jq -n -c --arg t "$T3" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.6",status:"Up 2 min"}],reported_at:$t}' >"$TMPDIR/body.json"
        TA1=$(date -u +%FT%TZ)
        jq -n -c --arg t "$TA1" '{role:"agent",containers:[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 1 min"}],errors_6h:3,published_24h:9,reported_at:$t}' >"$TMPDIR/abody.json"
        collect_once
        [[ $(jq -r .sources.agent.status "$out/data.json") == "ok" ]] \
          || { echo "host-stale: agent fresh run not ok" >&2; exit 1; }
        [[ $(jq -r .sources.agent.last_success "$out/data.json") == "$TA1" ]] \
          || { echo "host-stale: agent last_success is not reported_at" >&2; exit 1; }
        jq -e '.hosts.agent==[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 1 min"}] and .hosts.agent_errors_6h==3 and .hosts.agent_published_24h==9' "$out/data.json" >/dev/null \
          || { echo "host-stale: agent hosts shape" >&2; exit 1; }
        jq -n -c --arg t "$OLD" '{role:"agent",containers:[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 1 min"}],errors_6h:3,published_24h:9,reported_at:$t}' >"$TMPDIR/abody.json"
        collect_once
        [[ $(jq -r .sources.agent.status "$out/data.json") == "stale" ]] \
          || { echo "host-stale: agent stopped fixture not stale" >&2; exit 1; }
        [[ $(jq -r .sources.agent.last_success "$out/data.json") == "$TA1" ]] \
          || { echo "host-stale: agent stale last_success moved" >&2; exit 1; }
        jq -e '.hosts.agent==[{name:"agent-moog-agent-1",image:"moog-agent:v0.5",status:"Up 1 min"}] and .hosts.agent_errors_6h==3 and .hosts.agent_published_24h==9' "$out/data.json" >/dev/null \
          || { echo "host-stale: agent stale hosts not last good" >&2; exit 1; }
        TA3=$(date -u +%FT%TZ)
        jq -n -c --arg t "$TA3" '{role:"agent",containers:[{name:"agent-moog-agent-1",image:"moog-agent:v0.6",status:"Up 2 min"}],errors_6h:4,published_24h:10,reported_at:$t}' >"$TMPDIR/abody.json"
        collect_once
        [[ $(jq -r .sources.agent.status "$out/data.json") == "ok" ]] \
          || { echo "host-stale: agent no recovery on next update" >&2; exit 1; }
        [[ $(jq -r .sources.agent.last_success "$out/data.json") == "$TA3" ]] \
          || { echo "host-stale: agent recovered last_success wrong" >&2; exit 1; }
        jq -e '.hosts.agent==[{name:"agent-moog-agent-1",image:"moog-agent:v0.6",status:"Up 2 min"}] and .hosts.agent_errors_6h==4 and .hosts.agent_published_24h==10' "$out/data.json" >/dev/null \
          || { echo "host-stale: agent recovered hosts wrong" >&2; exit 1; }
        # Monitor staleness: same contract, last good {last, ok} served.
        jq -n -c --arg t "$TA3" '{role:"oracle",containers:[{name:"oracle-moog-oracle-1",image:"moog-oracle:v0.6",status:"Up 2 min"}],reported_at:$t}' >"$TMPDIR/body.json"
        jq -n -c --arg t "$TA3" '{role:"agent",containers:[{name:"agent-moog-agent-1",image:"moog-agent:v0.6",status:"Up 2 min"}],errors_6h:4,published_24h:10,reported_at:$t}' >"$TMPDIR/abody.json"
        TM1=$(date -u +%FT%TZ)
        jq -n -c --arg t "$TM1" '{role:"monitor",verdict:"OK run_id=abc age=100s maximum=200s",ok:true,reported_at:$t}' >"$TMPDIR/mbody.json"
        collect_once
        [[ $(jq -r .sources.monitor.status "$out/data.json") == "ok" ]] \
          || { echo "host-stale: monitor fresh run not ok" >&2; exit 1; }
        [[ $(jq -r .sources.monitor.last_success "$out/data.json") == "$TM1" ]] \
          || { echo "host-stale: monitor last_success is not reported_at" >&2; exit 1; }
        jq -e '.monitor=={last:"OK run_id=abc age=100s maximum=200s",ok:true}' "$out/data.json" >/dev/null \
          || { echo "host-stale: monitor shape" >&2; exit 1; }
        jq -n -c --arg t "$OLD" '{role:"monitor",verdict:"OK run_id=abc age=100s maximum=200s",ok:true,reported_at:$t}' >"$TMPDIR/mbody.json"
        collect_once
        [[ $(jq -r .sources.monitor.status "$out/data.json") == "stale" ]] \
          || { echo "host-stale: monitor stopped fixture not stale" >&2; exit 1; }
        [[ $(jq -r .sources.monitor.last_success "$out/data.json") == "$TM1" ]] \
          || { echo "host-stale: monitor stale last_success moved" >&2; exit 1; }
        jq -e '.monitor=={last:"OK run_id=abc age=100s maximum=200s",ok:true}' "$out/data.json" >/dev/null \
          || { echo "host-stale: monitor stale not last good" >&2; exit 1; }
        TM3=$(date -u +%FT%TZ)
        jq -n -c --arg t "$TM3" '{role:"monitor",verdict:"FAIL age exceeded",ok:false,reported_at:$t}' >"$TMPDIR/mbody.json"
        collect_once
        [[ $(jq -r .sources.monitor.status "$out/data.json") == "ok" ]] \
          || { echo "host-stale: monitor no recovery on next update" >&2; exit 1; }
        [[ $(jq -r .sources.monitor.last_success "$out/data.json") == "$TM3" ]] \
          || { echo "host-stale: monitor recovered last_success wrong" >&2; exit 1; }
        jq -e '.monitor=={last:"FAIL age exceeded",ok:false}' "$out/data.json" >/dev/null \
          || { echo "host-stale: monitor recovered shape wrong" >&2; exit 1; }
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
    grep -q 'push-verdict-smoke' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not run push-verdict-smoke" >&2
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
