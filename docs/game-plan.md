# Doon — full game plan

Dune: Awakening is a survival crafting/building MMO. This is the whole-game
build order. `terrain-plan.md` covers one input to Phase 5 and is not the
project plan.

**Decided:** server-authoritative multiplayer from day one; tight content spine.

## What the real game contains

Taken from the community wiki's own category structure, not from memory:

| Area | Systems |
| --- | --- |
| Survival | Hydration, Heat Exhaustion, Blood Harvesting, Coriolis Storms, Sandstorms, Stilltents |
| Water | Dew Harvesters, Blood Extractors, Blood Sacks, Fluid Extractors, Water Containers, Windtraps, Cisterns, Deathstills, Blood Purifiers |
| Gathering | Cutterays, Static Compactors, ore/spice/plant nodes, wreck salvage |
| Crafting | Survival / Garment / Weapons / Vehicle Fabricators (+Advanced), Ore / Spice / Chemical Refineries, Recycler, Repair Station |
| Building | Placeables, structural pieces, power (Fuel & Spice generators, Wind Turbines), storage, Sub-Fief consoles |
| Garments | Head / Torso / Hands / Legs / Feet slots, Light & Heavy Armor, Stillsuits, Augmentations |
| Weapons | Melee: crysknives, dirks, kindjals, rapiers, swords, long/short/dual blades. Ranged: maula pistols, battle rifles, spitdarts, scatterguns, drillshots, disruptors, lasguns, vulcans, pyrockets, missile launchers, flamethrowers. Plus Shields |
| Utility | Thumpers, Scanners, Suspensor Belts, Staking Units, Glow/Survey/Cartography/Solido tools, Power Packs |
| Vehicles | One/Four-Man Groundcars, Light/Medium Ornithopters, Sandcrawlers, Carryalls — all modular |
| Threats | Sandworms, enemy camps (263 in Hagga Basin), outposts (90), local gangs, scavengers |
| Progression | Player Level, Faction Rank, Archetypes, Specializations (Combat/Crafting/Exploration/Gathering/Sabotage), Trainers |
| Content | Journeys (story), Contracts & Contract Chains, Landsraad Missions, Testing Stations, Dungeons, Caves, Shipwrecks |
| Social | Guilds, Landsraad politics, Houses Major/Minor, Solari, Merchants, Tradeposts |
| World | Hagga Basin sub-regions, Deep Desert sectors A-2..A-9, Arrakeen, Harko Village |

A demake cannot be all of that. It can be the *spine* of it.

## The spine: water is the clock

Every survival game needs one resource that makes the clock tick. In Dune it is
unambiguously **water**. Hydration drains constantly; heat accelerates it;
shade, stillsuits and shelter slow it; every water source is a reason to leave
safety. Get that loop right and the game is recognisably Dune with no worm, no
vehicles and one weapon.

The sandworm is not the core. It is the **antagonist of the water economy** —
the reason a gathering run is a decision rather than a chore. It needs an
economy to threaten before it means anything, which is why it lands in Phase 4
and not Phase 1.

## Architecture: server-authoritative from day one

The client never owns game state. It sends intent; the server simulates and
replicates results. Non-negotiable for hydration, inventory, crafting, building
placement and loot, because every one of those is trivially cheatable
client-side.

**Solo play is a one-client session against a local headless server.** This is
the mitigation that makes the multiplayer choice affordable: you do not lose
fast solo iteration, you just always run the split. Build the headless server
target and a `run N clients` script in Phase 0 and never test any other way — an
MP bug found in week 1 is cheap, the same bug found in Phase 4 is not.

Rules that stay true for the whole project:

- **Prediction for movement only.** Player locomotion predicts and reconciles.
  Everything else — pick up, craft, place, drink, attack — is request → server
  validates → replicated result. A 100 ms delay on "drink" is unnoticeable; a
  desynced inventory is fatal.
- **Gameplay code never reads local state directly.** All reads go through the
  replicated store, so there is exactly one code path on host and client.
- **Server owns the clock.** Time-of-day drives heat, hydration drain and dew
  harvesting; if it drifts per-client the whole survival loop desyncs.
- **The terrain pipeline output is shared, static, and identical both sides.**
  Server needs the mask for worm logic and validation; client needs mesh plus
  mask for prediction. Since `terrain-plan.md` emits plain files, this is free —
  ship the same artefacts to both, version them, and refuse mismatched clients.
- **Persistence is server-side.** Built structures and containers outlive the
  session that made them.

