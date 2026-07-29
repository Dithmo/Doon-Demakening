#!/usr/bin/env python3
"""Generate a synthetic test region in the shared terrain format.

Phase 5 replaces this with real Hagga Basin data (see docs/terrain-plan.md).
The *format* is the contract, and it is deliberately dumb so that both the
Godot client and the headless server can load it identically with no importer:

  <region>/region.json   metadata
  <region>/height.r16    uint16 LE, height_cells_x * height_cells_z, row-major,
                         value/65535 * height_scale = metres
  <region>/mask.u8       uint8, mask_cells_x * mask_cells_z, row-major,
                         0 = sand, 1 = rock, 2 = cliff

Mask is stored at finer resolution than height on purpose: gameplay reads the
surface class as a hard boundary (worm-safe vs exposed) and wants full source
resolution, while relief is only ever eyeballed.

World space: +x east, +z south, y up. Origin is the region's north-west corner
at (0, 0), matching the wiki CRS which also runs y southward.
"""

import argparse
import json
import math
import pathlib
import random
import struct

SAND, ROCK, CLIFF = 0, 1, 2

# Rise-over-run above which a slope is impassable. Anything gentler stays ROCK
# and can be walked up.
CLIFF_SLOPE = 1.2


def build(name, size_m, cell_size, mask_cell_size, seed, n_outcrops, height_scale):
    rng = random.Random(seed)
    hx = hz = int(size_m / cell_size)
    mx = mz = int(size_m / mask_cell_size)

    # Rock outcrops as blobby superellipses, echoing the scattered mesas that
    # actually cover Hagga Basin South.
    outcrops = []
    for _ in range(n_outcrops):
        outcrops.append({
            "cx": rng.uniform(0.08, 0.92) * size_m,
            "cz": rng.uniform(0.08, 0.92) * size_m,
            "rx": rng.uniform(18.0, 55.0),
            "rz": rng.uniform(18.0, 55.0),
            "rot": rng.uniform(0, math.tau),
            "h": rng.uniform(8.0, 26.0),
            "wob": rng.uniform(0.15, 0.4),
            "phase": rng.uniform(0, math.tau),
            # Width of the talus apron as a fraction of the radius. Varied per
            # outcrop so some mesas are sheer and some are climbable -- if every
            # rim were a cliff, rock would be scenery rather than refuge, and
            # the Phase 4 worm would have nowhere to chase you to.
            "talus": rng.uniform(0.30, 0.75),
        })

    def outcrop_field(wx, wz):
        """Return (coverage 0..1, target height) at a world position."""
        best_cov, best_h = 0.0, 0.0
        for o in outcrops:
            dx, dz = wx - o["cx"], wz - o["cz"]
            c, s = math.cos(o["rot"]), math.sin(o["rot"])
            u, v = (dx * c + dz * s) / o["rx"], (-dx * s + dz * c) / o["rz"]
            r = math.sqrt(u * u + v * v)
            if r > 1.6:
                continue
            # wobble the rim so outcrops aren't ellipses
            r /= 1.0 + o["wob"] * math.sin(4.0 * math.atan2(v, u) + o["phase"])
            if r >= 1.0:
                continue
            cov = min(1.0, (1.0 - r) / o["talus"])
            if cov > best_cov:
                best_cov, best_h = cov, o["h"]
        return best_cov, best_h

    def dunes(wx, wz):
        """Low ridged dunes along a prevailing wind, plus a gentle basin tilt."""
        wind = math.radians(115.0)
        t = wx * math.cos(wind) + wz * math.sin(wind)
        cross = -wx * math.sin(wind) + wz * math.cos(wind)
        ridge = 1.0 - abs(math.sin(t / 42.0 + math.sin(cross / 190.0) * 0.9))
        return ridge * 2.6 + math.sin(wx / 260.0) * 1.1 + math.cos(wz / 310.0) * 0.9

    heights = bytearray()
    for jz in range(hz):
        for ix in range(hx):
            wx, wz = ix * cell_size, jz * cell_size
            cov, oh = outcrop_field(wx, wz)
            h = dunes(wx, wz) * (1.0 - cov) + oh * cov
            v = max(0, min(65535, int(h / height_scale * 65535.0)))
            heights += struct.pack("<H", v)

    # Slope drives the CLIFF class, so the mask stays consistent with relief --
    # same rule Phase 5 uses (see terrain-plan.md Layer 1 output note).
    mask = bytearray()
    for jz in range(mz):
        for ix in range(mx):
            wx, wz = ix * mask_cell_size, jz * mask_cell_size
            cov, _ = outcrop_field(wx, wz)
            if cov <= 0.0:
                mask.append(SAND)
                continue
            d = mask_cell_size
            c0, h0 = outcrop_field(wx, wz)
            c1, h1 = outcrop_field(wx + d, wz)
            c2, h2 = outcrop_field(wx, wz + d)
            grad = max(abs(c1 * h1 - c0 * h0), abs(c2 * h2 - c0 * h0)) / d
            mask.append(CLIFF if grad > CLIFF_SLOPE else ROCK)

    meta = {
        "name": name,
        "size_m": [size_m, size_m],
        "cell_size": cell_size,
        "height_cells": [hx, hz],
        "height_scale": height_scale,
        "mask_cell_size": mask_cell_size,
        "mask_cells": [mx, mz],
        "surface_classes": {"sand": SAND, "rock": ROCK, "cliff": CLIFF},
        "seed": seed,
        "synthetic": True,
    }
    return meta, heights, mask


