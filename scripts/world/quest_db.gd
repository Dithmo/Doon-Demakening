extends Node
## The Journey and the contract board, loaded from data/progression/quests.json.
##
## Both are lists of objectives over the same small vocabulary, so the matching
## logic lives in one place (QuestLog.observe) and adding either is a data
## change. Validated at load rather than at completion: a contract that asks for
## an item nobody can make is a content bug, and the honest time to find out is
## start-up, not the moment a player hands it in.

const PATH := "res://data/progression/quests.json"

## Every objective kind the game knows how to make progress on. Anything else
## in the data is a typo, and typos here fail silently forever if not caught.
const KINDS := ["gather", "craft", "use", "build", "stake", "kill", "extract",
	"visit", "visit_role", "learn", "sell"]

## Kinds whose `target` names an item.
const ITEM_KINDS := ["gather", "craft", "use", "build"]

var journey: Array = []
var contracts: Dictionary = {}
## Declaration order, which is board order.
var contract_ids: Array = []


func _ready() -> void:
	load_defs()


func load_defs() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("QuestDB: cannot open %s" % PATH)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("QuestDB: malformed %s" % PATH)
		return false

	journey.clear()
	contracts.clear()
	contract_ids.clear()

	for raw: Variant in parsed.get("journey", []):
		var step := _read_quest(raw)
		if step.is_empty():
			return false
		journey.append(step)

	for raw: Variant in parsed.get("contracts", []):
		var c := _read_quest(raw)
		if c.is_empty():
			return false
		c["giver"] = str((raw as Dictionary).get("giver", ""))
		c["level"] = int((raw as Dictionary).get("level", 1))
		c["next"] = str((raw as Dictionary).get("next", ""))
		if contracts.has(c["id"]):
			push_error("QuestDB: duplicate contract id '%s'" % c["id"])
			return false
		contracts[c["id"]] = c
		contract_ids.append(c["id"])

	for cid: String in contract_ids:
		var nxt := str(contracts[cid]["next"])
		if not nxt.is_empty() and not contracts.has(nxt):
			push_error("QuestDB: contract '%s' chains to unknown '%s'" % [cid, nxt])
			return false

	print("[quests] loaded %d journey step(s), %d contract(s)"
		% [journey.size(), contracts.size()])
	return true


func _read_quest(raw: Variant) -> Dictionary:
	var d: Dictionary = raw
	var obj: Dictionary = d.get("objective", {})
	var kind := str(obj.get("kind", ""))
	if not KINDS.has(kind):
		push_error("QuestDB: '%s' has unknown objective kind '%s'" % [d.get("id", "?"), kind])
		return {}
	var target := str(obj.get("target", ""))
	if ITEM_KINDS.has(kind) and not ItemDB.has(target):
		push_error("QuestDB: '%s' wants unknown item '%s'" % [d.get("id", "?"), target])
		return {}
	var carrying := str(obj.get("carrying", ""))
	if not carrying.is_empty() and not ItemDB.has(carrying):
		push_error("QuestDB: '%s' wants unknown carry item '%s'" % [d.get("id", "?"), carrying])
		return {}
	var reward: Dictionary = d.get("reward", {})
	return {
		"id": str(d["id"]),
		"name": str(d.get("name", d["id"])),
		"text": str(d.get("text", "")),
		"kind": kind,
		"target": target,
		# Some objectives are only satisfied while holding something -- the
		# testing-station step is "bring a blade", not "walk past".
		"carrying": carrying,
		"count": maxi(1, int(obj.get("count", 1))),
		"xp": float(reward.get("xp", 0.0)),
		"solari": int(reward.get("solari", 0)),
	}


func step(index: int) -> Dictionary:
	if index < 0 or index >= journey.size():
		return {}
	return journey[index]


func contract(cid: String) -> Dictionary:
	return contracts.get(cid, {})


## Contracts a given POI hands out, filtered to what this player can take on.
func offered_by(giver: String, level: int, done: Dictionary, active: Dictionary) -> Array:
	var out: Array = []
	for cid: String in contract_ids:
		var c: Dictionary = contracts[cid]
		if str(c["giver"]) != giver or done.has(cid) or active.has(cid):
			continue
		if level < int(c["level"]):
			continue
		# A chain link only appears once its predecessor is done.
		var prereq := _predecessor(cid)
		if not prereq.is_empty() and not done.has(prereq):
			continue
		out.append(c)
	return out


func _predecessor(cid: String) -> String:
	for other: String in contract_ids:
		if str(contracts[other]["next"]) == cid:
			return other
	return ""
