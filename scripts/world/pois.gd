extends Node
## Points of interest, projected from the community wiki's marker data.
##
## Built by tools/build_region.py alongside the heightmap and mask, so a POI's
## position is in the same world space as the ground under it: +x east, +z
## south, origin at the region's north-west corner.
##
## These are what stops the region being scenery. A cave is where the worm
## cannot reach you, a camp is where the fighting is, a wreck is why you walked
## out this far -- the terrain is only the shape of the argument between them.
##
## Server and client both load this. It is hashed into Terrain.fingerprint, so
## a client with different POIs is refused at the handshake rather than
## disagreeing silently about where shelter is.

const FILE := "pois.json"

## How close counts as being *at* a cave mouth. Caves are drawn as a single
## marker rather than a volume, so this is the whole of their footprint -- big
## enough to run into under pressure, small enough that it has to be aimed for.
const SHELTER_RADIUS := 14.0

var loaded: bool = false
var all: Array = []

var _by_role: Dictionary = {}
## Cave positions kept flat and separate: shelter_at() runs per player per
## threat tick, and it should not walk a dictionary of dictionaries to do it.
var _shelters: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	if not loaded:
		load_from(Terrain.region_dir)


func load_from(dir_path: String) -> bool:
	all.clear()
	_by_role.clear()
	_shelters = PackedVector2Array()
	loaded = false

	var f := FileAccess.open(dir_path.path_join(FILE), FileAccess.READ)
	if f == null:
		# Synthetic regions have no POIs and are not expected to. Everything
		# here degrades to "no POIs of that role", which the callers handle.
		print("[pois] none for %s" % dir_path)
		loaded = true
		return true

	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		push_error("Pois: malformed %s" % FILE)
		return false

	for raw: Variant in parsed:
		var d: Dictionary = raw
		var role := str(d.get("role", "landmark"))
		var poi := {
			"role": role,
			"group": str(d.get("group", "")),
			"name": str(d.get("name", "")),
			"x": float(d.get("x", 0.0)),
			"z": float(d.get("z", 0.0)),
		}
		all.append(poi)
		if not _by_role.has(role):
			_by_role[role] = []
		(_by_role[role] as Array).append(poi)
		if role == "shelter":
			_shelters.append(Vector2(poi["x"], poi["z"]))

	loaded = true
	var summary: PackedStringArray = PackedStringArray()
	for role: String in _by_role:
		summary.append("%s %d" % [role, (_by_role[role] as Array).size()])
	summary.sort()
	print("[pois] %d marker(s): %s" % [all.size(), ", ".join(summary)])
	return true


func of_role(role: String) -> Array:
	return _by_role.get(role, [])


func count() -> int:
	return all.size()


## Ground positions for a role, with the terrain height already sampled.
func positions(role: String) -> Array:
	var out: Array = []
	for p: Dictionary in of_role(role):
		var x := float(p["x"])
		var z := float(p["z"])
		out.append(Vector3(x, Terrain.sample_height(x, z), z))
	return out


## Nearest POI of a role, or an empty dictionary. Distance is horizontal --
## comparing in 3D would rank a marker on a mesa top as further away than it
## walks, and every caller here is asking a navigation question.
func nearest(role: String, x: float, z: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for p: Dictionary in of_role(role):
		var d := Vector2(float(p["x"]) - x, float(p["z"]) - z).length_squared()
		if d < best_d:
			best_d = d
			best = p
	return best


## Case-insensitive lookup by marker name. Wiki names are what a player would
## say out loud, so this is the handle tests and commands use.
func find_named(wanted: String) -> Dictionary:
	var needle := wanted.strip_edges().to_lower()
	for p: Dictionary in all:
		if str(p["name"]).to_lower() == needle:
			return p
	return {}


## True inside a cave mouth. The worm treats this exactly as it treats rock:
## caves are the mask's escape hatches out in the open sand, and without them a
## dune field a kilometre across has no answer in it at all.
func shelter_at(x: float, z: float, radius_mult: float = 1.0) -> bool:
	var r := SHELTER_RADIUS * radius_mult
	var r2 := r * r
	for s: Vector2 in _shelters:
		if Vector2(s.x - x, s.y - z).length_squared() <= r2:
			return true
	return false
