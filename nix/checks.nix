{ pkgs, src }:
let
  scripts = {
    shellcheck = {
      runtimeInputs = [ pkgs.shellcheck ];
      text = ''
        shellcheck collect/collect.sh deploy/cycle.sh deploy/publish.sh
      '';
    };

    format-check = {
      runtimeInputs = [ pkgs.shfmt ];
      text = ''
        shfmt -i 4 -d collect/collect.sh deploy/cycle.sh deploy/publish.sh
      '';
    };

    syntax = {
      runtimeInputs = [ pkgs.bash ];
      text = ''
        bash -n collect/collect.sh
        bash -n deploy/cycle.sh
        bash -n deploy/publish.sh
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
        if rg -n 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' site preview-sample README.md systemd justfile flake.nix; then
          echo "secrets gate: match found" >&2
          exit 1
        fi
        echo "secrets gate ok"
      '';
    };

    systemd-check = {
      runtimeInputs = [ pkgs.ripgrep ];
      text = ''
        # Static unit validation. Full `systemd-analyze verify` needs host
        # state unavailable in the sandbox, so CI runs it as a job step.
        rg -q '^ExecStart=/code/moog-antithesis-dashboard/deploy/cycle.sh' systemd/moog-antithesis-dashboard.service
        rg -q '^Type=oneshot' systemd/moog-antithesis-dashboard.service
        rg -q '^OnUnitActiveSec=10min' systemd/moog-antithesis-dashboard.timer
        rg -q '^WantedBy=timers.target' systemd/moog-antithesis-dashboard.timer
        echo "systemd ok"
      '';
    };

    publish-gate = {
      runtimeInputs = [ pkgs.bash pkgs.git pkgs.jq pkgs.coreutils pkgs.gnugrep ];
      text = ''
        # Behavioural test of deploy/publish.sh against a local bare remote:
        # a report link in a detail file must refuse the whole publication,
        # and a clean tree must publish data.json with the detail files.
        set -euo pipefail
        fixture="$TMPDIR/publish-fixture"
        remote="$TMPDIR/publish-remote.git"
        rm -rf "$fixture" "$remote"
        mkdir -p "$fixture/runs"
        git init -q --bare "$remote"
        printf '{"generated_at":"2026-01-01T00:00:00Z","runs":[]}' >"$fixture/data.json"
        printf '{"run_id":"probe","status":"completed","properties":[]}' >"$fixture/runs/probe.json"
        printf 'gate-fixture-key' >"$TMPDIR/fixture.key"
        export DASHBOARD_OUT="$fixture" DASHBOARD_REMOTE="$remote" ANTITHESIS_API_KEY_FILE="$TMPDIR/fixture.key"
        printf '{"run_id":"evil","link":"https://x.antithesis.com/report/a.html?auth=v2.public_probe"}' \
          >"$fixture/runs/evil.json"
        if bash deploy/publish.sh; then
          echo "publish gate let a report link through" >&2
          exit 1
        fi
        rm "$fixture/runs/evil.json"
        bash deploy/publish.sh
        git --git-dir="$remote" show gh-pages:data.json | grep -q generated_at
        git --git-dir="$remote" show gh-pages:runs/probe.json | grep -q probe
        echo "publish gate ok"
      '';
    };

    image-clean = {
      runtimeInputs = [ pkgs.docker pkgs.gnutar pkgs.gnugrep pkgs.coreutils pkgs.bash ];
      text = ''
        # The collector image must carry no secret: build it, export its
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
        tag="moog-collector:image-clean"
        canary="''${IMAGE_CLEAN_CANARY:-}"
        docker build -q -t "$tag" .
        cid=$(docker create "$tag")
        work=$(mktemp -d)
        cleanup() {
          docker rm -f "$cid" >/dev/null
          rm -rf "$work"
        }
        trap cleanup EXIT
        fail=0
        docker export "$cid" | tar -x -C "$work"
        leak_paths=$(grep -a -r -l -E -e 'v2\.public' -e 'github_pat_' "$work" || true)
        if [[ -n "$leak_paths" ]]; then
          echo "image-clean: key-shaped strings in these image paths:" >&2
          printf '%s\n' "$leak_paths" >&2
          fail=1
        fi
        if [[ -n "$canary" ]]; then
          canary_paths=$(grep -a -r -l -F -e "$canary" "$work" || true)
          if [[ -n "$canary_paths" ]]; then
            echo "image-clean: canary found in these image paths:" >&2
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
              echo "image-clean: unexpected key-shaped line(s) under /app in ''${f#"$work"/}" >&2
              fail=1
            fi
          done <<< "$app_files"
        fi
        env_out=$(docker run --rm "$tag" env)
        env_hits=$(printf '%s\n' "$env_out" | grep -E -c -e '^(.*_)?(KEY|TOKEN|SECRET|PASSWORD|BEARER)(_.*)?=[^[:space:]]' -e 'ghp_' -e 'github_pat_' -e 'Bearer ' -e 'v2\.public' -e 'auth=' || true)
        if [[ "$env_hits" -ne 0 ]]; then
          echo "image-clean: credential-shaped variable in 'docker run env'" >&2
          fail=1
        fi
        if [[ -n "$canary" ]] && printf '%s\n' "$env_out" | grep -q -F -e "$canary"; then
          echo "image-clean: canary found in 'docker run env'" >&2
          fail=1
        fi
        if [[ "$fail" -ne 0 ]]; then
          exit 1
        fi
        echo "image clean ok"
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
    if grep -E '^ADD[[:space:]]' Dockerfile; then
      echo "image-source-shape: Dockerfile must not use ADD" >&2
      exit 1
    fi
    if grep -E '^(ARG|ENV)[[:space:]]' Dockerfile; then
      echo "image-source-shape: Dockerfile must not use ARG or ENV" >&2
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
    grep -q 'ghcr.io/' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not publish to GHCR" >&2
      exit 1
    }
    grep -q 'packages: write' .github/workflows/ci.yml || {
      echo "image-source-shape: CI lacks packages: write" >&2
      exit 1
    }
    grep -q 'github.token' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not authenticate with GITHUB_TOKEN" >&2
      exit 1
    }
    grep -q 'github.sha' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not tag the commit SHA" >&2
      exit 1
    }
    grep -q ':main' .github/workflows/ci.yml || {
      echo "image-source-shape: CI does not tag main" >&2
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
  systemd-check = mkCheck "systemd-check" scripts.systemd-check;
  site-check = mkCheck "site-check" scripts.site-check;
  image-source-shape = image-source-shape;

  inherit apps;
}
