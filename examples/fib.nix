# Recursive function via `rec` / lazy self-reference
let
  fib = n:
    if n < 2 then n
    else fib (n - 1) + fib (n - 2);
in
builtins.map fib [0 1 2 3 4 5 6 7 8 9 10]
