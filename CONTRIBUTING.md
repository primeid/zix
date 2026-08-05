# Contributing to ZIX

Thanks for considering contributing! ZIX is a focused project with one goal:
**a bit-for-bit Nix-2.34-compatible implementation of the Nix expression
language in Zig**. All contributions that move us toward that goal — and keep
the project attractive to new contributors — are welcome.

## What needs help right now

The core language, all 107 builtins, derivations, `zix build` (with
sandboxing) and `zix gc` are done and CI-green. The most valuable next steps:

- **Nixpkgs at scale** — get `zix build (import <nixpkgs> {}).hello`
  realising end-to-end. `import <nixpkgs> {}` already evaluates;
  `pkgs.hello.drvPath` is close and documented in
  [ROADMAP.md](ROADMAP.md).
- **Cross-platform polish** — the musl build works; native Windows/macOS
  builder paths deserve more coverage.
- **Performance** — profiling the evaluator against nix on large nixpkgs
  subtrees.
- **Test coverage** — more nix-vs-zix battery cases, more unit tests, more
  fuzzing seeds.
- **Docs & examples** — more `examples/`, clearer error-message docs.

Small, focused PRs with tests are the fastest way to land work.

## Getting started

```console
$ zig build            # builds zig-out/bin/zix (ReleaseSafe by default)
$ zig build test       # 27 unit tests
$ zig build run -- eval -E '1 + 2 * 3'
```

The Zig version is **0.16.0** (see `build.zig.zon`). With Nix, `nix develop`
gives a ready-made environment. The CI workflow
(`.github/workflows/ci.yml`) builds on Linux, macOS and Windows.

## Testing workflow

Compatibility is a *testable property*. Run the full suite before pushing:

```console
$ zig build test       # unit tests
$ zig build verify     # 165-case nix-vs-zix battery (requires `nix` on PATH)
$ zig build lang       # golden language tests
$ zig build fuzz       # structured fuzzing vs nix
$ bash tests/build-smoke.sh
$ bash tests/sandbox-smoke.sh   # needs `bubblewrap` for the sandbox test
```

The battery in [`tests/nix-vs-zix.sh`](tests/nix-vs-zix.sh) evaluates each
expression in both `zix` and real `nix 2.34.7` and requires identical output.
If you change evaluation, builtins or store-path logic, the battery must stay
green.

## Guidelines

- **Compatibility first.** When you change evaluation or store-path logic,
  verify against real Nix: `nix eval --expr '…'` should equal
  `zix eval -E '…'`, and derivation paths should be identical.
- **Small, focused PRs.** One change per PR makes review easier.
- **Tests first.** Add a test covering your change; the full suite must be
  green before merge.
- **Style.** Zig formatting is standard (`zig fmt`); keep code compact and
  readable; comments in English.
- **Document intentional deviations.** If ZIX must differ from Nix, say so in
  the README and in the code comment.

## Bugs and issues

- Describe what you ran, what happened, and what you expected.
- Include output from both `zix` and `nix` where relevant — it tells us
  whether something is a compatibility bug or a ZIX-specific bug.
- Use the [issue templates](.github/ISSUE_TEMPLATE/).

## Communication

- Issue and PR discussions happen on GitHub.
- Be respectful and constructive — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- For security issues, see [SECURITY.md](SECURITY.md).

## Thanks!

A small project like this lives on its contributors. Whether you fix a typo,
write a test, or take on a nixpkgs milestone — it is appreciated.
