extends Node
## Crafting recipes, loaded from data/items/recipes.json.
##
## A recipe names the station it needs; the server checks the player is stood
## near one before consuming anything. Recipes are data so that Phase 3's
## buildables and Phase 6's progression gates can add to the table without
## touching crafting code.

const PATH := "res://data/items/recipes.json"

var _recipes: Dictionary = {}


func _ready() -> void:
	load_recipes()


func load_recipes() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("RecipeDB: cannot open %s" % PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("recipes"):
		push_error("RecipeDB: malformed %s" % PATH)
		return false

	_recipes.clear()
	for raw: Variant in parsed["recipes"]:
		var d: Dictionary = raw
		var id := str(d["id"])
		var out: Dictionary = d["output"]
		# A recipe naming an item that does not exist would fail silently at
		# craft time, so refuse to load it at all.
		if not ItemDB.has(str(out["id"])):
			push_error("RecipeDB: recipe '%s' outputs unknown item '%s'" % [id, out["id"]])
			return false
		var inputs: Array = []
		for raw_in: Variant in d["inputs"]:
			var i: Dictionary = raw_in
			if not ItemDB.has(str(i["id"])):
				push_error("RecipeDB: recipe '%s' needs unknown item '%s'" % [id, i["id"]])
				return false
			inputs.append({"id": str(i["id"]), "count": int(i["count"])})
		_recipes[id] = {
			"id": id,
			"name": str(d.get("name", id)),
			"station": str(d.get("station", "")),
			"output": {"id": str(out["id"]), "count": int(out.get("count", 1))},
			"inputs": inputs,
		}
	print("[recipes] loaded %d" % _recipes.size())
	return true


func has(id: String) -> bool:
	return _recipes.has(id)


func get_recipe(id: String) -> Dictionary:
	return _recipes.get(id, {})


func ids() -> Array:
	return _recipes.keys()


## Recipes a given station can make.
func for_station(station: String) -> Array:
	var out: Array = []
	for id: String in _recipes:
		if _recipes[id]["station"] == station:
			out.append(id)
	return out


## Human-readable input list, for the HUD and for refusal messages.
func describe_inputs(id: String) -> String:
	var r := get_recipe(id)
	if r.is_empty():
		return ""
	var parts: Array = []
	for i: Dictionary in r["inputs"]:
		parts.append("%s x%d" % [ItemDB.display_name(i["id"]), i["count"]])
	return ", ".join(parts)
