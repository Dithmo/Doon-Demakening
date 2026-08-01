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

Clone and run — the maps are committed, so there is no build step and no Python
needed to play.

Or by hand. The **first** run of a fresh checkout needs one import pass: Godot
registers `class_name` scripts during import, and the autoloads reference them,
so without it every autoload fails to parse and the game never starts.
`run_session.sh` does this for you; by hand it is one command, once.

```bash
godot --headless --import                 # once per fresh clone
godot --headless -- --server [--port N] [--region res://data/regions/NAME]
godot           -- --client [--host H] [--port N] [--identity NAME]
```

### Playing it

`tools/run_session.sh` with no arguments is the whole thing: a headless server
and one window. You start at Griffin's Reach Trading Post with water, a
cutteray and a dew harvester. There is no workbench in the kit: a Survival
Fabricator is a *structure* built from refined metal, so it comes after a claim,
a floor and a refinery -- not before them.

**Getting about**

| Key | Does |
| --- | --- |
| `WASD` / arrows | Walk, relative to where the camera is facing |
| `Shift` | Sprint — spends vigour and water, and the noise wakes the worm |
| `Space` | Jump |
| `Ctrl` (hold) | Climb the cliff you are pushing into, while your vigour lasts |
| Mouse | Look around. Click the window to capture the pointer, `Esc` to release |

Vigour is the second-to-second budget: sprinting, jumping and climbing all
spend it, it only returns once you ease off, and thirst caps how much of it you
get back. A cliff is a decision, not a ramp — and rock is the one surface a worm
cannot strike through, so it is worth the climb.

**Acting on the world** — the HUD only lists a key when there is something for
it to act on, and every one of them answers, refusals included.

| Key | Does |
| --- | --- |
| `E` | Pick up what is on the ground |
| `R` | Work what is in front of you: a resource node, or a spice blow |
| `F` | Drink |
| `G` | Harvest dew — after dark only, richest just before sunrise |
| `B` | Set down field kit -- a thumper, a stilltent |
| `C` | Craft the first thing you have the parts for |
| `V` / `X` | Place the selected structure / remove one |
| `T` | Open or close the chest you are standing at |
| Left mouse | Attack what is in reach |
| `Z` | Draw water from a body |
| `Y` / `U` / `P` | Vehicle: climb in or out / refuel / pack up |
| `Q` | Drop the first thing you are carrying |

**Items are made; structures are placed.** Anything you carry — tools, weapons,
ingots — is crafted, at personal crafting (`C`) or at a bench. Anything that
stands in the world — the Sub-Fief, foundations, walls, the refinery, the
fabricator itself — is *placed with the Construction Tool* and paid for straight
out of your bag. No structure is ever an item, and no recipe makes one. Open the
Build page, pick one, and pull the trigger with the tool in hand.

Everything but the Sub-Fief has to stand on a foundation, and the Sub-Fief is the
only thing that may go on unclaimed desert — so the opening has exactly one legal
order: **claim the ground, floor it, then build on the floor.**

**The bag and the bar** — `I` opens a grid you drag items around with the
mouse. Drag something onto the ten-slot bar along the bottom, then press its
number to take it in hand. What the **left mouse button** does depends on what
you are holding: a cutteray opens a beam that runs until you let go, anything
else swings. Aim with the crosshair — a node drains four units a second while
you hold the trigger, and a wreck or a vein holds forty.

**Pages** — `Tab` cycles them, `1`–`9` act on the numbered rows, `I` jumps
straight to the bag, `F3` hides the HUD for a clean screenshot.

| Page | For |
| --- | --- |
| Bag | **Equipping.** A row uses the slot, and using a stillsuit wears it |
| Build | **Structures.** Everything the Construction Tool can place, by category, with its price. A row selects; the trigger places |
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
python3 tools/test_phase10.py                           # spice, death, stamina, climbing
python3 tools/test_phase11.py                           # bag, hotbar, beam (needs xvfb-run)
```

The Python harnesses drive real bot clients against a real headless server and
assert on what the session actually logs — handshake, pickup exclusivity,
persistence, terrain-mismatch rejection, day-versus-night water drain, shade,
dew-harvest refusal in daylight, death and respawn.

Useful debug flags when running by hand: `--day-seconds N` (a huge value pins
the clock), `--start-time 0..1` (0.5 = noon, 0.0 = midnight),
`--start-hydration N`, `--grant "id:count,id:count"`,
`--bot-profile survive|reckless|forager|builder|prey|quarry|fighter|pilgrim|journeyman|driver|spicer`,
`--spice-now` (server: bring every spice field to a cuttable blow and hold it
there — the real cycle is 7–15 minutes of nothing, which is right for play and
useless for a test),
`--peaceful` (server: suppress worm and hostiles, for test isolation),
`--spawn-at "<wiki POI name>"` (server: where new players start),
`--goto "<wiki POI name>"` (client: where a `pilgrim` bot walks),
`--learn <skill id>` (client: attempt to learn once, for testing the trainer rule),
`--guild <name>` / `--deliver` (client: join or found a guild, then give to the Landsraad),
`--panel BAG|BUILD|JOURNEY|SKILLS|CONTRACTS|MARKET|GUILD|HOLD|CONTAINER` and `--press N`
(client: open a panel page, log it, and press one of its rows — works headless),
`--do "trigger,container"` (client: fire actions through the same dispatch table the
keyboard uses, so a harness can prove a key does its job; needs a window),
`--drag "bag:1>hot:0"` (client: run drags through the grid's own drop(), which is
what the pointer calls — the only way a mouse UI is testable at all; needs a window),
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

**The maps ship with the repo.** Clone it, point `$GODOT` at Godot 4.5, and run
— there is no build step and no Python needed to play. Hagga Basin South and the
two synthetic test regions are all committed, about 3 MB compressed between them.

They were left out once, on the reasoning that anything reproducible should be
rebuilt rather than vendored. That is a sound rule for build *inputs* and a bad
one for the game's own map: it meant a fresh clone had no ground to stand on and
would not run until the player installed numpy and ran two scripts. The tools
below are how the map is *re*-made when the pipeline changes — not how anyone
obtains it.

```bash
python3 -m pip install -r tools/requirements.txt
python3 tools/gen_synthetic_region.py     # small test terrain
python3 tools/fetch_map_data.py           # 655 markers + the 8182^2 render
python3 tools/build_region.py             # -> Hagga Basin South, the real map
```

The 8182-pixel wiki render those last two need is the one thing still not
vendored: it is large, it is only ever an input, and nothing at runtime reads it.

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
