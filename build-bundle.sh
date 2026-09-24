#!/usr/bin/env bash
# Build a self-contained, relocatable macOS drop-in tool bundle: non-SIP
# replacements for the SIP-protected system binaries that a monitored process
# tree shells out to (/bin/sh, /bin/cat, /usr/bin/grep, …).
#
# WHY THIS EXISTS (SIP / AMFI rationale — see
# reprobuild-specs/Portable-Macos-Sandbox-Tools.milestones.org and
# codetracer-specs §16.7.8):
#   On macOS 26 / Apple Silicon, System Integrity Protection strips
#   DYLD_INSERT_LIBRARIES when a binary under /bin, /sbin, /usr/bin, /usr/sbin
#   is exec'd, and AMFI SIGKILLs a *copy* of a restricted platform binary on
#   launch even when ad-hoc re-signed. So the io-mon monitor's SIP bypass
#   (rewriteExecPathForSip → rewriteSipPath) must redirect a SIP exec to a
#   binary WE provide that is NOT itself SIP/hardened. The injected shim then
#   loads into the drop-in and follows the process tree across the SIP boundary
#   instead of going blind.
#
# THE TIER MODEL — and why this script ENFORCES it.
#
# The bundle's first job is observability: a drop-in the shim can load into.
# Its second job is not to LIE while doing so. A drop-in that is observable but
# behaves differently from the binary it replaced converts an honest
# "unmonitored subtree" into a silent divergence: the monitor reports
# mcComplete over a build that did something other than what it would have done
# unmonitored. That is the worse failure, and it is the one this script exists
# to make impossible to introduce by accident.
#
# So every tool is declared in exactly one tier, and a tool that resolves from
# a tier OTHER than the one it is declared in fails the build:
#
#   APPLE_TOOLS       Apple's own source (apple-oss-distributions, APSL 2.0),
#                     compiled by us. Same program as the SIP binary, different
#                     build — behaviourally identical, and not an Apple
#                     platform binary, so AMFI lets it run and the injection
#                     survives. Everything that CAN be here MUST be here.
#   NEAR_TWIN_TOOLS   No Apple release, but macOS ships the same upstream
#                     program (bsdtar for tar, one-true-awk for awk), so we
#                     take that upstream at a different vintage.
#   SUBSTITUTE_TOOLS  A genuinely different implementation. The honest
#                     remainder. Each entry is a known divergence risk and is
#                     justified in flake.nix; shrinking this list is tracked
#                     work.
#
# The predecessor of this script scanned the ambient $PATH and took whatever it
# found — which on a nix dev shell meant GNU coreutils, GNU grep, GNU sed, gawk
# and gnutar standing in for BSD/Apple tools across the board. Every one of
# those was a tier-3 substitution nobody had decided to make: `stat -c` vs
# `stat -f`, `date -d` vs `date -v`, `sed -i` taking an argument or not.
# Declaring the tiers is what turned that from an invisible default into a
# reviewed list of ten.
#
# WHAT THIS PRODUCES:
#   A directory (default: build/sandbox-tools) shaped like the SIP filesystem,
#   so rewriteSipPath("/bin/cat", DIR) == "DIR/bin/cat" resolves:
#       DIR/bin/<tool>        (mirrors /bin)
#       DIR/usr/bin/<tool>    (mirrors /usr/bin)
#       DIR/bin/sh -> bash    (so a /bin/sh redirect lands on a real shell)
#       DIR/lib/<dylib>       (bundled non-system dylibs, if any)
#       DIR/PROVENANCE        (tool → tier → source store path, for auditing)
#   Every Mach-O is relocated with install_name_tool so it carries NO
#   /nix/store references and runs on a machine without Nix — this is the
#   distribution-grade drop-in source CT_SANDBOX_TOOLS_DIR can point at, vs the
#   dev-shell PATH symlinks that io-mon's populateReproSandboxTools drops in.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "build-bundle.sh is macOS-only (no-op on $(uname -s))" >&2
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_dir="${SANDBOX_TOOLS_OUT_DIR:-$here/build/sandbox-tools}"

path_apple="${SANDBOX_TOOLS_PATH_APPLE:-}"
path_near="${SANDBOX_TOOLS_PATH_NEAR:-}"
path_substitute="${SANDBOX_TOOLS_PATH_SUBSTITUTE:-}"

