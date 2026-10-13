{ pkgs, src }:
let
  applicationSrc = pkgs.lib.fileset.toSource {
    root = src;
    fileset = pkgs.lib.fileset.unions [
      (src + "/collect") (src + "/deploy") (src + "/site") (src + "/schema")
      (src + "/backend/src") (src + "/bb.edn")
    ];
  };
  # Only public application files enter the image; never copy a checkout.
  mkRoot = source: pkgs.runCommand "collector-root" { } ''
    mkdir -p $out/app $out/etc $out/cache $out/home/collector $out/tmp
    cp -r ${source}/collect ${source}/deploy ${source}/site ${source}/schema $out/app/
    cp -r ${source}/backend ${source}/bb.edn $out/app/
    chmod -R u+w $out/app
    find $out/app -type d -exec chmod 0755 {} +
    find $out/app -type f -exec chmod 0644 {} +
    find $out/app/collect $out/app/deploy -name '*.sh' -exec chmod 0755 {} +
  '';
  tools = pkgs.buildEnv {
    name = "collector-tools";
    paths = with pkgs; [
      babashka-unwrapped bash coreutils curl gh gitMinimal jq gnugrep gnused findutils
      gawk util-linux unzip cacert
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };
  mkImage = root: tag: pkgs.dockerTools.buildLayeredImage {
    name = "moog-collector";
    inherit tag;
    contents = [ root tools pkgs.dockerTools.binSh pkgs.dockerTools.usrBinEnv ];
    fakeRootCommands = ''
      # Docker exec resolves account files inside the container root. They
      # must be regular files, not absolute links into the Nix store.
      mkdir -p etc
      printf 'root:x:0:0:root:/root:/bin/bash\ncollector:x:1000:1000:collector:/home/collector:/bin/bash\n' >etc/passwd
      printf 'root:x:0:\ncollector:x:1000:\n' >etc/group
      chown 1000:1000 cache home/collector
      chmod 1777 tmp
    '';
    enableFakechroot = true;
    config = {
      User = "1000:1000";
      WorkingDir = "/app";
      Cmd = [ "/bin/bb" "--main" "dashboard.main" "loop" ];
      Env = [
        "PATH=/bin"
        "HOME=/home/collector"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
  stripped = pkgs.runCommand "collector-stripped-source" { } ''
    mkdir -p $out
    cp -r ${applicationSrc}/collect ${applicationSrc}/deploy ${applicationSrc}/site ${applicationSrc}/schema $out/
    cp -r ${applicationSrc}/backend ${applicationSrc}/bb.edn $out/
    chmod -R u+rwX,go-rwx $out
  '';
in {
  image = mkImage (mkRoot applicationSrc) "nix";
  # The smoke gate verifies permissions even when source modes are stripped.
  modesImage = mkImage (mkRoot stripped) "nix-modes";
}
