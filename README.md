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

## Analyse: hvorfor (og hvorfor ikke) omskrive Nix til Zig

Følgende er en gjennomgang av fordeler, kostnader og risiko ved å omskrive
Nix-språket/implementasjonen fra C++/OCaml til Zig — tatt med i sin helhet.

Hvis du mener **å omskrive Nix-språket eller Nix evaluator/implementasjonen fra C++/OCaml til Zig**, er det flere mulige fordeler, men også betydelige kostnader.

### Mulige fordeler med Zig

| Område                    | Potensiell fordel                                                                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Ytelse**                | Lavt overhead og god kontroll over minne og datastrukturer kan gi raskere evaluering og mindre ressursbruk.                           |
| **Minnebruk**             | Eksplisitt minnehåndtering og allocators gjør det mulig å optimalisere minneforbruket mer presist.                                    |
| **Enklere kodebase**      | Zig har et relativt lite og konsistent språk sammenlignet med C++ og kan redusere kompleksiteten i implementasjonen.                  |
| **Portabilitet**          | Zig har svært god cross-compilation og kan gjøre det enklere å bygge Nix-komponenter for Linux, macOS, Windows og andre plattformer.  |
| **C-interoperabilitet**   | Zig kan integreres direkte med C-biblioteker uten behov for et omfattende FFI-lag. Dette er relevant for Nix' eksisterende økosystem. |
| **Feilhåndtering**        | Zig har eksplisitt error handling, som kan gjøre kritiske deler av evaluator- og build-systemkoden lettere å følge.                   |
| **Færre avhengigheter**   | Zig-kompilatoren er relativt selvstendig og kan potensielt gjøre bootstrap og distribusjon enklere.                                   |
| **Sikkerhet**             | Selv om Zig ikke er memory-safe på samme måte som Rust, gir språket bedre verktøy for å oppdage enkelte feil enn tradisjonell C/C++.  |
| **Utviklerproduktivitet** | En mindre og mer moderne språkmodell kan gjøre det lettere for nye utviklere å bidra enn en stor C++-kodebase.                        |

### Den største potensielle gevinsten

Jeg tror den mest interessante fordelen ikke nødvendigvis er **rå ytelse**, men **vedlikeholdbarhet og portabilitet**.

Nix er i praksis flere ting samtidig:

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

Hvis den sentrale implementasjonen ble skrevet i Zig, kunne man potensielt få en **mindre, mer homogen og lettere porterbar runtime**. Det kunne gjøre det enklere å kjøre Nix-komponenter på flere plattformer og bygge dem fra kildekode.

### Men: Zig løser ikke nødvendigvis Nix' største problemer

Det er viktig å skille mellom:

**Nix-språket som språk**
og
**Nix som komplett system**.

Hvis problemet er for eksempel:

* langsom evaluering
* dårlig feilhåndtering
* komplisert kodebase
* vanskelig debugging
* dårlig Windows-støtte
* høy ressursbruk

kan Zig potensielt hjelpe.

Men hvis problemet er:

* kompleksiteten i Nix expression language
* laziness
* hermetiske builds
* dependency graphs
* reproducibility
* flakes
* UX
* Nixpkgs' enorme kompleksitet

så vil en omskriving til Zig **ikke automatisk løse dette**. Da flyttes problemene bare til en ny implementasjon.

### Min vurdering

Hvis målet var å modernisere Nix, ville jeg **ikke skrevet hele Nix på nytt i Zig fra dag én**. Jeg ville vurdert en gradvis arkitektur:

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

Da kunne man først skrive **en ny evaluator i Zig**, benchmarke den mot dagens Nix og gradvis erstatte komponenter dersom fordelene faktisk materialiserer seg.

**Kort sagt:** Zig kan potensielt gi Nix **lavere ressursbruk, enklere cross-compilation, en mer håndterbar implementasjon og bedre kontroll over runtime-ytelse**. Den største risikoen er at man bruker mange år på å omskrive et enormt og komplekst system uten å løse de underliggende problemene som faktisk gjør Nix vanskelig.

Hvis du egentlig mener **å omskrive selve Nix expression language til et nytt språk med Zig som implementasjonsspråk**, er analysen ganske annerledes. Da kan jeg også sammenligne **Nix vs. en hypotetisk "Zig-Nix"** arkitektur, inkludert hvordan man kunne bevare bakoverkompatibilitet med Nixpkgs.

## Lisens

MIT.
