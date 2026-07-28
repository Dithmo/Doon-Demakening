# Hagga Basin South — terrain source plan

> Scope: this document covers **one input to Phase 5** of `game-plan.md` —
> turning wiki map data into terrain. It is not the project plan. For build
> order across the whole game, start with `game-plan.md`.

Revision of an earlier three-layer plan, after verifying its assumptions against
the actual wiki data. The layered structure survives. Several of the numbers and
one of its central claims did not.

Everything below marked **verified** was checked against fetched data, not
inferred. Reproduce with `python3 tools/fetch_map_data.py`.

## What changed from the earlier plan

| Earlier claim | Status |
| --- | --- |
| Markers load from a `Data:` namespace page | **Wrong namespace.** This wiki has no `Data:` (486). Markers live in `Map:` (2900), page `Map:Hagga Basin`. |
| Marker coords are "normalised x/y you multiply by your world extent" | **Wrong.** They are absolute in a 0..100000 CRS. Treating them as 0..1 puts all 655 markers in one corner pixel. |
| Hagga Basin South is "likely a 2–3 km square" | **Wrong shape.** It is a wide, shallow strip: ~3.6 km × ~1.2 km. |
| "1024×1024 heightmap at 2.5 m per cell covers it" | **Undersized and over-coarse.** See sizing below. |
| The map "cannot give you the height of anything" | **Too strong, and it's the costly error.** The render has a baked directional sun; shadow length encodes height. |
| Sand/rock split is "a colour-threshold job" | **Won't work as described.** Lit rock tops are *brighter* than sand, and region tints shift hue globally. Texture energy works; hue does not. |

The last two are the ones that matter. The earlier plan concluded elevation was
unrecoverable and therefore had to be invented from noise. It is partly
recoverable, and recovering it is not much harder than inventing it.

## Verified facts

**Marker data.** `Map:Hagga Basin` is raw DataMaps JSON, served by the MediaWiki
action API with no auth. 655 markers in 19 groups: 263 enemy camps, 90 outposts,
74 caves, 51 intel points, 39 agave, 31 unique loot, 18 Landsraad reps, 13
shipwrecks, 13 ecology labs, plus trainers, trading posts, sandbikes, spice
blows, NPCs, Trials of Aql, landmarks.

**Coordinate system.** `crs: topLeft [0,0], bottomRight [100000,100000], order
"xy"`. **y increases southward** — screen convention, no flip. Confirmed twice
over: rendering markers unflipped lands shipwreck pins exactly on the wreck
sprites drawn into the map and cave pins on cave mouths; and independently,
"Hagga Basin South" resolves to the highest y-values of any sub-region.

**Base render.** `File:Hagga Basin.webp`, **8182 × 8182 px**, ~4.9 MB, no auth.
Against a region ~8.1 km across this is **≈1 px per metre** — the single most
useful number here. Conversion:

```
pixel_x = crs_x / 100000 * 8182          metres ≈ pixels
pixel_y = crs_y / 100000 * 8182          (y already points south)
```

**Sub-region extents** (`data/regions.json`) come from POI-article/category
cross-reference — each sub-region category's members matched against marker
`article` fields. These are hulls over *known POIs*, so they are a floor on true
extent, not a border.

**Hagga Basin South:** CRS x[44640, 88058], y[80763, 94598] → pixel x[3652,
7205], y[6608, 7739] → **≈3553 × 1132 m**, sitting south-centre-east. Extend
south to the map edge (y=8182 px) and pad ~200 px each way and you get a working
crop of about **3950 × 1725 m**.

**Baked sun.** Measured by correlating bright (rock-top) pixels against dark
(shadow) pixels over a sweep of offsets: shadows fall along image-space azimuth
**120°** (where 0° = +x/east, 90° = +y/south) — i.e. direction `(-0.50, +0.87)`,
down and to the left, sun in the upper-right. Shadow occupancy rises smoothly
from 0 and saturates at **~40–45 px**, so the tallest outcrops in Hagga Basin
South cast ~40 m shadows. One bake for the whole map, so this holds everywhere.

## Sizing

Terrain covering ~3950 × 1725 m at 1 m/px source data. The earlier plan's
1024×1024 @ 2.5 m throws away 60% of the linear detail the source actually has
and forces a square onto a 3.4:1 strip.

Use a **non-square heightmap at 2 m/cell: 1984 × 864**. That is 1.7 M cells —
fine for a `HeightMapShape3D` collider and, if you use Godot's `Terrain3D`,
irrelevant since it chunks anyway. Keep the **traversability mask at native 1 m**
(3950 × 1725), because gameplay reads the mask far more precisely than the eye
reads the relief — worm-safe/exposed is a hard boundary and wants full source
resolution.

Sanity check on the vertical: a 40 m shadow with a sun 30° above horizon implies
~23 m of rock. Plausible for the outcrops in this zone, so the source is not
telling you anything absurd.

## Layer 1 — traversability mask

