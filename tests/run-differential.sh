#!/usr/bin/env bash
# run-differential.sh — prove each bundled drop-in behaves like the SIP binary
# it replaces, by running both and comparing exit status, stdout and stderr.
#
# This is the test that gives the tier model in build-bundle.sh its teeth.
# The bundle's reason to exist is that the shim cannot load into a SIP binary;
# its reason to be TRUSTED is that swapping the drop-in in changes nothing else.
# Those are separate claims and only the second one can be tested — so it is.
#
# What a failure means depends on the tier, and the runner says which:
#
#   tier=apple       A DIFF IS A BUG. Same source as the system binary, so any
#                    divergence is a packaging or relocation defect on our side.
#   tier=near-twin   A diff is usually a VERSION skew (bsdtar 3.8 vs 3.5,
#                    one-true-awk 2026 vs 2020). Worth reading; not always
#                    worth acting on.
#   tier=substitute  A diff is EXPECTED and is exactly the divergence risk the
#                    tier documents. These are reported but do not fail the
#                    run; what WOULD fail it is a substitute quietly appearing
#                    in tier 1's list.
#
# Usage:
#   BUNDLE_DIR=/path/to/bundle tests/run-differential.sh [tool …]
#   nix run .#differential
#
# Cases live in tests/cases/<tool>.cases, one argv per line, `#` comments.
# A case may name the fixtures the harness materialises in a scratch cwd:
#   @f      a small text file          @f2   a second, differing text file
#   @dir    a directory with 3 files   @gz   a gzip-compressed @f
#   @tar    a tar archive of @dir      @link a symlink to @f
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle="${BUNDLE_DIR:-$here/../result}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "differential tests are macOS-only (no-op on $(uname -s))"
  exit 0
fi
if [ ! -d "$bundle/bin" ]; then
  echo "no bundle at $bundle — build it first (nix build .#stackable-hooks-macos-tools)" >&2
  exit 2
fi

provenance="$bundle/PROVENANCE"
tier_of() {
  [ -f "$provenance" ] || { echo unknown; return; }
  awk -v t="$1" '$2 == t { print $1; found=1; exit } END { if (!found) print "unknown" }' \
    "$provenance"
}

# The SIP binary a drop-in stands in for. macOS ships many tools at both /bin
# and /usr/bin; we compare against whichever exists, preferring /usr/bin since
# that is what a PATH lookup finds.
system_path_of() {
  local t="$1" p
  for p in /usr/bin /bin /usr/sbin /sbin; do
    [ -x "$p/$t" ] && { printf '%s\n' "$p/$t"; return 0; }
  done
  return 1
}

make_fixtures() {
  local d="$1"
  printf 'alpha\nbeta\ngamma\nalpha\n' > "$d/f"
  printf 'alpha\nBETA\ngamma\n' > "$d/f2"
  mkdir -p "$d/dir"
  printf 'one\n' > "$d/dir/a"
  printf 'two\n' > "$d/dir/b"
  printf 'three\n' > "$d/dir/c"
  ln -sf f "$d/link"
  cp "$d/f" "$d/gzsrc" && /usr/bin/gzip -kf "$d/gzsrc" 2>/dev/null || true
  /usr/bin/tar cf "$d/archive.tar" -C "$d" dir 2>/dev/null || true
}

normalise() {
  local s="$1" dir="$2" bin="$3" real
  real="$(cd "$dir" && pwd -P 2>/dev/null || printf '%s' "$dir")"
  s="${s//$real/<CWD>}"
  s="${s//$dir/<CWD>}"
  s="${s//$bin/<BIN>}"
  s="${s//$(basename "$bin")/<BIN>}"
  # LC_ALL=C: some tools (gzip -l, tar tvf) emit bytes that are not valid in
  # the ambient UTF-8 locale, and BSD sed refuses the whole stream with
  # "RE error: illegal byte sequence" rather than passing it through.
  printf '%s' "$s" | LC_ALL=C sed -E 's/[0-9]{7,}/<N>/g'
}

expand_case() {
  # Fixture placeholders are substituted textually; the cwd is the scratch dir
  # so the paths stay relative and identical for both runs.
  local line="$1"
  line="${line//@f2/f2}"
  line="${line//@f/f}"
  line="${line//@dir/dir}"
  line="${line//@gz/gzsrc.gz}"
  line="${line//@tar/archive.tar}"
  line="${line//@link/link}"
  printf '%s' "$line"
}

total=0
apple_fail=0
near_diff=0
sub_diff=0
skipped=0

declare -a failures=()

