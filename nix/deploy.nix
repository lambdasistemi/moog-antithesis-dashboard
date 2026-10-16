{ pkgs, src }:
let
  hostSource = pkgs.lib.fileset.toSource {
    root = src;
    fileset = src + "/host";
  };
  # The snapshot contract is checked with the schema shipped in the selected
  # image; this is only the validator that applies it.
  validator = pkgs.writeShellScriptBin "validate-snapshot" ''
    exec ${pkgs.python3.withPackages (ps: [ ps.jsonschema ])}/bin/python ${hostSource}/host/validate-snapshot.py "$@"
  '';
  # gh, curl and the validator come last on PATH: a test fixture that
  # provides its own wins. docker and its compose plugin always come from
  # the host.
  collectorDeploy = pkgs.writeShellScriptBin "collector-deploy" ''
    export PATH="$PATH:${pkgs.lib.makeBinPath [ pkgs.gh pkgs.curl pkgs.coreutils ]}"
    export DEPLOY_VALIDATOR="''${DEPLOY_VALIDATOR:-${validator}/bin/validate-snapshot}"
    exec ${pkgs.babashka-unwrapped}/bin/bb -cp ${hostSource}/host/src -m dashboard.deploy "$@"
  '';
  # The live smoke drives the real Docker daemon with a pinned client; `docker
  # compose` goes to the standalone Compose of the same major version.
  dockerWithCompose = pkgs.writeShellScriptBin "docker" ''
    if [ "''${1:-}" = compose ]; then
      shift
      exec ${pkgs.docker-compose}/bin/docker-compose "$@"
    fi
    exec ${pkgs.docker}/bin/docker "$@"
  '';
in
{ inherit collectorDeploy validator dockerWithCompose; }
