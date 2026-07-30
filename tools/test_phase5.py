#!/usr/bin/env python3
"""Phase 5 acceptance test: the real world.

Asserts the acceptance criteria from docs/game-plan.md Phase 5 -- that the game
now runs on Hagga Basin South recovered from the community wiki, not on a
synthetic test map:

  * the region is the real crop, and its coordinates round-trip back to the
    wiki's own CRS
  * the wiki's markers are in the world, on ground that connects to the rest
    of it
  * a player can navigate between two named landmarks using nothing but the
    map data -- the Phase 5 headline
  * caves shelter you from the worm, which is what makes the open dune fields
    crossable at all
  * camps put hostiles where the map says they are, and wrecks put salvage
    where it draws them
  * a client holding different terrain is refused rather than allowed to
    disagree quietly about where the ground is

Unlike phases 0-4 this suite deliberately does NOT pin --region: running on the
default is the thing being tested.

Run: python3 tools/test_phase5.py
"""

import argparse
import json
import math
import os
import pathlib
import re
import shutil
import tempfile
import subprocess
import sys
import time

GODOT = os.environ.get("GODOT", "/opt/godot/godot")
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27440"))

REGION = ROOT / "data" / "regions" / "hagga_basin_south"
CRS_SPAN = 100000.0
RENDER_PX = 8182

PILGRIM = re.compile(r"\[pilgrim\] (\S+) -> (.+?) dist=([\d.]+) (\w+)")
BOT = re.compile(r"\[bot\] (\S+) .*threat=([\d.]+) worm=(\d) on=(\w+)")

## Two named wiki landmarks ~300 m apart, both on ground the mask connects to
## the rest of the region. Far enough that crossing is a real traversal past
## several outcrops rather than a step sideways, close enough to walk inside a
## test run: at sprint speed this is about 40 seconds of desert.
FROM_POI = "Traitor's Grotto"
TO_POI = "Hollower Stillsuit"


class Proc:
    def __init__(self, args, env):
        self.lines = []
        # Output goes to a file, never a pipe. Nothing drains stdout while the
        # run is in flight, so a chatty session used to fill the 64 KB pipe
        # buffer and block the child mid-play -- which looks exactly like the
        # game being broken rather than the harness being wrong.
        self._out = tempfile.NamedTemporaryFile(
            mode="w+", suffix=".log", delete=False)
        self.p = subprocess.Popen(
            args, cwd=ROOT, env=env,
            stdout=self._out, stderr=subprocess.STDOUT,
        )

    def wait(self, timeout):
        try:
            self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self._collect()

    def _collect(self):
        # Read the log file the child wrote to. See the note on _out above.
        if self._out is None:
            return
        self._out.flush()
        self._out.close()
        with open(self._out.name, errors="replace") as fh:
            self.lines = [ln.rstrip() for ln in fh]
        os.unlink(self._out.name)
        self._out = None

    def text(self):
        return "\n".join(self.lines)


def launch(extra, user_dir, seconds, port):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    return Proc([GODOT, "--headless", "--path", str(ROOT), "--",
                 "--port", str(port), "--run-seconds", str(seconds)] + extra, env)


