#!/bin/bash
#
# Differential test: our arch(1) against Apple's, invocation by invocation.
#
# This file is the reason the reimplementation is defensible. Emulating arch is
# easy to do ALMOST right, and almost-right is the dangerous outcome: a build
# that silently runs the wrong slice, or a Rosetta probe that answers yes on a
# machine that cannot. So every behaviour we claim is compared against the real
# binary on the machine running the test, and the ones we deliberately do not
# implement are compared too — they must delegate and come out identical.
#
# Two divergences this caught on the first run, both of which would have
# shipped:
#   * `arch` with no arguments printed `arm64e`, because NXGetLocalArchInfo()
#     carries the SUBTYPE. Apple prints `arm64`.
#   * a missing program produced posix_spawnp's errno text and exit 127, where
#     Apple says "<prog> isn't executable" and exits 1.
#
# Usage: tests/arch-differential.sh [path-to-our-arch]
set -uo pipefail
OURS="${1:-${SANDBOX_TOOLS_ARCH_BIN:-./result/bin/arch}}"
REAL=/usr/bin/arch

if [ "$(uname -s)" != "Darwin" ]; then
  echo "arch differential test is macOS-only (no-op on $(uname -s))"
  exit 0
fi
if [ ! -x "$OURS" ]; then
  echo "no arch binary at $OURS — build it first (nix build .#arch)" >&2
  exit 2
fi
pass=0; fail=0
cmp_case() {
  desc="$1"; shift
  # `_` is the shell's last-command variable and necessarily names the binary
  # that ran; filtering it compares behaviour rather than our own path.
  # Capture status BEFORE filtering: `ro=$(cmd | grep)` would report grep's
  # exit code, which is how a differential test quietly stops comparing the
  # thing it is named after.
  raw_r=$("$REAL" "$@" 2>&1); rc_r=$?
  raw_o=$("$OURS" "$@" 2>&1); rc_o=$?
  ro=$(printf '%s\n' "$raw_r" | grep -v "^_=")
  oo=$(printf '%s\n' "$raw_o" | grep -v "^_=")
  if [ "$rc_r" = "$rc_o" ] && [ "$ro" = "$oo" ]; then
    pass=$((pass+1)); printf "  ok   %-44s exit=%s\n" "$desc" "$rc_r"
  else
    fail=$((fail+1))
    printf "  FAIL %-44s\n       real: exit=%s [%s]\n       ours: exit=%s [%s]\n" \
      "$desc" "$rc_r" "$(echo "$ro"|head -1)" "$rc_o" "$(echo "$oo"|head -1)"
  fi
}
cmp_case "no args"
cmp_case "-arch x86_64 true"        -arch x86_64 /usr/bin/true
cmp_case "-arch arm64 echo"         -arch arm64 /bin/echo hi
cmp_case "-x86_64 true (legacy)"    -x86_64 /usr/bin/true
cmp_case "-arm64 true (legacy)"     -arm64 /usr/bin/true
cmp_case "-arch bogus"              -arch bogus /usr/bin/true
cmp_case "-64 true"                 -64 /usr/bin/true
cmp_case "-h"                       -h
cmp_case "-e without -arch (plist)" -e FOO=bar /usr/bin/env
cmp_case "-d without -arch (plist)" -d FOO /usr/bin/env
cmp_case "nonexistent program"      -arch arm64 /nonexistent-program-xyz
cmp_case "exit code passthrough"    -arch arm64 /bin/sh -c "exit 42"
echo "  --- env mutations (compare filtered output)"
for flags in "-e FOO=bar" "-d PATH" "-c"; do
  ro=$($REAL -arch arm64 $flags /usr/bin/env 2>&1 | grep -v "^_=" | sort)
  oo=$($OURS -arch arm64 $flags /usr/bin/env 2>&1 | grep -v "^_=" | sort)
  if [ "$ro" = "$oo" ]; then pass=$((pass+1)); printf "  ok   -arch arm64 %s env\n" "$flags";
  else fail=$((fail+1)); printf "  FAIL -arch arm64 %s env (diff %s lines)\n" "$flags" "$(diff <(echo "$ro") <(echo "$oo") | grep -c '^[<>]')"; fi
done
echo "pass=$pass fail=$fail"
