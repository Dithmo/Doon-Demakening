extends Node
## Specialization tracks and skills, loaded from data/progression/skills.json.
##
## Same shape as ItemDB and RecipeDB: a validated read-only table both sides
## load, so client and server agree about what a skill does without the client
## being asked. Effects are looked up by *kind* rather than by skill id, which
## is what keeps adding a skill a data change -- see Progression.mult().

const PATH := "res://data/progression/skills.json"

var _tracks: Dictionary = {}
var _skills: Dictionary = {}
## track id -> [skill ids], in the order they were declared, which is the order
## they unlock in.
var _by_track: Dictionary = {}


func _ready() -> void:
	load_defs()


func load_defs() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("SkillDB: cannot open %s" % PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("skills"):
		push_error("SkillDB: malformed %s" % PATH)
		return false

	_tracks.clear()
	_skills.clear()
	_by_track.clear()

	for raw: Variant in parsed.get("tracks", []):
		var t: Dictionary = raw
		var tid := str(t["id"])
		_tracks[tid] = {
			"id": tid,
			"name": str(t.get("name", tid)),
			# The POI a player must stand at to spend a point in this track.
			# Empty means anywhere, which is what synthetic regions get.
			"trainer": str(t.get("trainer", "")),
			"desc": str(t.get("desc", "")),
		}
		_by_track[tid] = []

	for raw: Variant in parsed["skills"]:
		var d: Dictionary = raw
		var sid := str(d["id"])
		if _skills.has(sid):
			push_error("SkillDB: duplicate skill id '%s'" % sid)
			return false
		var track := str(d.get("track", ""))
		if not _tracks.has(track):
			push_error("SkillDB: skill '%s' is in unknown track '%s'" % [sid, track])
			return false
		_skills[sid] = {
			"id": sid,
			"track": track,
			"name": str(d.get("name", sid)),
			"level": int(d.get("level", 1)),
			"requires": str(d.get("requires", "")),
			"effects": d.get("effects", {}),
			"bonuses": d.get("bonuses", {}),
			"desc": str(d.get("desc", "")),
		}
		(_by_track[track] as Array).append(sid)

	# Prerequisites are checked after the whole table is in, so a skill may
	# require one declared below it.
	for sid: String in _skills:
		var needs := str(_skills[sid]["requires"])
		if not needs.is_empty() and not _skills.has(needs):
			push_error("SkillDB: '%s' requires unknown skill '%s'" % [sid, needs])
			return false

	print("[skills] loaded %d skill(s) across %d track(s)" % [_skills.size(), _tracks.size()])
	return true


func get_skill(skill_id: String) -> Dictionary:
	return _skills.get(skill_id, {})


func get_track(track_id: String) -> Dictionary:
	return _tracks.get(track_id, {})


func tracks() -> Array:
	return _tracks.keys()


func skills_in(track_id: String) -> Array:
	return _by_track.get(track_id, [])


func skill_ids() -> Array:
	return _skills.keys()


## POI name that teaches this skill's track, or "" if anywhere will do.
func trainer_for(skill_id: String) -> String:
	var s := get_skill(skill_id)
	if s.is_empty():
		return ""
	return str(get_track(str(s["track"])).get("trainer", ""))
