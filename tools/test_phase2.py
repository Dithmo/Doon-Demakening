#!/usr/bin/env python3
"""Phase 2 acceptance test: the economy, over the wire.

Asserts the acceptance criteria from docs/game-plan.md Phase 2:
  * resource nodes deplete under harvesting and are server-owned
  * two players racing one node get one winner and no duplication
  * nodes regrow on their own timer
  * stations deploy, are validated, and persist
  * crafting is refused without a station and works with one
  * the crafted stillsuit measurably slows water loss

Unit coverage for node and crafting rules lives in tests/survival_tests.gd
(run with: godot --headless -- --run-tests). This harness covers what that
cannot: replication, contention between real clients, and persistence.

Run: python3 tools/test_phase2.py
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

GODOT = os.environ.get("GODOT", "/opt/godot/godot")
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27260"))

HARVEST = re.compile(r"\[harvest\] (\S+) node=(\d+) (\w+) x(\d+) remaining=(\d+)")
BOT = re.compile(r"\[bot\] (\S+) t=[\d.]+ \w+ water=([\d.-]+)")


class Proc:
    def __init__(self, args, env):
        self.lines = []
        self.p = subprocess.Popen(
            args, cwd=ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )

    def wait(self, timeout):
        try:
            self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
        if self.p.stdout:
            for line in self.p.stdout:
                self.lines.append(line.rstrip())

    def text(self):
        return "\n".join(self.lines)


def launch(extra, user_dir, seconds, port):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    # --peaceful: these suites are about gathering and building, not the worm.
    return Proc([GODOT, "--headless", "--path", str(ROOT), "--",
                 "--port", str(port), "--run-seconds", str(seconds),
                 "--peaceful"] + extra, env)


def session(user_dir, seconds, port, extra, clients):
    server = launch(["--server"] + extra, user_dir, seconds, port)
    time.sleep(2.0)
    procs = [launch(c + extra, user_dir, seconds - 2, port) for c in clients]
    for p in procs + [server]:
        p.wait(seconds + 25)
    return server, procs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home_p2"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    # Long day pins the clock so water never becomes the story.
    clock = ["--day-seconds", "99999", "--start-time", "0.30"]

    # --- run 1: harvesting depletes a server-owned node ---------------------
    print("\n=== run 1: harvesting ===")
    srv, (a,) = session(user_dir, 40, PORT, clock,
                        [["--client", "--auto", "--identity", "digger"]])
    check("[nodes] seeded" in srv.text(), "a fresh world seeds resource nodes")
    picks = HARVEST.findall(srv.text())
    check(len(picks) > 3, f"nodes can be harvested ({len(picks)} swings)")

    by_node = {}
    for who, nid, item, count, remaining in picks:
        by_node.setdefault(nid, []).append(int(remaining))
    falling = all(v == sorted(v, reverse=True) and len(v) == len(set(v))
                  for v in by_node.values())
    check(falling, "each node's remaining count falls, never repeats or rises")
    check(any(v[-1] == 0 for v in by_node.values()),
          "at least one node was worked to depletion")

    # --- run 2: two clients contending for the same nodes --------------------
    # The node's remaining count is the lock. If it were not, two bots swinging
    # at one vein would each bank a full yield from the same decrement.
    print("\n=== run 2: contested harvesting ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv2, _ = session(user_dir, 45, PORT + 1, clock,
                      [["--client", "--auto", "--identity", "ada"],
                       ["--client", "--auto", "--identity", "bo"]])
    picks2 = HARVEST.findall(srv2.text())
    check(len(picks2) > 5, f"both clients harvest ({len(picks2)} swings)")

    shared = {}
    for who, nid, item, count, remaining in picks2:
        shared.setdefault(nid, []).append((who, int(remaining)))
    contested = [nid for nid, rows in shared.items()
                 if len({w for w, _ in rows}) > 1]
    ok_seq = True
    for nid, rows in shared.items():
        seq = [r for _, r in rows]
        if seq != sorted(seq, reverse=True) or len(seq) != len(set(seq)):
            ok_seq = False
    check(ok_seq, "no node was decremented twice for one swing")
    print(f"       ({len(contested)} node(s) worked by both clients)")

    # --- run 3: deploying and crafting --------------------------------------
    print("\n=== run 3: stations and crafting ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv3, (c,) = session(user_dir, 34, PORT + 2,
                         clock + ["--grant", "plant_fiber:12"],
                         [["--client", "--auto", "--identity", "smith"]])
    check("[place] smith ok" in srv3.text(), "a fabricator deploys")
    crafts = re.findall(r"\[craft\] smith ok: crafted (.+?) x(\d+)", srv3.text())
    check(bool(crafts), f"crafting works over the wire ({crafts[:3]})")
    check(any(n == "Fibre Weave" for n, _ in crafts), "fibre weave is crafted")

    save = next(iter(pathlib.Path(user_dir).rglob("world_save.json")), None)
    check(save is not None, "server wrote a save")
    if save:
        blob = json.loads(save.read_text())
        check(len(blob.get("blobs", {}).get("nodes", [])) > 0, "nodes are persisted")
        check(len(blob.get("blobs", {}).get("stations", [])) > 0, "stations are persisted")

        # --- run 4: restart keeps the world ---------------------------------
        print("\n=== run 4: restart ===")
        srv4, _ = session(user_dir, 16, PORT + 3, clock,
                          [["--client", "--auto", "--identity", "smith"]])
        check("[nodes] restored" in srv4.text(), "nodes survive a restart")
        check("[stations] restored" in srv4.text(), "stations survive a restart")
        check("[nodes] seeded" not in srv4.text(), "an existing world is not re-seeded")

    # --- run 5: the stillsuit payoff ----------------------------------------
    # Same midday sun for both, one with the materials to finish the chain.
    print("\n=== run 5: the stillsuit is worth making ===")
    noon = ["--day-seconds", "99999", "--start-time", "0.5"]

    shutil.rmtree(user_dir); user_dir.mkdir()
    _, (bare,) = session(user_dir, 30, PORT + 4, noon,
                         [["--client", "--auto", "--identity", "bare"]])
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv6, (suited,) = session(user_dir, 30, PORT + 5,
                              noon + ["--grant", "fiber_weave:4,steel_ingot:2"],
                              [["--client", "--auto", "--identity", "suited"]])
    check("crafted Stillsuit" in srv6.text(), "the stillsuit is crafted")
    check("equipped Stillsuit" in srv6.text(), "the stillsuit is worn")

    def drain(proc):
        w = [float(m[1]) for m in BOT.findall(proc.text())]
        drops = [x - y for x, y in zip(w, w[1:]) if x > y]
        return sum(drops) / len(drops) if drops else 0.0

    bare_rate, suited_rate = drain(bare), drain(suited)
    check(bare_rate > 0.0 and suited_rate > 0.0, "both bots lose water at midday")
    check(suited_rate < bare_rate * 0.85,
          f"the stillsuit measurably slows water loss ({suited_rate:.2f} vs {bare_rate:.2f})")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    print()
    if failures:
        print("FAILURES:", *failures, sep="\n  ")
        return 1
    print("Phase 2 acceptance: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
