# Store layout and database

ZIX's store directory (default `/nix/store`, override with `--store-dir DIR`
or `ZIX_STORE_DIR`) is byte-compatible with Nix's for *path computation*, and
uses a simple JSON index to track realised store objects.

## Layout

```text
<store-dir>/
  <hash>-<name>          # store objects: text files, sources, derivation
                         # outputs; written 0444, read-only like Nix
  zix-db.json            # realisation index (see below)
```

## `zix-db.json`

A single JSON object mapping store path → metadata:

```json
{
  "<store-dir>/<hash>-<name>": {
    "type": "text" | "source" | "output:out" | ...,
    "narHash": "<sha256 base16>",
    "refs": [ "<store path>", ... ],
    "deriver": "<store path to .drv>" | null,
    "outputs": { "<name>": "<store path>" } | null
  }
}
```

- `type` mirrors the store path fingerprint type (`text`, `source`,
  `output:<id>`).
- `narHash` is the NAR hash of the object (flat: hash of contents).
- `refs` are the store paths the object references (for future `zix gc`).
- `deriver` and `outputs` are set for realised derivation outputs.

Written atomically (write to `zix-db.json.tmp`, then rename). Read once at
startup into the in-memory `Store` index.

## Why JSON?

- Readable and debuggable — matches the project's "small, transparent" ethos.
- No runtime dependency (no sqlite).
- The file stays small for typical use; a future `zix gc` can rewrite it.
- The format is intentionally simple to migrate if sqlite is ever wanted.

## Future extensions

- `.narinfo` files per path for binary-cache compatibility (Phase 5 / optional).
- `zix gc`: traverse refs from live roots, delete unreachable objects.
