{ pkgs, src }:
let
  applicationSrc = pkgs.lib.fileset.toSource {
    root = src;
    fileset = pkgs.lib.fileset.unions [
      (src + "/collect") (src + "/deploy") (src + "/site")
    ];
  };
  # Only public application files enter the image; never copy a checkout.
  mkRoot = source: pkgs.runCommand "collector-root" { } ''
    mkdir -p $out/app $out/etc $out/cache $out/home/collector $out/tmp
    cp -r ${source}/collect ${source}/deploy ${source}/site $out/app/
    chmod -R u+w $out/app
    find $out/app -type d -exec chmod 0755 {} +
    find $out/app -type f -exec chmod 0644 {} +
    find $out/app/collect $out/app/deploy -name '*.sh' -exec chmod 0755 {} +
    printf 'root:x:0:0:root:/root:/bin/bash\ncollector:x:1000:1000:collector:/home/collector:/bin/bash\n' >$out/etc/passwd
    printf 'root:x:0:\ncollector:x:1000:\n' >$out/etc/group
  '';
  tools = pkgs.buildEnv {
    name = "collector-tools";
    paths = with pkgs; [
      bash coreutils curl gh gitMinimal jq gnugrep gnused findutils
      gawk util-linux unzip cacert
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };
  mkImage = root: tag: pkgs.dockerTools.buildLayeredImage {
    name = "moog-collector";
    inherit tag;
    contents = [ root tools pkgs.dockerTools.binSh pkgs.dockerTools.usrBinEnv ];
    fakeRootCommands = ''
      chown 1000:1000 cache home/collector
      chmod 1777 tmp
    '';
    enableFakechroot = true;
    config = {
      User = "1000:1000";
      WorkingDir = "/app";
      Cmd = [ "/app/deploy/loop.sh" ];
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
    cp -r ${applicationSrc}/collect ${applicationSrc}/deploy ${applicationSrc}/site $out/
    chmod -R u+rwX,go-rwx $out
  '';
in {
  image = mkImage (mkRoot applicationSrc) "nix";
  # The smoke gate verifies permissions even when source modes are stripped.
  modesImage = mkImage (mkRoot stripped) "nix-modes";
}
