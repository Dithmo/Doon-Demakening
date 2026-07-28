# Doon

A demake of *Dune: Awakening* in Godot 4.5.

Server-authoritative multiplayer from day one — **solo play is a one-client
session against a local headless server**, so there is no separate offline path
and exactly one set of code to get right.

## Running

```bash
tools/run_session.sh          # server + 1 client
tools/run_session.sh 3        # server + 3 clients
tools/run_session.sh 2 --auto # server + 2 bot clients
```

Or by hand:

```bash
godot --headless -- --server [--port N] [--region res://data/regions/NAME]
godot           -- --client [--host H] [--port N] [--identity NAME]
```

Controls: `WASD` move, `Shift` sprint, `E` pick up, `Q` drop.

## Testing

```bash
python3 tools/test_phase0.py
```

Runs three headless sessions — two bot clients against a real server — and
asserts handshake, movement, pickup exclusivity, cross-client despawn,
persistence across a server restart, and rejection of a client whose terrain
does not match the server's.

## Layout

| Path | What |
| --- | --- |
| `docs/game-plan.md` | Whole-game build order. **Start here.** |
| `docs/terrain-plan.md` | Wiki map → terrain pipeline (feeds Phase 5) |
| `scripts/net/` | Transport, roles, handshake |
| `scripts/world/` | World authority and replication |
| `scripts/terrain/` | `sample_height` / `sample_surface` contract |
| `scripts/items/` | Item database and inventory model |
| `scripts/player/` | Shared movement, run identically both sides |
| `scripts/client/` | Presentation only; owns no game state |
| `tools/` | Data pipeline and test harness |

## Regenerating data

Region and wiki files are reproducible rather than vendored:

```bash
python3 tools/gen_synthetic_region.py     # test terrain
python3 tools/fetch_map_data.py           # Hagga Basin markers + base render
```

## Notes

- Adding a script with a new `class_name` needs `godot --headless --import`
  before headless runs can see it — globals live in a cache the editor writes.
- Marker data and the base map render are community wiki content
  (CC-BY-SA, [awakening.wiki](https://awakening.wiki)), not game assets.
