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

### Playing it

`tools/run_session.sh` with no arguments is the whole thing: a headless server
and one window. You start at Griffin's Reach Trading Post with water, a
cutteray, a dew harvester and a fabricator.

**Getting about**

| Key | Does |
| --- | --- |
| `WASD` / arrows | Walk, relative to where the camera is facing |
| `Shift` | Sprint — doubles water loss, and noise wakes the worm |
| Mouse | Look around. Click the window to capture the pointer, `Esc` to release |

**Acting on the world** — the HUD only lists a key when there is something for
it to act on, and every one of them answers, refusals included.

| Key | Does |
| --- | --- |
| `E` | Pick up what is on the ground |
| `R` | Work the resource node in front of you (needs a cutteray) |
| `F` | Drink |
| `G` | Harvest dew — after dark only, richest just before sunrise |
| `B` | Deploy the first deployable in your bag |
| `C` | Craft the first thing you have the parts for |
| `V` / `X` | Build a piece / remove one |
| `T` | Open or close the chest you are standing at |
| `Space` | Attack what is in reach |
| `Z` | Draw water from a body |
| `Y` / `U` / `P` | Vehicle: climb in or out / refuel / pack up |
| `Q` | Drop the first thing you are carrying |

**Pages** — `Tab` cycles them, `1`–`9` act on the numbered rows, `I` jumps
straight to the bag, `F3` hides the HUD for a clean screenshot.

| Page | For |
| --- | --- |
| Bag | **Equipping.** A row uses the slot, and using a stillsuit wears it |
| Journey | The twelve-step path and how far along it you are |
| Skills | Five specializations, what each costs, and who teaches it |
| Contracts | What you are carrying, and what is on offer here (`H` to ask) |
| Market | Sell, at a trading post |
| Guild | Found or join (`N`), and the Landsraad standing table |
| Hold | Cargo in the vehicle you are driving |
| Container | **Moving resources.** Take from a chest, or store into it |

Learning a skill, taking a contract and selling all require standing at the
right person — the server checks, so walking there is the game.

## Testing

```bash
godot --headless -- --run-tests                          # survival rules, seconds
python3 tools/test_phase0.py                            # net spine + inventory
python3 tools/test_phase1.py                            # the water loop
python3 tools/test_phase2.py                            # the economy
python3 tools/test_phase3.py                            # bases and power
python3 tools/test_phase4.py                            # worms and combat
python3 tools/test_phase5.py                            # the real Hagga Basin
python3 tools/test_phase6.py                            # progression and content
python3 tools/test_phase7.py                            # vehicles and guilds
python3 tools/test_phase8.py                            # the client (needs xvfb-run)
python3 tools/test_phase9.py                            # the controls (needs xvfb-run)
```

The Python harnesses drive real bot clients against a real headless server and
assert on what the session actually logs — handshake, pickup exclusivity,
persistence, terrain-mismatch rejection, day-versus-night water drain, shade,
dew-harvest refusal in daylight, death and respawn.

Useful debug flags when running by hand: `--day-seconds N` (a huge value pins
the clock), `--start-time 0..1` (0.5 = noon, 0.0 = midnight),
`--start-hydration N`, `--grant "id:count,id:count"`,
`--bot-profile survive|reckless|forager|builder|prey|quarry|fighter|pilgrim|journeyman|driver`,
`--peaceful` (server: suppress worm and hostiles, for test isolation),
`--spawn-at "<wiki POI name>"` (server: where new players start),
`--goto "<wiki POI name>"` (client: where a `pilgrim` bot walks),
`--learn <skill id>` (client: attempt to learn once, for testing the trainer rule),
`--guild <name>` / `--deliver` (client: join or found a guild, then give to the Landsraad),
`--panel BAG|JOURNEY|SKILLS|CONTRACTS|MARKET|GUILD|HOLD|CONTAINER` and `--press N`
(client: open a panel page, log it, and press one of its rows — works headless),
`--do "attack,container"` (client: fire actions through the same dispatch table the
keyboard uses, so a harness can prove a key does its job; needs a window),
`--debug-steer`.

## Layout

| Path | What |
| --- | --- |
| `docs/game-plan.md` | Whole-game build order. **Start here.** |
| `docs/terrain-plan.md` | Wiki map → terrain pipeline, and what building it corrected |
| `scripts/net/` | Transport, roles, handshake |
| `scripts/world/` | World authority, clock, nodes, stations, base, worm |
| `scripts/terrain/` | `sample_height` / `sample_surface` contract |
| `scripts/items/` | Item database, recipes, inventory, use hooks, combat |
| `scripts/player/` | Shared movement, survival vitals, progression and skills |
| `scripts/client/` | Presentation only; owns no game state. Tiled terrain, paged panels |
| `tools/` | Data pipeline and test harnesses |
| `tests/` | In-engine unit tests (`-- --run-tests`) |

## Regenerating data

Region and wiki files are reproducible rather than vendored, so the heightmap
and mask are built rather than checked in. **A fresh clone has to build the real
region before it can play on it** — until then the game falls back to the
synthetic one and says so.

```bash
python3 -m pip install -r tools/requirements.txt
python3 tools/gen_synthetic_region.py     # small test terrain
python3 tools/fetch_map_data.py           # 655 markers + the 8182^2 render
python3 tools/build_region.py             # -> Hagga Basin South, the real map
```

Each region is four files: `region.json`, `height.r16`, `mask.u8` and
`reach.u8`. The last is derived from the mask, but it is shipped rather than
computed at load — flood-filling 7 million cells in GDScript took **12 seconds
on every server and client boot**, which was long enough to starve a connecting
client into timing out. The engine still derives it if the file is missing.

`build_region.py` recovers elevation from the render's baked sun rather than
inventing it: outcrop heights come from the length of the shadow each one casts,
dune relief from shape-from-shading. Pass `--debug DIR` to dump the intermediate
images, and `--measure-sun` to re-derive the sun angle from the picture instead
of trusting the constant. It prints a shading-fidelity score — the recovered
terrain re-rendered under the same light, correlated against the source — which
should be around +0.74; a low or negative number means the sun vector is wrong.

## Notes

- Adding a script with a new `class_name` needs `godot --headless --import`
  before headless runs can see it — globals live in a cache the editor writes.
- Marker data and the base map render are community wiki content
  (CC-BY-SA, [awakening.wiki](https://awakening.wiki)), not game assets.
