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

56 tools: the shells (`bash`, `dash`, `zsh`), the coreutils set, findutils,
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

- **A C compiler.** `/usr/bin/cc` is SIP-protected and un-injectable too, but
  substituting a *different* compiler changes what gets built, not just what
  gets observed. Reprobuild resolves a non-SIP compiler itself
  (`REPRO_BOOTSTRAP_CC`, and its PATH search prefers one).
- **`arch(1)`.** There is no non-Apple build with Apple's semantics
  (`arch -x86_64 …`). It stays un-injectable until the EndpointSecurity
  backend lands. An explicit gap beats a drop-in that silently misbehaves.
