#!/usr/bin/env bash
# Structured fuzzing: generate valid Nix expressions from a grammar, evaluate
# them in both zix and nix, and require identical output.
set -uo pipefail
cd "$(dirname "$0")/.."
ZIX=./zig-out/bin/zix
python3 - <<'PY'
import random, subprocess, sys

random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 42)

def gen_expr(depth):
    if depth <= 0:
        return random.choice(["1", "-2", "3.5", '"heisann"', "true", "false", "null",
                             "[ ]", "[ 1 2 3 ]", "{ a = 1; }", '"x${" + str(random.randint(1,9)) + "}y"',
                             "x", "builtins.length [ 1 2 3 ]"])
    r = random.random()
    if r < 0.12:
        return f"({gen_expr(depth-1)} + {gen_expr(depth-1)})"
    if r < 0.2:
        return f"({gen_expr(depth-1)} == {gen_expr(depth-1)})"
    if r < 0.28:
        return f"if {gen_expr(depth-1)} then {gen_expr(depth-1)} else {gen_expr(depth-1)}"
    if r < 0.36:
        return f"let x = {gen_expr(depth-1)}; y = 2; in x"
    if r < 0.44:
        return f"({gen_expr(depth-1)} // {{ b = 2; }})"
    if r < 0.52:
        return f"builtins.map (x: x + 1) [ 1 2 3 {random.randint(0,9)} ]"
    if r < 0.6:
        return f"(builtins.elemAt [ {gen_expr(depth-1)} 5 6 ] {random.randint(0,2)})"
    if r < 0.68:
        return f"builtins.toString {gen_expr(depth-1)}"
    if r < 0.74:
        return f"builtins.concatStringsSep \"-\" [ \"a\" \"b\" \"c\" ]"
    if r < 0.8:
        return f"builtins.substring {random.randint(0,5)} {random.randint(0,5)} \"abcdef\""
    if r < 0.86:
        return f"builtins.attrNames {{ alpha = 1; beta = 2; gamma = 3; }}"
    if r < 0.92:
        return f"(x: x + {random.randint(1,9)}) {random.randint(1,9)}"
    return f"(builtins.sort (a: b: a < b) [ {random.randint(0,9)} {random.randint(0,9)} {random.randint(0,9)} ])"

fails = 0
N = int(sys.argv[2]) if len(sys.argv) > 2 else 200
for i in range(N):
    e = gen_expr(random.randint(1, 5))
    # wrap so both sides evaluate the same expression
    z = subprocess.run(["./zig-out/bin/zix", "eval", "-E", e], capture_output=True, text=True, timeout=20)
    n = subprocess.run(["nix", "eval", "--expr", e], capture_output=True, text=True, timeout=20)
    zok = z.returncode == 0
    nok = n.returncode == 0
    zout = z.stdout.strip()
    nout = n.stdout.strip()
    if zok != nok or (zok and zout != nout):
        fails += 1
        print(f"DIFF: {e!r}")
        print(f"  zix: [{zout}] rc={z.returncode}")
        print(f"  nix: [{nout}] rc={n.returncode}")
        if fails >= 5:
            print("too many diffs, stopping")
            break
if fails:
    print(f"structured fuzz: {N} cases, {fails} diffs")
    sys.exit(1)
print(f"structured fuzz: {N} cases, 0 diffs")
PY
