# Architecture

ZIX is a from-scratch reimplementation of the Nix expression language in
Zig. It evaluates Nix expressions, computes Nix-compatible store paths
(bit-for-bit identical to Nix 2.34.7), and can build derivations in its own
store.

```
src/
  lexer.zig     Tokenizer — full Nix syntax incl. indented strings, paths,
                URIs, `<nixpkgs>` search paths, multi-line interpolation.
  parser.zig    Recursive-descent parser → AST (`ast.zig`), with source
                positions on every node.
  ast.zig       AST definitions (`Expr { pos, kind }`).
  eval.zig      The evaluator: lazy thunks with `unevaluated/evaluating/done`
                states, recursive attrsets via a recursive environment,
                `with` scopes, error traces, `call_depth` stack guard.
  value.zig     Runtime values: int, float, string+context, path+parts, bool,
                null, list, attrs (sorted), lambda, builtin, thunk.
  builtins.zig  ~90 builtins, including derivation, toFile, fetchurl/
                fetchTarball/fetchzip (curl), fetchGit, fromTOML/fromJSON,
                map/mapAttrs (lazy), regex match/split, and more.
  drv.zig       Derivation ATerm serialization + `hashDerivationModulo`
                (verified against Nix 2.34.7).
  store.zig     Store path computation (Nix32, NAR hashing), store writes,
                a JSON realisation index (`zix-db.json`).
  build.zig     The realisation layer: build planning (topological sort),
                builder execution, fixed-output hash validation, output
                registration.
  main.zig      CLI (`zix eval`, `zix parse`, `zix build`).
```

## Key design decisions

### Lazy evaluation with memoising thunks
Every non-trivial expression evaluates to a *thunk*: `{ expr, env, pos,
state, value }`. The state machine (`unevaluated → evaluating → done`)
memoises results and detects infinite recursion. Recursive attribute sets
(`rec` / `let ... in` bodies that reference siblings) share one environment
frame whose variable slots *are* the item values, so self-reference is
naturally lazy.

### Nix-identical store paths
Path computation mirrors Nix's algorithms exactly:

- **Nix32** base32 (`0123456789abcdfghijklmnpqrsvwxyz`), built from the end
  of the byte stream.
- **NAR** serialisation: `nix-archive-1` + typed nodes, u64-le lengths,
  8-byte padding.
- **Fingerprints**: `text:sha256:<hex>:<store>:<name>` for text paths,
  `source` for recursive, `fixed:out:` + digest for flat fixed-output,
  `output:out` for derivation outputs.
- **`hashDerivationModulo`**: input-addressed drv hashes verified against
  real Nix 2.34.7 for multi-input, fixed-output, and chained derivations.

The `tests/nix-vs-zix.sh` battery (run with `zig build verify`) compares 165
expressions against a real `nix` binary; 156 are byte-identical (the rest
are intentional: extra builtins and experimental operators).

### Nix 2.34 semantics
Where Nix's behavior changed over time, ZIX follows the installed Nix 2.34.7:

- String interpolation does **not** coerce non-strings (`"${42}"` is an
  error; use `toString`).
- `tryEval` catches only `assert` failures and `throw` (including
  search-path lookups, which Nix raises as `ThrownError`).
- `with` loses to lexical bindings.
- `-I` wins over `NIX_PATH`.
- Flat fixed-output paths use the modern `fixed:out:` scheme.

### Realisation (`zix build`)
`zix build <expr|file|drv>` plans the transitive input-drv graph
(topologically sorted, cycle-detected), runs each builder with the
derivation's environment (plus host defaults for PATH/HOME/TMPDIR), verifies
fixed-output hashes, and registers outputs in `zix-db.json`. Structured
attributes (`__structuredAttrs`) write `NIX_ATTRS_JSON_FILE`.

## Verification strategy

1. `zig build test` — unit + integration tests (26).
2. `zig build verify` — the 165-expression nix-vs-zix battery (requires
   `nix` on PATH).
3. `zig build lang` — golden tests for language features.
4. `zig build build-smoke` — end-to-end build in a temp store.
5. Fuzzing — random/adversarial inputs must never crash the CLI.

## Future work

See [ROADMAP.md](../ROADMAP.md): full `import <nixpkgs> {}` (blocked on the
module system's recursion), sandboxing, binary-cache substitution, `zix gc`.