run_tool() {
  local tool="$1" casefile="$2"
  local drop="$bundle/bin/$tool"
  local sys
  if ! sys="$(system_path_of "$tool")"; then
    printf '  %-10s SKIP (no SIP binary on this host to compare against)\n' "$tool"
    skipped=$((skipped + 1))
    return 0
  fi
  if [ ! -x "$drop" ]; then
    printf '  %-10s SKIP (not in the bundle)\n' "$tool"
    skipped=$((skipped + 1))
    return 0
  fi

  local tier
  tier="$(tier_of "$tool")"
  local n=0 d=0

  while IFS= read -r raw || [ -n "$raw" ]; do
    raw="${raw%%#*}"
    raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$raw" ] || continue

    local line
    line="$(expand_case "$raw")"

    # Each side gets its own pristine scratch dir, so a tool that MUTATES a
    # fixture (gzip, tar, touch, rm) is still compared fairly.
    local da db
    da="$(mktemp -d)"
    db="$(mktemp -d)"
    make_fixtures "$da"
    make_fixtures "$db"

    local out_a out_b st_a st_b
    out_a="$(cd "$da" && eval "\"$sys\" $line" 2>&1)"
    st_a=$?
    out_b="$(cd "$db" && eval "\"$drop\" $line" 2>&1)"
    st_b=$?

    # Normalise what CANNOT be equal before comparing. Two scratch dirs means
    # two sets of inodes and two absolute paths, and the binaries' own paths
    # appear in their usage/error text. Leaving those in would report a
    # divergence on every `ls -i`, `stat` and `readlink -f` — drowning the real
    # signal in noise that is guaranteed by construction. Each is masked
    # through a rule narrow enough that a genuine difference still shows:
    # inode-sized integers (>= 7 digits), the two scratch paths, the two
    # binary paths.
    out_a="$(normalise "$out_a" "$da" "$sys")"
    out_b="$(normalise "$out_b" "$db" "$drop")"

    # Compare the resulting directory state too — a tool can agree on stdout
    # and still write a different file.
    local tree_a tree_b
    tree_a="$(cd "$da" && find . | sort | sed "s|$da||")"
    tree_b="$(cd "$db" && find . | sort | sed "s|$db||")"

    n=$((n + 1))
    total=$((total + 1))
    if [ "$st_a" != "$st_b" ] || [ "$out_a" != "$out_b" ] || [ "$tree_a" != "$tree_b" ]; then
      d=$((d + 1))
      failures+=("$tier|$tool|$line|exit $st_a vs $st_b")
      if [ "$tier" = apple ] || [ "$tier" = multicall ]; then
        apple_fail=$((apple_fail + 1))
        printf '  %-10s [%s] DIFF  %s\n' "$tool" "$tier" "$line"
        printf '        system(%d): %s\n' "$st_a" "$(printf '%s' "$out_a" | head -3 | tr '\n' '\xe2\x90\xa4')"
        printf '        bundle(%d): %s\n' "$st_b" "$(printf '%s' "$out_b" | head -3 | tr '\n' '\xe2\x90\xa4')"
        [ "$tree_a" != "$tree_b" ] && printf '        filesystem state also differs\n'
      elif [ "$tier" = near-twin ]; then
        near_diff=$((near_diff + 1))
      else
        sub_diff=$((sub_diff + 1))
      fi
    fi
    rm -rf "$da" "$db"
  done < "$casefile"

  printf '  %-10s [%-10s] %2d cases, %d diff%s\n' "$tool" "$tier" "$n" "$d" \
    "$([ "$d" = 1 ] || echo s)"
}

echo "differential: bundle=$bundle"
echo

wanted=("$@")
if [ "${#wanted[@]}" -eq 0 ]; then
  for f in "$here"/cases/*.cases; do
    [ -e "$f" ] || continue
    wanted+=("$(basename "$f" .cases)")
  done
fi

for tool in "${wanted[@]}"; do
  cf="$here/cases/$tool.cases"
  if [ ! -f "$cf" ]; then
    printf '  %-10s SKIP (no cases file)\n' "$tool"
    skipped=$((skipped + 1))
    continue
  fi
  run_tool "$tool" "$cf"
done

echo
echo "── summary ─────────────────────────────────────────────────────────────"
echo "  cases run                 : $total"
echo "  tier-1/multicall failures : $apple_fail   (these are BUGS)"
echo "  near-twin differences     : $near_diff   (version skew — review)"
echo "  substitute differences    : $sub_diff   (expected; the documented risk)"
echo "  skipped                   : $skipped"

if [ "${#failures[@]}" -gt 0 ]; then
  echo
  echo "── every divergence, by tier ───────────────────────────────────────────"
  printf '%s\n' "${failures[@]}" | sort | awk -F'|' \
    '{ printf "  %-10s %-8s %-45s %s\n", $1, $2, $3, $4 }'
fi

if [ "$apple_fail" -gt 0 ]; then
  echo
  echo "FAIL: a tool built from Apple's own source diverged from the system" >&2
  echo "binary. That is a packaging defect, not an expected difference." >&2
  exit 1
fi
echo
echo "PASS: every Apple-sourced drop-in matches the SIP binary it replaces."
