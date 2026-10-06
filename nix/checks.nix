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
        if rg -n 'auth=|v2\.public|Bearer |Authorization|-u [^ ]+:[^ ]+|password' site README.md systemd justfile flake.nix; then
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
in
{
  shellcheck = mkCheck "shellcheck" scripts.shellcheck;
  format-check = mkCheck "format-check" scripts.format-check;
  syntax = mkCheck "syntax" scripts.syntax;
  secrets-gate = mkCheck "secrets-gate" scripts.secrets-gate;
  publish-gate = mkCheck "publish-gate" scripts.publish-gate;
  systemd-check = mkCheck "systemd-check" scripts.systemd-check;
  site-check = mkCheck "site-check" scripts.site-check;

  inherit apps;
}
