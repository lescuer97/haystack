# World layout, keys, and storage

Bare-bones reference for how the world is addressed, generated, and changed.

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
- Sectors exist only for the network (who receives which updates).

Nothing is stored for "empty" space. A chunk that was never touched does not exist.

---

## 2. The two keys

| Key             | Who has it        | Used for                                  |
|-----------------|-------------------|-------------------------------------------|
| **public seed** | client + server   | terrain, grass, trees, rocks (layout)     |
| **private key** | **server only**   | loot / yield / what a tile contains       |

### Public seed

Shipped with the game (or per world). Both sides run the same generator:

```
tile_state = generate(public_seed, x, y)
```

The client generates the world itself. The server never sends terrain.
It is fine that anyone can compute the whole map — that is the design.

### Private key

Lives only on the server (env var or file, never in git, never in the client build).

```
loot = PRF(private_key, x, y, attempt)
```

- `attempt` is assigned by the server, never by the client.
- Uses a keyed hash (e.g. SipHash / BLAKE3 keyed / HMAC).
- No storage needed: the result is recomputed on demand.
- The client cannot compute it, so it cannot pre-map the world's yields.
- Never derive the private key from the public seed.

---

## 3. What the client knows

| Known up front            | Only after the server says so |
|---------------------------|-------------------------------|
| terrain, grass, trees, rocks | loot, yields, contents     |
| other players nearby      | anything a player changed     |

The client may **predict** the public part (grass → cut).
It must **never** predict loot.

---

## 4. How changes are stored (server)

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

## 5. Action flow

```
client                          server
  │ predict: grass -> cut         │
  ├── Action{seq, x, y, tool} ───►│ validate (range, tool, cooldown, state)
  │                               │ loot = PRF(key, x, y, attempt)
  │                               │ store delta {state, owner, tick}
  │◄── Result{seq, state, loot} ──┤
  │ apply state, show loot        │
  │ if state differs -> revert    │
```

---

## 6. Rules

1. The client is hostile. Validate every action server-side.
2. Never send hidden data ahead of the action, and never add a "preview yield" endpoint.
3. Anything derivable from the public seed is public — do not put secrets there.
4. Deltas are absolute state, not toggles, so retries are safe.
5. Duplicate `(player, seq)` returns the stored result; it never rolls again.
6. The server starts only if the private key is present.
