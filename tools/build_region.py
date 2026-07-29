#!/usr/bin/env python3
"""Turn the community-wiki Hagga Basin render into a playable Godot region.

Reads `data/wiki/hagga_basin.webp` (fetched by fetch_map_data.py) and writes the
same three files a synthetic region has -- region.json, height.r16, mask.u8 --
plus pois.json, so nothing downstream has to know whether the terrain was
invented or recovered.

The method is documented in docs/terrain-plan.md. In short:

  Layer 1  classify sand/rock on *texture energy*, not colour, after dividing
           out the low-frequency sub-region colour wash.
  Layer 2  recover elevation from the render's baked directional sun -- shadow
           length gives outcrop height, shape-from-shading gives dune relief,
           and noise fills in only the sub-metre grain the source cannot hold.
  Layer 3  project the 655 wiki markers into world space and keep the ones
           inside the crop.

Everything is derived from one 8182x8182 image, so the numbers that matter are
measured from it and printed, not assumed: run with --debug to also dump the
intermediate images this was checked against.

Usage:
    python3 tools/build_region.py                       # default region
    python3 tools/build_region.py --debug /tmp/look     # + intermediate PNGs
"""

import argparse
import json
import math
import pathlib
import sys

import numpy as np
import scipy.ndimage as nd
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

# ---------------------------------------------------------------------------
# Source constants, all verified against the render itself (see terrain-plan.md)
# ---------------------------------------------------------------------------

RENDER = pathlib.Path("data/wiki/hagga_basin.webp")
DATAMAP = pathlib.Path("data/wiki/hagga_basin.datamap.json")

CRS_SPAN = 100000.0  # DataMaps CRS: topLeft [0,0], bottomRight [100000,100000]
RENDER_PX = 8182     # render is square at this size

## Metres per source pixel. The render covers a region ~8.1 km across in 8182
## px, so this is ~1.0 and every pixel measurement below is already in metres.
## Kept as a flag because it is the one number here inferred from outside the
## image; nothing else depends on it being exactly 1.
METRES_PER_PX = 1.0

## Crop for Hagga Basin South, in render pixels.
##
## The wiki's POI hull for the region is x[3652,7205] y[6608,7740], but a hull
## over known POIs is a floor on the region, not its border. The real borders
## are visible in the image, because each sub-region carries its own colour
## wash: sweeping hue and saturation along both axes, Hagga Basin South holds a
## flat plateau at hue ~27 / sat ~0.45, and its neighbours do not -- Sheol to
## the west reads hue 36-40, the Vermillius wash to the north reads hue 20 at
## sat 0.66, and the out-of-bounds hatch reads hue 18 at sat 0.55. The plateau
## runs x[3100,7600] y[6250,7870], which is what this crop is.
##
## Both original guesses were wrong in ways that showed up downstream.
## terrain-plan.md said to extend "south to the map edge (y=8182)": the render
## draws a red hatched out-of-bounds band from y=7887, and below it the image is
## flat filler with no terrain in it, so that would have imported ~300 m of
## nothing. And starting at y=6100 reached into the Vermillius wash, whose deep
## shadows merged with the outcrops below them -- the tall clamped mesas in the
## first build all clustered in that strip.
CROP = (3100, 6300, 7600, 7860)  # x0, y0, x1, y1

## Shadows fall along this image-space azimuth (0 deg = +x/east, 90 deg =
## +y/south), so the sun sits in the upper-right. Re-measured here by sweeping
## the offset direction from lit rock crust and asking which one lands on
## shadow most often: the peak is 125 deg with 115-135 within noise of it, so
## terrain-plan.md's 120 stands. --measure-sun reruns it.
##
## Measure this on *raw* luminance. Doing it on the tint-normalised image
## reports 155 deg, because the normaliser's job is to flatten low-frequency
## brightness and a shadow tens of metres across is exactly that.
SHADOW_AZIMUTH_DEG = 120.0

## Sun altitude above the horizon. This is the one free scalar in the pipeline:
## shadow length gives relative height exactly, and this turns it into metres.
## At 30 deg outcrops come out median 5 m, p90 23 m, tallest ~48 m, which is the
## right spread for the mesas and low crusts the render draws.
SUN_ALTITUDE_DEG = 30.0

## Outcrops taller than this are measurement artefacts -- a component whose
## shadow merges with a neighbour's reads as one enormous shadow. Clamping is
## honest here in a way that rescaling everything would not be: it only touches
## the few components that overrun.
MAX_OUTCROP_M = 34.0