**Do not threshold on hue.** Three things defeat it, all visible in the render:
lit mesa tops are brighter and paler than open sand; sand in shadow is as dark
as rock; and each sub-region carries a large translucent colour wash (Vermillius
Gap orange, Sheol yellow-green) that shifts hue over hundreds of metres.

What works:

1. **Normalise the region tint out.** The wash is low-frequency. Estimate it by
   heavy box-downsample-then-upsample per channel (~64× works), then divide it
   out and re-apply the global mean. Terrain texture is unaffected; the wash
   flattens. This is what makes a single threshold valid map-wide instead of
   per-region.
2. **Classify on texture energy, not colour.** Rock is high-frequency (fractured,
   speckled); sand is smooth with only long dune undulations. Take luminance,
   subtract a ~16 px lowpass, take `|detail|`, smooth with an ~8 px lowpass.
   Threshold near the 88th percentile.
3. **Fill and clean.** Raw energy fires on rock *edges* and leaves hollow
   interiors — a prototype run produced recognisable but donut-shaped outcrops.
   Binary-close then flood-fill enclosed holes, then drop components under ~20 px².
4. **Clip the chrome.** The render carries a red hatched out-of-bounds band along
   the south edge and thin pale sub-region boundary lines. Both are strongly
   saturated and desaturated respectively, unlike any terrain; mask them by
   saturation before classifying so they don't leak into the output. The hatched
   band also marks the true playable limit — clip the world to its inside edge.

Output: single-channel PNG, `0` sand / `128` rock / `255` impassable cliff, at
1 m/px. Derive the cliff class from Layer 2's slope rather than guessing it here.

## Layer 2 — elevation, recovered then synthesised

Replace "invent it all" with "recover the large features, invent only the fine
grain". Three passes:

**2a. Shadow-length height for outcrops.** For each rock component from Layer 1,
march along azimuth 120° from its sun-facing edge and measure how far the shadow
runs before luminance recovers. Height `h = L · tan(θ)` with `θ` the sun
altitude. `θ` is the one free scalar in the whole pipeline — tune it until the
mesas feel right in-engine and every outcrop on the map scales consistently,
because they all share the one bake. This gives *real relative heights*: the tall
outcrops are the ones that are actually tall, in the actual places.

Caveat worth stating: shadows occlude each other in dense clusters and clip
against neighbouring rock, so this degrades where outcrops crowd. Hagga Basin
South is sparse and open — near best-case. It would work far less well in the
Shield Wall to the north.

**2b. Dune relief from shading.** In sand, after tint normalisation, luminance is
close to a pure Lambertian response to the dune surface under a known light
direction. That is textbook shape-from-shading, and unlike the general case the
light direction is *known* — so integrating the gradient field along the sun
vector recovers dune undulation directly. This matters more than it sounds: it
puts the dunes where the map says they are, so the plan view a player navigates
by actually matches. It also hands you the prevailing wind vector for free
(dune crest orientation) instead of picking one.

**2c. Noise only for sub-metre grain.** Below ~4 m the render has no real signal —
that's texture, not terrain. Fill it with low-amplitude ridged noise aligned to
the 2b wind vector. This is the earlier plan's Layer 2, correctly demoted from
the whole method to a detail pass.

Then blend as the earlier plan had it — smoothstep over ~15 m from rock to sand
for talus rather than vertical seams. Keep that; it was right. Feed the final
slope back into Layer 1 to mark the impassable class.

## Layer 3 — POIs

Straightforward now the CRS is pinned. Convert, filter to the region crop, emit
as a Godot resource. 52 markers cross-reference to Hagga Basin South by
category, but the *geometric* filter on the crop is what you want — it will
catch more, since the category cross-reference only covers POIs with wiki
articles.

Groups worth wiring first, given a worm system is the point: **Shipwrecks** (13
map-wide) as landmark silhouettes and loot anchors; **Caves** (74) as worm-safe
volumes — these are the mask's escape hatches and matter mechanically;
**Camps/Outposts** (353) as threat spawns; **Spice Blows** (8) as worm-attractor
events. Each marker carries `id`, `name`, and often `article`, so they key
cleanly to a data table.

## Order of work

1. `tools/fetch_map_data.py` — **done**, reproducible, 655 markers + region boxes.
2. Layer 1 mask over the Hagga Basin South crop. Prototype confirms the approach;
   needs the fill and chrome-clip steps.
3. Layer 2a shadow heights — highest value per unit effort, and validates against
   2b/2c which are refinements.
4. Godot import: heightmap → `HeightMapShape3D`, mask → gameplay lookup.
5. Layer 3 POI placement.

## Legal note

Marker data and the base render are community wiki content (CC-BY-SA on
awakening.wiki), not Funcom game assets — nothing here rips from the game. Derived
heightmaps are a transformation of wiki content; attribute the wiki. Worth
keeping the pipeline reproducible-from-source rather than committing large
derived binaries, which is why `data/hagga_basin.webp` is fetched, not vendored.
