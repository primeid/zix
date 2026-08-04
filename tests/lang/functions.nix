let f = { a, b ? 10, ... }@args: a + b + (args.c or 0); in f { a = 1; c = 100; }
