# ZIX — The Nix language, in Zig

[![CI](https://github.com/primeid/zix/actions/workflows/ci.yml/badge.svg)](https://github.com/primeid/zix/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Lines of code](https://img.shields.io/badge/zig-~9.5k%20lines-38bdf8)](src)
[![Nix parity](https://img.shields.io/badge/nix%20parity-2.34.7-green)](https://github.com/primeid/zix/blob/main/tests/nix-vs-zix.sh)

> **An independent implementation of the Nix expression language in Zig —
> bit-for-bit compatible with Nix 2.34.7.**

ZIX evaluates Nix expressions and produces store paths, `.drv` files and
derivation attributes that are **identical** to what real `nix` produces.
Every result is verified against real Nix 2.34.7 in CI.

## Why ZIX?

- 🎯 **Compatibility is a testable property.** A 165-expression battery runs
  every case in both `zix` and real `nix` and requires identical output —
  language, builtins, and derivation store paths.
- ⚡ **Fast.** A 50 000-element `foldl'` evaluates in ~80 ms; a lazy evaluator
  with memoized thunks and cycle detection.
- 🔍 **Small and readable.** ~9 500 lines of Zig, zero runtime dependencies,
  no generated code.
- 🧩 **Faithful to the original.** Algorithms are modeled directly on Nix's
  own `parser.y`, `lexer.l`, `derivations.cc`, `store-dir-config.cc`,
  `archive.cc` and `hash.cc`.

## Features

- **The whole language**: literals, strings + interpolation, indented strings,
  paths, operators (`+ - * / // ++ == != < > <= >= && || -> ! ?`),
  attrsets (`inherit`, dynamic attributes, nesting), `let`/`rec`/`with`/
  `assert`/`if`, lambdas with formals/defaults/`@`-patterns, lists,
  `<nixpkgs>` lookup, `import`, `scopedImport`.
- **All 107 Nix 2.34.7 builtins**, including `derivation`/`derivationStrict`,
  `fetchurl`, `fetchTarball`, `fetchzip`, `fetchGit`, `fetchTree`,
  `fromTOML`, `toXML`, `hashString` (md5/sha1/sha256/sha512), regex
  (`match`/`split`, POSIX classes, capture groups), JSON, `placeholder`,
  `__structuredAttrs`, `tryEval`, `genericClosure` and more.
- **Derivations**: input-addressed, fixed-output (flat + recursive),
  multi-output, content-addressed/floating — `.drv` files and store paths
  byte-identical to Nix.
- **`zix build`**: realises derivations (and their inputs) in a writable
  store, verifies fixed-output hashes, registers outputs in a JSON store
  database, and supports **sandboxed builds** via bubblewrap (network
  isolation, read-only store, restricted writes).
- **`zix gc`**: garbage-collects unreachable store objects.
- **Pure/impure evaluation** exactly like `nix eval` / `nix eval --impure`.

## Building

Requirements: [Zig 0.16.0](https://ziglang.org/download/) — or `nix develop`
for a ready-made environment.

```console
$ zig build            # builds zig-out/bin/zix (ReleaseSafe by default)
$ zig build test       # 27 unit tests
$ zig build verify     # nix-vs-zix comparison battery (165 cases, needs `nix`)
$ zig build lang       # golden language tests
$ zig build fuzz       # structured fuzzing vs nix
```

A static, dependency-free binary is just a target flag away:

```console
$ zig build -Dtarget=x86_64-linux-musl
```

## Usage

```console
$ zix eval -E '1 + 2 * 3'
7
$ zix eval -E 'builtins.map (x: x * x) [1 2 3 4]'
[ 1 4 9 16 ]
$ zix eval --read-only -E '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; }).drvPath' --raw
/nix/store/k79611g7bg62d41fh6bvm7xpf1dl2x91-testdrv.drv   # identical to real nix
```

| Command | Purpose |
|---|---|
| `zix eval [-E EXPR | FILE]` | Evaluate (pure mode by default) |
| `zix eval --impure` | Allow paths, `currentSystem`, environment (like `nix eval --impure`) |
| `zix eval --json` | Print the result as JSON |
| `zix eval -A path` | Select an attribute path from the result |
| `zix eval --arg name value` / `--argstr` | Pass arguments (file targets) |
| `zix eval --read-only` | Compute store paths without writing |
| `zix parse FILE` | Lex + parse only |
| `zix build [--sandbox] [--dry-run] TARGET` | Realise a derivation (file, expression, or `.drv`) |
| `zix gc [--delete]` | Garbage-collect unreachable store objects |
| `--store-dir DIR` | Use a custom store (e.g. `/tmp/zs`) |
| `-I path`, `NIX_PATH` | Search path for `<nixpkgs>` |
| `--extra-experimental-features extra-builtins,pipe-operators` | Enable ZIX extensions |

### Example

```console
$ zix build --store-dir /tmp/zs examples/hello.nix
$ zix build --store-dir /tmp/zs --sandbox --dry-run x.drv
```

## Nix compatibility

ZIX targets **Nix 2.34.7** and verifies the following properties in CI:

- All 165 battery expressions produce identical output (values, errors, and
  derivation store paths) in `zix` and real `nix`.
- `builtins.toFile`, input-addressed, fixed-output (flat + recursive) and
  reference-carrying derivations produce byte-identical store paths.
- The full `import <nixpkgs> {}` bootstrap evaluates (`pkgs.system`,
  `pkgs.hello.name = "hello-2.12.3"`).

**Documented deviations** (all opt-in or cosmetic):

- `nixVersion` reports `2.34.7` (the compatibility target).
- ZIX ships a few extra builtins (`bitNot`, `toUpper`, `toLower`, `take`,
  `drop`, `reverseList`, `mapAttrs'`) and pipe operators (`|>`, `<|`), hidden
  behind `--extra-experimental-features` by default — mirroring how Nix gates
  its own experimental features.
- `fetchGit`/`fetchTree` hash the full repository (including `.git`), while
  Nix uses git's tree hash — store paths for *sources* differ; language and
  derivation behaviour are unaffected.

## Architecture

| Module | Contents |
|---|---|
| `src/lexer.zig` | Tokenization faithful to `lexer.l`: paths, URIs, strings, interpolation |
| `src/parser.zig` | Recursive-descent parser faithful to `parser.y`: full grammar, precedence, `stripIndentation` |
| `src/eval.zig` | Lazy evaluator: memoized thunks, `rec`/`let`/`with`, scoping, deep equality, concatenation |
| `src/value.zig` | Values: int/float/bool/null, strings with derivation context, lists, attrsets, lambdas, thunks |
| `src/builtins.zig` | All 107 primops |
| `src/drv.zig` | `.drv` ATerm serialization and `hashDerivationModulo` |
| `src/store.zig` | Store path computation, NAR serialization, store database |
| `src/nixhash.zig` | SHA-256, md5, sha1, sha512, base16, Nix base32 |
| `src/build.zig` | Realisation: planning, builder execution, sandboxing |
| `src/fsutil.zig` | Portable filesystem helpers |

Deeper write-ups: [architecture](docs/architecture.md), [store format](docs/store.md).

## Roadmap

The detailed phased plan lives in **[ROADMAP.md](ROADMAP.md)**. Short version:

- ✅ Phases 0–5 of the core (language, builtins, derivations, build,
  sandbox, gc, fuzzing, docs) — done and CI-green on 3 OSes.
- 🔜 Beyond 1.0: flakes, binary-cache substitution, a full nixpkgs
  `zix build (import <nixpkgs> {}).hello` end-to-end.

## Contributing

ZIX is a small project that depends on its contributors. Whether you are into
language implementation, Zig, Nix, or just think this is fun — there is a
place for you.

- [CONTRIBUTING.md](CONTRIBUTING.md) — guidelines, testing workflow, concrete tasks.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — be kind.
- [SECURITY.md](SECURITY.md) — how to report vulnerabilities.
- [CHANGELOG.md](CHANGELOG.md) — what changed.
- [Issues](https://github.com/primeid/zix/issues) and
  [PRs](https://github.com/primeid/zix/pulls) are welcome — small, focused
  changes with tests move fastest.

## Background

Why (and why not) rewrite Nix in Zig — a full analysis of the trade-offs, in
[`docs/analysis-notes.md`](docs/analysis-notes.md).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Magnus Lislevatn.
