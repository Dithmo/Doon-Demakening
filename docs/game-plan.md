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

### Phase 7 — Stretch, in value order — **vehicles and guilds done**
Vehicles (groundcar first — it changes water logistics most, and is the hardest
thing to replicate well). Ornithopters. Guilds and Landsraad. **Deep Desert +
Coriolis storms resetting the map are deliberately last** — that is endgame, and
it is worth having everything else running before the map starts moving.

*Test:* `python3 tools/test_phase7.py`.

**Vehicles.** A groundcar and a light ornithopter, both crafted, deployed from
the bag, fuelled a cell at a time, driven, loaded and packed up again. Driving
follows the project's oldest rule: `VehicleMotion` is one implementation run on
both the driver and the server, exactly as `Movement` is, because prediction
only works if both sides get the same answer from the same input. A vehicle is
not a faster player — it turns and accelerates instead of strafing, so
committing to a heading is the handling.

The reason vehicles land here rather than earlier is that they change the water
economy rather than decorating it. **A groundcar at speed is more than twice as
loud to the worm as a person sprinting, and a parked one is silent.** So the fast
way across the basin is also the way that gets you eaten, and the answer is the
ornithopter — silent while airborne, ignores the traversability mask entirely,
and burns fuel twice as fast for the privilege. Fuel is a separate craft on
purpose: a tank that refilled itself would make all of that decorative.

**Guilds** change exactly one rule, and it is the one that was already the most
consequential: a holding admits its owner's guild. Phase 3's anti-grief boundary
becomes the thing a group organises around instead of a wall between friends.
Claims holds an explicit reference to the register rather than reaching for a
global, and left null it behaves precisely as it did before guilds existed —
which is why every claim test written in Phase 3 still holds unchanged.

**Landsraad standing** is the shared goal: members hand goods to a
Representative marker from the wiki map, priced by the same `value` the trading
post pays, so contributing is always a real choice against selling. Standing is
public and belongs to the guild, not the person. Adding the role sent the
pipeline back to the map — `Representatives` had been falling through to
"landmark" since Phase 5, and there is exactly one house in this crop.

Not done: no passengers (a vehicle carries its driver and its cargo); vehicles
take no damage and cannot be destroyed; guilds have no invitations or ranks —
anyone may join by name and the founder's seat passes to whoever is left; and
Landsraad standing is a scoreboard that does not yet buy anything.

### Phase 8 — The client — **done**
Everything Phases 0–7 built, made reachable by a person rather than a bot.

*Test:* `python3 tools/test_phase8.py`.

This phase exists because of a specific failure of method, and it is worth
naming. Every rule in this project is server-owned and every rule is tested, and
all of that testing is headless and bot-driven — which was the right call, and
caught real bugs in every phase. But it meant **presentation drifted two whole
phases behind the simulation without a single check ever failing.** Vehicles were
replicated and drawn by nobody. Progression, trading, guilds and vehicle cargo
had no interface at all, so the only things that had ever used them were bots and
debug flags. And the ground was still built as one mesh in one pass.

Three things, in the order they mattered:

**Tiled terrain.** `_build_terrain` built the whole region at once: fine for
Phase 0's 512 m map at 65k quads, and 1.76 *million* quads with ~17 million
terrain samples on the real one. A windowed client on Hagga Basin South ran for
over four minutes without drawing a frame. `TerrainView` now builds 96 m tiles,
two per frame, within a 420 m radius, and drops them past 560 m — the gap is
hysteresis, or walking back and forth across a boundary rebuilds the same tile
forever. Fog is tuned to that radius so the world hazes out instead of ending.

**Vehicles are visible**, and the camera follows where you are going. It used to
be pinned facing north, which meant walking south moved you toward the lens with
the ground you were heading into off-screen — unremarkable to a bot, unplayable
for a person. Driving takes the vehicle's heading, so a groundcar turns the view
with it.

**A paged panel** — Journey, Skills, Contracts, Market, Guild, Hold — on Tab,
with the number keys acting on numbered rows. Deliberately text: a mouse-driven
inventory is a great deal of scaffolding for a demake, and a numbered list is
faster to build and faster to use. Every page renders from the replicated
mirrors and never from a local guess, and the dispatch lives beside the pages
rather than in the view, so **a headless client can press a row through the same
code path the keyboard uses.** That is what makes the interface testable at all
rather than only screenshot-able: `--panel MARKET --press 1` produces
`[trade] shopper ok: sold 1 Water for 12 solari` on the server.

Also: a key bound to two actions now warns at startup. Phase 8 bound "ask what
is on offer" to R, which was already "work the node in front of you", so every
harvest pestered the trader. Found by hand, and there is no reason the next one
should be.

Not done: no mouse-look and no aiming — the camera follows movement rather than
a cursor; no name entry, so founding a guild uses a fixed placeholder name; the
panel cannot buy, only sell; there is no map screen, and the wiki's 97 markers
are invisible until you walk into them; and vehicle *appearance* is checked by
eye rather than automatically, since asserting on pixels is worse than useless.

### Phase 9 — The controls — **done**
The keyboard, as its own subject.

*Test:* `python3 tools/test_phase9.py`.

Phase 8 claimed to make Phases 0–7 reachable by a person. It made *Phases 5–7*
reachable, wrote its acceptance suite against those three things, and passed 27
checks. What it missed: **six actions were bound to keys, printed in the HUD as
available, and handled by nobody** — `build`, `demolish`, `container`, `attack`,
`extract`, `toggle_debug`. Every one had a working, replicated, server-validated
implementation behind it; the last inch, `if pressed("attack"): try_attack()`,
was never written. So base building and combat — two entire phases — had no
human input path, and the HUD invited you to press keys that did nothing.

