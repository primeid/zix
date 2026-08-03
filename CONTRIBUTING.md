# Contributing to ZIX

Takk for at du vurderer å bidra! ZIX er et lite, fokusert prosjekt med ett mål:
**en bit-for-bit Nix-2.34-kompatibel implementasjon av Nix-uttrykksspråket i
Zig**. Alle bidrag som bringer oss nærmere det målet — og holder prosjektet
tiltrekkende for nye bidragsytere — er velkomne.

## Hva som trengs hjelp med

Se [Roadmap i README](README.md#roadmap) for den store oversikten. Konkrete
områder som alltid er aktuelle:

- **Realiseringslaget** (`zix build`): kjøre derivasjonsbyggere i en sandkasse
  og produsere utdata. Dette er det største og viktigste neste steget.
- **Flere builtins**: `fetchGit`, `fetchTarball`, `fromTOML`,
  `__structuredAttrs`, `builtins.path`-flagg, `scopedImport`, dynamiske
  derivations.
- **Nixpkgs-evaluering**: få `import <nixpkgs> {}` til å fungere.
- **Testdekning**: flere enhetstester og flere nix-vs-zix-sammenligninger
  (alle resultater verifiseres mot ekte `nix 2.34.x`).
- **Fiks av kjente avvik** i [README](README.md#kjente-avvik).

## Kom i gang

```console
$ zig build            # bygger zig-out/bin/zix (ReleaseSafe som standard)
$ zig build test       # 24 tester, inkludert store-path-verifisering mot Nix
$ zig build run -- eval -E '1 + 2 * 3'
```

Zig-versjonen som brukes er **0.16.0** (se `build.zig.zon`). Har du Nix kan du
bruke `nix develop` for et miljø med riktig Zig.

## Retningslinjer

- **Kompatibilitet er en testbar egenskap.** Når du endrer evaluerings- eller
  store-path-logikk, verifiser resultatet mot ekte Nix: `nix eval --expr '…'`
  skal gi samme utdata som `zix eval -E '…'`. Derivasjonsstier skal være
  identiske.
- **Små, fokuserte PR-er.** Én endring per PR gjør det lettere å gjennomgå.
- **Tester først.** Legg til en test som dekker endringen din; alle tester må
  være grønne før merge (`zig build test`).
- **Følg stilen.** Zig-formateringen er standard (`zig fmt`); hold koden
  kompakt og lesbar. Kommentarer på engelsk.
- **Dokumentér avvik.** Hvis zix bevisst avviker fra Nix (f.eks. ekstra
  builtins eller aktivert pipe-operators), noter det i README.

## Feilmeldinger og issues

- Beskriv hva du kjørte, hva som skjedde, og hva du forventet.
- Inkluder utdata fra både `zix` og `nix` der det er relevant — det hjelper
  oss å avgjøre om det er en kompatibilitetsfeil eller en zix-spesifikk feil.
- Bruk gjerne [issue-templatene](.github/ISSUE_TEMPLATE/).

## Kommunikasjon

- Issues og PR-diskusjoner foregår på GitHub.
- Vær respektfull og konstruktiv — se [CODE_OF_CONDUCT](CODE_OF_CONDUCT.md).

## Takk!

Et lite prosjekt som dette lever av bidragsyterne sine. Uansett om du fikser en
stavefeil, skriver en test eller bygger realiseringslaget — det er verdsatt.
