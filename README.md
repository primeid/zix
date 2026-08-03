# ZIX — Nix-språket, omskrevet i Zig

ZIX er en uavhengig reimplementasjon av **Nix-uttrykksspråket** i
[Zig](https://ziglang.org) 0.16, med mål om bit-for-bit-kompatibilitet med
Nix 2.34. Tolken produserer store paths, `.drv`-filer og derivasjonsattributter
som er identiske med det ekte `nix` gir — verifisert mot Nix 2.34.7 i testene.

## Bygge og kjøre

```console
$ zig build            # bygger zig-out/bin/zix
$ zig build test       # 23 tester, inkl. store-path-verifisering mot ekte Nix
```

```console
$ zix eval -E '1 + 2 * 3'
7
$ zix eval -E 'builtins.map (x: x * x) [1 2 3 4]'
[1 4 9 16]
$ zix eval examples/hello.nix          # en derivasjon (bruk --read-only / --store-dir)
$ zix eval --read-only -E '(builtins.derivation { name = "t"; system = "x86_64-linux"; builder = "/bin/sh"; }).drvPath' --raw
/nix/store/k79611g7bg62d41fh6bvm7xpf1dl2x91-testdrv.drv
```

Alternativer: `--raw` (rå strenger), `--read-only` (ikke skriv til store),
`--store-dir DIR` (egen store, f.eks. `/tmp/zs`), `-I path` / `NIX_PATH`
for `<nixpkgs>`-oppslag, `zix parse FIL` (kun lex+parse).

## Arkitektur

| Modul | Innhold |
|---|---|
| `src/lexer.zig` | Tokenisering tro mot `lexer.l`: stier, URI-er, `"…"`- og `''…''`-strenger med interpolasjon, kommentarer |
| `src/parser.zig` | Recursive-descent-parser tro mot `parser.y`: hele grammatikken, presedens, `stripIndentation` bit-for-bit |
| `src/value.zig` | Verdier: int/float/bool/null, strenger med derivasjons-kontekst, lister, attrsets, lambdas, thunks |
| `src/eval.zig` | Lazy evaluator: memoiserte thunks, `rec`/`let`/`with`, scoping, dyp likhet, strengkonkatenering |
| `src/builtins.zig` | ~85 primops: aritmetikk, lister, attrsets, strenger+regex, JSON, filer/store, `import`, `derivationStrict` + `derivation`-wrappere |
| `src/drv.zig` | `.drv`-ATerm-serialisering/-parsing og `hashDerivationModulo` |
| `src/store.zig` | Store-path-beregning (`makeStorePath`/`makeOutputPath`/`makeFixedOutputPath`/`makeTextPath`), NAR-serialisering |
| `src/nixhash.zig` | SHA-256, base16, Nix base32 («nix32»), hash-komprimering |

Alt hash- og sti-relatert er modellert direkte på Nix-kilden
(`path.cc`, `store-dir-config.cc`, `derivations.cc`, `hash.cc`, `archive.cc`,
`parser.y`, `lexer.l`) og verifisert mot `nix 2.34.7` på denne maskinen:
`builtins.toFile`, input-addressed derivations, fixed-output
(flat + recursive) og derivations med input-referanser gir nøyaktig samme
store paths.

## Status

Ferdig og verifisert:
- Hele språket: literaler, strenger/interpolasjon, indented strings, stier,
  operatorer (`+ - * / // ++ == != < > <= >= && || -> ! ?`), attrsets
  (inkl. `inherit`, dynamiske attributter, nesting), `let`/`rec`/`with`/
  `assert`/`if`, lambdaer med formals/standardverdier/`@`, lister,
  `<nixpkgs>`-oppslag, `import`.
- Lazy evaluering med memoization og syklusdeteksjon.
- `builtins.derivation` / `derivationStrict` → korrekte `.drv`-filer og
  `drvPath`/`outPath` (input-addressed, fixed-output, multi-output-stub).
- ~85 builtins inkl. `map`, `foldl'`, regex (`match`/`split`),
  `replaceStrings`, `compareVersions`, JSON, `hashString`, `toFile`,
  `readFile`, `readDir`, `path`, `placeholder`, `tryEval`, `genericClosure`.

Planlagt / delvis:
- **Realiserings-laget** (`zix build`): kjøre byggere i en sandkasse og
  produsere utdata — evalueringssiden er komplett, utførelsesiden gjenstår.
- Flere builtins (`fetchGit`, `fetchTarball`, `fromTOML`, `builtins.path`-flagg,
  `scopedImport`, dynamiske derivations, …) og `__structuredAttrs`.
- nixpkgs-evaluering: språket og builtins som nixpkgs bruker er stort sett på
  plass, men full `import <nixpkgs> {}` krever resten av punktet over.

## Lisens

MIT.