def session(user_dir, seconds, port, extra, clients):
    server = launch(["--server"] + extra, user_dir, seconds, port)
    time.sleep(2.0)
    procs = [launch(c + extra, user_dir, seconds - 3, port) for c in clients]
    for p in procs + [server]:
        p.wait(seconds + 30)
    return server, procs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1
    if not (REGION / "region.json").exists():
        print(f"FAIL: no region at {REGION}")
        print("      run: python3 tools/fetch_map_data.py && python3 tools/build_region.py")
        return 1

    user_dir = ROOT / ".test_home_p5"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    meta = json.loads((REGION / "region.json").read_text())
    pois = json.loads((REGION / "pois.json").read_text())

    # --- the artefacts themselves -------------------------------------------
    print("\n=== the region is the real place ===")
    w, h = meta["size_m"]
    check(not meta["synthetic"], f"the region is not synthetic ({meta['name']})")
    check(3000 < w < 6000 and 1000 < h < 2500,
          f"it is Hagga Basin South's shape, a wide shallow strip ({w:.0f}x{h:.0f} m)")

    mask_bytes = (REGION / "mask.u8").stat().st_size
    hx, hz = meta["height_cells"]
    check(mask_bytes == int(w) * int(h),
          f"the mask is one byte per metre ({mask_bytes} bytes)")
    check((REGION / "height.r16").stat().st_size == hx * hz * 2,
          f"the heightmap is 16-bit at {meta['cell_size']:.0f} m ({hx}x{hz})")

    src = meta["source"]
    check("awakening.wiki" in src["render"], "it records the wiki as its source")

    # Round-trip a marker: world metres -> render pixel -> wiki CRS, and compare
    # against the CRS the wiki actually published for that marker.
    datamap = json.loads((ROOT / "data" / "wiki" / "hagga_basin.datamap.json").read_text())
    # Only names that identify exactly one marker map-wide. Plenty of the wiki's
    # markers are just called "Cave" or "Camp", and matching on those compares a
    # POI here against a duplicate hundreds of metres away -- which is a bug in
    # the check, not in the projection.
    seen = {}
    for group, markers in datamap.get("markers", {}).items():
        for mk in markers:
            name = mk.get("name") or mk.get("article") or ""
            if name:
                seen.setdefault(name, []).append((mk["x"], mk["y"]))
    published = {k: v[0] for k, v in seen.items() if len(v) == 1}
    x0, y0, _, _ = src["crop_px"]
    worst = 0.0
    checked = 0
    for p in pois:
        if p["name"] not in published:
            continue
        cx = (p["x"] / src["metres_per_px"] + x0) / RENDER_PX * CRS_SPAN
        cy = (p["z"] / src["metres_per_px"] + y0) / RENDER_PX * CRS_SPAN
        px, py = published[p["name"]]
        worst = max(worst, math.hypot(cx - px, cy - py))
        checked += 1
    # One CRS unit is 0.08 m here, so this is a sub-metre agreement.
    check(checked > 20 and worst < 15.0,
          f"world coordinates round-trip to the wiki's CRS ({checked} markers, "
          f"worst {worst:.1f} CRS units = {worst / CRS_SPAN * RENDER_PX:.2f} m)")

    roles = {}
    for p in pois:
        roles[p["role"]] = roles.get(p["role"], 0) + 1
    check(roles.get("shelter", 0) >= 10 and roles.get("threat", 0) >= 20
          and roles.get("loot", 0) >= 5,
          f"the marker groups the game consumes are all present ({roles})")
    check(all(0 <= p["x"] <= w and 0 <= p["z"] <= h for p in pois),
          "every marker lands inside the region")

    # --- run 1: navigate between two named landmarks -------------------------
    print(f"\n=== run 1: walk from {FROM_POI} to {TO_POI} ===")
    a = next((p for p in pois if p["name"] == FROM_POI), None)
    b = next((p for p in pois if p["name"] == TO_POI), None)
    if a is None or b is None:
        print(f"  FAIL both landmarks must exist ({FROM_POI!r}, {TO_POI!r})")
        return 1
    span = math.dist((a["x"], a["z"]), (b["x"], b["z"]))
    print(f"  ({span:.0f} m apart)")

    # --spawn-at rides in the shared args because the *server* places players;
    # handing it to the client alone leaves the bot at the region centre, a
    # kilometre from the landmark it thinks it started at.
    # 180 s, not 130. Phase 10 put stamina on sprinting, so a bot crossing the
    # basin now runs in bursts and walks the rest -- the journey is genuinely
    # slower than it was, by design. The first run after that landed 12 m short
    # of the marker with the window already closed.
    srv, (walker,) = session(
        user_dir, 180, PORT,
        ["--day-seconds", "99999", "--start-time", "0.30", "--spawn-at", FROM_POI],
        [["--client", "--auto", "--bot-profile", "pilgrim",
          "--goto", TO_POI, "--identity", "pilgrim"]])

    legs = PILGRIM.findall(walker.text())
    dists = [float(m[2]) for m in legs]
    check(bool(legs), f"the walker reported its progress ({len(legs)} readings)")
    if dists:
        check(dists[0] > span * 0.7,
              f"it started at {FROM_POI} ({dists[0]:.0f} m out)")
        check(min(dists) < 12.0,
              f"it arrived at {TO_POI} (closest {min(dists):.0f} m)")
        check(dists[0] - min(dists) > span * 0.5,
              f"it crossed the region under its own steering "
              f"({dists[0] - min(dists):.0f} m closed)")
    check("ARRIVED" in walker.text(), "and the arrival was reported as such")

    log = srv.text()
    check("hagga_basin_south" in log, "the server ran on the real region")
    m = re.search(r"\[pois\] (\d+) marker", log)
    check(bool(m) and int(m.group(1)) > 50,
          f"which loaded the wiki markers ({m.group(1) if m else '0'})")
    m = re.search(r"seeded (\d+) npc\(s\) across (\d+) camp", log)
    check(bool(m) and int(m.group(2)) >= 20,
          f"and put hostiles at the map's own camps "
          f"({m.group(2) if m else 0} camps, {m.group(1) if m else 0} npcs)")

    # --- run 2: a cave is shelter from the worm ------------------------------
    print("\n=== run 2: a cave holds the worm off ===")
    cave = next(p for p in pois if p["role"] == "shelter")
    srv2, (hider,) = session(
        user_dir, 95, PORT + 1,
        ["--day-seconds", "99999", "--start-time", "0.30",
         "--spawn-at", cave["name"]],
        [["--client", "--auto", "--bot-profile", "pilgrim",
          "--goto", cave["name"], "--identity", "hider"]])
    samples = [{"threat": float(x[1]), "on": x[3]} for x in BOT.findall(hider.text())]
    threats = [s["threat"] for s in samples]
    check(len(threats) > 5, f"the sheltering bot reported vitals ({len(threats)})")
    if threats:
        check(max(threats) < 25.0,
              f"threat never roused the worm inside {cave['name']} "
              f"(peak {max(threats):.1f})")
    check("taken by a worm" not in hider.text(),
          "and nothing came for it")

    # --- run 3: a stale client is refused ------------------------------------
    print("\n=== run 3: terrain is versioned ===")
    srv3 = launch(["--server", "--day-seconds", "99999"], user_dir, 22, PORT + 2)
    time.sleep(2.0)
    stale = launch(["--client", "--auto", "--identity", "stale",
                    "--region", "res://data/regions/synthetic_test"],
                   user_dir, 14, PORT + 2)
    for p in (stale, srv3):
        p.wait(50)
    both = stale.text() + srv3.text()
    check("fingerprint" in both.lower() or "refus" in both.lower()
          or "reject" in both.lower(),
          "a client on different terrain is turned away at the handshake")
    check("synthetic_test" in stale.text(),
          "and it really was holding the other region")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    total = len(failures)
    print(f"\nPhase 5 acceptance: {'FAIL' if total else 'PASS'} "
          f"({total} failure(s))" if total else "\nPhase 5 acceptance: PASS")
    for f in failures:
        print(f"  - {f}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
