#!/usr/bin/env bash
# Compare zix vs real nix on a battery of expressions.
# Requires: zig-out/bin/zix (zig build) and `nix` on PATH.
# Compare zix vs real nix on a battery of expressions.
ZIX="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zix"
PASS=0; FAIL=0; FAILED=()
cmp1() {
  local desc="$1"; local expr="$2"
  local z n ze ne
  z=$($ZIX eval -E "$expr" 2>&1 | head -3)
  n=$(nix eval --expr "$expr" 2>&1 | head -3)
  if [ "$z" = "$n" ]; then PASS=$((PASS+1)); return; fi
  ze=$(echo "$z" | grep -c error ); ne=$(echo "$n" | grep -c error)
  if [ "$ze" -gt 0 ] && [ "$ne" -gt 0 ]; then PASS=$((PASS+1)); return; fi
  FAIL=$((FAIL+1)); FAILED+=("$desc: zix=[$z] nix=[$n]")
}
cmp2() {
  # derivations: paths computed against /nix/store (zix read-only)
  local desc="$1"; local expr="$2"
  local z n
  z=$($ZIX eval --read-only -E "$expr" 2>&1 | head -3)
  n=$(nix eval --expr "$expr" 2>&1 | head -3)
  if [ "$z" = "$n" ]; then PASS=$((PASS+1)); return; fi
  ze=$(echo "$z" | grep -c error ); ne=$(echo "$n" | grep -c error)
  if [ "$ze" -gt 0 ] && [ "$ne" -gt 0 ]; then PASS=$((PASS+1)); return; fi
  FAIL=$((FAIL+1)); FAILED+=("$desc: zix=[$z] nix=[$n]")
}

# ---- literals / arithmetic ----
cmp1 "int" '42'
cmp1 "neg" '-5'
cmp1 "float" '1.5'
cmp1 "float0" '2.0'
cmp1 "add" '1 + 2'
cmp1 "prec" '1 + 2 * 3'
cmp1 "parens" '(1 + 2) * 3'
cmp1 "sub" '10 - 4 - 3'
cmp1 "div int" '7 / 2'
cmp1 "div float" '7.0 / 2'
cmp1 "mod" 'builtins.mod 7 3'
cmp1 "eq" '1 == 1'
cmp1 "neq" '1 != 2'
cmp1 "lt" '1 < 2'
cmp1 "le" '2 <= 2'
cmp1 "gt" '3 > 2'
cmp1 "ge" '3 >= 4'
cmp1 "bool eq" 'true == false'
cmp1 "null eq" 'null == null'
cmp1 "float eq" '1.5 == 1.5'
cmp1 "int float eq" '1 == 1.0'
cmp1 "not" '!true'
cmp1 "and sc" 'false && builtins.abort "x"'
cmp1 "or sc" 'true || builtins.abort "x"'
cmp1 "impl" 'false -> true'
cmp1 "update" '{ a = 1; } // { b = 2; }'
cmp1 "update override" '{ a = 1; } // { a = 2; }'
cmp1 "concat lists" '[1 2] ++ [3]'
cmp1 "bitand" 'builtins.bitAnd 12 10'
cmp1 "bitor" 'builtins.bitOr 12 10'
cmp1 "bitxor" 'builtins.bitXor 12 10'
cmp1 "bitnot" 'builtins.bitNot 1'
cmp1 "lessThan" 'builtins.lessThan "a" "b"'
cmp1 "hasAttr op" '{ a = 1; } ? a'
cmp1 "hasAttr op2" '{ a = 1; } ? b'

# ---- strings ----
cmp1 "str concat" '"a" + "b"'
cmp1 "str interp" 'let x = 42; in "v: ${x}"'
cmp1 "str interp nested" '"${"${"a"}"}"'
cmp1 "str escape" '"a\nb\tc"'
cmp1 "str dollar" '"cost: $5"'
cmp1 "str esc dollar" '"\${not}"'
cmp1 "indented" $'let s = \'\'\n  a\n    b\n  c\n\'\'; in s'
cmp1 "indented interp" $'let x = "X"; in \'\'\n  pre${x}post\n\'\''
cmp1 "indented esc" "''a''\$b'''c''"
cmp1 "indented dollar" "''\$ {x}''"
cmp1 "toString int" 'builtins.toString 42'
cmp1 "toString float" 'builtins.toString 1.5'
cmp1 "toString bool" 'builtins.toString true'
cmp1 "toString list" 'builtins.toString [1 2 3]'
cmp1 "toString null" 'builtins.toString null'
cmp1 "stringLength" 'builtins.stringLength "héllo"'
cmp1 "substring" 'builtins.substring 1 3 "hello"'
cmp1 "toUpper" 'builtins.toUpper "aBc"'
cmp1 "toLower" 'builtins.toLower "aBc"'
cmp1 "concatStringsSep" 'builtins.concatStringsSep "-" ["a" "b" "c"]'
cmp1 "replaceStrings" 'builtins.replaceStrings ["a" "b"] ["x" "y"] "banana"'
cmp1 "split" 'builtins.split "([ab])" "abc"'
cmp1 "match" 'builtins.match "([a-z]+)-([0-9]+)" "abc-123"'
cmp1 "match nomatch" 'builtins.match "([0-9]+)" "abc"'
cmp1 "splitVersion" 'builtins.splitVersion "1.2.3pre"'
cmp1 "parseDrvName" 'builtins.parseDrvName "foo-1.2.3"'
cmp1 "compareVersions" 'builtins.compareVersions "2.3.1" "2.3a"'
cmp1 "compareVersions2" 'builtins.compareVersions "1.0" "1.0.1"'

