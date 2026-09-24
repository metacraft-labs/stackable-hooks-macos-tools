# stackable-hooks-macos-tools

A relocatable bundle of **non-SIP macOS command-line tools**, shared by every
implementation of the stackable-hooks framework.

## Why this exists

macOS System Integrity Protection strips `DYLD_INSERT_LIBRARIES` when a binary
under `/bin`, `/sbin`, `/usr/bin` or `/usr/sbin` is exec'd. An interpose-based
monitor therefore goes blind the moment a monitored process shells out to
`/bin/sh`, `/usr/bin/grep` or `/usr/bin/sed` — and it goes blind *silently*,
which for a dependency-capturing monitor is the cardinal sin: an incomplete
input set reported as complete is a false cache hit.

The fix is to exec a **different build** of the same tool. It cannot be a copy
of the Apple binary: AMFI `SIGKILL`s a relocated copy of a platform binary on
launch, even ad-hoc re-signed. So the drop-in has to be a genuinely non-Apple
build — GNU coreutils, GNU grep, bash — laid out in the shape of the SIP
filesystem so a hook can rewrite `/usr/bin/grep` to `<bundle>/usr/bin/grep`.

## Why it is its own repository

Every stackable-hooks implementation needs the same tools:

| Consumer | Uses them for |
|---|---|
| `nim-stackable-hooks` | the Nim framework's SIP path rewriting (`rewriteSipPath`) |
| `io-mon` | dependency capture across a SIP boundary |
| `reprobuild` | monitored build actions (and, through them, the action cache) |
| `codetracer` | recording across SIP-protected children |
| Agent Harbor | the Rust implementation's `sandbox-tools` component |

The tools belong to none of them, and until this repository existed each
consumer either built its own bundle or scanned `$PATH` and hoped. So it is
one package, built once, depended on by name — see
`metacraft-specs/infrastructure/package-distribution.md` §8.

## What the bundle contains

```text
<bundle>/bin/<tool>        # mirrors /bin      (bin/sh is bash)
<bundle>/usr/bin/<tool>    # mirrors /usr/bin
<bundle>/lib/*.dylib       # bundled non-system dylibs
```

56 portable tools: the shells (`bash`, `dash`, `zsh`), the coreutils set, findutils,
GNU grep/sed/awk, tar/gzip/xz, and `which`/`diff`/`cmp`. Every Mach-O is
rewritten with `install_name_tool` so it carries **no `/nix/store`
references** and runs on a machine without Nix — the bundle is a package
payload, not a symlink farm.

## Why the tool set is pinned rather than scanned

`build-bundle.sh` is lifted from io-mon's `scripts/build-sandbox-tools.sh`,
which resolves each tool against the ambient `$PATH` and skips what it cannot
find. That is the right fallback for a repository with no pinned tool set, and
it is exactly what this package removes. Measured on a stock macOS shell:

| Source | Tools | Result for `bash -c '/usr/bin/sed …; /usr/bin/grep …'` |
|---|---|---|
| `$PATH` scan | 41 of 56 (no `grep`, `sed`, `awk`, `find`, `tar`, `xz`, `diff`, …) | **2 event-losses** — both SIP execs un-injectable |
| this package | 56 of 56 | **0 event-losses** — subtree fully captured |

Two losses is not two missing records: an unknown-scope loss disables the
action-cache publish for the whole session. A bundle whose contents depend on
the host is therefore not a package, and `build-bundle.sh` here **fails** when
a tool cannot be resolved (`SANDBOX_TOOLS_STRICT=0` to override).

## Building

```bash
nix build .#stackable-hooks-macos-tools     # -> ./result
```

The tool set comes from this flake's pinned nixpkgs; the bundle is a function
of `flake.lock` and nothing else.

## Using it

Point the discovery variable at the bundle:

```bash
export CT_SANDBOX_TOOLS_DIR=$(nix build --no-link --print-out-paths .#default)
```

Discovery order for a consumer is: the explicit variable, then the packaged
prefix installed by the package, then — as a last resort — a `$PATH` scan.
The variable name is being unified across implementations
(`CT_SANDBOX_TOOLS_DIR` in io-mon, `AH_SANDBOX_TOOLS_DIR` in Agent Harbor);
see the open question in the packaging spec.

## What it deliberately does not ship

- **A C compiler.** Not because the compiler does not need a drop-in — it very
  much does, `/usr/bin/cc` being a SIP-protected `xcode_select` shim — but
  because the right drop-in is not a shipped binary. `xcrun -f clang` resolves
  Apple's *own* compiler at a path outside every SIP prefix, signed
  `flags=0x0(none)`, which takes the injection normally. So the toolchain
  drop-ins (`cc`, `clang`, `c++`, `clang++`, `cpp`, `ld`, `as`, `ar`, `nm`,
  `strip`, `lipo`, `libtool`) are **host-resolved symlinks created at populate
  time**, not payload: a redirect to the same binary the shim would have
  exec'd, so nothing about the build changes. See metacraft-labs/io-mon#18.
  Redistributing Apple's 290 MB toolchain would be neither legal nor useful.
Nothing else. `arch(1)` used to be on this list — see below.

## arch(1): reimplemented, because substituting it would answer wrong

GNU coreutils' `arch` only prints the machine type. Apple's also **runs a
chosen slice of a universal binary** (`arch -x86_64 prog`), and can set or
clear the child's environment on the way (`-e`, `-d`, `-c`). Dropping the GNU
one in would not lose an observation, it would produce a wrong answer: `nix`
probes for Rosetta with

```bash
arch -arch x86_64 /usr/bin/true
```

and a print-only `arch` exits 0 without running anything, reporting that
x86_64 execution works on a machine where it may not. (That invocation is not
hypothetical — it is the only `arch` call in a `nix print-dev-env` run here.)

So `src/arch.c` implements the two modes we can implement faithfully:

- **print** — via `NXGetArchInfoFromCpuType(…, CPU_SUBTYPE_MULTIPLE)`, the
  same source of truth Apple's binary uses, so quirks come along for free
  rather than being re-derived;
- **exec** — `posix_spawnattr_setbinpref_np` + `POSIX_SPAWN_SETEXEC`, which
  replaces this image in place, so the caller's `wait()` sees the target
  program and the monitor follows one process rather than inventing a
  generation.

Everything else — notably the per-application plist mode that `-e`/`-d`/`-c`
select when no architecture is given (`arch: Can't find any plists for …`) —
is **handed to `/usr/bin/arch` unchanged**. Losing the injection for that one
exec is the right trade: a wrong answer is worse than an unobserved one, and
the monitor records the loss.

`tests/arch-differential.sh` compares ours against Apple's, invocation by
invocation, including the delegated cases. It caught two divergences that
would otherwise have shipped: `arm64e` where Apple prints `arm64` (the local
arch info carries the subtype), and posix_spawnp's errno text with exit 127
where Apple says `<prog> isn't executable` and exits 1. Current score on
aarch64-darwin: **15/15**.

One consumer-side fix was needed for this to pay off: a `SETEXEC` spawn was
recorded twice by io-mon's shim, which made a fully-monitored `arch` chain
report the very loss the drop-in removes (metacraft-labs/io-mon#30). With
both, `arch -arch arm64 prog` under the monitor goes from 1 event-loss to 0.