if [ -z "$path_apple" ]; then
  echo "SANDBOX_TOOLS_PATH_APPLE is required: this bundle is built from pinned" >&2
  echo "tool sets, never from the ambient PATH. Use the flake:" >&2
  echo "    nix build .#stackable-hooks-macos-tools" >&2
  exit 2
fi

# A tool that cannot be resolved is a build failure, not a warning: a consumer
# that finds 41 of 56 drop-ins loses the subtree behind the other 15 and is
# told nothing.
strict="${SANDBOX_TOOLS_STRICT:-1}"

# install_name_tool / otool: prefer the cctools the dev shell provides; fall
# back to the SIP /usr/bin copies (fine — we only READ + relocate with them).
otool_bin="$(command -v otool || echo /usr/bin/otool)"
install_name_tool_bin="$(command -v install_name_tool || echo /usr/bin/install_name_tool)"

# ── The tier manifest ───────────────────────────────────────────────────────
#
# Keep in sync with reproSandboxBinaries in io-mon's src/io_mon/fs_snoop.nim
# (same realistic tool set, different delivery). `nproc` and `gawk` are
# deliberately absent: macOS ships neither, so a drop-in for them substitutes
# nothing and only adds surface.

APPLE_TOOLS=(
  # system_cmds
  arch sysctl getconf hostinfo vm_stat
  # shell_cmds
  echo test true false env printf find xargs date uname id hostname
  which mktemp expr seq sleep pwd basename dirname realpath tee kill
  # text_cmds
  cat grep sed sort head tail tr cut wc uniq comm join paste od cksum
  # file_cmds
  ls cp mv rm mkdir rmdir ln stat readlink chmod touch df gzip
)

NEAR_TWIN_TOOLS=(
  tar   # bsdtar/libarchive — /usr/bin/tar IS bsdtar
  awk   # one-true-awk      — /usr/bin/awk IS one-true-awk
  zsh
  dash
  xz
)

SUBSTITUTE_TOOLS=(
  bash  # 5.x standing in for Apple's bash 3.2.57
  diff  # GNU diffutils standing in for Apple's FreeBSD diff
  cmp
)

# Multicall links: these tools are argv[0] modes of a binary already bundled,
# so they inherit its tier for free rather than pulling in a second program.
# Verified against Apple's builds (egrep/fgrep on text_cmds grep, gunzip on
# file_cmds gzip) — see tests/run-differential.sh.
declare -a MULTICALL=(
  "egrep:grep"
  "fgrep:grep"
  "gunzip:gzip"
)