Godot 4 gives you `MultiplayerSpawner`, `MultiplayerSynchronizer` and RPCs over
ENet. That covers replication; it does not cover authority discipline, which is
on us.

## Dependency order

Nothing here is arbitrary — each phase is blocked on the one before it.

```
Foundations (net spine, player, terrain iface, inventory, item DB)
     |
Water loop  ->  Economy (gather/craft)  ->  Base (place/power/store)
                                                  |
                                          Threat (worm, heat, combat)
                                                  |
                                          Real world (Hagga Basin, POIs)
                                                  |
                                          Progression -> Content
                                                  |
                                          Stretch (vehicles, Deep Desert, guilds)
```

**Inventory and the item database are the root.** Crafting, building, loot,
gathering, vendors and equipment all resolve to item IDs. Build it once, early,
and generously — a data-driven `ItemDef` resource with stack size, slot, weight,
and a `use` behaviour hook. Getting this wrong is the single most expensive
mistake available, because everything downstream references it, and under
server authority a late change means migrating persisted state too.

## Phases

Each phase ends in something you can actually play, with at least two clients
connected. That is the whole point of the ordering.

### Phase 0 — Foundations — **done**
Godot project with **client and headless-server targets**, ENet transport,
connect/join/disconnect, and a script to launch a server plus N clients.
Character controller with predicted movement and reconciliation. `TerrainData`
interface (`sample_height`, `sample_surface`) backed by a synthetic region,
loaded identically both sides. Server-owned inventory + item database + client
inventory UI driven purely by replicated state. Server-side persistence.

*Test:* `python3 tools/test_phase0.py` — 21 assertions across three headless
sessions: handshake, bot-driven movement, pickup exclusivity, cross-client
despawn, persistence across a server restart, and rejection of a client whose
terrain does not match the server's.
*Not fun yet. Nothing after this works without it.*

Done: transport and handshake with protocol + terrain-fingerprint gating,
kinematic movement with client prediction and server reconciliation, the
`TerrainData` contract over a shared binary region format, server-owned
inventory and the item database, ground-item entities with server-validated
pickup, server-side persistence, a bot client for headless testing, and the
`tools/run_session.sh` launcher.

Not done: no HUD beyond a debug overlay, no equipment or use-hooks wired up
(the `ItemDef` fields exist but nothing consumes them yet), no reconnect
handling, no authentication — identity is whatever the client claims.

### Phase 1 — The water loop ← smallest recognisably-Dune build
Server-simulated hydration draining in real time, replicated to owning clients.
Heat exhaustion tied to a server-authoritative time-of-day and shade. One water
source — a dew harvester, since it only works dusk→dawn and so imposes a
schedule for free. One drinkable item. Death and respawn.

*Test:* can you die of thirst, and can you plan a night route to avoid it? Do
two players agree on what time it is?
*This is the vertical slice. If this isn't tense, stop and fix it before
building anything else.*

### Phase 2 — Economy — **done**
Resource nodes with server-owned depletion and respawn (contested harvesting is
the first real concurrency test). A gathering tool (cutteray). Fabricator
placeable + recipe data. Refining. First meaningful craft: the **stillsuit**,
which cuts water drain substantially.

*Test:* `godot --headless -- --run-tests` for node and crafting rules,
`python3 tools/test_phase2.py` for the wire — five sessions covering depletion,
two clients contending for one node, deployment, crafting, persistence, and the
stillsuit payoff.
*That's your first real progression beat, and it's pure economy.*

Done: four node kinds that deplete and regrow on their own timers, tool-gated
harvesting with a swing cooldown, deployable stations validated server-side,
a data-driven recipe table, and the gather → refine → craft chain ending in a
stillsuit that measurably halves water loss (0.52 vs 1.18 per tick at midday,
measured).

The concurrency result that matters: with two bots working the same veins, six
nodes were worked by both and no node was ever decremented twice for one swing.
The node's remaining count is the lock, and it lives only on the authority.

`Terrain.is_reachable()` was added here and is load-bearing beyond Phase 2: the
generator used to ring every outcrop in cliff, so *all* rock was unreachable.
Nodes were spawning on plateaus nobody could stand on — and Phase 4's "flee to
rock" would have had nowhere to flee to. Outcrops now get varied talus aprons,
and the generator reports reachable rock (99.9%) so a bad map fails at
generation rather than in play.

