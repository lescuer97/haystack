# World layout, keys, and storage

Bare-bones reference for how the world is addressed, generated, and changed.

---

## 0. Status: implemented vs planned

Implemented today in `shared/world.zig`, `src/world.zig`, and `server/`:

- 32×32 px tiles, 16×16-tile chunks (512×512 px).
- A `Tile` enum (`grass=0`, `dirt=1`, `rock=2`, `tree=3`, `water=4`), rendered
  as 32px terrain art with an optional debug grid. Terrain generator v2 uses hash-based smooth
  value noise at absolute tile coordinates, independent of chunk residency or
  load order. The demo uses a fixed all-zero `[32]u8` public seed; there is no
  world-seed configuration plumbing yet.
- `privateYield(private_seed: [32]u8, x: i32, y: i32) u64`, a keyed BLAKE3-256
  roll. It is implemented and tested but **unused**: not wired into gameplay,
  chunk generation, or any server.
- Resident chunks in a fixed-size memory pool plus a chunk-key map. Streaming
  unloads everything outside a 2-chunk prefetch ring, then loads visible chunks
  first and the rest of the ring second.
- Memory stats, allocation-free eviction scratch, and retry-after-OOM support.
- Standalone loopback WebSocket server with binary TLV messages, process-lifetime grass/tree cuts,
  fixed RAM budgets, volatile opaque-ID replay, and complete
  64-chunk bitmap area snapshots.
  See [server.md](server.md) for the implemented wire contract and limits.
- The game client has no networking, delta/input/render integration, dirty
  flags, or characters yet. Its resident chunks still contain generated terrain.

Sections 2–6 below describe **future rewardful gameplay**, not the current
rewardless server contract. Terrain and coordinate types are shared now; the
private-yield primitive stays unused in the client world module. The current
server needs **no private seed**, loot, player identity, or tool state.

Future gameplay edits must survive chunk eviction: resident `Chunk`s are a cache
and may be regenerated at any time, so changes cannot live only inside a
resident chunk. They need an authoritative state/delta layer keyed by world
coordinates with a resync path. That layer exists on the standalone server;
applying its snapshots to the game client is **not implemented**.

The unused starter draft also mentioned a `TileEntity` union
(`Tree`/`Grass`/`Character` with `CutStatus`), per-chunk `dirty` flags, and a
`Character{ yourself: bool }` entity. Those ideas are not implemented; today a
tile is only the generated grass/dirt/rock/tree/water `Tile` enum above, with no tree
entities, collision, harvesting, or separate layers.

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

### Terrain generator v2

Each smooth field bilinearly interpolates the high 16 bits of four `hash2`
lattice-corner values, using smoothstep `t*t*(3-2*t)` on each axis. Fixed point
uses 65536 as one, widened `u64` products, and rounds down after smoothstep and
each interpolation. Floor division and nonnegative remainders keep negative
coordinates continuous across lattice and chunk boundaries.

Domains XOR the first public-seed byte with 1 (forest), 2 (rock), 3 (dirt),
4 (per-tile tree density roll), or 5 (water); `hash2` and its v1 seed encoding
are unchanged. Selection order:

1. Water noise on a 32-tile lattice < 16000 produces water, before any land selection.
2. Rock noise on a 16-tile lattice >= 51000 produces solid rock formations.
3. Forest noise on a 32-tile lattice >= 32000 permits trees. A tile becomes a
   tree when its domain-4 hash's high 16 bits are below
   `min(56000, 22000 + forest - 32000)`, leaving grassy gaps even in dense areas.
4. Remaining tiles with dirt noise on an 8-tile lattice >= 55000 become dirt.
5. Everything else is grass.

These are single fields, not multi-octave noise, with no spawn carveout. Nonwater
tiles retain exactly the v1 land classification. Grass is the majority, and trees
outnumber rock, which outnumbers dirt over representative large regions, not
necessarily every chunk. In the public-seed 512×512 region [-256,255] on each
axis, water covers 36,241 tiles (about 13.825%). The v2 row-major FNV-1a terrain
ordinal checksum is `0x2beaf359deeea5bb`. Changing these rules or constants
changes the generated layout; the region checksum test locks the current output.

---

## 2. The two seeds (**rewardful gameplay planned**)

Both seeds are 32 bytes and independent. Never derive one from the other.

| Seed             | Who has it        | Used for                                  |
|------------------|-------------------|-------------------------------------------|
| **public seed**  | client + server   | terrain, grass, trees, rocks, water (layout) |
| **private seed** | **server only**   | loot / yield / what a tile contains       |

### Public seed

Shipped with the game (or per world). Both sides run the same generator:

```
tile_state = generate(public_seed, x, y)
```

The client generates the world itself. The server never sends terrain.
It is fine that anyone can compute the whole map — that is the design.

`hash2` accepts a `[32]u8` public seed. `generate` currently supplies a fixed
all-zero placeholder internally to the terrain sampler, which derives the five
public layout domains described above; world-seed configuration and plumbing
do not exist yet. This is a public layout hash, not a PRF. Private yields are
unchanged and never participate in terrain generation.

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

## 4. Future extended storage design (**planned**, not current RAM state)

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

## 5. Client integration and rewardful action flow (**planned**)

Not implemented in the client. When game networking is added, incoming messages
are collected without blocking and applied at the frame update boundary, before the local
action for that frame; callbacks only enqueue. See `game-loop.md` for the loop
ordering. The standalone rewardless binary TLV protocol is documented in `server.md`;
the diagram below is a future rewardful flow, not that protocol.

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
6. A future rewardful server would require a private seed; the implemented
   rewardless cut server neither requires nor uses one.
