class_name TerrainView
extends Node3D
## The visible ground, built in tiles around the player.
##
## Phase 0 built the whole region as one mesh in one pass, which was fine for a
## 512 m test map: 65k quads. Phase 5 made the world 4500 x 1560 m, and the same
## code became 1.76 *million* quads and ~17 million terrain samples in a single
## GDScript loop. A windowed client on the real map never finished loading -- it
## ran for over four minutes without drawing a frame. Every automated test passed
## throughout, because all of them are headless and none of them build a mesh.
##
## So: tiles, built a couple per frame within a view radius, dropped when they
## fall well outside it. The fog is tuned to the same radius so the world fades
## out rather than ending at a visible edge.

## Tile edge in metres, and the mesh resolution inside one. 96 / 2 gives 48x48
## quads per tile -- small enough that building one is imperceptible, large
## enough that a full view is a few dozen draw calls rather than hundreds.
const TILE_M := 96.0
const STEP := 2.0

## How far the ground is drawn, and how far a tile survives before being freed.
## The gap between them is hysteresis: without it, a player walking back and
## forth across a boundary rebuilds the same tile forever.
const VIEW_M := 420.0
const DROP_M := 560.0

## Tiles built per frame. The point of the budget is that arriving somewhere new
## costs a few frames of horizon rather than one long stall.
const BUDGET_PER_FRAME := 2

var _tiles: Dictionary = {}      ## Vector2i -> MeshInstance3D
var _material: StandardMaterial3D
var _cols: int = 0
var _rows: int = 0
var _pending: Array[Vector2i] = []
var _last_centre := Vector2i(-9999, -9999)


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.95
	_cols = int(ceil(Terrain.size_m.x / TILE_M))
	_rows = int(ceil(Terrain.size_m.y / TILE_M))
	print("[view] terrain in %dx%d tiles of %.0f m, drawn to %.0f m"
		% [_cols, _rows, TILE_M, VIEW_M])


## Call once per frame with the player's position.
func update_around(pos: Vector3) -> void:
	var centre := Vector2i(int(pos.x / TILE_M), int(pos.z / TILE_M))
	if centre != _last_centre:
		_last_centre = centre
		_requeue(pos)
	_drop_far(pos)

	var built := 0
	while built < BUDGET_PER_FRAME and not _pending.is_empty():
		var t: Vector2i = _pending.pop_front()
		if _tiles.has(t):
			continue
		_tiles[t] = _build_tile(t)
		built += 1


## Rebuild the work list, nearest first, so the ground under the player appears
## before the horizon does.
func _requeue(pos: Vector3) -> void:
	_pending.clear()
	var reach := int(ceil(VIEW_M / TILE_M))
	var here := Vector2i(int(pos.x / TILE_M), int(pos.z / TILE_M))
	var wanted: Array[Vector2i] = []
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var t := Vector2i(here.x + dx, here.y + dz)
			if t.x < 0 or t.y < 0 or t.x >= _cols or t.y >= _rows:
				continue
			if _tiles.has(t):
				continue
			if _centre_of(t).distance_to(Vector2(pos.x, pos.z)) > VIEW_M:
				continue
			wanted.append(t)
	var origin := Vector2(pos.x, pos.z)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _centre_of(a).distance_squared_to(origin) \
			< _centre_of(b).distance_squared_to(origin))
	_pending = wanted


func _drop_far(pos: Vector3) -> void:
	var origin := Vector2(pos.x, pos.z)
	for t: Vector2i in _tiles.keys():
		if _centre_of(t).distance_to(origin) > DROP_M:
			(_tiles[t] as Node).queue_free()
			_tiles.erase(t)


func _centre_of(t: Vector2i) -> Vector2:
	return Vector2((float(t.x) + 0.5) * TILE_M, (float(t.y) + 0.5) * TILE_M)


