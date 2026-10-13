{ pkgs, src }:
let
  applicationSrc = pkgs.lib.fileset.toSource {
    root = src;
    fileset = pkgs.lib.fileset.unions [
      (src + "/reporter")
      (src + "/schema")
    ];
  };
  # Only public application files enter the image; never copy a checkout.
  mkRoot = source: pkgs.runCommand "reporter-root" { } ''
    mkdir -p $out/app $out/etc $out/cache $out/home/reporter $out/tmp
    cp -r ${source}/reporter ${source}/schema $out/app/
    chmod -R u+w $out/app
    find $out/app -type d -exec chmod 0755 {} +
    find $out/app -type f -exec chmod 0644 {} +
    find $out/app/reporter -name '*.sh' -exec chmod 0755 {} +
  '';
  tools = pkgs.buildEnv {
    name = "reporter-tools";
    paths = with pkgs; [
      bash coreutils curl gh gitMinimal jq gnugrep gnused findutils
      gawk util-linux unzip cacert
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };
  mkImage = root: tag: pkgs.dockerTools.buildLayeredImage {
    name = "moog-reporter";
    inherit tag;
    contents = [ root tools pkgs.dockerTools.binSh pkgs.dockerTools.usrBinEnv ];
    fakeRootCommands = ''
      # Docker exec resolves account files inside the container root. They
      # must be regular files, not absolute links into the Nix store.
      mkdir -p etc
      printf 'root:x:0:0:root:/root:/bin/bash\nreporter:x:1000:1000:reporter:/home/reporter:/bin/bash\n' >etc/passwd
      printf 'root:x:0:\nreporter:x:1000:\n' >etc/group
      chown 1000:1000 cache home/reporter
      chmod 1777 tmp
    '';
    enableFakechroot = true;
    config = {
      User = "1000:1000";
      WorkingDir = "/app";
      Cmd = [ "/app/reporter/loop.sh" ];
      Env = [
        "PATH=/bin"
        "HOME=/home/reporter"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
  stripped = pkgs.runCommand "reporter-stripped-source" { } ''
    mkdir -p $out
    cp -r ${applicationSrc}/reporter ${applicationSrc}/schema $out/
    chmod -R u+rwX,go-rwx $out
  '';
in {
  image = mkImage (mkRoot applicationSrc) "nix";
  # The smoke gate verifies permissions even when source modes are stripped.
  modesImage = mkImage (mkRoot stripped) "nix-modes";
}
