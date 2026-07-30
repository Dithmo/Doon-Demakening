class_name NodeField
extends RefCounted
## Resource nodes: server-owned, depleting, regrowing.
##
## Unlike the loose ground pickups from Phase 0, a node holds several harvests
## and comes back on a timer, so a patch is somewhere you return to rather than
## a one-shot. That is what turns gathering into a route.
##
## All state lives on the authority. Two players hammering the same vein is the
## first real concurrency case in the project: the node's remaining count is the
## lock, and it is decremented here and nowhere else.

const PATH := "res://data/world/nodes.json"
## How close a player must be to work a node.
const REACH := 3.5
## Minimum seconds between harvests by the same player. Paces gathering without
## needing a channelled progress bar.
const SWING_COOLDOWN := 1.2

## kind id -> definition
var kinds: Dictionary = {}
## node id -> {kind, pos, remaining, respawn_at}
var nodes: Dictionary = {}

var _next_id: int = 1
var _rng := RandomNumberGenerator.new()


func load_kinds() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("NodeField: cannot open %s" % PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("kinds"):
		push_error("NodeField: malformed %s" % PATH)
		return false
	var surfaces := {
		"sand": Terrain.Surface.SAND,
		"rock": Terrain.Surface.ROCK,
		"cliff": Terrain.Surface.CLIFF,
	}
	kinds.clear()
	for raw: Variant in parsed["kinds"]:
		var d: Dictionary = raw
		var y: Dictionary = d["yield"]
		if not ItemDB.has(str(y["id"])):
			push_error("NodeField: kind '%s' yields unknown item '%s'" % [d["id"], y["id"]])
			return false
		kinds[str(d["id"])] = {
			"id": str(d["id"]),
			"name": str(d.get("name", d["id"])),
			"surface": int(surfaces.get(str(d.get("surface", "sand")), Terrain.Surface.SAND)),
			"yield_id": str(y["id"]),
			"yield_count": int(y.get("count", 1)),
			"harvests": int(d.get("harvests", 3)),
			# Units of resource in one node. A cutteray drains this at its own
			# rate per second, so a node is ten seconds of beam rather than
			# three taps of a key. `harvests` stays for the hand-picked kinds
			# and for the older tests, which count swings.
			"amount": int(d.get("amount", 40)),
			"respawn_seconds": float(d.get("respawn_seconds", 120.0)),
			# Empty means bare hands will do; otherwise the player needs an item
			# carrying this use hook.
			"tool": str(d.get("tool", "")),
			"count": int(d.get("count", 10)),
			# Nodes per square kilometre. `count` is a floor, so the small
			# synthetic regions keep the densities their harnesses were tuned
			# against and the real map gets scattered properly instead of
			# inheriting a test map's headcount across twenty-seven times the
			# ground.
			"per_km2": float(d.get("per_km2", 0.0)),
			# Anchored kinds are placed at POIs of a role rather than scattered.
			# Salvage belongs at the wrecks the map actually draws: that is what
			# makes a shipwreck somewhere you go rather than a silhouette.
			"anchor": str(d.get("anchor", "")),
			# Kinds added after Phases 0-4 were tuned stay off the synthetic test
			# region. That map is a fixture: its node layout is what those
			# suites' thresholds were measured against, so new content must not
			# rearrange it.
			"real_only": bool(d.get("real_only", false)),
		}
	print("[nodes] loaded %d kind(s)" % kinds.size())
	return true


## Scatter nodes across the region, each on the surface its kind belongs to.
func seed(seed_value: int = 424242) -> void:
	var synthetic := Terrain.region_dir.contains("synthetic")
	for kind_id: String in kinds:
		if synthetic and bool(kinds[kind_id]["real_only"]):
			continue
		# Each kind draws from its own stream, derived from the world seed and
		# the kind's name. One shared RNG meant that *adding* a resource
		# reshuffled the positions of every resource already on the map: copper
		# and carbon arrived, and every vein, outcrop and wreck moved with them.
		# A new material should appear alongside the old ones, not rearrange
		# the world.
		_rng.seed = seed_value ^ hash(kind_id)
		var k: Dictionary = kinds[kind_id]
		var placed := 0
		var tries := 0
		var anchor := str(k["anchor"])
		if not anchor.is_empty():
			for p: Vector3 in Pois.positions(anchor):
				if not Terrain.is_reachable(p.x, p.z):
					continue
				_spawn(kind_id, p)
				placed += 1
			if placed > 0:
				continue
			# No markers for that role -- a synthetic region, or a crop that
			# caught none. Fall through and scatter rather than ship a kind
			# that silently does not exist.
		var want := _target_count(k)
		while placed < want and tries < want * 300:
			tries += 1
			var x := _rng.randf_range(6.0, Terrain.size_m.x - 6.0)
			var z := _rng.randf_range(6.0, Terrain.size_m.y - 6.0)
			if Terrain.sample_surface(x, z) != k["surface"]:
				continue
			# Reachable, not merely walkable: a vein on a cliff-ringed plateau
			# is one no player can ever work.
			if not Terrain.is_reachable(x, z):
				continue
			_spawn(kind_id, Vector3(x, Terrain.sample_height(x, z), z))
			placed += 1
		if placed < want:
			push_warning("NodeField: only placed %d/%d %s" % [placed, want, kind_id])
	print("[nodes] seeded %d node(s)" % nodes.size())


## How many of a kind this region should carry: whichever is larger of the
## authored floor and the density applied to the region's actual area.
func _target_count(k: Dictionary) -> int:
	var area_km2 := (Terrain.size_m.x * Terrain.size_m.y) / 1000000.0
	return maxi(int(k["count"]), int(round(float(k["per_km2"]) * area_km2)))


func _spawn(kind_id: String, pos: Vector3) -> int:
	var id := _next_id
	_next_id += 1
	nodes[id] = {
		"kind": kind_id, "pos": pos,
		"remaining": int(kinds[kind_id]["harvests"]), "respawn_at": 0.0,
		# Units left in the pool, and the fraction of a unit the beam has cut
		# but not yet handed over -- a 4/s beam on a 1/60 s tick moves 0.067 of
		# a unit, and dropping that would mean the beam yielded nothing at all.
		"units": int(kinds[kind_id]["amount"]), "part": 0.0,
	}
	return id


## Bring depleted nodes back. Returns the ids that regrew, so the caller can
## replicate them.
func tick(now: float) -> Array:
	var regrown: Array = []
	for id: int in nodes:
		var n: Dictionary = nodes[id]
		if float(n["respawn_at"]) <= 0.0:
			continue
		if int(n["remaining"]) > 0 and int(n.get("units", 0)) > 0:
			continue
		if now >= float(n["respawn_at"]):
			n["remaining"] = int(kinds[n["kind"]]["harvests"])
			n["units"] = int(kinds[n["kind"]]["amount"])
			n["part"] = 0.0
			n["respawn_at"] = 0.0
			regrown.append(id)
	return regrown


## Attempt one harvest. Returns
## {ok, msg, item, count, depleted, remaining} -- `depleted` means this swing
## emptied the node.
##
## Every rule is checked here rather than trusted from the client: reach against
## the server's own position, the tool actually in the bag, and the node's own
## remaining count.
## `bonus` is Deep Harvest's flat extra, `salvage_mult` is Salvager. Both
## default to neutral so callers written before skills keep their meaning.
func harvest(player_pos: Vector3, inv: Inventory, node_id: int,
		cooldowns: Dictionary, now: float, bonus: int = 0,
		salvage_mult: float = 1.0) -> Dictionary:
	if not nodes.has(node_id):
		return _fail("nothing there")
	var n: Dictionary = nodes[node_id]
	var k: Dictionary = kinds[n["kind"]]

	if player_pos.distance_to(n["pos"]) > REACH:
		return _fail("too far from the %s" % k["name"])
	if int(n["remaining"]) <= 0:
		return _fail("%s is spent" % k["name"])
	if now < float(cooldowns.get("swing", 0.0)):
		return _fail("")  # mid-swing; silent, this fires constantly

	var tool_hook := str(k["tool"])
	if not tool_hook.is_empty() and not _has_tool(inv, tool_hook):
		return _fail("need a cutting tool for %s" % k["name"])

	var amount := int(k["yield_count"]) + maxi(0, bonus)
	# Salvager applies only where the map says there is a wreck, which is what
	# makes it a crafting skill rather than a second gathering one.
	if not str(k["anchor"]).is_empty():
		amount = int(round(float(amount) * salvage_mult))
	amount = maxi(1, amount)
	var leftover := inv.add(str(k["yield_id"]), amount)
	if leftover >= amount:
		return _fail("no room for %s" % ItemDB.display_name(k["yield_id"]))

	cooldowns["swing"] = now + SWING_COOLDOWN
	n["remaining"] = int(n["remaining"]) - 1
	var depleted := int(n["remaining"]) <= 0
	if depleted:
		n["respawn_at"] = now + float(k["respawn_seconds"])

	return {
		"ok": true, "msg": "harvested %s x%d" % [ItemDB.display_name(k["yield_id"]),
			amount - leftover],
		"item": str(k["yield_id"]), "count": amount - leftover,
		"depleted": depleted, "remaining": int(n["remaining"]),
	}


func _has_tool(inv: Inventory, hook: String) -> bool:
	for s: Dictionary in inv.slots:
		if s.is_empty():
			continue
		if str(ItemDB.get_def(s["id"]).get("use", "")) == hook:
			return true
	return false


## Wire/disk form: [id, kind, x, y, z, remaining].
func to_wire() -> Array:
	var out: Array = []
	for id: int in nodes:
		var n: Dictionary = nodes[id]
		var p: Vector3 = n["pos"]
		out.append([id, n["kind"], p.x, p.y, p.z, int(n["remaining"]), int(n["units"])])
	return out


## Restore. `now` rebases respawn timers, which are wall-clock and so cannot
## survive a restart -- anything mid-regrow simply comes back ready.
func from_wire(rows: Array, now: float) -> void:
	nodes.clear()
	for row: Array in rows:
		var id := int(row[0])
		var kind := str(row[1])
		if not kinds.has(kind):
			continue
		var remaining := int(row[5])
		# Saves written before nodes had a unit pool have no sixth column; those
		# nodes come back full rather than unmineable.
		var units := int(row[6]) if row.size() > 6 else int(kinds[kind]["amount"])
		var dry := remaining <= 0 or units <= 0
		nodes[id] = {
			"kind": kind,
			"pos": Vector3(float(row[2]), float(row[3]), float(row[4])),
			"remaining": remaining,
			"units": units,
			"part": 0.0,
			"respawn_at": now + kinds[kind]["respawn_seconds"] if dry else 0.0,
		}
		_next_id = maxi(_next_id, id + 1)


func _fail(msg: String) -> Dictionary:
	return {"ok": false, "msg": msg, "item": "", "count": 0,
		"depleted": false, "remaining": 0}


## Cut `dt` seconds of beam at `rate` units/second out of a node.
##
## Server-only, and the node's `units` count is the lock exactly as `remaining`
## is for a swung harvest: two players beaming the same wreck both land here,
## one at a time, and between them they can take out what is in it and no more.
##
## Returns {ok, msg, count, units, exhausted}. `count` is whole units moved to
## the bag this call, which is usually zero on any given frame -- the fraction
## is banked on the node until it adds up.
func beam(player_pos: Vector3, inv: Inventory, node_id: int, rate: float,
		range_m: float, dt: float, yield_mult: float = 1.0) -> Dictionary:
	if not nodes.has(node_id):
		return _fail("no such node")
	var n: Dictionary = nodes[node_id]
	var k: Dictionary = kinds[str(n["kind"])]
	if int(n["units"]) <= 0:
		return _fail("that is stripped bare")
	if player_pos.distance_to(n["pos"]) > range_m:
		return _fail("out of range")
	# The node's own requirement, not just "is the thing in my hand a beam".
	# Only cutterays carry a beam rate today, so nothing could reach here
	# without one -- but the requirement belongs to the rock, and when tiered
	# tools arrive this is the line that has to already be right.
	var need := str(k["tool"])
	if not need.is_empty() and not _has_tool(inv, need):
		return _fail("%s needs the right tool" % k["name"])

	n["part"] = float(n["part"]) + rate * yield_mult * dt
	var whole := int(floor(float(n["part"])))
	if whole <= 0:
		return {"ok": true, "msg": "", "count": 0,
			"units": int(n["units"]), "exhausted": false}
	whole = mini(whole, int(n["units"]))
	n["part"] = float(n["part"]) - float(whole)

	var leftover := inv.add(str(k["yield_id"]), whole)
	var taken := whole - leftover
	if taken <= 0:
		# Bag is full. Put the fraction back rather than burning the node down
		# into a bag that cannot hold it.
		n["part"] = 0.0
		return _fail("no room for the %s" % k["yield_id"])

	n["units"] = int(n["units"]) - taken
	var dry := int(n["units"]) <= 0
	if dry:
		# A stripped node goes on the same respawn timer a swung-out one uses.
		n["remaining"] = 0
		n["part"] = 0.0
		n["respawn_at"] = Time.get_ticks_msec() / 1000.0 + float(k["respawn_seconds"])
	return {"ok": true, "msg": "", "count": taken, "item": str(k["yield_id"]),
		"units": int(n["units"]), "exhausted": dry}
