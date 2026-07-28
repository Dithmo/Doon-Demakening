#!/usr/bin/env python3
"""Pull Hagga Basin map data off the Dune: Awakening community wiki.

The wiki runs the DataMaps extension. Marker sets live as JSON in the `Map:`
namespace (id 2900) -- not the `Data:` namespace DataMaps uses on some other
wikis -- and MediaWiki's action API serves that page's raw content.

Writes:
  data/wiki/hagga_basin.datamap.json  raw marker JSON, exactly as the wiki stores it
  data/wiki/regions.json              sub-region bounding boxes in CRS units
  data/wiki/hagga_basin.webp          base map render, 8182x8182

Coordinate system, verified against the map render:
  CRS spans 0..100000 on both axes, order "xy", topLeft [0,0].
  y increases SOUTHWARD (screen convention, no flip).
  pixel = crs / 100000 * 8182, so 1 px is very close to 1 metre.
"""

import argparse
import json
import pathlib
import urllib.parse
import urllib.request

API = "https://awakening.wiki/api.php"
MAP_PAGE = "Map:Hagga Basin"
BACKGROUND = "File:Hagga Basin.webp"
UA = "Doon-Demakening/0.1 (terrain research)"

# Sub-region categories under Category:Hagga Basin. Marker `article` values are
# matched against each category's members to recover where the region sits.
REGIONS = [
    "Hagga Basin South",
    "The O'odham",
    "Sheol",
    "Western Vermillius Gap",
    "Eastern Vermillius Gap",
    "Hagga Rift",
    "Mysa Tarill",
    "Western Shield Wall",
    "Eastern Shield Wall",
    "Jabal Eifrit Al-janub",
    "Jabal Eifrit Al-gharb",
    "Jabal Eifrit Al-sharq",
]


def api(**params):
    params.setdefault("format", "json")
    url = f"{API}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def page_content(title):
    d = api(action="query", prop="revisions", rvprop="content", rvslots="main", titles=title)
    page = next(iter(d["query"]["pages"].values()))
    return page["revisions"][0]["slots"]["main"]["*"]


def category_members(title):
    d = api(action="query", list="categorymembers", cmtitle=f"Category:{title}", cmlimit=500)
    return [m["title"] for m in d.get("query", {}).get("categorymembers", [])]


def region_boxes(datamap):
    """Bounding box per sub-region, from the markers whose article is in it.

    These are hulls over known POIs, so they under-estimate a region's true
    extent -- treat them as a floor, not a border.
    """
    by_article = {}
    for group, markers in datamap["markers"].items():
        for m in markers:
            for key in ("article", "name"):
                if key in m:
                    by_article.setdefault(m[key], []).append((m["x"], m["y"], group))

    out = {}
    for region in REGIONS:
        pts = [p for t in category_members(region) for p in by_article.get(t, [])]
        if not pts:
            out[region] = {"marker_count": 0}
            continue
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        out[region] = {
            "marker_count": len(pts),
            "crs_bbox": {"x0": min(xs), "y0": min(ys), "x1": max(xs), "y1": max(ys)},
            "crs_centroid": [sum(xs) / len(xs), sum(ys) / len(ys)],
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/wiki", type=pathlib.Path)
    ap.add_argument("--skip-image", action="store_true")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    raw = page_content(MAP_PAGE)
    datamap = json.loads(raw)
    (args.out / "hagga_basin.datamap.json").write_text(raw)
    total = sum(len(v) for v in datamap["markers"].values())
    print(f"markers: {total} across {len(datamap['markers'])} groups")

    boxes = region_boxes(datamap)
    (args.out / "regions.json").write_text(json.dumps(boxes, indent=2))
    for name, box in boxes.items():
        if box["marker_count"]:
            b = box["crs_bbox"]
            print(f"  {name:26s} n={box['marker_count']:3d} "
                  f"x[{b['x0']:.0f},{b['x1']:.0f}] y[{b['y0']:.0f},{b['y1']:.0f}]")

    if not args.skip_image:
        info = api(action="query", titles=BACKGROUND, prop="imageinfo", iiprop="url|size")
        ii = next(iter(info["query"]["pages"].values()))["imageinfo"][0]
        print(f"background: {ii['width']}x{ii['height']} {ii['url']}")
        req = urllib.request.Request(ii["url"], headers={"User-Agent": UA})
        with urllib.request.urlopen(req) as r:
            (args.out / "hagga_basin.webp").write_bytes(r.read())


if __name__ == "__main__":
    main()
