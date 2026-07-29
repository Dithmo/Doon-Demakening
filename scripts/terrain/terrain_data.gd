extends Node
## Terrain sampling. The single source of ground truth for both client and server.
##
## Phase 0 loads a synthetic region; Phase 5 swaps in real Hagga Basin data
## produced by tools/ (see docs/terrain-plan.md). Nothing that consumes this
## interface should care which it got, so keep the API free of both.
##
## World space: +x east, +z south, y up. Region origin is its north-west corner
## at (0, 0), matching the wiki CRS which also runs y southward.

enum Surface { SAND = 0, ROCK = 1, CLIFF = 2 }

## Hagga Basin South, recovered from the community wiki's map render by
## tools/build_region.py. The synthetic regions are still there and still
## build -- the phase harnesses pin themselves to one so their tuned numbers
## keep meaning what they meant -- but the game's world is the real place now.
const DEFAULT_REGION := "res://data/regions/hagga_basin_south"

var loaded: bool = false
var region_name: String = ""
## Where the region was loaded from. Pois reads its own file out of the same
## directory, because POIs are region data and travel with it.
var region_dir: String = ""
## Content hash of the region files. Client and server must agree on this or
## prediction silently diverges -- Net refuses mismatched clients.
var fingerprint: String = ""
var size_m: Vector2 = Vector2.ZERO

var _cell: float = 1.0
var _hx: int = 0
var _hz: int = 0
var _height_scale: float = 1.0
var _heights: PackedFloat32Array = PackedFloat32Array()

var _mask_cell: float = 1.0
var _mx: int = 0
var _mz: int = 0
var _mask: PackedByteArray = PackedByteArray()
## Walkable cells connected to the region centre. A rock plateau ringed by
## cliff is walkable but unreachable: anything spawned on one is invisible to
## players, and come Phase 4 it is refuge nobody can run to. Computed once on
## load so placement can simply ask.
var _reachable: PackedByteArray = PackedByteArray()
var reachable_fraction: float = 0.0


## Region used when the real one has not been built yet. Small, seeded, and
## checked in, so the game always has *something* to stand on.
const FALLBACK_REGION := "res://data/regions/synthetic_test"


func _ready() -> void:
	if loaded:
		return
	var wanted := Args.value("--region", DEFAULT_REGION)
	if load_region(wanted):
		return
	# The real region's height and mask are derived artefacts and the repo does
	# not carry them -- same rule as the wiki render itself. A fresh clone would
	# otherwise refuse to start, so fall back and say exactly how to fix it,
	# rather than failing with a missing-file error about a path nobody chose.
	if wanted == DEFAULT_REGION:
		push_warning("Terrain: %s is not built yet -- falling back to %s.\n"
			% [wanted, FALLBACK_REGION]
			+ "  Build it with:  python3 -m pip install -r tools/requirements.txt\n"
			+ "                  python3 tools/fetch_map_data.py\n"
			+ "                  python3 tools/build_region.py")
		load_region(FALLBACK_REGION)


func load_region(dir_path: String) -> bool:
	var meta_text := _read_text(dir_path.path_join("region.json"))
	if meta_text.is_empty():
		return false

	var meta: Variant = JSON.parse_string(meta_text)
	if typeof(meta) != TYPE_DICTIONARY:
		push_error("Terrain: malformed region.json at %s" % dir_path)
		return false

	region_name = str(meta.get("name", "unnamed"))
	_cell = float(meta["cell_size"])
	_hx = int(meta["height_cells"][0])
	_hz = int(meta["height_cells"][1])
	_height_scale = float(meta["height_scale"])
	_mask_cell = float(meta["mask_cell_size"])
	_mx = int(meta["mask_cells"][0])
	_mz = int(meta["mask_cells"][1])
	size_m = Vector2(float(meta["size_m"][0]), float(meta["size_m"][1]))

	var raw_h := _read_bytes(dir_path.path_join("height.r16"))
	var raw_m := _read_bytes(dir_path.path_join("mask.u8"))
	# Distinguish "not built" from "built wrong". They call for opposite
	# reactions -- run the pipeline, or go and find out what it produced -- and
	# reporting a missing file as "0 bytes, expected 3510000" sends you looking
	# for corruption that is not there.
	if not _has_file(dir_path, "height.r16") or not _has_file(dir_path, "mask.u8"):
		return false
	if raw_h.size() != _hx * _hz * 2:
		push_error("Terrain: height.r16 is %d bytes, expected %d" % [raw_h.size(), _hx * _hz * 2])
		return false
	if raw_m.size() != _mx * _mz:
		push_error("Terrain: mask.u8 is %d bytes, expected %d" % [raw_m.size(), _mx * _mz])
		return false

	# Decode uint16 -> metres once, so sampling stays cheap in the movement loop.
	var decoded := PackedFloat32Array()
	decoded.resize(_hx * _hz)
	var scale := _height_scale / 65535.0
	for i in range(_hx * _hz):
		decoded[i] = float(raw_h.decode_u16(i * 2)) * scale
	_heights = decoded
	_mask = raw_m

	_build_reachability()
	# POIs go into the fingerprint alongside the terrain. They decide where
	# shelter and camps are, so a client holding a different set disagrees with
	# the server about the world in a way that has to be refused at the
	# handshake, not discovered when the worm takes someone standing in a cave.
	fingerprint = _hash(meta_text, raw_h, raw_m, _read_bytes(dir_path.path_join("pois.json")))
	region_dir = dir_path
	loaded = true
	print("[terrain] %s  %.0fx%.0f m  height %dx%d @ %.1f m  mask %dx%d @ %.1f m  reach %.0f%%  fp=%s"
		% [region_name, size_m.x, size_m.y, _hx, _hz, _cell, _mx, _mz, _mask_cell,
		reachable_fraction * 100.0, fingerprint])
	return true


