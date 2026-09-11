{
  description = "Non-SIP macOS drop-in tools for every stackable-hooks implementation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # The tool set, pinned. Every entry is a NON-Apple build of a binary
        # that also exists under a SIP-protected prefix, which is the only
        # thing that makes it a usable drop-in: macOS strips
        # DYLD_INSERT_LIBRARIES when a binary under /bin, /sbin, /usr/bin or
        # /usr/sbin is exec'd, and AMFI SIGKILLs a relocated COPY of an Apple
        # platform binary — so the replacement has to be a genuinely different
        # build, not the system one moved.
        #
        # Keep in step with `TOOLS` in build-bundle.sh; the script fails the
        # build if any name in that list cannot be resolved here.
        toolPackages = with pkgs; [
          bashInteractive
          dash
          zsh
          coreutils
          findutils
          gnugrep
          gawk
          gnused
          gnutar
          gzip
          xz
          which
          diffutils
        ];

        toolPath = pkgs.lib.makeBinPath toolPackages;

        bundle = pkgs.stdenvNoCC.mkDerivation {
          pname = "stackable-hooks-macos-tools";
          version = "0.1.0";
          src = ./.;

          # `file` classifies Mach-O vs script; the cctools pair reads and
          # rewrites load commands. They are build-time only: the point of the
          # bundle is that the RESULT needs nothing from the store.
          nativeBuildInputs = [ pkgs.file pkgs.darwin.cctools ];

          dontConfigure = true;
          dontInstall = true;
          dontFixup = true;

          buildPhase = ''
            runHook preBuild
            export SANDBOX_TOOLS_PATH=${toolPath}
            export SANDBOX_TOOLS_OUT_DIR=$out
            export SANDBOX_TOOLS_STRICT=1
            bash ./build-bundle.sh
            runHook postBuild
          '';

          meta = with pkgs.lib; {
            description =
              "Relocatable non-SIP macOS tool bundle shared by stackable-hooks implementations";
            platforms = platforms.darwin;
          };
        };
      in
      {
        packages = {
          stackable-hooks-macos-tools = bundle;
          default = bundle;
        };

        # For a consumer's dev shell:
        #
        #     inputs.stackable-hooks-macos-tools.packages.${system}.default
        #
        # and export STACKABLE_HOOKS_TOOLS_DIR (plus the legacy
        # CT_SANDBOX_TOOLS_DIR / AH_SANDBOX_TOOLS_DIR aliases) pointing at it.
        devShells.default = pkgs.mkShellNoCC {
          packages = [ pkgs.file pkgs.darwin.cctools ] ++ toolPackages;
          shellHook = ''
            export SANDBOX_TOOLS_PATH=${toolPath}
          '';
        };
      }
    );
}
