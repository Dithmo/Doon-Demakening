class_name Claims
extends RefCounted
## Land ownership. Server-owned, and the reason a base is yours.
##
## Phase 2's placement rules only stopped you stacking things on each other.
## That is not enough once bases exist: without ownership, anyone can wall you
## in, sit a fabricator in your doorway, or empty your cistern. Claims are
## where griefing gets answered, so every rule here is enforced on the
## authority and nothing is trusted from a client.
##
## A claim is a circle anchored on a Sub-Fief console. Placing one inside
## someone else's claim is refused; so is building or deploying there.

## claim id -> {owner, pos, radius, station_id}
var claims: Dictionary = {}
var _next_id: int = 1


## Register a claim for `owner` at `pos`. Returns {ok, msg, id}.
func stake(owner: String, pos: Vector3, radius: float, station_id: int) -> Dictionary:
	var trespass := claim_at(pos)
	if trespass != 0 and str(claims[trespass]["owner"]) != owner:
		return {"ok": false, "msg": "inside %s's holding" % claims[trespass]["owner"], "id": 0}
	# Overlapping your own claims is pointless but harmless; overlapping
	# someone else's is the thing we refuse, including at the rim.
	for cid: int in claims:
		var c: Dictionary = claims[cid]
		if str(c["owner"]) == owner:
			continue
		if _flat_distance(c["pos"], pos) < float(c["radius"]) + radius:
			return {"ok": false, "msg": "too close to %s's holding" % c["owner"], "id": 0}

	var id := _next_id
	_next_id += 1
	claims[id] = {"owner": owner, "pos": pos, "radius": radius, "station_id": station_id}
	return {"ok": true, "msg": "holding registered", "id": id}


## The guild register, set by the server at startup. Held as an explicit
## reference rather than reached for globally, and left null on clients and in
## unit tests -- where it makes may_build behave exactly as it did before
## guilds existed, so every claim test written against it still holds.
var allies: Guilds = null


## The claim containing this point, or 0.
func claim_at(pos: Vector3) -> int:
	for cid: int in claims:
		var c: Dictionary = claims[cid]
		if _flat_distance(c["pos"], pos) <= float(c["radius"]):
			return cid
	return 0


## May `owner` build at this point? Unclaimed land is open to everyone --
## claiming it is what makes it yours.
func may_build(owner: String, pos: Vector3) -> bool:
	var cid := claim_at(pos)
	if cid == 0:
		return true
	var holder := str(claims[cid]["owner"])
	if holder == owner:
		return true
	# A holding admits its owner's guild. That is the single rule a guild
	# changes about the world, which is why it is one line here rather than a
	# permissions system: Phase 3's anti-grief boundary becomes the thing a
	# group organises around instead of a wall between friends.
	return allies != null and allies.allied(holder, owner)


func owner_at(pos: Vector3) -> String:
	var cid := claim_at(pos)
	return "" if cid == 0 else str(claims[cid]["owner"])


func release(claim_id: int) -> void:
	claims.erase(claim_id)


## Claim anchored on a given station, or 0. Used when a console is packed up.
func claim_for_station(station_id: int) -> int:
	for cid: int in claims:
		if int(claims[cid]["station_id"]) == station_id:
			return cid
	return 0


## Compared on the horizontal plane: a claim is a footprint on the ground, and
## letting a height difference shrink it would leave gaps on sloped terrain.
func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Wire/disk form: [id, owner, x, y, z, radius, station_id].
func to_wire() -> Array:
	var out: Array = []
	for cid: int in claims:
		var c: Dictionary = claims[cid]
		var p: Vector3 = c["pos"]
		out.append([cid, c["owner"], p.x, p.y, p.z, c["radius"], c["station_id"]])
	return out


func from_wire(rows: Array) -> void:
	claims.clear()
	for row: Array in rows:
		var cid := int(row[0])
		claims[cid] = {
			"owner": str(row[1]),
			"pos": Vector3(float(row[2]), float(row[3]), float(row[4])),
			"radius": float(row[5]),
			"station_id": int(row[6]),
		}
		_next_id = maxi(_next_id, cid + 1)
