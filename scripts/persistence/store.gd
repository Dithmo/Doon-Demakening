extends Node
## Server-side persistence. Built structures and containers must outlive the
## session that made them, so state is keyed by a stable player identity rather
## than by peer id (which is reassigned every connection).
##
## Phase 0 has no authentication -- identity is whatever the client claims.
## That is fine for a local session and deliberately isolated here, so adding
## real auth later touches this file and Net's handshake, nothing else.

const SAVE_PATH := "user://world_save.json"
const AUTOSAVE_SECONDS := 30.0
const SAVE_VERSION := 2

var _data: Dictionary = {"version": SAVE_VERSION, "players": {}, "entities": [], "blobs": {}}
var _dirty: bool = false
var _timer: float = 0.0


func _ready() -> void:
	# Clients never persist world state; only the authority does.
	if not Net.is_server():
		set_process(false)
		return
	load_all()


func _process(delta: float) -> void:
	if not _dirty:
		return
	_timer += delta
	if _timer >= AUTOSAVE_SECONDS:
		save_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if Net.is_server() and _dirty:
			save_all()


func mark_dirty() -> void:
	_dirty = true


## Snapshot for one player. Returns {} for someone never seen before.
func player_state(who: String) -> Dictionary:
	return (_data["players"] as Dictionary).get(who, {})


func put_player(who: String, pos: Vector3, inventory: Array,
		vitals: Dictionary = {}, equipped: Dictionary = {}) -> void:
	(_data["players"] as Dictionary)[who] = {
		"pos": [pos.x, pos.y, pos.z],
		"inventory": inventory,
		"vitals": vitals,
		# JSON object keys are strings; Vitals/World cast them back to the slot
		# enum on load.
		"equipped": equipped,
	}
	_dirty = true


func put_entities(entities: Array) -> void:
	_data["entities"] = entities
	_dirty = true


func entities() -> Array:
	return _data.get("entities", [])


## Generic named world state, so a new subsystem does not need a new save
## field and its own migration. Callers own the shape of what they store.
func put_blob(key: String, value: Array) -> void:
	var blobs: Dictionary = _data.get("blobs", {})
	blobs[key] = value
	_data["blobs"] = blobs
	_dirty = true


func get_blob(key: String) -> Array:
	return (_data.get("blobs", {}) as Dictionary).get(key, [])


func load_all() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		print("[store] no save at %s, starting fresh" % SAVE_PATH)
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		push_error("Store: cannot read %s" % SAVE_PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Store: malformed save, ignoring")
		return false
	var version := int((parsed as Dictionary).get("version", 0))
	if version != SAVE_VERSION:
		# Loud rather than silent: a schema change that quietly wipes a world is
		# worse than one that refuses to load it.
		push_warning("Store: save version %d != %d, ignoring" % [version, SAVE_VERSION])
		return false
	_data = parsed
	_data["players"] = _data.get("players", {})
	_data["entities"] = _data.get("entities", [])
	_data["blobs"] = _data.get("blobs", {})
	print("[store] loaded %d player(s), %d entity(ies)"
		% [(_data["players"] as Dictionary).size(), (_data["entities"] as Array).size()])
	return true


func save_all() -> bool:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Store: cannot write %s" % SAVE_PATH)
		return false
	f.store_string(JSON.stringify(_data, "  "))
	f.close()
	_dirty = false
	_timer = 0.0
	return true


func wipe() -> void:
	_data = {"version": SAVE_VERSION, "players": {}, "entities": [], "blobs": {}}
	_dirty = true
	save_all()
