class_name BuildGrid
extends RefCounted
## Structural building: foundations, walls and ceilings on a snapped grid.
##
## Pieces snap to a fixed grid rather than being placed freely. That is not a
## simplification for its own sake -- it makes "is this piece supported?" and
## "is this cell occupied?" exact integer questions, which is what lets the
## server validate a build without trusting a single client-supplied transform.
##
## Support rules, which is all the structure a demake needs:
##   foundation  level 0 only, on reachable and reasonably flat ground
##   wall        on one of the four edges of a supported cell
##   ceiling     on a supported cell, and becomes support for the level above
##
## A ceiling supporting the next level up is what gives multi-storey building
## for free, without a second set of rules.

const CELL := 3.0
## Ground under a foundation must not vary by more than this across the cell.
const MAX_UNEVENNESS := 1.6
## How far a player can reach to place or remove a piece.
const BUILD_RANGE := 8.0

enum Piece { FOUNDATION, WALL, CEILING }

const PIECE_NAMES := {"foundation": Piece.FOUNDATION, "wall": Piece.WALL,
	"ceiling": Piece.CEILING}

## key -> {piece, cell: Vector2i, level: int, side: int, owner: String}
## Key is a string so it survives a JSON round-trip unchanged.
var pieces: Dictionary = {}


static func world_to_cell(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))


