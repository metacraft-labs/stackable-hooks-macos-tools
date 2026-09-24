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

        # Every entry below is a NON-Apple *build* of a binary that also exists
        # under a SIP-protected prefix, which is the only thing that makes it a
        # usable drop-in: macOS strips DYLD_INSERT_LIBRARIES when a binary under
        # /bin, /sbin, /usr/bin or /usr/sbin is exec'd, and AMFI SIGKILLs a
        # relocated COPY of an Apple platform binary — so the replacement has to
        # be a genuinely different build, not the system one moved.
        #
        # "A different build" does NOT have to mean "a different program", and
        # that distinction is the whole point of the three tiers below. A
        # drop-in that is observable but BEHAVES DIFFERENTLY trades an honest
        # loss for a silent divergence, which is the worse of the two failures:
        # the monitor reports mcComplete over a build that did something other
        # than what it would have done unmonitored.

        # ── Tier 1: Apple's own source, compiled by us ───────────────────────
        #
        # Apple releases the BSD userland under APSL 2.0 at
        # github.com/apple-oss-distributions, and nixpkgs already packages it.
        # A nix build of `text_cmds` is byte-for-byte the same PROGRAM as
        # /usr/bin/sed — same source, different build — so it is ad-hoc signed
        # rather than an Apple platform binary (no AMFI kill) while behaving
        # identically. This is strictly better than any reimplementation or
        # GNU stand-in, and it is where every tool belongs that can be here.
        appleToolPackages = with pkgs.darwin; [
          system_cmds # arch, sysctl, getconf, hostinfo, vm_stat, nvram, dmesg
          shell_cmds # echo test env printf find xargs date uname id which …
          text_cmds # cat grep sed sort head tail tr cut wc uniq paste …
          file_cmds # ls cp mv rm mkdir stat readlink chmod gzip touch …
          adv_cmds # ps stty tty locale last whois
        ];

        # ── Tier 2: no Apple release, but the SAME implementation ────────────
        #
        # macOS ships these from an upstream Apple does not re-release, so we
        # take that upstream directly. `/usr/bin/tar` IS bsdtar/libarchive and
        # `/usr/bin/awk` IS one-true-awk (`awk version 20200816`), so libarchive
        # and nawk are the same program at a different vintage — a far closer
        # twin than gnutar/gawk, which are different programs wearing the name.
        nearTwinPackages = with pkgs; [
          libarchive # bsdtar        ← /usr/bin/tar is bsdtar 3.5.3
          nawk # one-true-awk  ← /usr/bin/awk is one-true-awk
          zsh # zsh 5.x       ← /bin/zsh is zsh 5.9
          dash # dash          ← /bin/dash
          xz
        ];

        # ── Tier 3: a genuinely DIFFERENT implementation ─────────────────────
        #
        # These are the honest remainder: no Apple release and no upstream twin
        # we can package, so the drop-in is a different program and a build that
        # takes this path may behave differently than it would unmonitored.
        # Keeping the list explicit — and making build-bundle.sh fail when a
        # tool silently changes tier — is what stops this set from growing by
        # accident. Shrinking it is tracked work, not a nice-to-have:
        #
        #   * bash    /bin/bash and /bin/sh are bash 3.2.57 (Apple's last GPLv2
        #             release). We ship bash 5.x. POSIX `sh` scripts are largely
        #             unaffected, but bash-specific scripts are not.
        #   * diff    /usr/bin/diff is "Apple diff (based on FreeBSD diff)".
        #     cmp     We ship GNU diffutils.
        substitutePackages = with pkgs; [
          bashInteractive
          diffutils
        ];

        binPath = pkgs.lib.makeBinPath;

        bundle = pkgs.stdenvNoCC.mkDerivation {
          pname = "stackable-hooks-macos-tools";
          version = "0.2.0";
          src = ./.;

          # `file` classifies Mach-O vs script; the cctools pair reads and
          # rewrites load commands. They are build-time only: the point of the
          # bundle is that the RESULT needs nothing from the store.
          nativeBuildInputs = [ pkgs.file pkgs.darwin.cctools ];

          dontConfigure = true;
          dontInstall = true;
          dontFixup = true;

          # Three paths rather than one, so the script can report — and
          # ENFORCE — which tier each tool actually resolved from. A
          # single concatenated path would let a tool drift from Apple's
          # build to a GNU stand-in with nothing to notice.
          buildPhase = ''
            runHook preBuild
            export SANDBOX_TOOLS_PATH_APPLE=${binPath appleToolPackages}
            export SANDBOX_TOOLS_PATH_NEAR=${binPath nearTwinPackages}
            export SANDBOX_TOOLS_PATH_SUBSTITUTE=${binPath substitutePackages}
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
          packages = [ pkgs.file pkgs.darwin.cctools ];
          shellHook = ''
            export SANDBOX_TOOLS_PATH_APPLE=${binPath appleToolPackages}
            export SANDBOX_TOOLS_PATH_NEAR=${binPath nearTwinPackages}
            export SANDBOX_TOOLS_PATH_SUBSTITUTE=${binPath substitutePackages}
          '';
        };
      }
    );
}