def reachability(mask, mx, mz):
    """Flood-fill walkable (non-cliff) cells from the map centre.

    A rock plateau ringed entirely by cliff is unreachable: nodes placed on it
    are invisible to players and, come Phase 4, it is refuge nobody can run to.
    Checking it here means a bad map fails at generation rather than in play.
    """
    start = None
    cz, cx = mz // 2, mx // 2
    for radius in range(0, max(mx, mz) // 2):
        for dz in range(-radius, radius + 1):
            for dx in (-radius, radius) if radius else (0,):
                z, x = cz + dz, cx + dx
                if 0 <= z < mz and 0 <= x < mx and mask[z * mx + x] != CLIFF:
                    start = (x, z)
                    break
            if start:
                break
        if start:
            break
    if start is None:
        return {"reachable": 0, "rock_frac": 0.0}

    seen = bytearray(mx * mz)
    stack = [start]
    seen[start[1] * mx + start[0]] = 1
    reachable = 0
    rock_reachable = 0
    while stack:
        x, z = stack.pop()
        reachable += 1
        if mask[z * mx + x] == ROCK:
            rock_reachable += 1
        for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, nz = x + dx, z + dz
            if not (0 <= nx < mx and 0 <= nz < mz):
                continue
            i = nz * mx + nx
            if seen[i] or mask[i] == CLIFF:
                continue
            seen[i] = 1
            stack.append((nx, nz))

    total_rock = sum(1 for b in mask if b == ROCK)
    return {"reachable": reachable,
            "rock_frac": rock_reachable / total_rock if total_rock else 0.0}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/regions/synthetic_test", type=pathlib.Path)
    ap.add_argument("--size", type=float, default=512.0, help="region edge, metres")
    ap.add_argument("--cell", type=float, default=2.0, help="heightmap cell, metres")
    ap.add_argument("--mask-cell", type=float, default=1.0, help="mask cell, metres")
    ap.add_argument("--height-scale", type=float, default=64.0)
    ap.add_argument("--outcrops", type=int, default=14)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    meta, heights, mask = build(args.out.name, args.size, args.cell, args.mask_cell,
                                args.seed, args.outcrops, args.height_scale)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "region.json").write_text(json.dumps(meta, indent=2))
    (args.out / "height.r16").write_bytes(heights)
    (args.out / "mask.u8").write_bytes(mask)

    counts = {SAND: 0, ROCK: 0, CLIFF: 0}
    for b in mask:
        counts[b] += 1
    total = len(mask)
    reach = reachability(mask, meta["mask_cells"][0], meta["mask_cells"][1])
    print(f"wrote {args.out}")
    print(f"  height {meta['height_cells']} @ {args.cell} m  ({len(heights)} bytes)")
    print(f"  mask   {meta['mask_cells']} @ {args.mask_cell} m  ({total} bytes)")
    print(f"  sand {counts[SAND]/total:.1%}  rock {counts[ROCK]/total:.1%}  "
          f"cliff {counts[CLIFF]/total:.1%}")
    print(f"  reachable from centre: {reach['reachable']/total:.1%} of map, "
          f"{reach['rock_frac']:.1%} of rock")
    if reach["rock_frac"] < 0.5:
        print("  WARNING: most rock is unreachable -- players cannot shelter on it")


if __name__ == "__main__":
    main()