Not done: crafting is instant (no progress bar), the craft key picks the first
available recipe rather than opening a menu, and stations have no ownership --
anyone can pack one up. All three are Phase 3 concerns.

### Phase 3 — Base — **done**
Placement with snapping and **server-side validation** — overlap, terrain fit,
and ownership, since this is where griefing lives. Structural pieces, storage
containers with concurrent-access rules. Power (generator + wind turbine).
Windtrap and cistern producing water passively while offline. Stilltent as a
portable safe point.

*Test:* `godot --headless -- --run-tests` for claim, build and power rules,
`python3 tools/test_phase3.py` for the wire — four runs covering a base being
raised, production continuing with nobody connected, a restart paying out the
gap, a second player being refused, and container transfers.
*The base converts water from a per-trip crisis into infrastructure — that shift
is the game's mid-game.*

Done: claims anchored on a Sub-Fief console; a snapped build grid with real
support rules (foundation → wall → ceiling, where a ceiling is the floor of the
storey above, so multi-storey comes free); power pooled per holding rather than
wired piece to piece; windtraps filling cisterns; containers with server-owned
transfers; and the stilltent as portable shade.

The measured results: a windtrap kept producing for 7 ticks after the player
logged out, a restart paid out the gap (18 → 22 water), and a second player was
refused 102 times trying to build on someone else's land.

Two fixes worth noting. `ItemDB` whitelisted which fields it copied, so every
new item property vanished silently — that cost a debugging round in Phase 2
(`station`) and again here (the whole power/container set). It now passes every
key through and normalises only the typed ones, so adding an item property is a
data change. And deploying now snaps to the nearest legal spot instead of
demanding the player stand exactly right, because otherwise a second station
could not go down without walking away from the first.

Not done: power is binary (a starved holding simply stops rather than
browning out), generators never consume fuel, containers have no access control
beyond the claim, and there are no doors — a wall is a wall.

### Phase 4 — Threat — **done**
Now, and not before: sandworms on sand, keyed to the traversability mask, as
**replicated world entities** with server-owned aggro — per-player threat
accumulation, one shared worm. Thumpers as bait and as a tool. Melee + ranged
combat with the Dune shield rule (slow blade penetrates), server-hit-validated.
Enemy camps. Corpse blood extraction, tying combat back into the water economy.

*Test:* `godot --headless -- --run-tests` for the worm, shield and blood rules,
`python3 tools/test_phase4.py` for the wire — five runs covering a strike on
open sand, escaping to rock, a thumper as bait, the shield trade, and hostiles
into blood.

Done: one shared worm reading the same traversability mask the terrain pipeline
produces, with server-owned threat; thumpers as bait; combat with the Holtzman
rule; enemy camps; and blood extraction closing the loop back to the water
economy.

The encounter, and why it is shaped this way. Threat builds while you move on
open sand — faster sprinting, faster still with a shield running — and bleeds
off if you stand still, faster again on rock. The worm wakes, comes, surfaces
for five seconds, then takes whatever is still on sand inside eleven metres.
It travels at 11 m/s against a 7.6 m/s sprint **on purpose**: you cannot outrun
it, so the answer is never "run further", it is "get off the sand". A worm you
could outrun would make the mask decorative.

Measured over the wire: threat peaked at 100 and the prey bot was taken; a bot
that ran for rock during the warning was spared and the worm lost interest; a
thumper woke the worm on its own and drew it off the player; and a running
shield made a bot 2.7x louder (20.6 vs 7.6 threat per tick).

The shield is the phase's best trade. It turns fast blades and darts and is
useless against a slow one, so a shielded opponent is a puzzle rather than a
wall — and the same shield that saves you in a fight is what gets you eaten
crossing open ground.

Not done: NPCs carry no shields, so the Holtzman rule only bites between
players; there is no ranged projectile travel (a dart resolves instantly at
range); worms never appear in the deep desert because there is no deep desert
yet; and one worm serves the whole map.

### Phase 5 — The real world — **done**
Swap the synthetic region for Hagga Basin South via `terrain-plan.md`. Real
mask, real heights, the 655 POIs — wrecks as loot sites, caves as worm-safe
shelters, camps as threat spawns. Version the terrain artefacts and reject
mismatched clients.

*Test:* navigate between two named landmarks using the actual wiki map,
`python3 tools/test_phase5.py`.

