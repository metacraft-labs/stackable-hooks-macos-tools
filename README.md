# stackable-hooks-macos-tools

Non-SIP macOS drop-in binaries, shared by every language implementation of the
stackable-hooks framework (`nim-stackable-hooks`, io-mon, agent-harbor, and the
reprobuild monitor that sits on top of them).

## The problem

On macOS, System Integrity Protection strips `DYLD_INSERT_LIBRARIES` from the
environment whenever a binary under `/bin`, `/sbin`, `/usr/bin` or `/usr/sbin`
is `exec`'d. A monitor that follows a process tree by injecting a shim
therefore goes **blind** the moment a build shells out to `/bin/sh`,
`/usr/bin/grep` or `/usr/bin/sed` — which is to say, immediately.

AMFI closes the obvious workaround: it `SIGKILL`s a *copy* of a restricted
Apple platform binary at launch, even after ad-hoc re-signing. So the
replacement cannot be the system binary moved somewhere else. It has to be a
genuinely different **build**.

io-mon's `rewriteSipPath` redirects such an exec to `<tools-dir>/usr/bin/<tool>`.
This repo produces that directory.

## The part that is easy to get wrong

Making the exec observable is the easy half. The hard half is not changing what
the build *does* while you do it.

A drop-in that the shim can load into but that **behaves differently** from the
binary it replaced is worse than no drop-in at all. Losing the subtree is
honest: the monitor reports `mcIncomplete`, the action is not cached, and a
human is told. A behavioural substitution is silent: the monitor reports
`mcComplete` over a build that did something other than what it would have done
unmonitored, and that result gets published to the action cache.

The first version of this bundle took whatever the nix dev shell had on
`$PATH`, which meant GNU coreutils, GNU grep, GNU sed, gawk and gnutar standing
in for the BSD tools macOS actually ships. `stat -c` versus `stat -f`. `date -d`
versus `date -v`. `sed -i` taking a mandatory suffix argument or not. Ten of
those substitutions were real, and none had been decided.

## The tier model

Every tool is declared in exactly one tier, and the build **fails** if a tool
resolves from a different tier than the one it is declared in. Silent promotion
is as unwelcome as silent demotion: both mean the manifest stopped describing
reality.

| Tier | Source | What a differential diff means |
|---|---|---|
| **apple** (56 tools) | Apple's own source from [apple-oss-distributions](https://github.com/apple-oss-distributions) (APSL 2.0), compiled by us via nixpkgs `darwin.{system_cmds,shell_cmds,text_cmds,file_cmds,adv_cmds}` | **A bug.** Same program as the system binary, different build. |
| **near-twin** (5) | No Apple release, but macOS ships the same upstream: `libarchive`→`tar`, `nawk`→`awk`, plus `zsh`, `dash`, `xz` | Version skew. Review, don't panic. |
| **substitute** (3) | A genuinely different implementation: `bash` 5.x for Apple's bash 3.2.57, GNU `diff`/`cmp` for Apple's FreeBSD diff | **Expected.** This is the documented divergence risk. |
| **multicall** (3) | `argv[0]` modes of an already-bundled binary: `egrep`/`fgrep` on Apple's `grep`, `gunzip` on Apple's `gzip` | A bug, same as tier 1. |

Compiling Apple's own source is what makes tier 1 possible, and it is worth
being precise about why it works: the binary is behaviourally identical because
it *is* the same program, and AMFI permits it because it is an ad-hoc-signed
build of ours rather than an Apple platform binary. Both properties at once —
which is exactly what a reimplementation cannot offer and a relocated copy
cannot either.

`arch(1)` is the tool that motivated this repo, and it is the clearest case.
GNU coreutils' `arch` only *prints* the machine type; Apple's also **runs** a
chosen slice of a universal binary, and `nix` uses precisely that mode to probe
for Rosetta (`arch -arch x86_64 /usr/bin/true`). A GNU stand-in answers *wrong*
rather than merely unobserved. This repo first shipped a 329-line
reimplementation of it; Apple's is 802 lines, and the differential suite found
the gap (`-32`, and an invalid `ARCHPREFERENCE`, both silently succeeded when
they should have failed). Apple's own source now builds from nixpkgs and passes
all 19 cases.

The bundle records what it did in `PROVENANCE`: tool, tier, and the exact store
path it came from.

## Usage

```sh
nix build .#stackable-hooks-macos-tools
export CT_SANDBOX_TOOLS_DIR=$PWD/result     # io-mon / codetracer
export AH_SANDBOX_TOOLS_DIR=$PWD/result     # agent-harbor
```

As a flake input:

```nix
inputs.stackable-hooks-macos-tools.url = "github:metacraft-labs/stackable-hooks-macos-tools";
# then, in the dev shell:
#   export STACKABLE_HOOKS_TOOLS_DIR=${inputs.stackable-hooks-macos-tools.packages.${system}.default}
```

The output is relocatable: every Mach-O has its dylib closure bundled under
`lib/` and rewritten to `@executable_path`/`@loader_path`, so the directory runs
on a machine with no Nix at all. The build verifies this and refuses to publish
a bundle with a surviving `/nix/store` reference.

## Testing

```sh
nix run .#differential           # all tools
BUNDLE_DIR=./result tests/run-differential.sh sed grep arch
```

The suite runs each bundled tool and the SIP binary it replaces against the same
inputs in identical scratch directories, comparing **exit status, stdout, stderr
and the resulting directory tree**. What cannot be equal is normalised through
narrow rules — inode-sized integers, the two scratch paths, the two binary paths
— so a real difference still shows.

Current state: **106 cases, 0 tier-1 failures, 0 near-twin differences, 2
substitute differences** (GNU `diff -u`/`-c` header format versus Apple's).

Cases live one file per tool in `tests/cases/<tool>.cases`. Adding coverage is
adding lines there; the fixtures (`@f`, `@f2`, `@dir`, `@link`, `@gz`, `@tar`)
are materialised fresh for every case.

## What is not here yet

Four SIP binaries still have no drop-in, so a build that execs one still loses
the subtree behind it — and, because a Level 2 (unknown-scope) loss disables
cache *hits* for the rest of the session, it costs far more than the one edge:

| Tool | Status |
|---|---|
| `xcrun` | Not open source. [b-man/xcode-tools](https://github.com/b-man/xcode-tools) is a reimplementation covering `-find`, `-run`, `-sdk`, `-toolchain`, `--show-sdk-path` and `DEVELOPER_DIR`; needs a differential suite before it can be trusted. io-mon's `resolveAppleToolchainTool` currently sidesteps it by resolving the 12 toolchain tools once, at populate time. |
| `codesign` | Do not reimplement. [`rcodesign`](https://github.com/indygreg/apple-platform-rs) (Rust, full signing/notarisation/stapling) and [`nix-community/sigtool`](https://github.com/nix-community/sigtool) (ad-hoc signing, already used by nixpkgs) both exist. |
| `plutil` | [`libplist`'s `plistutil`](https://github.com/libimobiledevice/libplist) converts formats but is not flag-compatible; [`withgraphite/plutil`](https://github.com/withgraphite/plutil) claims drop-in status but was archived in July 2023. Most likely a small reimplementation. |
| `sw_vers` | Not in any Apple OSS release, but trivial: it reads `/System/Library/CoreServices/SystemVersion.plist`. |
