class_name CoarsePath
extends RefCounted
## Coarse navigation over the traversability mask.
##
## Bot test infrastructure, not game AI. Phase 5's pilgrim walks in a straight
## line on purpose -- the point of that test is that the region is crossable,
## and a pathfinder would hide exactly the failure worth knowing about. Phase 6
## has the opposite problem: the journeyman has to *reach specific things*, and
## a bot that walls itself against an outcrop 200 m short of the agave it needs
## reports "progression is broken" when the truth is "the bot stopped walking".
##
## So: a flow field, not a path. BFS out from the goal over a coarse grid, then
## every step is "move to the neighbour closest to the goal". That costs one
## search per destination rather than one per tick, survives the bot being
## shoved off its route, and needs no path to be stored or invalidated.

## Grid pitch in metres. Coarse enough that a whole region is a few tens of
## thousands of cells, fine enough to thread the gaps between outcrops -- the
## rock aprons are tens of metres across, so anything much larger closes
## passages that are really open.
const CELL := 12.0

var _cols: int = 0
var _rows: int = 0
var _walkable: PackedByteArray = PackedByteArray()
## BFS distance from the current goal, in cells. -1 is unreached.
var _dist: PackedInt32Array = PackedInt32Array()
var _goal_cell: int = -1


func _ready_grid() -> void:
	if _cols > 0:
		return
	_cols = maxi(1, int(Terrain.size_m.x / CELL))
	_rows = maxi(1, int(Terrain.size_m.y / CELL))
	_walkable.resize(_cols * _rows)
	for r in range(_rows):
		for c in range(_cols):
			var x := (float(c) + 0.5) * CELL
			var z := (float(r) + 0.5) * CELL
			# Reachable, not merely walkable: routing a bot onto a cliff-ringed
			# plateau it can see but cannot enter is the same bug in a hat.
			_walkable[r * _cols + c] = 1 if Terrain.is_reachable(x, z) else 0


func _cell_of(x: float, z: float) -> int:
	_ready_grid()
	var c: int = clampi(int(x / CELL), 0, _cols - 1)
	var r: int = clampi(int(z / CELL), 0, _rows - 1)
	return r * _cols + c


func _centre(cell: int) -> Vector3:
	var c := cell % _cols
	var r := cell / _cols
	var x := (float(c) + 0.5) * CELL
	var z := (float(r) + 0.5) * CELL
	return Vector3(x, Terrain.sample_height(x, z), z)


## Recompute the flow field if the goal has moved to a different cell. Cheap to
## call every tick; the BFS only runs when the destination actually changes.
func retarget(goal: Vector3) -> void:
	_ready_grid()
	var g := _nearest_walkable(_cell_of(goal.x, goal.z))
	if g == _goal_cell:
		return
	_goal_cell = g
	_dist = PackedInt32Array()
	_dist.resize(_cols * _rows)
	_dist.fill(-1)
	if g < 0:
		return
	_dist[g] = 0
	var queue: PackedInt32Array = PackedInt32Array([g])
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var ci := i % _cols
		var ri := i / _cols
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
				Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1),
				Vector2i(-1, 1), Vector2i(-1, -1)]:
			var nc := ci + d.x
			var nr := ri + d.y
			if nc < 0 or nr < 0 or nc >= _cols or nr >= _rows:
				continue
			var j := nr * _cols + nc
			if _dist[j] >= 0 or _walkable[j] == 0:
				continue
			_dist[j] = _dist[i] + 1
			queue.append(j)


## Where to head from `from`, given the current flow field. Returns the goal
## itself once adjacent, and ZERO when there is no route at all -- an honest
## "cannot get there" rather than a direction that walks into a wall forever.
func step_from(from: Vector3, goal: Vector3) -> Vector3:
	retarget(goal)
	if _goal_cell < 0:
		return Vector3.ZERO
	var here := _cell_of(from.x, from.z)
	if _dist[here] <= 1:
		return goal
	# Downhill on the distance field. Ties do not matter: any neighbour closer
	# to the goal is progress.
	var best := -1
	var best_d := _dist[here]
	var ci := here % _cols
	var ri := here / _cols
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
			Vector2i(0, -1), Vector2i(1, 1), Vector2i(1, -1),
			Vector2i(-1, 1), Vector2i(-1, -1)]:
		var nc := ci + d.x
		var nr := ri + d.y
		if nc < 0 or nr < 0 or nc >= _cols or nr >= _rows:
			continue
		var j := nr * _cols + nc
		if _dist[j] < 0:
			continue
		if best_d < 0 or _dist[j] < best_d:
			best_d = _dist[j]
			best = j
	if best < 0:
		# Standing somewhere the field never reached. Aim straight at the goal
		# and let the caller's stall handling deal with it.
		return goal
	return _centre(best)


## Nearest walkable cell to `cell`, searched outward. A wiki marker or a node
## can sit a few metres inside rock, and refusing to route to it at all would
## be worse than routing to its doorstep.
func _nearest_walkable(cell: int) -> int:
	if cell >= 0 and _walkable[cell] == 1:
		return cell
	var ci := cell % _cols
	var ri := cell / _cols
	for radius in range(1, 12):
		for dr in range(-radius, radius + 1):
			for dc in range(-radius, radius + 1):
				if absi(dr) != radius and absi(dc) != radius:
					continue
				var nc := ci + dc
				var nr := ri + dr
				if nc < 0 or nr < 0 or nc >= _cols or nr >= _rows:
					continue
				var j := nr * _cols + nc
				if _walkable[j] == 1:
					return j
	return -1
