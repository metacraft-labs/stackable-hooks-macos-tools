{
  description = "Non-SIP macOS drop-in tools for every stackable-hooks implementation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        bundle = pkgs.callPackage ./package.nix { };
        inherit (bundle) appleToolPackages nearTwinPackages substitutePackages;
        binPath = pkgs.lib.makeBinPath;
      in
      {
        packages = {
          stackable-hooks-macos-tools = bundle;
          default = bundle;
        };

        # `nix run .#differential` — compare every bundled tool against the
        # SIP binary it stands in for, on this host.
        apps.differential = {
          type = "app";
          program = "${pkgs.writeShellScript "differential" ''
            export BUNDLE_DIR=''${BUNDLE_DIR:-${bundle}}
            exec ${pkgs.bash}/bin/bash ${./tests}/run-differential.sh "$@"
          ''}";
        };

        # For a consumer's dev shell:
        #
        #     inputs.stackable-hooks-macos-tools.packages.${system}.default
        #
        # and export STACKABLE_HOOKS_TOOLS_DIR (plus the legacy
        # CT_SANDBOX_TOOLS_DIR / AH_SANDBOX_TOOLS_DIR aliases) pointing at it.
        devShells.default = pkgs.mkShellNoCC {
          packages = [
            pkgs.file
            pkgs.darwin.cctools
          ];
          shellHook = ''
            export SANDBOX_TOOLS_PATH_APPLE=${binPath appleToolPackages}
            export SANDBOX_TOOLS_PATH_NEAR=${binPath nearTwinPackages}
            export SANDBOX_TOOLS_PATH_SUBSTITUTE=${binPath substitutePackages}
          '';
        };
      }
    );
}
