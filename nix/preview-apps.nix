{ pkgs }:
let
  mkApp = name: { runtimeInputs, text }:
    pkgs.writeShellApplication {
      inherit name text runtimeInputs;
    };

  scripts = {
    preview-smoke = {
      runtimeInputs = [ pkgs.python3 pkgs.curl pkgs.jq pkgs.gnugrep pkgs.coreutils ];
      text = ''
        set -euo pipefail
        [ -d preview-site ] || { echo "preview-site missing" >&2; exit 1; }
        python3 -m http.server 4173 --bind 127.0.0.1 --directory preview-site &
        server_pid=$!
        trap 'kill "$server_pid"' EXIT
        for _ in $(seq 1 30); do
          if curl -fsS http://127.0.0.1:4173/ >/dev/null; then
            break
          fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:4173/ | grep -q 'Moog.*Antithesis pipeline'
        curl -fsS http://127.0.0.1:4173/data.json | jq -e '.runs | length > 0' >/dev/null
        for rid in $(jq -r '.runs[].run_id' preview-site/data.json); do
          curl -fsS "http://127.0.0.1:4173/runs/$rid.json" | jq -e --arg r "$rid" '.run_id == $r' >/dev/null
        done
        echo "preview smoke ok"
      '';
    };

    preview-verify = {
      runtimeInputs = [ pkgs.curl pkgs.jq ];
      text = ''
        set -euo pipefail
        base="''${1:?usage: preview-verify URL}"
        curl -fsS "$base/data.json" | jq -e '.runs | length > 0' >/dev/null
        rid=$(jq -r '.runs[0].run_id' preview-site/data.json)
        curl -fsS "$base/runs/$rid.json" | jq -e --arg r "$rid" '.run_id == $r' >/dev/null
        echo "preview verify ok"
      '';
    };
  };

  apps = builtins.mapAttrs mkApp scripts;
in
builtins.mapAttrs
  (_: app: {
    type = "app";
    program = pkgs.lib.getExe app;
  })
  apps
