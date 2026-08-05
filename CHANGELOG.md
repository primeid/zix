# Changelog

All notable changes to ZIX are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/) from the 1.0 release.

## [Unreleased]

### Added

- All 107 Nix 2.34.7 builtins implemented, including `findFile`, `hasContext`,
  `ceil`, `floor`, `readFileType`, `warn`, `traceVerbose`, `convertHash`,
  `filterSource`, `unsafeDiscardOutputDependency`, `break`, `parseFlakeRef`,
  `flakeRefToString`, `fetchMercurial`, `fetchTree`, `getFlake`.
- `zix gc` — garbage collection of unreachable store objects.
- Sandboxed builds (`zix build --sandbox`) via bubblewrap: network
  isolation, read-only store, restricted writes.
- `--impure` mode and pure-by-default evaluation, mirroring `nix eval`.
- Experimental features gated behind
  `--extra-experimental-features` (extra builtins, pipe operators) — like
  Nix's own experimental-feature flags.

### Fixed

- `__functor` use-after-free; duplicate-attribute merge semantics;
  comparator errors in `builtins.sort` now propagate; failed thunks no longer
  stay poisoned; atomic store-database writes; `zix build` on a large-stack
  thread; trailing-dot floats and `1.a or 42` parsing per Nix; eager
  undefined-variable detection; store-path existence validation in
  `storePath`; `dirOf` type preservation; NAR-based path copying
  (bit-identical with Nix); recursion/cycle handling without hangs or
  segfaults.

### Changed

- Extra builtins and pipe operators are disabled by default (opt-in via
  `--extra-experimental-features`).
- Error messages, pure/impure behavior, and store paths match Nix 2.34.7.
