class_name StationField
extends RefCounted
## Deployed crafting stations, and the crafting they enable.
##
## Phase 2 needed somewhere to craft; Phase 3 makes these the working parts of
## a holding -- generators, windtraps, cisterns, chests -- so placement is now
## claim-aware and some stations carry an inventory of their own.
##
## Structural pieces live in BuildGrid, not here: a wall snaps to a grid and
## needs support, whereas a station is a free-standing point. Keeping the two
## apart means neither has to carry the other's rules.

## How close a player must be to use a station, and how far apart stations go.
const USE_RANGE := 4.0
const MIN_SPACING := 3.0
const PLACE_RANGE := 6.0

## station id -> {kind, item_id, pos, owner}
var stations: Dictionary = {}
var _next_id: int = 1


## Two kinds of thing stand in this field, and they come from two catalogues.
## A *structure* -- refinery, windtrap, chest -- is placed with the Construction
## Tool and never exists as an item, so it is defined in StructureDB. A
## *deployable item* -- thumper, stilltent -- is field kit you carry and set
## down, so it is in ItemDB like anything else you can hold. Both end up here
## because both are a thing standing in the world at a point; only where their
## definition lives differs.
static func def_of(id: String) -> Dictionary:
	return StructureDB.get_def(id) if StructureDB.has(id) else ItemDB.get_def(id)


## What to call it, whichever catalogue it came from.
static func name_of(id: String) -> String:
	return StructureDB.display_name(id) if StructureDB.has(id) \
		else ItemDB.display_name(id)


## Place a station in front of the player. Returns {ok, msg, id}.
##
## `claims` may be null for callers that predate ownership (and for tests that
## are only exercising spacing); when given, deploying inside someone else's
## holding is refused.
func place(owner: String, player_pos: Vector3, item_id: String,
		claims: Claims = null, grid: BuildGrid = null) -> Dictionary:
	var def := def_of(item_id)
	var kind := str(def.get("station", ""))
	if kind.is_empty():
		return {"ok": false, "msg": "%s cannot be deployed" % def.get("name", item_id), "id": 0}

	if not Terrain.is_reachable(player_pos.x, player_pos.z):
		return {"ok": false, "msg": "cannot deploy here", "id": 0}
	# Open ground is for the Sub-Fief, which is the thing that *creates* a
	# claim, and for field kit you carry -- a thumper is bait you throw into
	# open sand. Everything else belongs to a holding.
	var open_ok := float(def.get("claim_radius", 0.0)) > 0.0 \
		or bool(def.get("open_ground", false))
	if claims != null and not claims.may_build(owner, player_pos, open_ok):
		return {"ok": false, "msg": "you must build inside your own holding",
			"id": 0}

	# A structure stands on a floor. That is what puts the order of the opening
	# beyond argument: console, then floor, then anything that does work.
	#
	# Like the claim rule above it, this lapses when `claims` is null. Standing
	# on a floor is a rule about land, and a caller that has opted out of land
	# ownership entirely -- the crafting tests, which only care that a bench is
	# reachable -- has opted out of this too. Both rules are on together or off
	# together; being on separately is how a fixture ends up asserting against
	# half a world.
	var needs_floor := claims != null and bool(def.get("needs_foundation", false))
	if needs_floor and grid == null:
		return {"ok": false, "msg": "that needs a foundation to stand on", "id": 0}

	# Snap to the nearest legal spot rather than demanding the player stand in
	# exactly the right place. Deploying a second thing should not require
	# walking away from the first.
	var spot := _free_spot(player_pos, owner, claims, open_ok,
		grid if needs_floor else null)
	if spot.is_empty():
		return {"ok": false, "msg": "that needs a foundation to stand on"
			if needs_floor else "no room to deploy here", "id": 0}
	var pos: Vector3 = spot["pos"]
	var id := _next_id
	_next_id += 1
	stations[id] = {"kind": kind, "item_id": item_id, "pos": pos, "owner": owner}
	# Containers carry their own inventory, so a cistern is somewhere a
	# windtrap can put water and a chest is somewhere a player can.
	var slots := int(def.get("container_slots", 0))
	if slots > 0:
		stations[id]["inventory"] = Inventory.new(slots)
	return {"ok": true, "msg": "deployed %s" % def.get("name", item_id), "id": id}


