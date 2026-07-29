extends RefCounted
class_name QuestLog
## One player's place in the Journey and on the contract board.
##
## The whole point of this class is that progress is *observed*, never claimed.
## World calls observe() with what actually happened on the server -- an item
## really left a node, a body really fell -- and everything that could advance
## does. No client ever says "I finished that", and no subsystem has to know
## which quests exist.

## Journey step the player is on. Equal to QuestDB.journey.size() when done.
var step: int = 0
var step_progress: int = 0

## contract id -> progress count
var active: Dictionary = {}
## contract id -> true
var done: Dictionary = {}


## Something happened. Returns a list of completions for the caller to reward
## and announce: [{"kind": "journey"|"contract", "id", "name", "xp", "solari"}]
##
## `count` is how much of it happened; `target` identifies what, and is matched
## against the objective's target unless the objective's target is empty, which
## means "any". `carrying` is the player's bag, needed only by objectives that
## demand you bring something.
func observe(kind: String, target: String, count: int = 1,
		carrying: Inventory = null) -> Array:
	var finished: Array = []
	if count <= 0:
		return finished

	var current := QuestDB.step(step)
	if not current.is_empty() and _matches(current, kind, target, carrying):
		step_progress += count
		if step_progress >= int(current["count"]):
			finished.append({"kind": "journey", "id": current["id"],
				"name": current["name"], "xp": current["xp"],
				"solari": current["solari"]})
			step += 1
			step_progress = 0

	for cid: String in active.keys():
		var c := QuestDB.contract(cid)
		if c.is_empty() or not _matches(c, kind, target, carrying):
			continue
		active[cid] = int(active[cid]) + count
		if int(active[cid]) >= int(c["count"]):
			active.erase(cid)
			done[cid] = true
			finished.append({"kind": "contract", "id": cid, "name": c["name"],
				"xp": c["xp"], "solari": c["solari"]})
	return finished


func _matches(quest: Dictionary, kind: String, target: String,
		carrying: Inventory) -> bool:
	if str(quest["kind"]) != kind:
		return false
	var want := str(quest["target"])
	if not want.is_empty() and want != target:
		return false
	var must_carry := str(quest["carrying"])
	if not must_carry.is_empty():
		if carrying == null or carrying.count_of(must_carry) <= 0:
			return false
	return true


func accept(cid: String, level: int) -> Dictionary:
	var c := QuestDB.contract(cid)
	if c.is_empty():
		return {"ok": false, "msg": "no such contract"}
	if done.has(cid):
		return {"ok": false, "msg": "%s is already settled" % c["name"]}
	if active.has(cid):
		return {"ok": false, "msg": "you are already on %s" % c["name"]}
	if level < int(c["level"]):
		return {"ok": false, "msg": "%s wants level %d" % [c["name"], c["level"]]}
	active[cid] = 0
	return {"ok": true, "msg": "took on %s: %s" % [c["name"], c["text"]]}


func journey_done() -> bool:
	return step >= QuestDB.journey.size()


func to_data() -> Dictionary:
	return {"step": step, "step_progress": step_progress,
		"active": active.duplicate(), "done": done.keys()}


func from_data(d: Dictionary) -> void:
	step = maxi(0, int(d.get("step", 0)))
	step_progress = maxi(0, int(d.get("step_progress", 0)))
	active.clear()
	for k: Variant in d.get("active", {}):
		# Drop contracts that no longer exist rather than keeping a slot open
		# against a quest that can never be finished.
		if not QuestDB.contract(str(k)).is_empty():
			active[str(k)] = int(d["active"][k])
	done.clear()
	for k: Variant in d.get("done", []):
		done[str(k)] = true


func to_wire() -> Dictionary:
	var current := QuestDB.step(step)
	return {
		"step": step,
		"step_name": str(current.get("name", "")),
		"step_text": str(current.get("text", "")),
		# The objective itself, not just its prose. A client needs this to point
		# the player at the right thing, and the journeyman bot needs it to play
		# the path at all -- without it a "directed path" is only a caption.
		"step_kind": str(current.get("kind", "")),
		"step_target": str(current.get("target", "")),
		"step_need": int(current.get("count", 0)),
		"step_have": step_progress,
		"active": active.duplicate(),
		"done": done.size(),
	}
