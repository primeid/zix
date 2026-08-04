#!/usr/bin/env bash
# Golden tests: evaluate tests/lang/*.nix and compare with the .exp file.
set -u
ZIX="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zix"
PASS=0; FAIL=0
for nix in "$(dirname "$0")"/lang/*.nix; do
  exp="${nix%.nix}.exp"
  got=$("$ZIX" eval "$nix" 2>&1 | head -1)
  want=$(cat "$exp")
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $nix"; echo "  want: $want"; echo "  got:  $got"; fi
done
echo "lang tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
