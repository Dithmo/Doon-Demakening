extends Node
## What the Construction Tool can put down, loaded from
## data/items/structures.json.
##
## Deliberately a separate catalogue from ItemDB rather than a flag on an item.
## Structures and items are different kinds of thing: an item is fabricated,
## carried and consumed; a structure is placed, paid for out of your bag at the
## moment you place it, and never exists as a stack. Modelling structures as
## craftable items is what put a Survival Fabricator -- a late bench built from
## refined metal -- in front of the first Sub-Fief, and made the opening of the
## game unplayable. Two catalogues means that mistake cannot be made by
## accident: adding something to the wrong file is visible in the diff.

const PATH := "res://data/items/structures.json"

var _defs: Dictionary = {}
var _order: Array = []


func _ready() -> void:
	load_defs()


func load_defs() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("StructureDB: cannot open %s" % PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("structures"):
		push_error("StructureDB: malformed %s" % PATH)
		return false

	_defs.clear()
	_order.clear()
	for raw: Variant in parsed["structures"]:
		var d: Dictionary = raw
		var id := str(d["id"])
		if _defs.has(id):
			push_error("StructureDB: duplicate structure id '%s'" % id)
			return false
		# Pass every key through and normalise only the typed ones, the same
		# way ItemDB does -- whitelisting fields there dropped new properties
		# silently twice, and the failure surfaced a long way from the cause.
		var def: Dictionary = d.duplicate(true)
		def["id"] = id
		def["name"] = str(d.get("name", id))
		def["kind"] = str(d.get("kind", "station"))
		def["category"] = str(d.get("category", "Structure"))
		def["needs_foundation"] = bool(d.get("needs_foundation", true))
		def["open_ground"] = bool(d.get("open_ground", false))
		def["claim_radius"] = float(d.get("claim_radius", 0.0))
		def["cost"] = d.get("cost", [])
		_defs[id] = def
		_order.append(id)
	return true


func has(id: String) -> bool:
	return _defs.has(id)


func get_def(id: String) -> Dictionary:
	return _defs.get(id, {})


func display_name(id: String) -> String:
	return str(_defs[id].get("name", id)) if _defs.has(id) else id


## Every structure id, in the order the data file lists them.
func ids() -> Array:
	return _order.duplicate()


## The palette's tabs, in first-seen order, so reordering the data reorders the
## interface and nothing else has to be told.
func categories() -> Array:
	var out: Array = []
	for id: String in _order:
		var c := str(_defs[id]["category"])
		if not out.has(c):
			out.append(c)
	return out


func in_category(category: String) -> Array:
	var out: Array = []
	for id: String in _order:
		if str(_defs[id]["category"]) == category:
			out.append(id)
	return out


## Can `inv` pay for `id` right now? Returns {ok, msg}, where the message names
## the first thing you are short of rather than saying "not enough materials" --
## a refusal that does not say what is missing costs the player a trip.
func affordable(id: String, inv: Inventory) -> Dictionary:
	if not _defs.has(id):
		return {"ok": false, "msg": "there is no such structure"}
	for raw: Variant in _defs[id]["cost"]:
		var need: Dictionary = raw
		var want := int(need["count"])
		var have := inv.count_of(str(need["id"]))
		if have < want:
			return {"ok": false, "msg": "need %s x%d (you have %d)"
				% [ItemDB.display_name(str(need["id"])), want, have]}
	return {"ok": true, "msg": ""}


## Take the price out of `inv`. Only ever called after `affordable` has passed
## on the server, which is the only place either is called.
func charge(id: String, inv: Inventory) -> void:
	for raw: Variant in _defs[id]["cost"]:
		var need: Dictionary = raw
		inv.remove(str(need["id"]), int(need["count"]))


## "Granite Stone x12, Salvaged Metal x2", for the palette row.
func cost_line(id: String) -> String:
	var parts: Array = []
	for raw: Variant in _defs.get(id, {}).get("cost", []):
		var need: Dictionary = raw
		parts.append("%s x%d" % [ItemDB.display_name(str(need["id"])),
			int(need["count"])])
	return ", ".join(parts)