Done: the game's default region is now **Hagga Basin South, 4500 × 1560 m**,
recovered from the wiki's own map render by `tools/build_region.py` — a
traversability mask at one byte per metre, a heightmap at 2 m, and 97 markers
projected into world space. World coordinates round-trip back to the wiki's CRS
to within 6 mm, so a player reading the community map is reading this world.

The elevation is *recovered*, not invented. Outcrop heights come from the length
of the shadow each one casts under the render's baked sun; dune relief comes
from shape-from-shading, which works here because the light direction is known.
Re-rendering the recovered height with that same light and correlating it
against the source scores **+0.74**, against 0.00 for a shuffled control. Only
the sub-metre grain is noise, and that is the one part the source genuinely
cannot hold.

The markers are what stop it being scenery: 20 caves are worm-safe shelter, 51
camps and outposts are where the 153 hostiles stand, and salvage sits on all 10
wreck and loot markers rather than scattered at random. Caves matter
mechanically more than they look — Hagga Basin South is mostly open dune with
rock in scattered clumps, so there are stretches where the nearest outcrop is
further away than the worm's warning gives you, and the caves are what make
those crossable rather than simply fatal.

Phases 0–4 are pinned to the synthetic region now. Their thresholds were tuned
against a 512 m map, and re-tuning five suites for a 4500 m one would have
turned a swap into a rewrite; each stays a test of its own subsystem.

Not done: the region is one crop of one basin, so the rest of Hagga Basin and
all the deep desert are still absent; caves are marker-radius volumes rather
than actual interiors; wrecks are salvage nodes rather than places you enter;
and the heightmap feeds gameplay sampling but there is no mesh or collider built
from it yet.

### Phase 6 — Progression and content — **done**
Player level, the five specializations, trainers, contracts, testing stations, a
Journey questline. Solari and vendors. All progression state server-owned.

*Test:* a new character has a directed 2–3 hour path,
`python3 tools/test_phase6.py`.

Done: experience and twelve levels, five specializations with fifteen skills
between them, trainers you have to physically stand at, a twelve-step Journey,
eight contracts in four chains, Solari, and a trading post that buys and sells.

**Progress is observed, never claimed.** One server-side funnel — `_advance` —
takes every rewardable thing that actually happened, awards the experience,
advances whatever Journey step or contract it touches, pays out, and tells the
client. No client ever reports finishing anything, and no subsystem knows what a
quest is: harvesting calls it with `gather`, the worm's victims never do. Adding
an objective kind is a data change plus one call.

**Skills move dials that already existed** rather than adding a parallel stat
sheet. Blade Training multiplies the damage `Combat.strike` already computed,
Light Step multiplies the threat rate the worm already accrues, Cave Sense
widens the shelter radius Phase 5 introduced, Deep Harvest adds to the node
yield. Every one of them defaults to 1.0 or 0, so the call sites multiply
unconditionally and every test written before Phase 6 still means what it meant.

The Journey is the phase's headline and it is tested by a bot that reads the
objective rather than following a script — it knows how to satisfy each *kind*
of goal, not which steps exist, so reordering the Journey into something
unplayable fails the test instead of passing it quietly.

Two bugs this phase surfaced that were not its own. Node counts were tuned
against a 0.26 km² test map and never rescaled when Phase 5 made the world
7.0 km², so density had silently dropped twenty-seven-fold and the nearest agave
was 700 m from anywhere; nodes now carry a per-km² density with the old count as
a floor. And new players spawned at the geometric centre of the map, which on
the real region is a patch of empty sand — they now start at Griffin's Reach
Trading Post, which has a trainer fifty metres away.

Not done: testing stations are a Journey step that asks you to carry a blade to
a marker rather than a system of their own; contracts do not expire or repeat;
there is no faction rank, no Landsraad, and no guilds; and the five tracks share
three trainers because the region crop only contains three trainer-ish markers.

### Phase 7 — Stretch, in value order
Vehicles (groundcar first — it changes water logistics most, and is the hardest
thing to replicate well). Deep Desert + Coriolis storms resetting the map.
Ornithopters. Guilds and Landsraad.

## Where the demake cuts

Tight spine, ~30–50 items:

- **One weapon family per class**, not eleven. A blade and a dart pistol.
- **Flat recipe trees.** One fabricator tier, not Basic/Advanced/Mk6.
- **No modular vehicles.** A groundcar is a groundcar.
- **Static world.** Coriolis storms are Phase 7; the map doesn't reset.
- **Small sessions.** Design for ~8 players on one server, not an MMO shard.
  This keeps replication naive and lets you skip interest management until it
  actually hurts.
