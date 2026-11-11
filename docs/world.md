# World layout, keys, and storage

Bare-bones reference for how the world is addressed, generated, and changed.

---

## 0. Status: implemented vs planned

Implemented today in `src/world.zig`:

- 32×32 px tiles, 16×16-tile chunks (512×512 px).
- A `Tile` enum (`grass`, `dirt`, `rock`) generated deterministically from tile
  coordinates by a coordinate hash. The hash takes an explicit `[32]u8` public
  seed; the demo passes a fixed all-zero placeholder, and there is no
  world-seed configuration plumbing yet.
- `privateYield(private_seed: [32]u8, x: i32, y: i32) u64`, a keyed BLAKE3-256
  roll. It is implemented and tested but **unused**: not wired into gameplay,
  chunk generation, or any server.
- Resident chunks in a fixed-size memory pool plus a chunk-key map. Streaming
  unloads everything outside a 2-chunk prefetch ring, then loads visible chunks
  first and the rest of the ring second.
- Memory stats, allocation-free eviction scratch, and retry-after-OOM support.
- No tile deltas, no dirty flags, no characters, no network, and no gameplay
  mutation yet.

Sections 2–6 below are **planned**. The seed types and both hash helpers exist
in `world.zig`, but the client/server split, server-side private-seed handling,
delta storage, and action flow are design notes, not current code.

Future gameplay edits must survive chunk eviction: resident `Chunk`s are a cache
and may be regenerated at any time, so changes cannot live only inside a
resident chunk. They need an authoritative state/delta layer keyed by world
coordinates with a resync path. That layer is **not implemented**, and no wire
format should be invented until it is.

The unused starter draft also mentioned a `TileEntity` union
(`Tree`/`Grass`/`Character` with `CutStatus`), per-chunk `dirty` flags, and a
`Character{ yourself: bool }` entity. Those ideas are not implemented; today a
tile is only the generated grass/dirt/rock `Tile` enum above.

---

## 1. Layout

Three spaces, all integers:

| Space  | Unit            | Size        |
|--------|-----------------|-------------|
| tile   | 1 cell          | 32×32 px    |
| chunk  | 16×16 tiles     | 512 × 512 px|
| sector | 8×8 chunks      | network / interest unit |

```
tile (x, y)          i32, may be negative, world is endless
chunk (cx, cy)       cx = floor(x / 16),  cy = floor(y / 16)
local  (lx, ly)      lx = x - cx*16,       ly = y - cy*16   (0..15)
```

- Tiles are the only thing gameplay touches.
- Chunks are the unit of generation, storage, and rendering.
- Sectors exist only in the planned network design (who receives which updates).

Nothing is stored for untouched space. An untouched chunk is not resident; the
deterministic generator recreates it on demand. The resident chunk map is a
cache, not the world itself.

---

## 2. The two seeds (**server integration planned**)

Both seeds are 32 bytes and independent. Never derive one from the other.

| Seed             | Who has it        | Used for                                  |
|------------------|-------------------|-------------------------------------------|
| **public seed**  | client + server   | terrain, grass, trees, rocks (layout)     |
| **private seed** | **server only**   | loot / yield / what a tile contains       |

### Public seed

Shipped with the game (or per world). Both sides run the same generator:

```
tile_state = generate(public_seed, x, y)
```

The client generates the world itself. The server never sends terrain.
It is fine that anyone can compute the whole map — that is the design.

`hash2` accepts a `[32]u8` public seed. `generate` currently supplies a fixed
all-zero placeholder internally; world-seed configuration and plumbing do not
exist yet. This is a public layout hash, not a PRF.

### Private seed

The server-only secret key for the keyed PRF. It lives only on the server (env
var or file, never in git, never in the client build) and is separate from the
public seed.

Implemented primitive:

```
roll = privateYield(private_seed, x, y)   // u64, keyed BLAKE3-256
```

- Input is the domain tag `haystack.private-yield.v1` plus `x` and `y` as
  little-endian 32-bit fields; the first 8 output bytes, read little endian,
  become the u64 roll.
- The whole 32-byte `private_seed` is the BLAKE3 key, in array order.
- Keyed BLAKE3-256 is the standard for private yields. No alternative algorithm
  is implemented.
- It is unused today: not wired into gameplay, chunk generation, or a server.
  No private seed constant lives in production code.
- Planned server call: `loot = PRF(private_seed, x, y, attempt)`. `attempt` is a
  server-assigned respawn/action identifier for the future protocol; it is
  **not** part of the implemented primitive, which rolls from coordinates only.
- The roll itself needs no per-tile storage: it is recomputed on demand. What a
  player actually harvested (state, owner) must still be stored authoritatively
  as deltas (section 4).
- The client cannot compute it, so it cannot pre-map the world's yields.
- Never derive the private seed from the public seed.

---

## 3. What the client knows (**planned split**)

Today the client only knows the generated terrain, computed locally. It does not
predict gameplay changes because no gameplay mutation exists yet.

| Known up front            | Only after the server says so |
|---------------------------|-------------------------------|
| terrain, grass, trees, rocks | loot, yields, contents     |
| other players nearby      | anything a player changed     |

The client may **predict** the public part (grass → cut).
It must **never** predict loot.

---

## 4. How changes are stored on the server (**planned**)

```
real_tile = generate(public_seed, x, y)   default
          overridden by delta              stored
```

Only changes are stored. Everything else is regenerated.

Per chunk:

```
ChunkRecord {
    chunk_x, chunk_y        i32
    gen_version             u16      // generator version used
    deltas: list of {
        local_x, local_y    u8       // 0..15
        state               u8       // cut, tilled, rock_mined, ...
        owner               u32      // player id, 0 = nobody
        tick                u32      // last change, for conflicts
    }
}
```

- Absent delta = trust the generator.
- Deltas are written **before** replying to the client (no save-scumming).
- Blob on disk: header (`gen_version`, count) + sorted, delta-encoded entries (~3–6 bytes each).
- `gen_version` mismatch → do not regenerate that chunk; the stored deltas stay authoritative.

---

## 5. Action flow (**planned**)

Not implemented. When networking is added, incoming messages are collected
without blocking and applied at the frame update boundary, before the local
action for that frame; callbacks only enqueue. See `game-loop.md` for the loop
ordering. No wire protocol exists yet.

```
client                          server
  │ predict: grass -> cut         │
  ├── Action{seq, x, y, tool} ───►│ validate (range, tool, cooldown, state)
  │                               │ loot = PRF(private_seed, x, y, attempt)
  │                               │ store delta {state, owner, tick}
  │◄── Result{seq, state, loot} ──┤
  │ apply state, show loot        │
  │ if state differs -> revert    │
```

---

## 6. Rules for the planned server design

1. The client is hostile. Validate every action server-side.
2. Never send hidden data ahead of the action, and never add a "preview yield" endpoint.
3. Anything derivable from the public seed is public — do not put secrets there.
4. Deltas are absolute state, not toggles, so retries are safe.
5. Duplicate `(player, seq)` returns the stored result; it never rolls again.
6. The server starts only if the private seed is present.