No test could see it. Every harness in this project drives bots, and a bot calls
`world.try_attack()` directly. The keyboard was the one part of the program
nothing had ever exercised.

**The structural fix** matters more than the six lines. Input dispatch is now a
table mapping action name → what it does, and the view checks that table against
the `InputMap` at startup, warning about any registered action nothing answers
to. The set of keys the client handles is now a value the program can compare
against the set of keys it registers, so the next dead key announces itself.
`--do "attack,container"` fires entries through that same table, which is what
makes a key assertable at all — the same trick as `--press`, one layer down.

**Mouse-look**, which turned out to be the reason the game looked dead in
screenshots: the camera was pinned to the direction of travel, so you could not
look at anything you were not already walking at. Movement is now
camera-relative, done by rotating the input vector on the client *before* it is
predicted and *before* it is sent — the server still receives a plain
world-space direction and validates it exactly as before, so prediction stays
byte-identical. Released pointer or a bot means yaw 0, which is the old
behaviour untouched.

**Two pages that were missing subsystems, not polish.** *Bag* is the only way a
person can equip anything — pressing a row uses the slot, and using a stillsuit
wears it. *Container* is the only way to move resources into a chest. Both had
complete server implementations reachable only by bots.

Also: several server decisions were silent. Asking to draw water with no corpse
in reach returned without a log line or a notice — the player got no answer at
all. Attack, extract, demolish and container refusals now all say so, on both
sides. A key that does nothing and says nothing is the same bug as a key that
isn't wired.

Not done: still no aiming — building places a piece a couple of metres ahead
rather than under a cursor; no name entry, so founding a guild uses a fixed
placeholder; the panel sells but cannot buy; no map screen, and the wiki's 97
markers are invisible until you walk into them; and the trading post you spawn
at has no building, so the Market page names a place the world does not draw.

### Phase 10 — The mechanics, read against the wiki — **done**
Four things that were missing outright rather than scaled down.

*Test:* `python3 tools/test_phase10.py`, plus the traversal and spice unit suites.

Phases 0–9 were built from the design in this document. Phase 10 is the first
time the build was checked against [awakening.wiki](https://awakening.wiki)
system by system, and four gaps were not demake cuts — they were things the game
is *made of* that simply did not exist.

**Spice.** The defining substance of the setting was absent in every form: no
item, no blow, no melange, no reason to cross open sand. It is now a cycle
rather than a resource node, which is what the wiki describes: a field is
dormant for 7–15 minutes, erupts for 45 seconds — announced to every player on
the server, with a bearing, because a blow is visible for miles and the race to
it is the point — then dries into cuttable spice for four minutes before the
sand takes it back. Cutting it needs a cutteray and is the **loudest act in the
game** (×34 threat), so the richest thing on the map is also the one that rings
the dinner bell hardest. Spice sand refines 5:1 into melange at a refinery, and
melange is what a major trait costs — one per specialization — so spice is a
progression currency and not merely an expensive rock.

The wiki's eight Spiceblows markers all sit in the north-west of Hagga Basin,
outside the southern crop this region is built from. That is a fact about the
crop, not the game: a blow is an eruption on open sand, not a landmark. So the
seeder takes any marker inside the region and makes up the shortfall on real
open sand, out past a keep-out radius from the trading post — spice you can
reach without crossing open sand is spice without a decision attached.

**Dying cost nothing.** You revived on the spot with a full bag, which made the
worm, the heat and the entire water clock theatre. The wiki is blunt: a player
the worm takes "loses all carried items, including gear and equipment". Now
death empties the bag *and* the equipment slots. Being eaten destroys it;
anything else leaves it where you fell, so a night lost to thirst is a walk back
rather than a wipe.

**Stamina.** Sprinting was limited only by water, making it a travel mode. It is
now a second-to-second budget — sprint, jump and climb all spend it, it returns
only after you ease off, and thirst caps the ceiling. Sprinting is a burst now,
not a way to cross the map, which the bots demonstrated immediately by dropping
to a walk.

**A vertical axis.** Cliffs were walls: `is_walkable` refused them and that was
the end of it, so a mesa was a hole in the map and rock — the one surface a worm
cannot strike through — was reachable only where the ground happened to ramp.
Jumping, gravity, fall damage and stamina-priced climbing are all in the shared
`Movement.step`, advanced from a motion state both sides carry, so prediction
stays exact. Walking into a cliff still slides along it; *holding* climb takes
you up it, and an exhausted climber does exactly what a walker does.

Three real bugs came out of building it, all caught by tests rather than by eye:
stamina regeneration depended on the tick rate (a long tick consumed the delay
and recovered nothing); `Inventory.add` returns the *leftover* rather than the
amount taken, so the spice harvest added the spice and then reported failure;
and only spice *eruptions* were replicated, not the dry-out — a bot walked 750 m,
stood on the blow, and could not cut it, because as far as the client knew it was
still erupting.

Not done, and honestly outstanding: **durability and repair** (the wiki's
Crafting specialization is largely about them) needs per-item wear in inventory
slots, which is a refactor of the stacking model that trading, containers and
persistence all sit on; **armour beyond the stillsuit** — the slots exist,
the items do not; and **ammunition** for the maula pistol.

## Where the demake cuts

Tight spine, ~30–50 items:

- **One weapon family per class**, not eleven. A blade and a dart pistol.
- **Flat recipe trees.** One fabricator tier, not Basic/Advanced/Mk6.
- **No modular vehicles.** A groundcar is a groundcar.
- **Static world.** Coriolis storms are Phase 7; the map doesn't reset.
- **Small sessions.** Design for ~8 players on one server, not an MMO shard.
  This keeps replication naive and lets you skip interest management until it
  actually hurts.
