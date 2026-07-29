class_name StationField
extends RefCounted
## Deployed crafting stations, and the crafting they enable.
##
## Phase 2 needs somewhere to craft, not a building system: a station is a point
## with a kind, placed on legal ground and validated server-side. Phase 3
## replaces the placement rules here with real structural building (snapping,
## power, ownership) without changing what crafting asks of it -- "is the player
## stood near a station of kind X".

## How close a player must be to use a station, and how far apart stations go.
const USE_RANGE := 4.0
const MIN_SPACING := 3.0
const PLACE_RANGE := 4.0

## station id -> {kind, item_id, pos, owner}
var stations: Dictionary = {}
var _next_id: int = 1


## Place a station in front of the player. Returns {ok, msg, id}.
func place(owner: String, player_pos: Vector3, item_id: String) -> Dictionary:
	var def := ItemDB.get_def(item_id)
	var kind := str(def.get("station", ""))
	if kind.is_empty():
		return {"ok": false, "msg": "%s cannot be deployed" % def.get("name", item_id), "id": 0}

	if not Terrain.is_reachable(player_pos.x, player_pos.z):
		return {"ok": false, "msg": "cannot deploy here", "id": 0}

	var pos := Vector3(player_pos.x, Terrain.sample_height(player_pos.x, player_pos.z),
		player_pos.z)
	# Refusing to stack stations is the whole of Phase 2's placement validation.
	# It is deliberately the same shape as the overlap test Phase 3 will need.
	#
	# Compared on the horizontal plane: spacing is a footprint, and letting a
	# height difference inflate the distance would allow two stations to overlap
	# on any slope.
	for sid: int in stations:
		var other: Vector3 = stations[sid]["pos"]
		if Vector2(other.x - pos.x, other.z - pos.z).length() < MIN_SPACING:
			return {"ok": false, "msg": "too close to another station", "id": 0}
	var id := _next_id
	_next_id += 1
	stations[id] = {"kind": kind, "item_id": item_id, "pos": pos, "owner": owner}
	return {"ok": true, "msg": "deployed %s" % def.get("name", item_id), "id": id}


## Take a station back into the bag. Anyone may pick one up in Phase 2 --
## ownership becomes enforceable once Phase 3 has a claim system.
func pick_up(player_pos: Vector3, station_id: int) -> Dictionary:
	if not stations.has(station_id):
		return {"ok": false, "msg": "nothing there", "item_id": ""}
	var s: Dictionary = stations[station_id]
	if player_pos.distance_to(s["pos"]) > USE_RANGE:
		return {"ok": false, "msg": "too far away", "item_id": ""}
	var item_id: String = s["item_id"]
	stations.erase(station_id)
	return {"ok": true, "msg": "packed up %s" % ItemDB.display_name(item_id),
		"item_id": item_id}


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
func craft(player_pos: Vector3, inv: Inventory, recipe_id: String) -> Dictionary:
	if not RecipeDB.has(recipe_id):
		return {"ok": false, "msg": "no such recipe"}
	var r := RecipeDB.get_recipe(recipe_id)

	var kind := str(r["station"])
	if not kind.is_empty() and station_in_reach(player_pos, kind) == 0:
		return {"ok": false, "msg": "need a %s in reach" % kind}

	for i: Dictionary in r["inputs"]:
		if inv.count_of(i["id"]) < int(i["count"]):
			return {"ok": false,
				"msg": "need %s" % RecipeDB.describe_inputs(recipe_id)}

	# Check for room before consuming: the output has to land somewhere.
	var out: Dictionary = r["output"]
	if not _has_room(inv, str(out["id"]), int(out["count"])):
		return {"ok": false, "msg": "no room for %s" % ItemDB.display_name(out["id"])}

	for i: Dictionary in r["inputs"]:
		inv.remove(str(i["id"]), int(i["count"]))
	var leftover := inv.add(str(out["id"]), int(out["count"]))
	if leftover > 0:
		# _has_room said otherwise; surface it rather than silently voiding it.
		push_error("StationField: lost %d %s crafting %s" % [leftover, out["id"], recipe_id])
	return {"ok": true, "msg": "crafted %s x%d" % [ItemDB.display_name(out["id"]),
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


## Wire/disk form: [id, kind, item_id, x, y, z, owner].
func to_wire() -> Array:
	var out: Array = []
	for id: int in stations:
		var s: Dictionary = stations[id]
		var p: Vector3 = s["pos"]
		out.append([id, s["kind"], s["item_id"], p.x, p.y, p.z, s["owner"]])
	return out


func from_wire(rows: Array) -> void:
	stations.clear()
	for row: Array in rows:
		var id := int(row[0])
		stations[id] = {
			"kind": str(row[1]), "item_id": str(row[2]),
			"pos": Vector3(float(row[3]), float(row[4]), float(row[5])),
			"owner": str(row[6]),
		}
		_next_id = maxi(_next_id, id + 1)
