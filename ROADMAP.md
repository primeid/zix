# ZIX Roadmap — plan for completing the full roadmap

This document breaks the [README roadmap](README.md#roadmap) into concrete,
phased work packages with milestones, verification criteria and rough sizes.
Each phase ends in something testable against real `nix 2.34.x`.

Legend for effort: **S** = small (≤ 1 day), **M** = medium (2–5 days),
**L** = large (1–2 weeks), **XL** = > 2 weeks. All sizes are for one
experienced contributor.

---

## Phase 0 — Foundations and test infrastructure

*Cross-cutting; do first. Everything below builds on this.*

| Task | Effort | Details |
|---|---|---|
| **0.1 Committed nix-vs-zix verification harness** | S | Move the 165-expression comparison battery (currently `/tmp/compare.sh`) into the repo as `tests/nix-vs-zix.sh` + a `zig build verify` step that runs it when `nix` is available. |
| **0.2 Golden-test corpus** | M | Add more expression fixtures (port Nix's own `tests/functional/lang/*.nix` expectations where possible) so regressions are caught without a `nix` binary. |
| **0.3 Store DB format decision** | S | Decide how realised paths are tracked. Recommended: per-store JSON index (`<store>/zix-db.json`: path → {type, refs, narHash, deriver, output}) plus optional `.narinfo` files for future substitution. Keep it readable; no sqlite dependency. |
| **0.4 Error/position infrastructure stub** | S | Introduce the error type + position plumbing now (see Phase 4) so Phases 1–3 produce locatable errors from day one. |

**Exit criteria:** `zig build verify` runs the full battery on CI (Linux) and
locally; store-DB format is written down in `docs/store.md`.

---

## Phase 1 — The realisation layer (`zix build`)

*The largest missing piece: take a `.drv` and actually produce its outputs.*

### 1.1 Store write model
| Task | Effort | Details |
|---|---|---|
| `addToStore` (recursive/flat) that **writes** | M | Extend `store.addPathToStore` (currently compute-only) to dump the NAR into the store dir, set mode `0444`, and register the path in the DB. |
| `addTextToStore` with refs | S | Wire existing `writeText` through registration. |
| Store DB read/write | M | `zix-db.json` read at startup, appended on realisation, `zix gc`-ready structure (mark Phase 5). |

### 1.2 Build planning
| Task | Effort | Details |
|---|---|---|
| Drv-graph loading + topological sort | M | Resolve `inputDrvs` from the store, build a DAG, detect cycles, produce a build order with inputSrcs presence checks. |
| `--dry-run` plan output | S | Print the build order + output paths without executing (format close to `nix-build --dry-run`). |

### 1.3 Builder execution (unsandboxed first)
| Task | Effort | Details |
|---|---|---|
| Fork/exec builder | M | POSIX: fork + exec the builder with `args`, env vars from the drv `env` (incl. `out`/`PATH`/`HOME` etc.), correct cwd; capture stdout/stderr; timeout + exit-status handling. |
| Output creation + registration | M | After success: verify each output exists, fix permissions (0444), register in DB. For fixed-output: re-hash and compare against `outputHash`; mismatch → error (mirror Nix behaviour). |
| Multi-output support | M | Multiple outputs in one build; `$out`, `$dev`, … env vars; per-output registration. |
| Parallel builds | M | `-j N` with a worker pool (Zig threads); dependency-aware scheduling. |
| Windows builder support | L | Windows build execution differs fundamentally (no fork/exec, no `/bin/sh`). Scope: POSIX first; Windows runs `zix build` with a documented limitation or a minimal stub (`cmd`-based builders). |

### 1.4 Sandboxing (Linux; macOS optional)
| Task | Effort | Details |
|---|---|---|
| Path-restricted sandbox | M | Run builders with a restricted view: only the store, the builder, and explicitly allowed paths visible; deny network by default; env scrubbing (`__noChroot`-style escape hatches later). |
| chroot/pivot_root sandbox | L | Full chroot with store mounted read-only (mirrors Nix's sandbox). Requires deciding the bootstrap strategy: which `/bin/sh` and coreutils are available inside (host paths vs a bundled mini-bootstrap). |
| macOS / Windows sandbox | L | macOS `sandbox-exec` profiles; Windows: none (document). |

### 1.5 CLI
| Task | Effort | Details |
|---|---|---|
| `zix build` | M | Accept a drv path or a derivation-valued expression; `--dry-run`, `-j`, `--no-sandbox`, `--keep-failed`, `--out-link` (gc-roots later). |
| `zix path-info`, `zix store cat`, `zix store add-path` | S | Read-only store utilities useful for debugging and for CI. |

**Exit criteria:** `zix build` realises a hand-written drv (e.g.
`examples/hello.nix`) end-to-end; a fixed-output drv is verified by hash; the
result matches what `nix` produces for the same expression (paths + contents).
Sandboxed builds are the last sub-goal, not the first.

---

## Phase 2 — More builtins

| Task | Effort | Details |
|---|---|---|
| `builtins.path` full flags (`name`, `filter`, `recursive`, `sha256`) | M | Filter callback during NAR dump; flat/recursive mode; `name` override. |
| `fromTOML` | M | Small TOML parser (strings, ints, floats, bools, arrays, tables, inline tables, dates as strings). Compare against `nix eval --expr 'builtins.fromTOML …'`. |
| `fetchTarball` / `fetchurl` / `fetchzip` | L | HTTPS client (Zig 0.16 `std.http`); download to a fixed-output drv, validate `sha256`/`narHash` (SRI), unpack tar/zip for `fetchTarball`/`fetchzip`. Network in sandbox later (derivation `fetchurl` uses the `builtin:fetchurl` builder). |
| `fetchGit` | L | Shell out to `git` for clone (documented dependency) OR implement minimal git object reading; produce store path via Git-tree ingestion (`git:` method). |
| `__structuredAttrs` in derivations | M | `derivationStrict`: when set, write `__json`/`NIX_ATTRS_JSON_FILE` env + `NIX_ATTRS_JSON_FILE`/`NIX_ATTRS_SH_FILE` semantics; `outputs` etc. read from the JSON. |
| `scopedImport` (real implementation) | S | Currently registered but stubbed; implement the custom-scope variant. |
| Dynamic derivations (experimental) | L | Deferred/impure outputs; `builtins.placeholder` already works; add `DeriveWithVersion` handling + dynamic inputDrvs. Mark as optional. |
| `fetchClosure` | M | Copy a closure of store paths (local or from a binary cache later). |
| `unsafeGetAttrPos` | S | Depends on Phase 4 positions. |
| `getFlake` / flake evaluation | XL | Full flake support is a project of its own. **Decision needed**: in scope for "full Nix-compatible" or explicitly out (recommend: out for v1, documented). |

**Exit criteria:** every builtin has a nix-vs-zix comparison entry; `nixpkgs.lib`
functions that use `fetchGit`/`fetchTarball`/`fromTOML` work identically.

---

## Phase 3 — Nixpkgs evaluation

*The stress test that validates the language, builtins and laziness at scale.*

| Task | Effort | Details |
|---|---|---|
| Evaluate `import <nixpkgs> {}`'s `lib` | M | **DONE** — `lib` (trivial, attrsets, lists, strings, fixedPoints, customisation, systems, types, modules single-module paths) evaluates and matches Nix. |
| Construct the `pkgs` attrset | M | **DONE** — `import <nixpkgs> {}` fully evaluates: `pkgs.system`, `pkgs.hello.name = "hello-2.12.3"`, the full stdenv bootstrap (380 drvs). |
| Build `hello` from nixpkgs end-to-end | L | **In progress** — `pkgs.hello.drvPath` evaluates through the whole stdenv (gcc, glibc, coreutils, ...) and is blocked on a JSON-serialisation cycle: the `__structuredAttrs` env of a derivation contains a derivation value whose `all`-chain (`lib/customisation.nix:409`) recurses during `jsonWrite`. Next step: coerce derivation values in the structured env to their output path before JSON. |
| Nixpkgs-compat fixes landed | — | trailing comma in formals, `@args` visible in formals defaults, lazy `map`/`mapAttrs` (no false recursion), `builtins.split` capture groups, search-path errors as `ThrownError` (tryEval parity), multi-line string interpolation. |
| Construct the `pkgs` attrset | M | stdenv bootstrapping: needs `fetchurl`/`fetchTarball` (Phase 2), `derivation` correctness, and `__structuredAttrs`-free path first. |
| Build `hello` from nixpkgs end-to-end | L | The canonical milestone: `zix build (import <nixpkgs> {}).hello` produces a working binary identical to `nix build`. |
| Full `pkgs` attribute-set evaluation | L | Force the whole `pkgs` attrset; fix remaining builtins (`fetchgit`, `fetchzip`, …) and language corners (`builtins.match` regex coverage, `lib` uses of `builtins.split`, …). |
| Performance at nixpkgs scale | L | Benchmark vs `nix eval`; profile hot paths (string building, attrset lookup, thunk allocation). Possible: bump the arena strategy or introduce value GC for very large evals. |
| `nix-instantiate`-compatible CLI | M | `zix eval --json`, `zix instantiate`, exit codes, `--arg`/`--argstr`, `-A` attr-path selection. |

**Exit criteria:** `zix build (import <nixpkgs> {}).hello` works and produces
the same store paths as `nix`; `zix eval` of a large `pkgs` slice completes in
the same order of magnitude of time as `nix`.

---

## Phase 4 — Position tracking and error parity

| Task | Effort | Details |
|---|---|---|
| Positions in the AST | M | The lexer already tracks line/col; thread a `Pos` through the parser into every `ast.Expr` node (file + line + col). |
| Nix-style error rendering | M | `error: <message>` + `at «file»:line:col` + `while evaluating …` frames, matching Nix's format closely (not necessarily byte-for-byte). |
| `__curPos` real values | S | Replace the current placeholder (file only, line 0) with real positions. |
| Lambda printing | S | `«lambda @ «file»:line:col»` instead of `«lambda»`. |
| `unsafeGetAttrPos` | S | Return the definition position of an attribute. |

**Exit criteria:** error messages from `zix` and `nix` for the same broken
expression agree on file/line/col and overall structure; the 165-expression
battery still passes.

---

## Phase 5 — Hardening, testing and release

| Task | Effort | Details |
|---|---|---|
| Fuzzing | M | Fuzz lexer/parser/evaluator (random bytes + random Nix-ish expressions); no crashes/panics; clean errors. |
| Expand the comparison battery | M | Port more of Nix's own language tests; add property tests for hash/store-path invariants. |
| `zix gc` (optional) | M | Garbage-collect unreachable store paths using the DB refs. |
| Binary-cache substitution (optional) | XL | Speak the NAR/binary-cache protocol (`cache.nixos.org`) to substitute instead of build. Big; recommend post-1.0. |
| Documentation | M | CLI reference (`docs/cli.md`), store format (`docs/store.md`), architecture updates, contribution guide refresh. |
| 1.0 release | — | Tag, release notes, CI matrix green, roadmap checkboxes ticked. |

---

## Suggested ordering and dependency map

```text
Phase 0 ──► Phase 1 (realisation) ──► Phase 3 (nixpkgs) ──► Phase 5 (release)
   │             ▲                          ▲
   └──► Phase 4 (positions)                │
        (parallel, small)                  │
        └──► Phase 2 (builtins) ───────────┘
```

- **Phase 4 is the natural first contribution** for newcomers (self-contained, small, immediately visible in error messages).
- **Phase 1.1–1.3 (unsandboxed `zix build`)** is the highest-value milestone for the project's core goal.
- **Phase 2 `fetchTarball`/`fetchurl`** unlocks nixpkgs (Phase 3).
- Phases 1–3 can proceed in parallel once Phase 0 and the Phase 4 position stub exist.

## Open decisions (need input)

1. **Flakes / `getFlake`**: in scope for v1, or explicitly out of scope (documented)? Recommendation: out for v1.
2. **Binary-cache substitution** (`cache.nixos.org`): post-1.0, or essential?
3. **Sandbox bootstrap**: use host tools (`/bin/sh` etc.) unsandboxed first, or invest in a bundled mini-bootstrap for chroot from the start? Recommendation: unsandboxed first, sandbox after (matches the milestone order above).
4. **Store DB**: JSON index (recommended) vs sqlite.

## Open decisions — resolved

| Decision | Resolution | Status |
|---|---|---|
| Flakes / `getFlake` in v1 | **Out of scope for v1.** ZIX targets the language core, derivations and the store. Flake support (flake.nix, locks, registries) is a large surface orthogonal to the evaluator and will land after 1.0 behind the `flakes` experimental feature, mirroring Nix. | Documented |
| Binary-cache substitution | **After 1.0.** `zix build` realizes derivations locally; downloading prebuilt store paths (narinfo + NAR-over-HTTP) reuses the same NAR codec already implemented and is a natural follow-up. | Documented |
| Sandbox bootstrapping | **Unsandboxed first, sandbox opt-in.** `zix build` runs builders unsandboxed by default; `--sandbox` enables a bubblewrap sandbox (`--unshare-all`, read-only root, tmpfs /tmp//run//dev, scrubbed env). Verified: network blocked, writes outside the store fail. | **Implemented** |
| Store database | **JSON index** (`zix-db.json` in the store dir) — human-readable, trivially diffable, no external dependencies. Loaded at startup, rewritten on registration. `zix gc` computes the live set from the DB + .drv files. | **Implemented** |
