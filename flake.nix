{
  description = "Live status page for the moog Antithesis test pipeline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      src = ./.;
      checksFull = import ./nix/checks.nix { inherit pkgs src; };
      checkApps = import ./nix/apps.nix { inherit pkgs; checks = checksFull; };
      previewApps = import ./nix/preview-apps.nix { inherit pkgs; };
      checks = builtins.removeAttrs checksFull [ "apps" ];
    in
    {
      checks.${system} = checks;
      apps.${system} = checkApps // previewApps // {
        default = checkApps.shellcheck;
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          bash
          curl
          gh
          jq
          just
          python3
          shellcheck
          shfmt
          systemd
          unzip
        ];
      };
    };
}