is_sip_path() {
  case "$1" in
    /bin/* | /sbin/* | /usr/bin/* | /usr/sbin/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Some upstreams install the program under its own name rather than the macOS
# one: libarchive ships `bsdtar`, one-true-awk ships `nawk`. That rename is
# exactly what makes them the right twin — /usr/bin/tar IS bsdtar — so the
# bundle installs them under the macOS name and records the real source in
# PROVENANCE.
tool_source_name() {
  case "$1" in
    tar) echo bsdtar ;;
    awk) echo nawk ;;
    *) echo "$1" ;;
  esac
}

# Resolve a tool basename to a NON-SIP absolute path on one specific tier's
# path, following symlinks to the real Mach-O so we copy a relocatable file (a
# nix `sh` symlink points at bash; we want the bash binary).
resolve_in_path() {
  local name="$1" search="$2" dir cand real
  name="$(tool_source_name "$name")"
  local OLDIFS="$IFS"
  IFS=:
  # shellcheck disable=SC2086
  set -- $search
  IFS="$OLDIFS"
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    cand="$dir/$name"
    [ -f "$cand" ] || continue
    is_sip_path "$cand" && continue
    real="$(/bin/readlink -f "$cand" 2>/dev/null || true)"
    [ -n "$real" ] && cand="$real"
    is_sip_path "$cand" && continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

is_machO() { file "$1" 2>/dev/null | grep -q "Mach-O"; }

# A load-command path that the target machine already provides, and that must
# therefore be left alone rather than bundled.
is_system_dylib() {
  case "$1" in
    /usr/lib/* | /System/* | @rpath/* | @executable_path/* | @loader_path/*) return 0 ;;
    *) return 1 ;;
  esac
}

deps_of() {
  "$otool_bin" -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

# Copy $1 (a real Mach-O) to $out_dir/bin/$2. Dylib bundling happens later, in
# one fixed-point pass over everything — see bundle_dylib_closure.
copy_tool() {
  local src="$1" name="$2"
  local dest="$out_dir/bin/$name"
  cp "$src" "$dest"
  chmod u+w "$dest"
}

# Pull the TRANSITIVE closure of non-system dylibs into $out_dir/lib, then
# rewrite every reference — in the tools AND in the bundled dylibs themselves —
# to a relative @executable_path / @loader_path form.
#
# This is a worklist to a fixed point rather than the two hand-unrolled levels
# it replaces. Depth two happened to be enough for GNU coreutils; it is not
# enough in general, and the failure mode is quiet: the bundle builds, runs on
# the machine that built it, and dies on a machine without that /nix/store
# path. `bash -> libintl -> libiconv` is exactly three levels and was the case
# that exposed it.
bundle_dylib_closure() {
  local -a queue=()
  local f dep base

  for f in "$out_dir/bin"/*; do
    [ -f "$f" ] || continue
    is_machO "$f" || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] && ! is_system_dylib "$dep" && queue+=("$dep")
    done < <(deps_of "$f")
  done

  while [ "${#queue[@]}" -gt 0 ]; do
    dep="${queue[0]}"
    queue=("${queue[@]:1}")
    base="$(basename "$dep")"
    [ -f "$out_dir/lib/$base" ] && continue
    [ -f "$dep" ] || continue
    cp "$dep" "$out_dir/lib/$base"
    chmod u+w "$out_dir/lib/$base"
    while IFS= read -r sub; do
      [ -n "$sub" ] && ! is_system_dylib "$sub" && queue+=("$sub")
    done < <(deps_of "$out_dir/lib/$base")
  done

  # Now that the closure is complete, rewrite every reference in one pass.
  for f in "$out_dir/bin"/*; do
    [ -f "$f" ] || continue
    is_machO "$f" || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      is_system_dylib "$dep" && continue
      base="$(basename "$dep")"
      [ -f "$out_dir/lib/$base" ] || continue
      "$install_name_tool_bin" -change "$dep" \
        "@executable_path/../lib/$base" "$f" 2>/dev/null || true
    done < <(deps_of "$f")
  done

  for f in "$out_dir/lib"/*; do
    [ -f "$f" ] || continue
    is_machO "$f" || continue
    "$install_name_tool_bin" -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      is_system_dylib "$dep" && continue
      base="$(basename "$dep")"
      [ -f "$out_dir/lib/$base" ] || continue
      "$install_name_tool_bin" -change "$dep" \
        "@loader_path/$base" "$f" 2>/dev/null || true
    done < <(deps_of "$f")
  done
}

rm -rf "$out_dir"
mkdir -p "$out_dir/bin" "$out_dir/usr/bin" "$out_dir/lib"

provenance="$out_dir/PROVENANCE"
{
  echo "# stackable-hooks-macos-tools — bundled tool provenance"
  echo "# tier  tool  source"
  echo "#"
  echo "# tier=apple       Apple's own source (APSL 2.0), compiled by us."
  echo "# tier=near-twin   Same upstream program macOS ships, different vintage."
  echo "# tier=substitute  A DIFFERENT implementation — known divergence risk."
  echo "# tier=multicall   An argv[0] mode of an already-bundled binary."
} > "$provenance"

declare -a missing=()
declare -a wrong_tier=()
declare -a copied=()

# Resolve one declared tier. A tool declared in tier T must resolve in T's
# path; finding it ONLY in a lower-fidelity tier is a demotion we refuse to
# make silently, and finding a tier-3 tool in the Apple path is a promotion we
# want to hear about.
resolve_tier() {
  local name="$1" tier="$2" search="$3" src
  if src="$(resolve_in_path "$name" "$search")"; then
    copy_tool "$src" "$name"
    copied+=("$name")
    printf '%-10s %-10s %s\n' "$tier" "$name" "$src" >> "$provenance"
    return 0
  fi
  return 1
}

for name in "${APPLE_TOOLS[@]}"; do
  if ! resolve_tier "$name" apple "$path_apple"; then
    if resolve_in_path "$name" "$path_near:$path_substitute" > /dev/null; then
      wrong_tier+=("$name (declared apple; only found in a lower tier)")
    else
      missing+=("$name")
    fi
  fi
done

for name in "${NEAR_TWIN_TOOLS[@]}"; do
  if resolve_in_path "$name" "$path_apple" > /dev/null; then
    wrong_tier+=("$name (declared near-twin; Apple now ships it — promote it)")
    resolve_tier "$name" apple "$path_apple" || true
  elif ! resolve_tier "$name" near-twin "$path_near"; then
    missing+=("$name")
  fi
done

for name in "${SUBSTITUTE_TOOLS[@]}"; do
  if resolve_in_path "$name" "$path_apple" > /dev/null; then
    wrong_tier+=("$name (declared substitute; Apple now ships it — promote it)")
    resolve_tier "$name" apple "$path_apple" || true
  elif ! resolve_tier "$name" substitute "$path_substitute"; then
    missing+=("$name")
  fi
done

# bash provides the POSIX shell: expose it as `sh` so a /bin/sh SIP redirect
# lands on a real shell. macOS's /bin/sh is itself bash (3.2) in sh mode, so
# this mirrors the real topology rather than inventing one.
if [ -f "$out_dir/bin/bash" ]; then
  ln -sf bash "$out_dir/bin/sh"
  printf '%-10s %-10s %s\n' substitute sh "argv[0] mode of bundled bash" >> "$provenance"
fi

# argv[0] multicall modes of already-bundled binaries.
for entry in "${MULTICALL[@]}"; do
  link="${entry%%:*}"
  target="${entry##*:}"
  if [ -f "$out_dir/bin/$target" ]; then
    ln -sf "$target" "$out_dir/bin/$link"
    printf '%-10s %-10s %s\n' multicall "$link" "argv[0] mode of bundled $target" >> "$provenance"
  elif [ "$strict" = "1" ]; then
    echo "multicall link $link needs $target, which was not bundled" >&2
    exit 1
  fi
done

# Mirror every produced tool into usr/bin so a /usr/bin/<tool> SIP redirect
# resolves too (macOS ships many tools at BOTH /bin and /usr/bin; a test may
# invoke either path). Relative symlinks keep the bundle relocatable.
for f in "$out_dir/bin"/*; do
  [ -e "$f" ] || continue
  ln -sf "../../bin/$(basename "$f")" "$out_dir/usr/bin/$(basename "$f")"
done

# Pull in and relocate the transitive dylib closure, now that every tool has
# been copied. Doing it once at the end (rather than per-tool) is what makes
# the fixed point reachable.
bundle_dylib_closure

# Verify no /nix/store references remain in any bundled Mach-O.
portability_ok=1
for f in "$out_dir/bin"/* "$out_dir/lib"/*; do
  [ -f "$f" ] || continue
  if file "$f" 2>/dev/null | grep -q "Mach-O"; then
    if "$otool_bin" -L "$f" 2>/dev/null | tail -n +2 | grep -q "/nix/store"; then
      echo "WARNING: $f still references /nix/store:" >&2
      "$otool_bin" -L "$f" | tail -n +2 | grep "/nix/store" >&2
      portability_ok=0
    fi
  fi
done

echo "sandbox-tools bundle: $out_dir"
echo "  copied: ${#copied[@]} tools"
echo "  tiers:  apple=$(grep -c '^apple ' "$provenance" || true)" \
  "near-twin=$(grep -c '^near-twin ' "$provenance" || true)" \
  "substitute=$(grep -c '^substitute ' "$provenance" || true)" \
  "multicall=$(grep -c '^multicall ' "$provenance" || true)"

if [ "${#wrong_tier[@]}" -gt 0 ]; then
  echo "  TIER DRIFT — the manifest no longer matches reality:" >&2
  printf '    %s\n' "${wrong_tier[@]}" >&2
  echo "  Update the tier arrays in this script (and the rationale in" >&2
  echo "  flake.nix) rather than letting a tool change implementation" >&2
  echo "  silently." >&2
  [ "$strict" = "1" ] && exit 1
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "  MISSING (no non-SIP source in any declared tier): ${missing[*]}" >&2
  if [ "$strict" = "1" ]; then
    echo "  refusing to publish a partial bundle (SANDBOX_TOOLS_STRICT=0 to override)" >&2
    exit 1
  fi
fi

if [ "$portability_ok" -eq 1 ]; then
  echo "  portability: OK (no /nix/store references)"
else
  echo "  portability: INCOMPLETE (see warnings above)" >&2
  [ "$strict" = "1" ] && exit 1
fi