# Output resolutions. The mask stays at native source resolution because
# gameplay reads it as a hard boundary (worm-safe vs exposed) and wants every
# metre the source has; the heightmap is coarser because the eye reads relief
# far less precisely than the worm rules read the mask.
HEIGHT_CELL_M = 2.0
MASK_CELL_M = 1.0
HEIGHT_SCALE_M = 64.0  # uint16 full scale

SAND, ROCK, CLIFF = 0, 1, 2

## Slope above which ground stops being walkable. Also the apron target: rock
## aprons are widened until their outside slope lands under this, because a
## mesa nobody can climb is not refuge, and Phase 4's whole answer to the worm
## is "get off the sand".
CLIFF_SLOPE_DEG = 38.0
APRON_SLOPE_DEG = 26.0
MIN_APRON_M = 10.0


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------

def hsl(rgb):
    """Hue (deg), saturation (0..1) and luminance (0..255) planes."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx = rgb.max(2)
    mn = rgb.min(2)
    d = mx - mn
    h = np.zeros_like(mx)
    m = d > 1e-6
    rm = (mx == r) & m
    gm = (mx == g) & m & ~rm
    bm = (mx == b) & m & ~rm & ~gm
    safe = np.maximum(d, 1e-6)
    h[rm] = (60.0 * ((g - b) / safe)[rm]) % 360.0
    h[gm] = 60.0 * ((b - r) / safe + 2.0)[gm]
    h[bm] = 60.0 * ((r - g) / safe + 4.0)[bm]
    sat = np.where(mx > 0, d / np.maximum(mx, 1.0), 0.0)
    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return h, sat, lum


def chrome_mask(hue, sat, lum):
    """Pixels the map draws *on top of* the terrain, which must not be classified.

    Three kinds, each separable from desert by colour alone -- open sand sits at
    hue ~27 deg with saturation ~0.45, and none of these do:

      hatch   the red out-of-bounds band and the translucent red POI circles
      pale    sub-region boundary lines, desaturated and bright
      icons   shipwreck/POI sprites painted in teal
    """
    hatch = nd.binary_closing(((hue < 20.0) | (hue > 300.0)) & (sat > 0.15),
                              np.ones((15, 15)))
    # Only sizeable patches of hatch are the out-of-bounds band; scattered
    # off-hue pixels in deep shadow are not, and walling those off would put
    # random impassable specks across open sand.
    lbl, n = nd.label(hatch)
    if n:
        sizes = np.bincount(lbl.ravel())
        keep = sizes >= 4000
        keep[0] = False
        hatch = keep[lbl]
    pale = (sat < 0.28) & (lum > 135.0)
    icons = (hue > 140.0) & (hue < 260.0)
    m = hatch | pale | icons
    # Grow slightly: these are drawn with soft edges that would otherwise leave
    # a halo of half-chrome pixels reading as texture.
    m = nd.binary_dilation(m, np.ones((5, 5)))
    # Sprites are only *mostly* off-hue -- a shipwreck's teal panels are caught
    # by the icon test but its dark hull is not, so a colour test alone leaves a
    # ragged half-wreck behind that then classifies as rock and gets a height
    # from its own drop shadow. Close and fill so a sprite goes as one object.
    m = nd.binary_fill_holes(nd.binary_closing(m, np.ones((21, 21))))
    # The hatch is returned separately as well: the rest of the chrome sits on
    # top of terrain and gets painted out, but the hatch *is* the map's edge and
    # the region has to end there rather than have terrain invented under it.
    return m, nd.binary_dilation(hatch, np.ones((9, 9)))


def inpaint(img, mask):
    """Replace masked pixels with their nearest unmasked neighbour.

    Chrome has to go *before* classification rather than just being excluded
    from it: a hard hole in the image is an edge, and an edge is exactly what
    the texture-energy step is looking for.
    """
    if not mask.any():
        return img
    idx = nd.distance_transform_edt(mask, return_distances=False, return_indices=True)
    return img[tuple(idx)]


def normalise_tint(rgb):
    """Divide out the per-sub-region colour wash.

    Each region carries a large translucent tint (Vermillius orange, Sheol
    yellow-green) that shifts colour over hundreds of metres. It is purely
    low-frequency, so estimating it with a heavy blur and dividing it out leaves
    terrain texture untouched while flattening the wash -- which is what lets a
    single threshold hold across the whole crop instead of per region.
    """
    out = np.empty_like(rgb)
    for c in range(3):
        plane = rgb[..., c]
        wash = nd.uniform_filter(plane, 257)
        out[..., c] = plane / np.maximum(wash, 1e-3) * float(plane.mean())
    return out


# ---------------------------------------------------------------------------
# Layer 1 -- traversability
# ---------------------------------------------------------------------------

## Classification scales, in source pixels (= metres). The detail window has to
## be wider than the crust features being detected and the smoothing wider still,
## or the energy field fires on rock *edges* and leaves interiors hollow -- the
## first run of this produced recognisable but donut-shaped outcrops, and a
## tighter version of these numbers produced stringy fragments that partitioned
## the map. Checked against the render at 33/31: 119 solid outcrops whose
## outlines sit on the ones the eye picks out.
DETAIL_WINDOW = 33
ENERGY_SMOOTH = 31
CLOSE_RADIUS = 21


def texture_energy(lum):
    """High-frequency content. Rock is fractured and speckled; sand is smooth.

    Colour cannot do this job -- lit mesa tops are brighter and paler than open
    sand, and sand in shadow is as dark as rock -- but the frequency content
    separates them cleanly.
    """
    detail = lum - nd.uniform_filter(lum, DETAIL_WINDOW)
    return nd.uniform_filter(np.abs(detail), ENERGY_SMOOTH)


def classify_rock(energy, percentile, min_area_px):
    """Threshold, then repair into solid bodies."""
    thresh = float(np.percentile(energy, percentile))
    m = energy > thresh
    m = nd.binary_closing(m, np.ones((CLOSE_RADIUS, CLOSE_RADIUS)))
    m = nd.binary_fill_holes(m)
    m = nd.binary_opening(m, np.ones((5, 5)))
    lbl, n = nd.label(m)
    if n:
        sizes = np.bincount(lbl.ravel())
        keep = np.zeros(sizes.shape[0], bool)
        keep[sizes >= min_area_px] = True
        keep[0] = False
        m = keep[lbl]
    lbl, n = nd.label(m)
    return m, lbl, n, thresh


def lit_baseline(lum, rock):
    """Local illumination level with the shadows taken back out of it.

    A plain local mean is dragged down by the very shadows it is meant to be the
    reference for, which shrinks their apparent depth until the tallest mesa
    reads a few metres tall. Re-weighting by what the previous pass called lit
    converges in about three rounds and is what makes shadow depth measurable
    at all.
    """
    wt = np.ones_like(lum)
    shade = np.zeros(lum.shape, bool)
    for _ in range(3):
        base = nd.uniform_filter(lum * wt, 193) / np.maximum(nd.uniform_filter(wt, 193), 1e-3)
        shade = (lum < base * 0.90) & ~rock
        wt = (~shade).astype(np.float32)
    return shade


def measure_sun(rock, lum):
    """Re-derive the shadow azimuth from the image, as a check on the constant.

    Seeded from lit crust rather than from rock outline: an outline pixel has
    shadow on one side whatever the sun is doing, so it votes for every azimuth
    and flattens the peak.

    Deliberately *not* using lit_baseline's shade here. That one excludes rock,
    so an azimuth is rewarded for leaving the outcrop quickly rather than for
    pointing along the light -- which is outcrop shape, not sun position, and
    reports 150 deg. Scoring against a plain local threshold that keeps rock in
    gives a clean peak at 125 deg with a minimum 180 deg opposite it.
    """
    shade = lum < nd.uniform_filter(lum, 257) * 0.85
    bright = nd.binary_opening(lum > np.percentile(lum, 92), np.ones((3, 3)))
    ys, xs = np.nonzero(bright)
    if len(ys) == 0:
        return SHADOW_AZIMUTH_DEG, 0.0, []
    if len(ys) > 40000:  # sampling is plenty; this is a 1-D argmax
        sel = np.random.default_rng(0).choice(len(ys), 40000, replace=False)
        ys, xs = ys[sel], xs[sel]
    scores = []
    for az in range(0, 360, 5):
        rad = math.radians(az)
        dx, dy = math.cos(rad), math.sin(rad)
        hits = 0.0
        for d in (8, 14, 20, 26):
            px = np.clip((xs + dx * d).astype(int), 0, shade.shape[1] - 1)
            py = np.clip((ys + dy * d).astype(int), 0, shade.shape[0] - 1)
            hits += shade[py, px].mean()
        scores.append((az, hits / 4.0))
    best, best_score = max(scores, key=lambda t: t[1])
    return best, best_score, scores


# ---------------------------------------------------------------------------
# Layer 2 -- elevation
# ---------------------------------------------------------------------------

def shadow_heights(rock, lbl, n_comp, lum, shadow_dir, sun_alt_deg, max_march=80):
    """Height per rock component, from the area of the shadow it casts.

    This is the step that makes the terrain *this* place rather than a
    plausible desert: shadow length is a direct measure of height, so the tall
    outcrops come out tall, in the positions the map actually draws them.

    Measured by walking each shadow pixel back toward the sun until it hits the
    rock that cast it, then dividing each component's shadow area by its
    silhouette width across the sun direction. The obvious alternative -- march
    outward from each outcrop's edge and time the darkness -- was tried first
    and failed: shadow edges are soft, so a ray tested pixel by pixel dies on
    the first not-quite-dark step and reports zero. That version left 65 of 119
    outcrops flat. Working backwards from the shadows themselves has no such
    cliff edge, and leaves exactly one.

    Still degrades where outcrops crowd and shadows merge, which is what
    MAX_OUTCROP_M is for. Hagga Basin South is sparse and open, near best-case;
    the Shield Wall to the north would not fare nearly as well.
    """
    h, w = rock.shape
    shade = lit_baseline(lum, rock)
    dx, dy = shadow_dir

    ys, xs = np.nonzero(shade)
    px = xs.astype(np.float32)
    py = ys.astype(np.float32)
    owner = np.zeros(len(ys), np.int32)
    alive = np.ones(len(ys), bool)
    for _ in range(max_march):
        px -= dx
        py -= dy
        ix = np.clip(px.astype(int), 0, w - 1)
        iy = np.clip(py.astype(int), 0, h - 1)
        inside = (px >= 0) & (py >= 0) & (px < w) & (py < h)
        hit = rock[iy, ix] & alive & inside
        owner[hit] = lbl[iy[hit], ix[hit]]
        alive &= ~hit & inside

    area = np.bincount(owner, minlength=n_comp + 1).astype(np.float64)
    area[0] = 0.0

    # Silhouette width is measured across the sun, not along it: a long thin
    # ridge lying with the light casts a short shadow for its size, and
    # dividing by its full extent would call it flat.
    ry, rx = np.nonzero(rock)
    rc = lbl[ry, rx]
    perp = (-dy) * rx + dx * ry
    order = np.argsort(rc, kind="stable")
    rc_s, perp_s = rc[order], perp[order]
    bounds = np.searchsorted(rc_s, np.arange(1, n_comp + 2))
    width = np.ones(n_comp + 1)
    for c in range(1, n_comp + 1):
        seg = perp_s[bounds[c - 1]:bounds[c]]
        if len(seg):
            width[c] = max(seg.max() - seg.min(), 1.0)

    tan_alt = math.tan(math.radians(sun_alt_deg))
    heights = (area / width * METRES_PER_PX * tan_alt).astype(np.float32)
    heights = np.clip(heights, 0.0, MAX_OUTCROP_M)
    heights[0] = 0.0
    return heights, shade


## Dune band, in metres. The short end is a slope budget, not a taste call: a
## 24 m wavelength carrying a few metres of amplitude implies ~57 deg faces, and
## the first run of this filled the region with a lattice of cliff cells that
## cut it into islands -- 54% of the map was cut off from its own centre. At
## 60 m the same amplitude lands near 24 deg and the map stays whole.
DUNE_MIN_WAVELENGTH = 60.0
DUNE_MAX_WAVELENGTH = 600.0
DUNE_AMPLITUDE_M = 3.0
GRAIN_AMPLITUDE_M = 0.3
## Damping for wavevectors that run across the sun, where shading carries no
## height information. See dune_relief.
SHADING_ALPHA = 0.35


def dune_relief(lum, sand, sun_xy, min_wavelength=DUNE_MIN_WAVELENGTH,
                max_wavelength=DUNE_MAX_WAVELENGTH):
    """Recover dune undulation from shading.

    On sand, after the tint is normalised, luminance is close to a Lambertian
    response to the dune surface under a light whose direction we know. That
    makes this shape-from-shading with the usual ambiguity removed: the surface
    gradient along the sun azimuth is proportional to the luminance deviation,
    so height is its integral along that direction.

    Integrating in the Fourier domain rather than by marching rays: the operator
    is a directional derivative, so dividing by (i k.u) inverts it in one pass,
    and band-limiting the same expression is what stops the integration drifting
    (low k) and amplifying speckle (high k) -- both of which a spatial cumsum
    would need separate passes to control.

    This matters more than "nicer dunes": it puts the dunes where the map draws
    them, so the plan view a player navigates by matches the ground they walk.
    """
    f = np.where(sand, lum - nd.uniform_filter(lum, 129), 0.0).astype(np.float32)
    pad = 256
    fp = np.pad(f, pad, mode="reflect")
    H, W = fp.shape
    F = np.fft.rfft2(fp)
    ky = np.fft.fftfreq(H)[:, None]
    kx = np.fft.rfftfreq(W)[None, :]
    # Directional derivative along the horizontal sun vector.
    w = 2.0 * math.pi * (kx * sun_xy[0] + ky * sun_xy[1])
    k = 2.0 * math.pi * np.maximum(np.sqrt(kx * kx + ky * ky), 1e-9)

    # Cosine-tapered band rather than a hard one: a box in Fourier rings in
    # space, and the ringing lands at exactly the scale the dunes occupy.
    lo, hi = 1.0 / max_wavelength, 1.0 / min_wavelength
    kr = np.sqrt(kx * kx + ky * ky)
    band = np.clip((kr - lo) / (lo * 1.5), 0.0, 1.0) * np.clip((hi - kr) / (hi * 0.5), 0.0, 1.0)

    # Wiener-regularised inverse, not a plain 1/(i.w). Components whose
    # wavevector runs across the sun carry no shading information -- w -> 0 --
    # and dividing by that amplified pure noise into a herringbone of diagonal
    # ridges tens of metres tall that swamped the real relief. Damping by
    # (ALPHA.k)^2 suppresses those directions instead of trusting them.
    #
    # The sign is negative because a slope tilted *toward* the sun is brighter:
    # f ~ -cos(altitude) . (grad z . u). Getting it backwards inverts every
    # dune, which a forward-render check catches immediately -- correlation
    # against the source comes out -0.74 rather than +0.74.
    Z = -F * (-1j * w) / (w * w + (SHADING_ALPHA * k) ** 2) * band
    z = np.fft.irfft2(Z, s=fp.shape)[pad:pad + f.shape[0], pad:pad + f.shape[1]]
    return z.astype(np.float32)


def shading_fidelity(z, lum, sand, sun_xy):
    """Re-render the recovered height and correlate it with the source.

    The one check that can tell "recovered the actual dunes" from "produced a
    plausible dune-like field", and it is nearly free. Shuffling the height
    scores 0.00 on the same test, so this is not measuring the terrain being
    smooth.
    """
    gy, gx = np.gradient(z, 1.0)
    pred = -(gx * sun_xy[0] + gy * sun_xy[1])
    obs = lum - nd.uniform_filter(lum, 129)
    sel = sand
    if sel.sum() < 100:
        return 0.0
    return float(np.corrcoef(pred[sel].ravel(), obs[sel].ravel())[0, 1])


def wind_vector(lum, sand):
    """Prevailing wind, from dune crest orientation via the structure tensor.

    Free from data we already have, and better than picking a direction: the
    detail noise is stretched along it so the fine grain agrees with the dunes
    the render actually draws.
    """
    l = np.where(sand, lum, float(lum.mean()))
    gy, gx = np.gradient(nd.uniform_filter(l, 9))
    jxx = nd.uniform_filter(gx * gx, 65)
    jyy = nd.uniform_filter(gy * gy, 65)
    jxy = nd.uniform_filter(gx * gy, 65)
    sel = sand
    a, b, c = jxx[sel].mean(), jxy[sel].mean(), jyy[sel].mean()
    # Principal direction of the averaged tensor; crests run perpendicular to it.
    theta = 0.5 * math.atan2(2.0 * b, a - c)
    return (math.cos(theta), math.sin(theta)), math.degrees(theta) % 180.0


def ridged_noise(shape, wind, rng, octaves=3, base=64.0):
    """Sub-metre grain, stretched along the wind.

    Below roughly 4 m the render has no terrain signal left -- that is texture,
    not landform -- so this is the only part of the elevation that is invented,
    and it is deliberately the smallest part.
    """
    h, w = shape
    out = np.zeros(shape, np.float32)
    amp = 1.0
    total = 0.0
    for o in range(octaves):
        lam = base / (2 ** o)
        sh = (max(2, int(h / lam)), max(2, int(w / lam)))
        n = rng.standard_normal(sh).astype(np.float32)
        n = np.asarray(Image.fromarray(n).resize((w, h), Image.BICUBIC))
        out += amp * (1.0 - np.abs(n / (np.abs(n).max() + 1e-6)))
        total += amp
        amp *= 0.5
    out /= total
    # Stretch along the wind so the grain lies with the dunes, not across them.
    ang = math.degrees(math.atan2(wind[1], wind[0]))
    out = nd.rotate(out, -ang, reshape=False, order=1, mode="reflect")
    out = nd.uniform_filter(out, size=(1, 9))
    out = nd.rotate(out, ang, reshape=False, order=1, mode="reflect")
    return out - out.mean()


def rock_field(rock, lbl, heights):
    """Mesa tops with talus aprons, rather than vertical seams.

    The apron width is set per component from its own height so the outside
    slope lands near APRON_SLOPE_DEG. That is a gameplay constraint before it is
    an aesthetic one: an outcrop ringed in unclimbable cliff is refuge nobody
    can reach, which is the bug that made every rock in the Phase 2 synthetic
    region unreachable and would have silently broken Phase 4's flee-to-rock.
    """
    dist, idx = nd.distance_transform_edt(~rock, return_distances=True, return_indices=True)
    nearest_comp = lbl[tuple(idx)]
    comp_h = heights[nearest_comp]
    apron = np.maximum(MIN_APRON_M, comp_h / math.tan(math.radians(APRON_SLOPE_DEG)))
    t = np.clip(dist * METRES_PER_PX / np.maximum(apron, 1e-3), 0.0, 1.0)
    fall = 1.0 - (t * t * (3.0 - 2.0 * t))  # smoothstep
    field = comp_h * fall
    field[rock] = heights[lbl[rock]]
    # Soften the shoulder so the top does not meet the apron in a crease.
    return nd.uniform_filter(field, 9)


# ---------------------------------------------------------------------------
# Layer 3 -- POIs
# ---------------------------------------------------------------------------

## Groups the game actually consumes, mapped to what they mean mechanically.
## Everything else is kept as a landmark rather than dropped -- they cost
## nothing and they are what a player navigates by.
## Keys are the datamap's own group names, verified against the fetched JSON --
## guessing them from the wiki's prose labels ("enemy camps", "spice blows")
## silently filed 70 of 99 markers as landmarks on the first run.
POI_ROLES = {
    "Shipwrecks": "loot",
    "Loot": "loot",
    "Caves": "shelter",
    "Camps": "threat",
    "Outposts": "threat",
    "Spiceblows": "spice",
    "TradingPosts": "trade",
    "Agave": "harvest",
    "EcoLabs": "harvest",
    "Sandbikes": "vehicle",
    "Trainers": "trainer",
    "Intel": "intel",
}


def load_pois(crop):
    if not DATAMAP.exists():
        return []
    dm = json.loads(DATAMAP.read_text())
    x0, y0, x1, y1 = crop
    out = []
    for group, markers in dm.get("markers", {}).items():
        key = group.split(":")[-1].strip()
        role = POI_ROLES.get(key, "landmark")
        for mk in markers:
            px = mk["x"] / CRS_SPAN * RENDER_PX
            py = mk["y"] / CRS_SPAN * RENDER_PX
            if not (x0 <= px < x1 and y0 <= py < y1):
                continue
            out.append({
                "group": key,
                "role": role,
                "name": mk.get("name") or mk.get("article") or "",
                "article": mk.get("article", ""),
                # World space: +x east, +z south, origin at the crop's NW corner.
                "x": round((px - x0) * METRES_PER_PX, 2),
                "z": round((py - y0) * METRES_PER_PX, 2),
            })
    return out


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=pathlib.Path,
                    default=pathlib.Path("data/regions/hagga_basin_south"))
    ap.add_argument("--name", default="hagga_basin_south")
    ap.add_argument("--debug", type=pathlib.Path, default=None,
                    help="directory for intermediate PNGs")
    ap.add_argument("--rock-percentile", type=float, default=88.0)
    ap.add_argument("--min-rock-area", type=float, default=80.0)
    ap.add_argument("--sun-altitude", type=float, default=SUN_ALTITUDE_DEG)
    ap.add_argument("--measure-sun", action="store_true")
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()

    if not RENDER.exists():
        sys.exit(f"missing {RENDER} -- run tools/fetch_map_data.py first")

    x0, y0, x1, y1 = CROP
    W, H = x1 - x0, y1 - y0
    log(f"[crop] render px x[{x0},{x1}] y[{y0},{y1}] -> {W}x{H} m")

    rgb = np.asarray(Image.open(RENDER).convert("RGB")).astype(np.float32)[y0:y1, x0:x1]
    hue, sat, lum0 = hsl(rgb)

    chrome, hatch = chrome_mask(hue, sat, lum0)
    log(f"[chrome] {chrome.mean() * 100:.2f}% of crop painted over, inpainted; "
        f"{hatch.mean() * 100:.2f}% is out-of-bounds hatch")
    rgb = inpaint(rgb, chrome)

    # Two luminance planes on purpose. Classification wants the wash divided out
    # so one threshold holds map-wide; shadow work wants it left in, because
    # normalising flattens exactly the large dark areas the height recovery is
    # measuring. Using the normalised plane for both put every mesa under 7 m.
    _, _, lum_raw = hsl(rgb)
    rgb = normalise_tint(rgb)
    _, _, lum = hsl(rgb)

    energy = texture_energy(lum)
    rock, lbl, n_comp, thresh = classify_rock(energy, args.rock_percentile,
                                              args.min_rock_area)
    log(f"[layer1] energy threshold {thresh:.2f} at p{args.rock_percentile:.0f}; "
        f"{n_comp} outcrops, {rock.mean() * 100:.1f}% rock")

    az = SHADOW_AZIMUTH_DEG
    if args.measure_sun:
        found, score, _ = measure_sun(rock, lum_raw)
        log(f"[sun] measured shadow azimuth {found} deg (occupancy {score:.3f}); "
            f"constant is {SHADOW_AZIMUTH_DEG:.0f}")
    rad = math.radians(az)
    shadow_dir = (math.cos(rad), math.sin(rad))
    sun_xy = (-shadow_dir[0], -shadow_dir[1])

    heights, shade = shadow_heights(rock, lbl, n_comp, lum_raw, shadow_dir,
                                    args.sun_altitude)
    nz = heights[1:][heights[1:] > 0]
    if len(nz):
        log(f"[layer2a] {len(nz)}/{n_comp} outcrops measured; height median "
            f"{np.median(nz):.1f} m, p90 {np.percentile(nz, 90):.1f} m, "
            f"max {nz.max():.1f} m (sun altitude {args.sun_altitude:.0f} deg)")

    sand = ~rock
    wind, wind_deg = wind_vector(lum, sand)
    log(f"[layer2b] prevailing wind {wind_deg:.0f} deg from dune crests")
    dunes = dune_relief(lum, sand, sun_xy)
    fid = shading_fidelity(dunes, lum, sand, sun_xy)
    log(f"[layer2b] shading fidelity {fid:+.2f} "
        f"(re-rendered relief vs source; sign must be positive)")
    if fid < 0.3:
        log("[layer2b] WARNING: recovered relief does not reproduce the source "
            "shading -- check the sun vector")
    # Scale the recovered relief to a believable amplitude. Shape-from-shading
    # gives the *form* correctly but its absolute scale rides on an unknown
    # albedo, so this is the second and last free scalar in the pipeline.
    if dunes.std() > 1e-6:
        dunes *= DUNE_AMPLITUDE_M / dunes.std()
    dunes = np.clip(dunes, -10.0, 10.0)

    rng = np.random.default_rng(args.seed)
    grain = ridged_noise((H, W), wind, rng) * GRAIN_AMPLITUDE_M

    field = rock_field(rock, lbl, heights)
    # Outcrops stand *on* the ground, they do not replace it. Adding the rock
    # field to a dune base rather than substituting for it is the difference
    # between a mesa and a hole: shadow heights are heights above local ground,
    # median 5 m, and the dunes swing +/-10 m, so a substituted outcrop sank
    # below the sand beside it and half of them read as pits.
    grain_weight = 1.0 - np.clip(field / 6.0, 0.0, 1.0)  # mesa tops read flat
    height = dunes + grain * grain_weight + field
    height -= height.min()
    log(f"[layer2] height range 0..{height.max():.1f} m, mean {height.mean():.1f} m")
    if height.max() > HEIGHT_SCALE_M:
        log(f"[layer2] clipping to {HEIGHT_SCALE_M:.0f} m full scale")
        height = np.clip(height, 0.0, HEIGHT_SCALE_M)

    # --- emit -------------------------------------------------------------
    args.out.mkdir(parents=True, exist_ok=True)
    hx, hz = int(W / HEIGHT_CELL_M), int(H / HEIGHT_CELL_M)
    small = np.asarray(Image.fromarray(height).resize((hx, hz), Image.BILINEAR))

    # Cliff comes from the finished slope rather than being guessed in Layer 1,
    # and it is measured on the *downsampled* grid because that is the surface
    # the engine samples and the collider uses. Measuring at 1 m instead marks
    # cells cliff over detail the game cannot feel, and the mask and the ground
    # under the player then disagree about what is climbable.
    gy, gx = np.gradient(small, HEIGHT_CELL_M)
    slope = np.degrees(np.arctan(np.hypot(gx, gy)))
    slope_full = np.asarray(Image.fromarray(slope.astype(np.float32)).resize((W, H), Image.BILINEAR))
    mask = np.where(rock, ROCK, SAND).astype(np.uint8)
    mask[slope_full > CLIFF_SLOPE_DEG] = CLIFF
    # The region's own edge. The crop is a rectangle but the playable area is
    # not, so its corners clip out-of-bounds; walling them off is what stops the
    # map ending in terrain that was invented under a "you cannot go here" sign.
    mask[hatch] = CLIFF
    log(f"[layer1] final mask: sand {(mask == SAND).mean() * 100:.1f}%  "
        f"rock {(mask == ROCK).mean() * 100:.1f}%  cliff {(mask == CLIFF).mean() * 100:.1f}%")

    reach = reachability(mask)
    rock_cells = (mask == ROCK).sum()
    log(f"[reach] {reach.mean() * 100:.1f}% of the region reachable from its centre; "
        f"{(reach & (mask == ROCK)).sum() / max(rock_cells, 1) * 100:.1f}% "
        f"of rock is reachable")

    q = np.clip(small / HEIGHT_SCALE_M * 65535.0, 0, 65535).astype("<u2")
    (args.out / "height.r16").write_bytes(q.tobytes())
    (args.out / "mask.u8").write_bytes(mask.astype(np.uint8).tobytes())

    pois = load_pois(CROP)
    (args.out / "pois.json").write_text(json.dumps(pois, indent=1))
    by_role = {}
    for p in pois:
        by_role[p["role"]] = by_role.get(p["role"], 0) + 1
    log(f"[layer3] {len(pois)} POIs inside the crop: " +
        ", ".join(f"{k} {v}" for k, v in sorted(by_role.items())))

    meta = {
        "name": args.name,
        "size_m": [float(W) * METRES_PER_PX, float(H) * METRES_PER_PX],
        "cell_size": HEIGHT_CELL_M,
        "height_cells": [hx, hz],
        "height_scale": HEIGHT_SCALE_M,
        "mask_cell_size": MASK_CELL_M,
        "mask_cells": [W, H],
        "surface_classes": {"sand": SAND, "rock": ROCK, "cliff": CLIFF},
        "synthetic": False,
        "source": {
            "render": "File:Hagga Basin.webp (awakening.wiki, CC-BY-SA)",
            "crop_px": list(CROP),
            "crs_bbox": [x0 / RENDER_PX * CRS_SPAN, y0 / RENDER_PX * CRS_SPAN,
                         x1 / RENDER_PX * CRS_SPAN, y1 / RENDER_PX * CRS_SPAN],
            "metres_per_px": METRES_PER_PX,
            "shadow_azimuth_deg": az,
            "sun_altitude_deg": args.sun_altitude,
            "wind_deg": round(wind_deg, 1),
        },
    }
    (args.out / "region.json").write_text(json.dumps(meta, indent=2))
    log(f"[out] {args.out}  height {hx}x{hz}  mask {W}x{H}")

    if args.debug:
        dump_debug(args.debug, rgb, lum, energy, rock, shade, height, mask, reach)


def reachability(mask):
    """Walkable cells connected to the region centre.

    Mirrors what Terrain does at load. Reported here because a region that
    generates beautifully and strands the player is a build-time failure, and
    finding that out in-engine costs a whole test cycle.
    """
    walk = mask != CLIFF
    lbl, n = nd.label(walk)
    if n == 0:
        return np.zeros_like(walk)
    cz, cx = mask.shape[0] // 2, mask.shape[1] // 2
    pid = lbl[cz, cx]
    if pid == 0:
        ys, xs = np.nonzero(walk)
        d = (ys - cz) ** 2 + (xs - cx) ** 2
        pid = lbl[ys[d.argmin()], xs[d.argmin()]]
    return lbl == pid


def dump_debug(out, rgb, lum, energy, rock, shade, height, mask, reach):
    out.mkdir(parents=True, exist_ok=True)

    def png(name, arr, cmap=None):
        a = np.asarray(arr)
        if a.dtype == bool:
            a = a.astype(np.uint8) * 255
        elif a.dtype != np.uint8:
            lo, hi = float(a.min()), float(a.max())
            a = ((a - lo) / max(hi - lo, 1e-6) * 255).astype(np.uint8)
        im = Image.fromarray(a)
        im.save(out / name)

    png("01_normalised.png", np.clip(rgb, 0, 255).astype(np.uint8))
    png("02_energy.png", energy)
    png("03_rock.png", rock)
    png("04_shade.png", shade)
    png("05_height.png", height)
    colour = np.zeros(mask.shape + (3,), np.uint8)
    colour[mask == SAND] = (222, 184, 135)
    colour[mask == ROCK] = (120, 100, 90)
    colour[mask == CLIFF] = (200, 40, 40)
    colour[~reach] = colour[~reach] // 3
    png("06_mask.png", colour)
    log(f"[debug] wrote intermediates to {out}")


if __name__ == "__main__":
    main()
