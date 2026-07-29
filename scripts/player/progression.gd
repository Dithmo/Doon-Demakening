extends RefCounted
class_name Progression
## One player's progression: experience, level, specialization points, the
## skills bought with them, and Solari.
##
## Server-owned like everything that matters. The client is sent a mirror to
## draw, and asks the server to spend points; it never decides that it levelled
## up, because "what level am I" is exactly the sort of claim a client would
## enjoy making about itself.
##
## Held per player alongside Inventory and Vitals, and persisted with them.

## Experience needed to reach a level, from level 1. Quadratic rather than
## exponential: the spine is 2-3 hours long, and an exponential curve over that
## span either front-loads every level into the first twenty minutes or walls
## the last one off entirely.
const XP_BASE := 120.0
const XP_GROWTH := 55.0
const MAX_LEVEL := 12

## One specialization point per level, including the first. A player who has
## just arrived can already commit to something.
const POINTS_PER_LEVEL := 1

var xp: float = 0.0
var level: int = 1
var solari: int = 0
## skill id -> true. Skills are owned or not; there are no ranks, because a
## rank-3 version of a thing is content padding rather than a decision.
var skills: Dictionary = {}
## POI names already visited, so discovery pays once.
var discovered: Dictionary = {}


## Total experience required to have reached `lvl`.
static func xp_for_level(lvl: int) -> float:
	if lvl <= 1:
		return 0.0
	var n := float(lvl - 1)
	return XP_BASE * n + XP_GROWTH * n * (n - 1.0) * 0.5


## Experience still to go before the next level, or 0 at the cap.
func xp_to_next() -> float:
	if level >= MAX_LEVEL:
		return 0.0
	return maxf(0.0, xp_for_level(level + 1) - xp)


## Award experience. Returns how many levels it crossed, so the caller can
## announce them -- levelling is the one progression event worth interrupting
## someone for.
func award(amount: float) -> int:
	if amount <= 0.0 or level >= MAX_LEVEL:
		return 0
	xp += amount
	var gained := 0
	while level < MAX_LEVEL and xp >= xp_for_level(level + 1):
		level += 1
		gained += 1
	return gained


func points_total() -> int:
	return level * POINTS_PER_LEVEL


func points_spent() -> int:
	return skills.size()


func points_available() -> int:
	return points_total() - points_spent()


func has_skill(skill_id: String) -> bool:
	return skills.has(skill_id)


## Buy a skill. Every reason to refuse is checked here rather than at the call
## site, so the RPC handler cannot forget one.
func learn(skill_id: String) -> Dictionary:
	var def := SkillDB.get_skill(skill_id)
	if def.is_empty():
		return {"ok": false, "msg": "no such skill"}
	if has_skill(skill_id):
		return {"ok": false, "msg": "you already know %s" % def["name"]}
	if points_available() <= 0:
		return {"ok": false, "msg": "no specialization points to spend"}
	if level < int(def["level"]):
		return {"ok": false, "msg": "%s needs level %d" % [def["name"], def["level"]]}
	var needs := str(def.get("requires", ""))
	if not needs.is_empty() and not has_skill(needs):
		return {"ok": false, "msg": "%s needs %s first"
			% [def["name"], SkillDB.get_skill(needs).get("name", needs)]}
	skills[skill_id] = true
	return {"ok": true, "msg": "learned %s" % def["name"]}


## Combined multiplier for an effect kind, across every skill owned.
##
## Multiplicative rather than additive so two skills touching the same dial
## cannot stack to zero or to something absurd, and so the identity is 1.0 --
## callers can multiply unconditionally without asking whether any skill
## applies.
func mult(kind: String) -> float:
	var m := 1.0
	for skill_id: String in skills:
		var def := SkillDB.get_skill(skill_id)
		var effects: Dictionary = def.get("effects", {})
		if effects.has(kind):
			m *= float(effects[kind])
	return m


## Flat bonus for an effect kind. Separate from mult() because "+1 item per
## node" and "x1.5 yield" are different promises and blending them silently
## would make both unreadable.
func bonus(kind: String) -> float:
	var b := 0.0
	for skill_id: String in skills:
		var def := SkillDB.get_skill(skill_id)
		var flats: Dictionary = def.get("bonuses", {})
		if flats.has(kind):
			b += float(flats[kind])
	return b


func spend_solari(amount: int) -> bool:
	if amount < 0 or solari < amount:
		return false
	solari -= amount
	return true


func earn_solari(amount: int) -> void:
	solari += maxi(0, amount)


## True the first time a POI is seen, false ever after.
func discover(poi_name: String) -> bool:
	if poi_name.is_empty() or discovered.has(poi_name):
		return false
	discovered[poi_name] = true
	return true


func to_data() -> Dictionary:
	return {
		"xp": xp,
		"level": level,
		"solari": solari,
		"skills": skills.keys(),
		"discovered": discovered.keys(),
	}


func from_data(d: Dictionary) -> void:
	xp = float(d.get("xp", 0.0))
	level = maxi(1, int(d.get("level", 1)))
	solari = int(d.get("solari", 0))
	skills.clear()
	for s: Variant in d.get("skills", []):
		# Drop skills that no longer exist rather than carrying dead ids that
		# would keep consuming a point forever.
		if not SkillDB.get_skill(str(s)).is_empty():
			skills[str(s)] = true
	discovered.clear()
	for p: Variant in d.get("discovered", []):
		discovered[str(p)] = true


## Compact form for the client mirror.
func to_wire() -> Dictionary:
	return {
		"xp": xp, "level": level, "solari": solari,
		"next": xp_to_next(), "points": points_available(),
		"skills": skills.keys(),
	}
