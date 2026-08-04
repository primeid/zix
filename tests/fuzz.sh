#!/bin/bash
# Fuzz smoke: random bytes + mutated nix expressions must not crash the CLI.
ZIX=./zig-out/bin/zix
CRASHES=0
python3 - <<'PYEOF' > /tmp/fuzz-inputs.txt
import random, os
random.seed(42)
fragments = ['let', 'in', 'rec', '{', '}', '[', ']', '(', ')', ':', ';', ',', '.', '=', '?', '@', '...', 'if', 'then', 'else', 'assert', 'with', 'inherit', 'or', '//', '++', '&&', '||', '->', '!"', '${', '$', '"', "'", '#', '/', '/*', '*/', 'builtins.', 'abort', 'throw', 'true', 'false', 'null', '123', '-5', '3.14', '"str"', "''indented''", 'x', 'f', '1 + 2', 'a.b', 'x: y', '{ a = 1; }', '[1 2 3]', '<nixpkgs>', '\x00', '\x7f', '\xff']
for i in range(400):
    n = random.randint(1, 40)
    s = ''.join(random.choice(fragments) for _ in range(n))
    print(s)
for i in range(200):
    n = random.randint(1, 200)
    print(os.urandom(n).decode('latin1'))
PYEOF
i=0
while IFS= read -r line; do
  i=$((i+1))
  timeout 5 $ZIX eval -E "$line" >/dev/null 2>&1
  rc=$?
  if [ $rc -eq 139 ] || [ $rc -eq 134 ] || [ $rc -eq 132 ]; then
    CRASHES=$((CRASHES+1))
    echo "CRASH rc=$rc on: ${line:0:80}" | tee -a /tmp/fuzz-crashes.txt
  fi
done < /tmp/fuzz-inputs.txt
echo "fuzz: $i inputs, $CRASHES crashes"