# ---- lists ----
cmp1 "list" '[1 2 3]'
cmp1 "list nested" '[ [1] [2 3] ]'
cmp1 "list empty" '[]'
cmp1 "map" 'builtins.map (x: x * 2) [1 2 3]'
cmp1 "filter" 'builtins.filter (x: x > 1) [1 2 3]'
cmp1 "foldl" 'builtins.foldl'"'"' (a: b: a + b) 0 [1 2 3 4]'
cmp1 "genList" 'builtins.genList (x: x * x) 5'
cmp1 "length" 'builtins.length [1 2 3]'
cmp1 "head" 'builtins.head [1 2 3]'
cmp1 "tail" 'builtins.tail [1 2 3]'
cmp1 "elemAt" 'builtins.elemAt [10 20 30] 1'
cmp1 "elem" 'builtins.elem 2 [1 2 3]'
cmp1 "concatLists" 'builtins.concatLists [[1] [2 3] []]'
cmp1 "concatMap" 'builtins.concatMap (x: [x x]) [1 2]'
cmp1 "all" 'builtins.all (x: x > 0) [1 2 3]'
cmp1 "any" 'builtins.any (x: x < 0) [1 2 3]'
cmp1 "take" 'builtins.take 2 [1 2 3 4]'
cmp1 "drop" 'builtins.drop 2 [1 2 3 4]'
cmp1 "reverseList" 'builtins.reverseList [1 2 3]'
cmp1 "sort" 'builtins.sort (a: b: a < b) [3 1 2]'
cmp1 "partition" 'builtins.partition (x: x > 1) [1 2 3]'
cmp1 "groupBy" 'builtins.groupBy (x: if x > 0 then "p" else "n") [1 -2 3]'
cmp1 "listToAttrs" 'builtins.listToAttrs [{ name = "a"; value = 1; } { name = "b"; value = 2; }]'
cmp1 "catAttrs" 'builtins.catAttrs "a" [{ a = 1; } { b = 2; } { a = 3; }]'
cmp1 "zipAttrsWith" 'builtins.zipAttrsWith (name: xs: builtins.length xs) [ { a = 1; } { a = 2; b = 3; } ]'
cmp1 "genericClosure" 'builtins.genericClosure { startSet = [{ key = 1; }]; operator = x: [ { key = 2; } ]; }'
cmp1 "isList" 'builtins.isList [1]'
cmp1 "typeOf list" 'builtins.typeOf [1]'

# ---- attrsets ----
cmp1 "attrset" '{ a = 1; b = "x"; }'
cmp1 "attrset empty" '{}'
cmp1 "attrNames" 'builtins.attrNames { b = 1; a = 2; }'
cmp1 "attrValues" 'builtins.attrValues { a = 1; b = 2; }'
cmp1 "getAttr" 'builtins.getAttr "a" { a = 1; }'
cmp1 "hasAttr" 'builtins.hasAttr "a" { a = 1; }'
cmp1 "removeAttrs" 'builtins.removeAttrs { a = 1; b = 2; c = 3; } ["a" "c"]'
cmp1 "intersectAttrs" 'builtins.intersectAttrs { a = 1; b = 2; } { b = 9; c = 3; }'
cmp1 "nested attrs" '{ a.b.c = 1; a.b.d = 2; }'
cmp1 "nested select" '{ a = { b = { c = 1; }; }; }.a.b.c'
cmp1 "inherit" 'let a = 1; b = 2; in { inherit a b; }'
cmp1 "inherit from" 'let x = { p = 1; q = 2; }; in { inherit (x) p q; }'
cmp1 "inherit string" 'let a = 1; in { inherit a; "b" = 2; }'
cmp1 "dynamic attr" 'let k = "dyn"; in { ${k} = 1; }'
cmp1 "dynamic path" 'let k = "d"; in { a.${k} = 1; }'
cmp1 "attr or" '{ a = { b = 1; }; }.a.c or 42'
cmp1 "functionArgs" 'builtins.functionArgs ({ a, b ? 1, ... }: a)'
cmp1 "isAttrs" 'builtins.isAttrs { a = 1; }'
cmp1 "isFunction lambda" 'builtins.isFunction (x: x)'
cmp1 "typeOf attrs" 'builtins.typeOf { a = 1; }'

