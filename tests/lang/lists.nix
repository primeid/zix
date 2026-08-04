builtins.foldl' (acc: x: acc + x) 0 (builtins.map (x: x * x) [1 2 3 4])
