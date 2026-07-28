# Doon — full game plan

Dune: Awakening is a survival crafting/building MMO. This is the whole-game
build order. `terrain-plan.md` covers one input to Phase 5 and is not the
project plan.

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

## Dependency order

Nothing here is arbitrary — each phase is blocked on the one before it.

```
Foundations (player, terrain iface, inventory, item DB)
     |
Water loop  ->  Economy (gather/craft)  ->  Base (place/power/store)
                                                  |
                                          Threat (worm, heat, combat)
                                                  |
                                          Real world (Hagga Basin, POIs)
                                                  |
                                          Progression -> Content
                                                  |
                                          Stretch (vehicles, Deep Desert, MP)
```

**Inventory and the item database are the root.** Crafting, building, loot,
gathering, vendors and equipment all resolve to item IDs. Build it once, early,
and generously — a data-driven `ItemDef` resource with stack size, slot, weight,
and a `use` behaviour hook. Getting this wrong is the single most expensive
mistake available, because everything downstream references it.

## Phases

Each phase ends in something you can actually play. That is the whole point of
the ordering.

### Phase 0 — Foundations
Godot project, character controller, camera, a flat test world. `TerrainData`
interface (`sample_height`, `sample_surface`) backed by a synthetic region.
Inventory model + item database + a working inventory UI. Save/load.

*Test:* walk around, pick up a debug item, see it in the bag, reload and it's
still there.
*Not fun yet. Nothing after this works without it.*

### Phase 1 — The water loop ← smallest recognisably-Dune build
Hydration stat draining in real time. Heat exhaustion tied to time-of-day and
shade. One water source (a dew harvester, since it only works dusk→dawn and so
imposes a schedule for free). One drinkable item. Death and respawn.

*Test:* can you die of thirst, and can you plan a night route to avoid it?
*This is the vertical slice. If this isn't tense, stop and fix it before
building anything else.*

### Phase 2 — Economy
Resource nodes (plant fibre, ore, salvage). A gathering tool (cutteray).
Fabricator placeable + recipe data. Refining. First meaningful craft: the
**stillsuit**, which cuts water drain substantially.

*Test:* gather → refine → craft a stillsuit → measurably survive longer.
*That's your first real progression beat, and it's pure economy.*

### Phase 3 — Base
Placement with snapping, structural pieces, storage containers. Power
(generator + wind turbine). Windtrap and cistern producing water passively.
Stilltent as a portable safe point.

*Test:* build a base with a windtrap, go on a run, come back to stored water.
*The base converts water from a per-trip crisis into infrastructure — that shift
is the game's mid-game.*

### Phase 4 — Threat
Now, and not before: sandworms on sand, keyed to the traversability mask.
Thumpers as bait and as a tool. Melee + ranged combat with the Dune shield rule
(slow blade penetrates). Enemy camps. Corpse blood extraction, which ties
combat back into the water economy.

*Test:* a loaded return trip across open sand is genuinely frightening because
you can lose the run.

### Phase 5 — The real world
Swap the synthetic region for Hagga Basin South via `terrain-plan.md`. Real
mask, real heights, the 655 POIs — wrecks as loot sites, caves as worm-safe
shelters, camps as threat spawns.

*Test:* navigate between two named shipwrecks using the actual wiki map.

### Phase 6 — Progression and content
Player level, the five specializations, trainers, contracts, testing stations,
a Journey questline. Solari and vendors.

*Test:* a new character has a directed 2–3 hour path.

### Phase 7 — Stretch, in value order
Vehicles (groundcar first — it changes water logistics most). Deep Desert +
Coriolis storms resetting the map. Ornithopters. Multiplayer, Guilds, Landsraad.

## Where the demake cuts

- **One weapon family per class**, not eleven. A blade and a dart pistol.
- **Flat recipe trees.** One fabricator tier, not Basic/Advanced/Mk6.
- **No modular vehicles.** A groundcar is a groundcar.
- **Static world.** Coriolis storms are Phase 7; the map doesn't reset.
- **Solo-first.** See below.

## The one decision that can't be deferred

**Single-player or multiplayer.** This is not a Phase 7 question — it decides
whether Phase 0's inventory, building and save systems are authoritative-server
or local. Retrofitting multiplayer onto a solo codebase is a rewrite, not a
feature. Everything above assumes solo unless decided otherwise now.
