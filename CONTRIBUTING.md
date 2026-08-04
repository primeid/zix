# Contributing to ZIX

Thanks for considering contributing! ZIX is a small, focused project with one
goal: **a bit-for-bit Nix-2.34-compatible implementation of the Nix expression
language in Zig**. All contributions that move us toward that goal — and keep
the project attractive to new contributors — are welcome.

## What needs help

See the [Roadmap in the README](README.md#roadmap) for the big picture.
Concrete areas that are always relevant:

- **The realisation layer** (`zix build`): run derivation builders in a
  sandbox and produce outputs. This is the biggest and most important next step.
- **More builtins**: `fetchGit`, `fetchTarball`, `fromTOML`,
  `__structuredAttrs`, `builtins.path` flags, `scopedImport`, dynamic derivations.
- **Nixpkgs evaluation**: get `import <nixpkgs> {}` working.
- **Test coverage**: more unit tests and more nix-vs-zix comparisons
  (all results are verified against real `nix 2.34.x`).
- **Fixes for known deviations** in the [README](README.md#known-deviations-from-nix).

## Getting started

```console
$ zig build            # builds zig-out/bin/zix (ReleaseSafe by default)
$ zig build test       # 24 tests, incl. store-path verification against Nix
$ zig build run -- eval -E '1 + 2 * 3'
```

The Zig version used is **0.16.0** (see `build.zig.zon`). If you have Nix,
`nix develop` gives you a ready-made environment.

## Guidelines

- **Compatibility is a testable property.** When you change evaluation or
  store-path logic, verify the result against real Nix:
  `nix eval --expr '…'` should produce the same output as `zix eval -E '…'`.
  Derivation paths should be identical.
- **Small, focused PRs.** One change per PR makes review easier.
- **Tests first.** Add a test covering your change; all tests must be green
  before merge (`zig build test`).
- **Follow the style.** Zig formatting is standard (`zig fmt`); keep the code
  compact and readable. Comments in English.
- **Document deviations.** If ZIX intentionally deviates from Nix (e.g. extra
  builtins or pipe operators enabled by default), note it in the README.

## Bugs and issues

- Describe what you ran, what happened, and what you expected.
- Include output from both `zix` and `nix` where relevant — it helps us tell
  whether something is a compatibility bug or a ZIX-specific bug.
- Feel free to use the [issue templates](.github/ISSUE_TEMPLATE/).

## Communication

- Issue and PR discussions happen on GitHub.
- Be respectful and constructive — see [CODE_OF_CONDUCT](CODE_OF_CONDUCT.md).

## Thanks!

A small project like this lives on its contributors. Whether you fix a typo,
write a test or build the realisation layer — it is appreciated.
