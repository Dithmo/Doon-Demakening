extends Node
## Item definitions, loaded from data/items/items.json.
##
## JSON rather than .tres on purpose: item data is generated and diffed by
## tooling as much as it is hand-edited, and the pipeline in tools/ already
## speaks JSON. The tradeoff is losing the inspector for item authoring.
##
## Everything downstream -- crafting, building, loot, vendors, equipment --
## resolves to the string ids in here. Under server authority a late change to
## this schema means migrating persisted inventories too, so it is worth being
## generous with fields early.

const PATH := "res://data/items/items.json"

## Equipment slots. Mirrors the real game's garment slots; UTILITY covers
## tools like the cutteray and dew harvester that are held rather than worn.
enum Slot { NONE, HEAD, TORSO, HANDS, LEGS, FEET, UTILITY }

const SLOT_NAMES := {
	"none": Slot.NONE, "head": Slot.HEAD, "torso": Slot.TORSO,
	"hands": Slot.HANDS, "legs": Slot.LEGS, "feet": Slot.FEET,
	"utility": Slot.UTILITY,
}

var _defs: Dictionary = {}


func _ready() -> void:
	load_defs()


func load_defs() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("ItemDB: cannot open %s" % PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("items"):
		push_error("ItemDB: malformed %s" % PATH)
		return false

	_defs.clear()
	for raw: Variant in parsed["items"]:
		var d: Dictionary = raw
		var id := str(d["id"])
		if _defs.has(id):
			push_error("ItemDB: duplicate item id '%s'" % id)
			return false
		# Carry every key through, then normalise the ones with a fixed type.
		# Whitelisting fields here has silently dropped new properties twice
		# (`station` in Phase 2, the whole power/container set in Phase 3), and
		# a dropped field fails as "this item does nothing" a long way from the
		# cause. Pass-through means adding an item property is a data change.
		var def: Dictionary = d.duplicate(true)
		def["id"] = id
		def["name"] = str(d.get("name", id))
		def["stack"] = int(d.get("stack", 1))
		def["slot"] = SLOT_NAMES.get(str(d.get("slot", "none")), Slot.NONE)
		def["weight"] = float(d.get("weight", 0.0))
		# Behaviour hook: dispatched on rather than the item id, so new
		# consumables need no code change.
		def["use"] = str(d.get("use", ""))
		def["use_value"] = float(d.get("use_value", 0.0))
		# Deployables name the station kind they become when placed.
		def["station"] = str(d.get("station", ""))
		def["desc"] = str(d.get("desc", ""))
		_defs[id] = def
	print("[items] loaded %d definitions" % _defs.size())
	return true


func has(id: String) -> bool:
	return _defs.has(id)


func get_def(id: String) -> Dictionary:
	return _defs.get(id, {})


func display_name(id: String) -> String:
	return str(_defs.get(id, {}).get("name", id))


func stack_size(id: String) -> int:
	return int(_defs.get(id, {}).get("stack", 1))


func ids() -> Array:
	return _defs.keys()