## Take a station back into the bag. Refuses inside someone else's holding, and
## refuses to swallow a container that still has something in it.
func pick_up(player_pos: Vector3, station_id: int, who: String = "",
		claims: Claims = null) -> Dictionary:
	if not stations.has(station_id):
		return {"ok": false, "msg": "nothing there", "item_id": ""}
	var s: Dictionary = stations[station_id]
	if player_pos.distance_to(s["pos"]) > USE_RANGE:
		return {"ok": false, "msg": "too far away", "item_id": ""}
	if claims != null and not who.is_empty() and not claims.may_build(who, s["pos"]):
		return {"ok": false, "msg": "that is %s's holding" % claims.owner_at(s["pos"]),
			"item_id": ""}
	if s.has("inventory") and not _container_empty(s["inventory"]):
		return {"ok": false, "msg": "empty it first", "item_id": ""}
	var item_id: String = s["item_id"]
	stations.erase(station_id)
	return {"ok": true, "msg": "packed up %s" % name_of(item_id),
		"item_id": item_id}


## Nearest position to the player that is clear of other stations, legal
## terrain, and inside a claim they may build in. Spirals outward so the result
## is as close to the player as the rules allow. `on_open_ground` rides through
## because the exemption belongs to the item, and a spot that is legal for the
## caller must be legal for the spiral too -- otherwise the check above says yes
## and the search below quietly says no.
## `floor_grid`, when given, restricts the search to cells that already have a
## floor tile on them -- passed only for structures that need one, so field kit
## and the console still spiral over open ground.
func _free_spot(near: Vector3, owner: String, claims: Claims,
		on_open_ground: bool = false, floor_grid: BuildGrid = null) -> Dictionary:
	var radius := 0.0
	while radius <= PLACE_RANGE:
		var steps: int = maxi(1, int(radius * 3.0))
		for i in range(steps):
			var a := TAU * float(i) / float(steps)
			var x := near.x + cos(a) * radius
			var z := near.z + sin(a) * radius
			if not Terrain.is_reachable(x, z):
				continue
			# The candidate's real height, not zero. A claim is a *volume* now,
			# so asking whether you may build at y=0 asks about a point six
			# metres under the floor of your own holding -- which said no
			# everywhere and refused every deployment on the map.
			var probe := Vector3(x, Terrain.sample_height(x, z), z)
			if claims != null and not claims.may_build(owner, probe, on_open_ground):
				continue
			if floor_grid != null and not floor_grid.has_floor_at(probe, claims):
				continue
			var clear := true
			for sid: int in stations:
				var other: Vector3 = stations[sid]["pos"]
				# Horizontal: spacing is a footprint, and a height difference
				# must not be allowed to inflate it on a slope.
				if Vector2(other.x - x, other.z - z).length() < MIN_SPACING:
					clear = false
					break
			if clear:
				return {"pos": Vector3(x, Terrain.sample_height(x, z), z)}
		radius += 1.0
	return {}


func _container_empty(inv: Inventory) -> bool:
	for s: Dictionary in inv.slots:
		if not s.is_empty():
			return false
	return true


## Nearest container station within reach, or 0.
func container_in_reach(player_pos: Vector3) -> int:
	for id: int in stations:
		var s: Dictionary = stations[id]
		if s.has("inventory") and player_pos.distance_to(s["pos"]) <= USE_RANGE:
			return id
	return 0


## Move a stack between a player's bag and a container. `to_container` chooses
## the direction. Both sides are server-owned, so two players emptying the same
## chest resolve one at a time and cannot duplicate a stack.
func transfer(player_pos: Vector3, inv: Inventory, station_id: int,
		slot_index: int, to_container: bool) -> Dictionary:
	if not stations.has(station_id):
		return {"ok": false, "msg": "nothing there"}
	var s: Dictionary = stations[station_id]
	if not s.has("inventory"):
		return {"ok": false, "msg": "that holds nothing"}
	if player_pos.distance_to(s["pos"]) > USE_RANGE:
		return {"ok": false, "msg": "too far away"}

	var box: Inventory = s["inventory"]
	var from: Inventory = inv if to_container else box
	var into: Inventory = box if to_container else inv
	var stack := from.take_slot(slot_index)
	if stack.is_empty():
		return {"ok": false, "msg": "nothing in that slot"}
	var leftover := into.add(str(stack["id"]), int(stack["count"]))
	if leftover > 0:
		# Put back exactly what would not fit rather than losing it.
		from.add(str(stack["id"]), leftover)
	var moved := int(stack["count"]) - leftover
	if moved <= 0:
		return {"ok": false, "msg": "no room"}
	return {"ok": true, "msg": "moved %s x%d" % [ItemDB.display_name(stack["id"]), moved]}


