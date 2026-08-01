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
## A claim is an axis-aligned **box** anchored on a Sub-Fief console: the volume
## of ground and air you own. It reaches SIZE/2 either way horizontally, DOWN
## below the console's footing so its floor sits under the surface, and UP above
## it. Everything you build has to be inside it, and the build grid is measured
## from its corner so cells line up with its edges.
##
## It was a circle until Phase 12, which read fine on a map and badly in the
## world: you cannot see the edge of a circle, you cannot align a square grid
## to one, and there is no answer to "how high may I build".

## Edge length of a Sub-Fief claim, and how far the box reaches above and below
## the console. 48 m is sixteen 3 m cells, so the boundary is always a cell
## edge rather than a line through the middle of one.
const SIZE := 48.0
const UP := 24.0
const DOWN := 6.0

## claim id -> {owner, pos, radius, station_id}
var claims: Dictionary = {}
var _next_id: int = 1


## Register a claim for `owner` at `pos`. Returns {ok, msg, id}.
func stake(owner: String, pos: Vector3, radius: float, station_id: int) -> Dictionary:
	var trespass := claim_at(pos)
	if trespass != 0 and str(claims[trespass]["owner"]) != owner:
		return {"ok": false, "msg": "inside %s's holding" % claims[trespass]["owner"], "id": 0}
	# No two holdings may overlap, including two of your own. Letting a player
	# stack consoles on ground they already hold buys them nothing -- the land
	# is already theirs -- and it stacks the volumes on screen until the build
	# grid is unreadable, which is how it was noticed.
	for cid: int in claims:
		var c: Dictionary = claims[cid]
		# Boxes may not overlap, which for axis-aligned boxes is a separating
		# axis test on two axes rather than a distance.
		var gap: float = float(c["radius"]) + radius
		if absf(c["pos"].x - pos.x) < gap and absf(c["pos"].z - pos.z) < gap:
			if str(c["owner"]) == owner:
				return {"ok": false,
					"msg": "you already hold this ground", "id": 0}
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


## The claim containing this point, or 0. A box test, and it takes height into
## account: above the roof of the volume is outside it, which is what stops
## someone building a tower off the top of your holding.
func claim_at(pos: Vector3) -> int:
	for cid: int in claims:
		if contains(cid, pos):
			return cid
	return 0


## Is `pos` inside claim `cid`'s volume?
func contains(cid: int, pos: Vector3) -> bool:
	if not claims.has(cid):
		return false
	var c: Dictionary = claims[cid]
	return inside(c["pos"], float(c["radius"]), pos)


## The volume test on its own, so the client can ask "am I in this holding?" of
## a replicated row and get the same answer the server builds by. It went its
## own way once -- the HUD kept a circle after the server moved to a box, and
## said you were on your own land while the server refused to build there.
static func inside(centre: Vector3, half: float, pos: Vector3) -> bool:
	if absf(pos.x - centre.x) > half or absf(pos.z - centre.z) > half:
		return false
	return pos.y >= centre.y - DOWN and pos.y <= centre.y + UP


## The floor of a claim: the level every foundation in it sits at, so a floor
## comes out flat however the ground under it rolls.
func floor_of(cid: int) -> float:
	return float(claims[cid]["pos"].y) if claims.has(cid) else 0.0


## The -x/-z corner of a claim, which the build grid measures cells from. Cells
## are counted from here so the claim boundary is always a cell edge.
func origin_of(cid: int) -> Vector2:
	if not claims.has(cid):
		return Vector2.ZERO
	var o: Vector3 = claims[cid]["pos"]
	var half: float = float(claims[cid]["radius"])
	return Vector2(o.x - half, o.z - half)


## May `owner` build at this point? Only inside a holding they own or are
## allied to. Unclaimed ground is no longer open: the wiki is explicit that the
## Construction Tool "can only be used on land claimed using a Sub-fief
## console", and a claim you can build outside of is not a claim.
func may_build(owner: String, pos: Vector3, on_open_ground: bool = false) -> bool:
	var cid := claim_at(pos)
	if cid == 0:
		# The exception, and it has to exist, or the opening of the game is a
		# deadlock. A Sub-Fief is what *makes* ground claimable, and the
		# Survival Fabricator is the bench you craft the Sub-Fief at, so both go
		# down on open desert. Everything else needs a claim already there,
		# which is what the wiki means by the Construction Tool only working on
		# claimed land.
		return on_open_ground
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