func _build_tile(t: Vector2i) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x0 := float(t.x) * TILE_M
	var z0 := float(t.y) * TILE_M
	var n := int(TILE_M / STEP)

	for jz in range(n):
		for ix in range(n):
			var ax := x0 + float(ix) * STEP
			var az := z0 + float(jz) * STEP
			var bx := ax + STEP
			var bz := az + STEP
			if ax > Terrain.size_m.x or az > Terrain.size_m.y:
				continue
			# Four corners sampled once each and reused by both triangles. The
			# original sampled per emitted vertex -- six heights and six surface
			# lookups per quad instead of four and four.
			var c := [
				Vector3(ax, Terrain.sample_height(ax, az), az),
				Vector3(bx, Terrain.sample_height(bx, az), az),
				Vector3(bx, Terrain.sample_height(bx, bz), bz),
				Vector3(ax, Terrain.sample_height(ax, bz), bz),
			]
			# How steep this quad is, from the spread across its own corners.
			# One number for the quad rather than a gradient per vertex: it is
			# the difference between a dune face and a flat, which is all the
			# eye needs to read the shape of the ground.
			var lo: float = minf(minf(c[0].y, c[1].y), minf(c[2].y, c[3].y))
			var hi: float = maxf(maxf(c[0].y, c[1].y), maxf(c[2].y, c[3].y))
			var slope := clampf((hi - lo) / STEP, 0.0, 1.0)
			var col := [
				_shade(Terrain.sample_surface(ax, az), c[0], slope),
				_shade(Terrain.sample_surface(bx, az), c[1], slope),
				_shade(Terrain.sample_surface(bx, bz), c[2], slope),
				_shade(Terrain.sample_surface(ax, bz), c[3], slope),
			]
			for tri: Array in [[0, 2, 1], [0, 3, 2]]:
				for k: int in tri:
					st.set_color(col[k])
					st.add_vertex(c[k])
	st.generate_normals()

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _material
	add_child(mi)
	return mi


## The colour of one vertex: its surface, then modulated by how the ground lies.
##
## Flat sand under a single directional light comes out one uniform tone, and
## with a tan sky behind it there is no horizon and no shape -- a player
## standing on open desert reported the floor as missing, and they were right
## that nothing was visible even though everything was drawn. Three cheap terms
## fix it, all computed once when a tile is built:
##
##   slope   dune faces darken, so a crest reads against the flat below it
##   height  crests pale off, the way wind-scoured sand actually does
##   ripple  a fine standing pattern, so a dead-level flat still has texture
##
## The ripple is deterministic in world space, not random: two tiles meeting at
## an edge have to agree, or the seam shows as a stripe.
func _shade(surface: int, at: Vector3, slope: float) -> Color:
	var base := _surface_color(surface)
	if surface != Terrain.Surface.SAND:
		# Rock and cliff already have shape of their own; only steepness.
		return base.darkened(slope * 0.25)

	var c := base.darkened(slope * 0.30)
	c = c.lightened(clampf(at.y / 120.0, 0.0, 1.0) * 0.16)
	# Sand ripples at roughly 8 m, with a broader 70 m drift over the top so the
	# flats are patchy rather than corduroy. Both wavelengths are well above the
	# 2 m vertex spacing, or the pattern aliases into noise. Two incommensurate
	# terms, so it does not visibly repeat.
	#
	# The amplitude is deliberately generous. A first pass at 0.05 was
	# technically correct and completely invisible, which is the same as not
	# having done it -- on a dead-flat pan there is no slope term and no height
	# term, so this is the only thing standing between the player and a blank
	# wall of beige.
	var ripple := sin(at.x * 0.78 + sin(at.z * 0.19) * 1.4) * 0.6 \
		+ sin(at.x * 0.089 + at.z * 0.067) * 0.4
	return c.lightened(clampf(ripple, 0.0, 1.0) * 0.13) \
		.darkened(clampf(-ripple, 0.0, 1.0) * 0.13)


func _surface_color(s: int) -> Color:
	match s:
		Terrain.Surface.ROCK: return Color(0.42, 0.33, 0.26)
		Terrain.Surface.CLIFF: return Color(0.25, 0.19, 0.16)
	return Color(0.76, 0.63, 0.44)


## Diagnostics for the harness: how much ground is currently drawn.
func stats() -> Dictionary:
	return {"tiles": _tiles.size(), "pending": _pending.size(),
		"total": _cols * _rows}