func station_in_reach(player_pos: Vector3, kind: String) -> int:
	for id: int in stations:
		var s: Dictionary = stations[id]
		if s["kind"] == kind and player_pos.distance_to(s["pos"]) <= USE_RANGE:
			return id
	return 0


## Kinds of station the player can currently reach. Drives the craft menu.
func kinds_in_reach(player_pos: Vector3) -> Array:
	var out: Array = []
	for id: int in stations:
		var s: Dictionary = stations[id]
		if player_pos.distance_to(s["pos"]) <= USE_RANGE and not out.has(s["kind"]):
			out.append(s["kind"])
	return out


## Craft one unit. Returns {ok, msg}.
##
## Inputs are only removed once everything has been checked, so a failed craft
## never eats materials.
## `cost_mult` is the crafter's Efficient Fabrication discount, applied to every
## input. Rounded up and floored at one, so a discount can make a recipe cheaper
## but never free -- a zero-input recipe is an item printer.
func craft(player_pos: Vector3, inv: Inventory, recipe_id: String,
		cost_mult: float = 1.0) -> Dictionary:
	if not RecipeDB.has(recipe_id):
		return {"ok": false, "msg": "no such recipe"}
	var r := RecipeDB.get_recipe(recipe_id)

	var kind := str(r["station"])
	if not kind.is_empty() and station_in_reach(player_pos, kind) == 0:
		return {"ok": false, "msg": "need a %s in reach" % kind}

	var needs: Array = []
	for i: Dictionary in r["inputs"]:
		var n: int = maxi(1, int(ceil(float(i["count"]) * cost_mult)))
		needs.append({"id": str(i["id"]), "count": n})
		if inv.count_of(i["id"]) < n:
			return {"ok": false,
				"msg": "need %s" % RecipeDB.describe_inputs(recipe_id)}

	# Check for room before consuming: the output has to land somewhere.
	var out: Dictionary = r["output"]
	if not _has_room(inv, str(out["id"]), int(out["count"])):
		return {"ok": false, "msg": "no room for %s" % ItemDB.display_name(out["id"])}

	for i: Dictionary in needs:
		inv.remove(str(i["id"]), int(i["count"]))
	var leftover := inv.add(str(out["id"]), int(out["count"]))
	if leftover > 0:
		# _has_room said otherwise; surface it rather than silently voiding it.
		push_error("StationField: lost %d %s crafting %s" % [leftover, out["id"], recipe_id])
	return {"ok": true, "item": str(out["id"]), "count": int(out["count"]) - leftover,
		"msg": "crafted %s x%d" % [ItemDB.display_name(out["id"]),
		int(out["count"]) - leftover]}


## Would `count` of `id` fit, given current contents?
func _has_room(inv: Inventory, id: String, count: int) -> bool:
	var cap := ItemDB.stack_size(id)
	var room := 0
	for s: Dictionary in inv.slots:
		if s.is_empty():
			room += cap
		elif s["id"] == id:
			room += cap - int(s["count"])
		if room >= count:
			return true
	return room >= count


## Wire/disk form: [id, kind, item_id, x, y, z, owner, contents, carry].
## Contents ride along so a cistern still holds its water after a restart.
func to_wire() -> Array:
	var out: Array = []
	for id: int in stations:
		var s: Dictionary = stations[id]
		var p: Vector3 = s["pos"]
		var contents: Array = (s["inventory"] as Inventory).to_data() \
			if s.has("inventory") else []
		out.append([id, s["kind"], s["item_id"], p.x, p.y, p.z, s["owner"],
			contents, float(s.get("carry", 0.0))])
	return out


func from_wire(rows: Array) -> void:
	stations.clear()
	for row: Array in rows:
		var id := int(row[0])
		var item_id := str(row[2])
		var s: Dictionary = {
			"kind": str(row[1]), "item_id": item_id,
			"pos": Vector3(float(row[3]), float(row[4]), float(row[5])),
			"owner": str(row[6]),
			"carry": float(row[8]) if row.size() > 8 else 0.0,
		}
		var slots := int(def_of(item_id).get("container_slots", 0))
		if slots > 0:
			var inv := Inventory.new(slots)
			if row.size() > 7:
				inv.from_data(row[7])
			s["inventory"] = inv
		stations[id] = s
		_next_id = maxi(_next_id, id + 1)
