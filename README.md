# ZIX — The Nix language in Zig

[![CI](https://github.com/primeid/zix/actions/workflows/ci.yml/badge.svg)](https://github.com/primeid/zix/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **The Nix expression language, reimplemented in Zig — bit-for-bit compatible with Nix 2.34.**

ZIX is an independent implementation of the **Nix expression language** in
[Zig](https://ziglang.org) 0.16. It evaluates Nix expressions and produces
store paths, `.drv` files and derivation attributes that are **identical** to
what the real `nix` produces — every single path result is verified against
Nix 2.34.7.

**What makes ZIX interesting:**
- 🎯 **Compatibility as a testable property** — tests compare against real Nix output.
- ⚡ **Fast** — a 50 000-element `foldl'` in ~80 ms; a lazy evaluator with memoized thunks.
- 🔍 **Small and readable codebase** — ~9 000 lines of Zig, zero runtime dependencies.
- 🧩 **Built from Nix's own source** — the algorithms are modeled directly on
  `path.cc`, `derivations.cc`, `parser.y`, `lexer.l` with exactly the same semantics.

---

## Building and running

Requirements: [Zig 0.16.0](https://ziglang.org/download/) (or `nix develop` for a ready-made environment).

```console
$ zig build            # builds zig-out/bin/zix (ReleaseSafe by default)
$ zig build test       # 24 tests, incl. store-path verification against real Nix
```

```console
$ zix eval -E '1 + 2 * 3'
7
$ zix eval -E 'builtins.map (x: x * x) [1 2 3 4]'
[ 1 4 9 16 ]
$ zix eval --read-only -E '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; }).drvPath' --raw
/nix/store/k79611g7bg62d41fh6bvm7xpf1dl2x91-testdrv.drv   # = real nix
```

Options: `--raw` (raw strings), `--read-only` (don't write to the store),
`--store-dir DIR` (own store, e.g. `/tmp/zs`), `-I path` / `NIX_PATH`
for `<nixpkgs>` lookup, `zix parse FILE` (lex+parse only).

Examples live in [`examples/`](examples/).

## Architecture

| Module | Contents |
|---|---|
| `src/lexer.zig` | Tokenization faithful to `lexer.l`: paths, URIs, `"…"` and `''…''` strings with interpolation, comments |
| `src/parser.zig` | Recursive-descent parser faithful to `parser.y`: the whole grammar, precedence, `stripIndentation` bit-for-bit |
| `src/value.zig` | Values: int/float/bool/null, strings with derivation context, lists, attrsets, lambdas, thunks |
| `src/eval.zig` | Lazy evaluator: memoized thunks, `rec`/`let`/`with`, scoping, deep equality, string concatenation |
| `src/builtins.zig` | ~85 primops: arithmetic, lists, attrsets, strings+regex, JSON, files/store, `import`, `derivationStrict` + `derivation` wrappers |
| `src/drv.zig` | `.drv` ATerm serialization/parsing and `hashDerivationModulo` |
| `src/store.zig` | Store path computation (`makeStorePath`/`makeOutputPath`/`makeFixedOutputPath`/`makeTextPath`), NAR serialization |
| `src/nixhash.zig` | SHA-256, base16, Nix base32 ("nix32"), hash compression |

All hashing and path logic is modeled directly on the Nix source
(`path.cc`, `store-dir-config.cc`, `derivations.cc`, `hash.cc`, `archive.cc`,
`parser.y`, `lexer.l`) and verified against `nix 2.34.7` on this machine:
`builtins.toFile`, input-addressed derivations, fixed-output
(flat + recursive) and derivations with input references produce exactly the
same store paths.

## Status

**Done and verified against Nix 2.34.7:**

- **The whole language**: literals, strings/interpolation, indented strings,
  paths, operators (`+ - * / // ++ == != < > <= >= && || -> ! ?`), attrsets
  (incl. `inherit`, dynamic attributes, nesting), `let`/`rec`/`with`/
  `assert`/`if`, lambdas with formals/defaults/`@`, lists,
  `<nixpkgs>` lookup, `import`.
- **Lazy evaluation** with memoization, cycle detection and deep-recursion protection.
- **Derivations**: `builtins.derivation`/`derivationStrict` → correct
  `.drv` files and `drvPath`/`outPath` (input-addressed, fixed-output flat+recursive,
  multi-output).
- **~85 builtins**: `map`, `foldl'`, regex (`match`/`split`), `replaceStrings`,
  `compareVersions`, JSON, `hashString`, `toFile`, `readFile`, `readDir`,
  `path`, `placeholder`, `tryEval`, `genericClosure` and much more.

**Verification methodology:** a comparison battery of 165 expressions runs
each expression in both `zix` and real `nix 2.34.7` and requires identical
results — language, builtins and derivation paths. See
[CONTRIBUTING](CONTRIBUTING.md) for how to run it yourself.

## Roadmap

The big picture — a detailed, phased plan with milestones and verification
criteria lives in **[ROADMAP.md](ROADMAP.md)**. The short version:

- [ ] **The realisation layer** (`zix build`): run builders (sandboxed, on
      POSIX) and produce outputs. Evaluation is complete; execution remains.
- [ ] **More builtins**: `fetchGit`, `fetchTarball`, `fetchurl`, `fromTOML`,
      `__structuredAttrs`, `builtins.path` flags, `scopedImport`,
      dynamic derivations.
- [ ] **Nixpkgs evaluation**: `import <nixpkgs> {}` at full scale (milestone:
      `zix build (import <nixpkgs> {}).hello`).
- [ ] **Position tracking** in the AST (Nix-style error messages and
      `«lambda @ «file»:line:col»` output).

Ideally as a [contribution](CONTRIBUTING.md) — Phase 4 (positions) is the best
starting point for new contributors.

## Known deviations from Nix

Conscious and documented differences:

- **Extra builtins** that Nix 2.34 lacks: `bitNot`, `toUpper`, `toLower`,
  `take`, `drop`, `reverseList`, `currentSystem` — compatibility-friendly extensions.
- **`|>` / `<|`** (pipe operators) are enabled by default; Nix requires
  `--extra-experimental-features pipe-operators`.
- **Lambda printing** shows `«lambda»` without position (`«lambda @ «string»:1:3»`
  in Nix) — position tracking is on the roadmap.
- **Error messages** behave the same (the same cases fail), but the text is
  often shorter than Nix's.
- `nixVersion` reports `2.34.7` (for compatibility), `langVersion` = 6.

## Contributing

ZIX is a small project that depends on its contributors. Interested in
language implementations, Zig, Nix, or just think this is fun?

- Check [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines and concrete tasks.
- Read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- See [Roadmap](#roadmap) for what matters most.
- Issues and PRs are welcome — small, focused changes with tests move fastest.

## Analysis: why (and why not) rewrite Nix in Zig

The following is a walkthrough of the benefits, costs and risks of rewriting
the Nix language/implementation from C++/OCaml to Zig — included in full.

If you mean **rewriting the Nix language or the Nix evaluator/implementation from C++/OCaml to Zig**, there are several possible benefits, but also significant costs.

### Possible benefits of Zig

| Area | Potential benefit |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Performance** | Low overhead and good control over memory and data structures can give faster evaluation and lower resource usage. |
| **Memory usage** | Explicit memory management and allocators make it possible to optimize memory consumption more precisely. |
| **Simpler codebase** | Zig is a relatively small and consistent language compared with C++ and can reduce the complexity of the implementation. |
| **Portability** | Zig has excellent cross-compilation and can make it easier to build Nix components for Linux, macOS, Windows and other platforms. |
| **C interoperability** | Zig integrates directly with C libraries without needing an extensive FFI layer. This is relevant to Nix's existing ecosystem. |
| **Error handling** | Zig has explicit error handling, which can make critical parts of the evaluator and build-system code easier to follow. |
| **Fewer dependencies** | The Zig compiler is relatively self-contained and can potentially make bootstrap and distribution simpler. |
| **Safety** | Although Zig is not memory-safe in the same way as Rust, the language offers better tools for catching certain bugs than traditional C/C++. |
| **Developer productivity** | A smaller, more modern language model can make it easier for new developers to contribute than a large C++ codebase. |

### The biggest potential win

I believe the most interesting benefit is not necessarily **raw performance**, but **maintainability and portability**.

Nix is in practice several things at once:

```text
Nix language
     │
     ▼
Parser
     │
     ▼
AST / evaluator
     │
     ▼
Derivations
     │
     ▼
Store / builds
     │
     ▼
Sandboxing
     │
     ▼
Binary caches / deployment
```

If the core implementation were written in Zig, one could potentially get a **smaller, more homogeneous and more easily portable runtime**. That could make it easier to run Nix components on more platforms and build them from source.

### But: Zig does not necessarily solve Nix's biggest problems

It is important to distinguish between:

**The Nix language as a language**
and
**Nix as a complete system**.

If the problem is, for example:

* slow evaluation
* poor error handling
* a complicated codebase
* difficult debugging
* poor Windows support
* high resource usage

Zig can potentially help.

But if the problem is:

* the complexity of the Nix expression language
* laziness
* hermetic builds
* dependency graphs
* reproducibility
* flakes
* UX
* the enormous complexity of Nixpkgs

then a rewrite in Zig will **not automatically solve this**. The problems are simply moved to a new implementation.

### My assessment

If the goal were to modernize Nix, I would **not rewrite all of Nix in Zig from day one**. I would consider a gradual architecture:

```text
              Existing Nix
                   │
        ┌──────────┴──────────┐
        │                     │
   Existing code          New Zig components
                              │
                    ┌─────────┼─────────┐
                    │         │         │
                 Parser    Evaluator   Store
                    │         │         │
                    └─────────┴─────────┘
                              │
                       Compatibility
                              │
                         Nix ecosystem
```

Then one could first write **a new evaluator in Zig**, benchmark it against today's Nix and gradually replace components if the benefits actually materialize.

**In short:** Zig can potentially give Nix **lower resource usage, easier cross-compilation, a more manageable implementation and better control over runtime performance**. The biggest risk is spending many years rewriting an enormous and complex system without solving the underlying problems that actually make Nix difficult.

If you really mean **rewriting the Nix expression language itself into a new language with Zig as the implementation language**, the analysis is quite different. Then I can also compare **Nix vs. a hypothetical "Zig-Nix"** architecture, including how to preserve backward compatibility with Nixpkgs.

## License

MIT — see [LICENSE](LICENSE).