## Ground height in metres. Bilinear, so movement doesn't stair-step.
func sample_height(x: float, z: float) -> float:
	if not loaded:
		return 0.0
	var fx: float = clampf(x / _cell, 0.0, float(_hx - 1))
	var fz: float = clampf(z / _cell, 0.0, float(_hz - 1))
	var ix := int(fx)
	var iz := int(fz)
	var jx: int = mini(ix + 1, _hx - 1)
	var jz: int = mini(iz + 1, _hz - 1)
	var tx := fx - float(ix)
	var tz := fz - float(iz)
	var h00 := _heights[iz * _hx + ix]
	var h10 := _heights[iz * _hx + jx]
	var h01 := _heights[jz * _hx + ix]
	var h11 := _heights[jz * _hx + jx]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Surface class. Nearest-neighbour on purpose: this is a hard gameplay
## boundary (worm-safe vs exposed) and must not be smeared by interpolation.
func sample_surface(x: float, z: float) -> Surface:
	if not loaded:
		return Surface.SAND
	var ix: int = clampi(int(x / _mask_cell), 0, _mx - 1)
	var iz: int = clampi(int(z / _mask_cell), 0, _mz - 1)
	return _mask[iz * _mx + ix] as Surface


## Flood-fill the walkable cells connected to the middle of the region.
## One pass at load; the result is what placement and spawning consult.
func _build_reachability() -> void:
	_reachable = PackedByteArray()
	_reachable.resize(_mx * _mz)
	var start := _nearest_open(_mx / 2, _mz / 2)
	if start < 0:
		push_warning("Terrain: no walkable cell near the centre")
		reachable_fraction = 0.0
		return

	var stack: PackedInt32Array = PackedInt32Array([start])
	_reachable[start] = 1
	var count := 0
	while not stack.is_empty():
		var i := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		count += 1
		var x := i % _mx
		var z := i / _mx
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx := x + d.x
			var nz := z + d.y
			if nx < 0 or nz < 0 or nx >= _mx or nz >= _mz:
				continue
			var j := nz * _mx + nx
			if _reachable[j] == 1 or _mask[j] == Surface.CLIFF:
				continue
			_reachable[j] = 1
			stack.append(j)
	reachable_fraction = float(count) / float(_mx * _mz)


func _nearest_open(cx: int, cz: int) -> int:
	for r in range(0, maxi(_mx, _mz) / 2):
		var offsets: PackedInt32Array = PackedInt32Array([0]) if r == 0 \
			else PackedInt32Array([-r, r])
		for dz in range(-r, r + 1):
			for dx: int in offsets:
				var x: int = cx + dx
				var z: int = cz + dz
				if x < 0 or z < 0 or x >= _mx or z >= _mz:
					continue
				var i: int = z * _mx + x
				if _mask[i] != Surface.CLIFF:
					return i
	return -1


## Walkable *and* connected to the rest of the map. Prefer this over
## is_walkable() for anything being placed into the world.
func is_reachable(x: float, z: float) -> bool:
	if not loaded or _reachable.is_empty():
		return false
	if x < 0.0 or z < 0.0 or x > size_m.x or z > size_m.y:
		return false
	var ix: int = clampi(int(x / _mask_cell), 0, _mx - 1)
	var iz: int = clampi(int(z / _mask_cell), 0, _mz - 1)
	return _reachable[iz * _mx + ix] == 1


## True when terrain blocks the line to the sun from head height here.
##
## Marched against the heightmap rather than approximated from the surface
## class, because shade has to move as the sun does -- the west face of an
## outcrop is shelter in the morning and an oven in the afternoon. That
## time-dependence is what makes shade a thing you route around rather than a
## property of a tile.
##
## Cost is bounded by MAX_SHADE_STEPS regardless of sun angle; a very low sun
## casts shadows longer than we march, so this under-reports shade near dawn
## and dusk. Acceptable: exposure is near zero then anyway.
const MAX_SHADE_STEPS := 48
const SHADE_STEP_M := 2.5
const EYE_HEIGHT := 1.7

func is_shaded(x: float, z: float, sun: Vector3) -> bool:
	if not loaded or sun.y <= 0.02:
		return true  # sun on or below the horizon
	var base := sample_height(x, z) + EYE_HEIGHT
	for i in range(1, MAX_SHADE_STEPS + 1):
		var d := float(i) * SHADE_STEP_M
		var px := x + sun.x * d
		var pz := z + sun.z * d
		if px < 0.0 or pz < 0.0 or px > size_m.x or pz > size_m.y:
			return false
		if sample_height(px, pz) > base + sun.y * d:
			return true
	return false


func is_walkable(x: float, z: float) -> bool:
	if x < 0.0 or z < 0.0 or x > size_m.x or z > size_m.y:
		return false
	return sample_surface(x, z) != Surface.CLIFF


func surface_name(s: Surface) -> String:
	match s:
		Surface.SAND: return "SAND"
		Surface.ROCK: return "ROCK"
		Surface.CLIFF: return "CLIFF"
	return "?"


func _read_text(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _has_file(dir_path: String, name: String) -> bool:
	return FileAccess.file_exists(dir_path.path_join(name))


func _read_bytes(p: String) -> PackedByteArray:
	var f := FileAccess.open(p, FileAccess.READ)
	return PackedByteArray() if f == null else f.get_buffer(f.get_length())


func _hash(meta: String, h: PackedByteArray, m: PackedByteArray,
		p: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(meta.to_utf8_buffer())
	ctx.update(h)
	ctx.update(m)
	if not p.is_empty():
		ctx.update(p)
	return ctx.finish().hex_encode().substr(0, 12)
