#!/usr/bin/env bash
# Smoke test for the realisation layer: build a small derivation in a temp
# store and verify the output contents.
set -u
ZIX="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zix"
STORE=$(mktemp -d)
trap 'rm -rf "$STORE"' EXIT

DRV=$("$ZIX" eval --store-dir "$STORE" -E '(builtins.derivation { name = "smoke"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "mkdir -p $out && echo smoke-ok > $out/result.txt" ]; }).drvPath' --raw 2>/dev/null)
[ -n "$DRV" ] || { echo "FAIL: could not create drv"; exit 1; }

OUT=$("$ZIX" build --store-dir "$STORE" "$DRV" 2>&1 | tail -1)
[ -n "$OUT" ] || { echo "FAIL: build produced no output"; exit 1; }

CONTENT=$(cat "$STORE"/*-smoke/result.txt 2>/dev/null)
if [ "$CONTENT" = "smoke-ok" ]; then
  echo "build smoke test: PASS ($OUT)"
else
  echo "FAIL: unexpected content: $CONTENT"
  exit 1
fi
