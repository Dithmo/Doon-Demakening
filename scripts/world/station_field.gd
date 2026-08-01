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


## Place a station in front of the player. Returns {ok, msg, id}.
##
## `claims` may be null for callers that predate ownership (and for tests that
## are only exercising spacing); when given, deploying inside someone else's
## holding is refused.
func place(owner: String, player_pos: Vector3, item_id: String,
		claims: Claims = null) -> Dictionary:
	var def := ItemDB.get_def(item_id)
	var kind := str(def.get("station", ""))
	if kind.is_empty():
		return {"ok": false, "msg": "%s cannot be deployed" % def.get("name", item_id), "id": 0}

	if not Terrain.is_reachable(player_pos.x, player_pos.z):
		return {"ok": false, "msg": "cannot deploy here", "id": 0}
	# A console that stakes a claim may be set down on unclaimed ground; that is
	# the whole point of it.
	var stakes := float(ItemDB.get_def(item_id).get("claim_radius", 0.0)) > 0.0
	if claims != null and not claims.may_build(owner, player_pos, stakes):
		return {"ok": false, "msg": "you must build inside your own holding",
			"id": 0}

	# Snap to the nearest legal spot rather than demanding the player stand in
	# exactly the right place. Deploying a second thing should not require
	# walking away from the first.
	var spot := _free_spot(player_pos, owner, claims)
	if spot.is_empty():
		return {"ok": false, "msg": "no room to deploy here", "id": 0}
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
	return {"ok": true, "msg": "packed up %s" % ItemDB.display_name(item_id),
		"item_id": item_id}


## Nearest position to the player that is clear of other stations, legal
## terrain, and inside a claim they may build in. Spirals outward so the result
## is as close to the player as the rules allow.
func _free_spot(near: Vector3, owner: String, claims: Claims) -> Dictionary:
	var radius := 0.0
	while radius <= PLACE_RANGE:
		var steps: int = maxi(1, int(radius * 3.0))
		for i in range(steps):
			var a := TAU * float(i) / float(steps)
			var x := near.x + cos(a) * radius
			var z := near.z + sin(a) * radius
			if not Terrain.is_reachable(x, z):
				continue
			if claims != null and not claims.may_build(owner, Vector3(x, 0.0, z)):
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
		var slots := int(ItemDB.get_def(item_id).get("container_slots", 0))
		if slots > 0:
			var inv := Inventory.new(slots)
			if row.size() > 7:
				inv.from_data(row[7])
			s["inventory"] = inv
		stations[id] = s
		_next_id = maxi(_next_id, id + 1)