# ---- control flow / functions ----
cmp1 "let" 'let x = 1; in x + 2'
cmp1 "let multi" 'let a = 1; b = a + 1; in b * 2'
cmp1 "rec" 'rec { a = 1; b = a + 1; c = b * 10; }.c'
cmp1 "with" 'with { a = 5; }; a'
cmp1 "with shadow" 'let a = 1; in with { a = 5; }; a'
cmp1 "with select" 'with { x = { y = 7; }; }; x.y'
cmp1 "lambda" '(x: x + 1) 41'
cmp1 "lambda curry" 'let f = x: y: x + y; in f 1 2'
cmp1 "formals" '({ a, b }: a + b) { a = 1; b = 2; }'
cmp1 "formals default" '({ a, b ? 10 }: a + b) { a = 1; }'
cmp1 "formals ellipsis" '({ a, ... }: a) { a = 1; b = 2; }'
cmp1 "formals at" '({ a, ... }@args: a + args.b) { a = 1; b = 2; }'
cmp1 "at formals" '(args@{ a, ... }: a + args.b) { a = 1; b = 2; }'
cmp1 "if" 'if 1 < 2 then "yes" else "no"'
cmp1 "assert pass" 'assert 1 == 1; 5'
cmp1 "let braces" 'let { a = 1; b = a + 1; } in b'
cmp1 "list of funcs" '[(x: x) (y: y)]'
cmp1 "pipe" '1 |> (x: x + 1)'
cmp1 "pipe back" '(x: x + 1) <| 1'
cmp1 "curpos" 'builtins.typeOf __curPos'
cmp1 "uri string" 'https://example.com/x'

# ---- JSON ----
cmp1 "toJSON" 'builtins.toJSON { a = 1; b = [true null "x"]; }'
cmp1 "toJSON nested" 'builtins.toJSON { a = { b = { c = [1 2]; }; }; }'
cmp1 "fromJSON" 'builtins.fromJSON "{\"a\": [1, 2.5, \"x\", true, null]}"'
cmp1 "fromJSON arr" 'builtins.fromJSON "[1, \"two\"]"'

# ---- misc builtins ----
cmp1 "hashString" 'builtins.hashString "sha256" "hello"'
cmp1 "baseNameOf" 'builtins.baseNameOf "/a/b/c.txt"'
cmp1 "dirOf" 'builtins.dirOf /a/b/c.txt'  # path, printed bare'
cmp1 "getEnv empty" 'builtins.getEnv "ZIX_NONEXISTENT_XYZ"'
cmp1 "seq" 'builtins.seq 1 2'
cmp1 "deepSeq" 'builtins.deepSeq { a = [1 2]; } 3'
cmp1 "isNull" 'builtins.isNull null'
cmp1 "typeOf null" 'builtins.typeOf null'
cmp1 "typeOf int" 'builtins.typeOf 1'
cmp1 "placeholder" 'builtins.placeholder "out"'
cmp1 "tryEval" 'builtins.tryEval (builtins.throw "boom")'
cmp1 "tryEval ok" 'builtins.tryEval (1 + 1)'
cmp1 "langVersion" 'builtins.langVersion'
cmp1 "nixVersion" 'builtins.nixVersion'
cmp1 "storeDir" 'builtins.storeDir'
cmp1 "nixPath" 'builtins.nixPath'
cmp1 "currentSystem" 'builtins.currentSystem'
cmp1 "unsafeDiscardStringContext" 'builtins.unsafeDiscardStringContext "abc"'

# ---- derivations (paths vs /nix/store) ----
cmp2 "drv basic" '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; })'
cmp2 "drv args" '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "echo hi" ]; })'
cmp2 "drv env" '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; FOO = "bar"; })'
cmp2 "drv multi-output" '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; outputs = [ "out" "dev" ]; })'
cmp2 "drv fixed flat" '(builtins.derivation { name = "f"; system = "x86_64-linux"; builder = "/bin/sh"; outputHash = "0a3666a0710c08aa6d0de92ce72beeb5b93124cce1bf3701c9d6cdeb543cb73e"; outputHashAlgo = "sha256"; outputHashMode = "flat"; })'
cmp2 "drv fixed rec" '(builtins.derivation { name = "f"; system = "x86_64-linux"; builder = "/bin/sh"; outputHash = "0a3666a0710c08aa6d0de92ce72beeb5b93124cce1bf3701c9d6cdeb543cb73e"; outputHashAlgo = "sha256"; outputHashMode = "recursive"; })'
cmp2 "drv ref toFile" 'let f = builtins.toFile "g" "hi"; in (builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; src = f; })'
cmp2 "drv toFile" 'builtins.toFile "name" "contents"'
cmp2 "drv chain" 'let a = builtins.toFile "a" "A"; b = builtins.toFile "b" "B"; in (builtins.derivation { name = "chain"; system = "x86_64-linux"; builder = "/bin/sh"; x = a; y = b; })'
cmp2 "placeholder" 'builtins.placeholder "out"'
cmp2 "drvStrict" '(builtins.derivationStrict { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; })'

echo "========================================"
echo "PASS: $PASS  FAIL: $FAIL"
if [ ${#FAILED[@]} -gt 0 ]; then printf '%s\n' "${FAILED[@]}" | head -40; fi
