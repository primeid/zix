#!/usr/bin/env bash
# Sandbox smoke test: network isolation + path restriction via bwrap.
set -euo pipefail
cd "$(dirname "$0")/.."
ZIX=./zig-out/bin/zix
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/net.nix" <<'NIX'
builtins.derivation {
  name = "net-test";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "curl -sS -m 3 https://example.com > $out 2>/dev/null || echo BLOCKED > $out" ];
}
NIX
cat > "$TMP/write.nix" <<'NIX'
builtins.derivation {
  name = "write-test";
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [ "-c" "touch /etc/zix-pwned 2>/dev/null && echo VULN > $out || echo RESTRICTED > $out" ];
}
NIX
for f in net write; do
  DRV=$($ZIX eval --store-dir "$TMP/store" -E "(import $TMP/$f.nix).drvPath" --raw 2>/dev/null | tail -1)
  $ZIX build --store-dir "$TMP/store" --sandbox "$DRV" >/dev/null 2>&1
done
N=$(cat "$TMP"/store/*-net-test 2>/dev/null | head -1)
W=$(cat "$TMP"/store/*-write-test 2>/dev/null | head -1)
[ "$N" = "BLOCKED" ] || { echo "FAIL: network not blocked (got '$N')"; exit 1; }
[ "$W" = "RESTRICTED" ] || { echo "FAIL: path not restricted (got '$W')"; exit 1; }
echo "sandbox smoke test: PASS"