static func cell_centre(cell: Vector2i) -> Vector2:
	return Vector2((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL)


## Which cell of a claim a point falls in, counted from the claim's corner.
static func cell_in(pos: Vector3, origin: Vector2) -> Vector2i:
	return Vector2i(int(floor((pos.x - origin.x) / CELL)),
		int(floor((pos.z - origin.y) / CELL)))


## The centre of a claim-relative cell, back in world space.
static func cell_centre_in(cell: Vector2i, origin: Vector2) -> Vector2:
	return origin + Vector2((float(cell.x) + 0.5) * CELL,
		(float(cell.y) + 0.5) * CELL)


## The edge of `cell` nearest to `pos`: 0 = -z, 1 = +x, 2 = +z, 3 = -x.
## Walls snap to whichever edge the player is closest to, so aiming roughly at
## a side is enough.
## Which edge of a cell a point is nearest. Takes the claim's corner, because
## cells are counted from there -- measuring against a world-origin centre put
## every wall on whichever side the claim happened to be offset towards.
static func nearest_side(cell: Vector2i, pos: Vector3,
		origin: Vector2 = Vector2.ZERO) -> int:
	var c := cell_centre_in(cell, origin)
	var dx := pos.x - c.x
	var dz := pos.z - c.y
	if absf(dx) > absf(dz):
		return 1 if dx > 0.0 else 3
	return 2 if dz > 0.0 else 0


func _key(piece: Piece, cell: Vector2i, level: int, side: int) -> String:
	return "%d:%d:%d:%d:%d" % [piece, cell.x, cell.y, level, side]


func has_piece(piece: Piece, cell: Vector2i, level: int, side: int = 0) -> bool:
	return pieces.has(_key(piece, cell, level, side))


## A cell can carry walls and a ceiling if it has a foundation at this level,
## or a ceiling directly beneath it.
func supported(cell: Vector2i, level: int) -> bool:
	if has_piece(Piece.FOUNDATION, cell, level):
		return true
	return level > 0 and has_piece(Piece.CEILING, cell, level - 1)


## Ground height under a cell, and how uneven it is.
func _ground(cell: Vector2i) -> Array:
	var lo := INF
	var hi := -INF
	for dx: float in [0.0, 1.0]:
		for dz: float in [0.0, 1.0]:
			var x: float = (float(cell.x) + dx) * CELL
			var z: float = (float(cell.y) + dz) * CELL
			var h := Terrain.sample_height(x, z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return [lo, hi - lo]


## Place a piece. `aim` is where the player is looking/standing; the cell and
## the wall side are derived from it rather than sent by the client.
## Returns {ok, msg, key, pos}.
func build(owner: String, player_pos: Vector3, aim: Vector3, build_kind: String,
		claims: Claims) -> Dictionary:
	if not PIECE_NAMES.has(build_kind):
		return _fail("cannot build that")
	var piece: Piece = PIECE_NAMES[build_kind]

	if player_pos.distance_to(aim) > BUILD_RANGE:
		return _fail("too far to build there")
	if not claims.may_build(owner, aim):
		return _fail("that is %s's holding" % claims.owner_at(aim))

	var cid := claims.claim_at(aim)
	var origin := claims.origin_of(cid)
	var cell := cell_in(aim, origin)
	# The floor of the holding, not the lie of the land under this one cell.
	# Foundations used to sit at their own cell's terrain height, so a floor on
	# a slope came out as a staircase; the claim is a box, and its floor is
	# flat, so the platform you build on it is flat too.
	var base: float = claims.floor_of(cid)
	var level := 0
	if piece != Piece.FOUNDATION:
		# Snap to whichever level the player is standing closest to.
		level = maxi(0, int(round((player_pos.y - base) / CELL)))

	var side := nearest_side(cell, aim, origin) if piece == Piece.WALL else 0
	if pieces.has(_key(piece, cell, level, side)):
		return _fail("something is already there")

	match piece:
		Piece.FOUNDATION:
			if not Terrain.is_reachable(aim.x, aim.z):
				return _fail("cannot build on that ground")
			# The floor is flat, so what matters is not how uneven this cell is
			# but how far the ground under it strays from that floor: much
			# above and the tile is buried, much below and it hangs in the air.
			if absf(Terrain.sample_height(aim.x, aim.z) - base) > CELL:
				return _fail("the ground here is too far from your floor")
		Piece.WALL, Piece.CEILING:
			if not supported(cell, level):
				return _fail("nothing to build onto")

	var key := _key(piece, cell, level, side)
	pieces[key] = {"piece": int(piece), "cell": cell, "level": level,
		"side": side, "owner": owner, "claim": cid,
		"pos": _world_of(piece, cell, level, side, origin, base)}
	return {"ok": true, "msg": "built %s" % build_kind, "key": key,
		"pos": piece_position(pieces[key])}


## Remove a piece, refusing if something rests on it. Returns
## {ok, msg, build_kind}.
func demolish(owner: String, player_pos: Vector3, aim: Vector3,
		claims: Claims) -> Dictionary:
	if not claims.may_build(owner, aim):
		return {"ok": false, "msg": "that is %s's holding" % claims.owner_at(aim),
			"build_kind": ""}
	# Demolition measures from the same corner building does, or it would look
	# for a piece in a cell that has nothing in it.
	var cid := claims.claim_at(aim)
	var origin := claims.origin_of(cid)
	var cell := cell_in(aim, origin)
	var base: float = claims.floor_of(cid)
	var level: int = maxi(0, int(round((player_pos.y - base) / CELL)))

	# Walls first: they are what the player is most likely aiming at, and
	# removing the floor out from under one should not be the default.
	var candidates: Array = [
		[Piece.WALL, nearest_side(cell, aim, origin)],
		[Piece.CEILING, 0],
		[Piece.FOUNDATION, 0],
	]
	for c: Array in candidates:
		var piece: Piece = c[0]
		var side: int = c[1]
		if not has_piece(piece, cell, level, side):
			continue
		if piece != Piece.WALL and _carries_load(cell, level, piece):
			return {"ok": false, "msg": "something is resting on that", "build_kind": ""}
		pieces.erase(_key(piece, cell, level, side))
		return {"ok": true, "msg": "removed", "build_kind": PIECE_NAMES.find_key(piece)}
	return {"ok": false, "msg": "nothing to remove", "build_kind": ""}


## Would removing this piece leave something unsupported?
func _carries_load(cell: Vector2i, level: int, piece: Piece) -> bool:
	if piece == Piece.FOUNDATION:
		# Walls and a ceiling on the same level lean on it.
		if has_piece(Piece.CEILING, cell, level):
			return true
		for side in range(4):
			if has_piece(Piece.WALL, cell, level, side):
				return true
	if piece == Piece.CEILING:
		return supported(cell, level + 1) or _has_anything(cell, level + 1)
	return false


func _has_anything(cell: Vector2i, level: int) -> bool:
	if has_piece(Piece.CEILING, cell, level) or has_piece(Piece.FOUNDATION, cell, level):
		return true
	for side in range(4):
		if has_piece(Piece.WALL, cell, level, side):
			return true
	return false


## Where a piece sits in world space, for rendering and for range checks.
## Where a piece stands. Read off the piece rather than recomputed: cells are
## measured from the claim's corner now, and the client has no claim registry
## to measure from.
func piece_position(p: Dictionary) -> Vector3:
	return p["pos"]


static func _world_of(piece: Piece, cell: Vector2i, level: int, side: int,
		origin: Vector2, base: float) -> Vector3:
	var c := cell_centre_in(cell, origin)
	var y := base + float(level) * CELL
	if piece == Piece.WALL:
		var half := CELL * 0.5
		match side:
			0: return Vector3(c.x, y + half, c.y - half)
			1: return Vector3(c.x + half, y + half, c.y)
			2: return Vector3(c.x, y + half, c.y + half)
			_: return Vector3(c.x - half, y + half, c.y)
	if piece == Piece.CEILING:
		return Vector3(c.x, y + CELL, c.y)
	return Vector3(c.x, y, c.y)


func count() -> int:
	return pieces.size()


## Wire/disk form: [key, piece, cx, cz, level, side, owner].
func to_wire() -> Array:
	var out: Array = []
	for key: String in pieces:
		var p: Dictionary = pieces[key]
		var cell: Vector2i = p["cell"]
		var w: Vector3 = p["pos"]
		out.append([key, int(p["piece"]), cell.x, cell.y, int(p["level"]),
			int(p["side"]), str(p["owner"]), w.x, w.y, w.z, int(p["claim"])])
	return out


func from_wire(rows: Array) -> void:
	pieces.clear()
	for row: Array in rows:
		pieces[str(row[0])] = {
			"piece": int(row[1]),
			"cell": Vector2i(int(row[2]), int(row[3])),
			"level": int(row[4]), "side": int(row[5]), "owner": str(row[6]),
			"pos": Vector3(float(row[7]), float(row[8]), float(row[9])),
			"claim": int(row[10]),
		}


func _fail(msg: String) -> Dictionary:
	return {"ok": false, "msg": msg, "key": "", "pos": Vector3.ZERO}
