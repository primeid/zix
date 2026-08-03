---
name: Bug report
about: Rapporter en feil — gjerne med sammenligning mot ekte nix
title: ""
labels: bug
assignees: ""
---

**Beskriv feilen**

**Hvordan reprodusere**

```console
$ zix eval -E '…'
```

**Forventet / faktisk**

| | Utdata |
|---|---|
| `zix` | … |
| `nix eval --expr '…'` | … |

**Miljø**: OS, Zig-versjon (`zig version`), zix-revisjon (`git rev-parse HEAD`).

**Er det en kompatibilitetsfeil?** Ja / nei / usikker
