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
        port_file=$(mktemp)
        python3 - "$port_file" <<'PY' &
        import functools
        import http.server
        import pathlib
        import sys

        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory="preview-site")
        with http.server.HTTPServer(("127.0.0.1", 0), handler) as server:
            pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
            server.serve_forever()
        PY
        server_pid=$!
        cleanup() {
          kill "$server_pid" 2>/dev/null || true
          wait "$server_pid" 2>/dev/null || true
          rm -f "$port_file"
        }
        trap cleanup EXIT
        for _ in $(seq 1 30); do
          if [ -s "$port_file" ]; then
            break
          fi
          kill -0 "$server_pid" 2>/dev/null || { echo "preview server failed to start" >&2; exit 1; }
          sleep 1
        done
        [ -s "$port_file" ] || { echo "preview server startup timed out" >&2; exit 1; }
        base="http://127.0.0.1:$(cat "$port_file")"
        curl -fsS --max-time 10 "$base/" | grep -q 'Moog.*Antithesis pipeline'
        curl -fsS --max-time 10 "$base/data.json" | jq -e '.runs | length > 0' >/dev/null
        for rid in $(jq -r '.runs[].run_id' preview-site/data.json); do
          curl -fsS --max-time 10 "$base/runs/$rid.json" | jq -e --arg r "$rid" '.run_id == $r' >/dev/null
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
