{ pkgs, src }:
let
  hostSource = pkgs.lib.fileset.toSource {
    root = src;
    fileset = src + "/host";
  };
  # gh and curl come last on PATH: a host (or a test fixture) that provides
  # its own wins. docker and its compose plugin always come from the host.
  collectorDeploy = pkgs.writeShellScriptBin "collector-deploy" ''
    export PATH="$PATH:${pkgs.lib.makeBinPath [ pkgs.gh pkgs.curl pkgs.coreutils ]}"
    exec ${pkgs.babashka-unwrapped}/bin/bb -cp ${hostSource}/host/src -m dashboard.deploy "$@"
  '';
in
{ inherit collectorDeploy; }
