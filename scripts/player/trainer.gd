extends RefCounted
class_name Trainer
## Where a specialization point may be spent.
##
## Skills are not bought from a menu in the middle of the desert: each track
## names a trainer POI, and you have to be standing at it. That is the whole
## mechanic, and it exists to give the map's named people a reason to be on it
## -- without it the trainer markers are decoration and levelling is something
## that happens in an inventory screen.

## How close you must be to a trainer to learn from them. Generous compared to
## the vendor's range: a trainer is a person somewhere in a camp, not a counter.
const RANGE := 20.0


## The trainer POI required for a skill, and whether the player is at it.
##
## A track whose trainer is not in the loaded region falls back to "anywhere".
## That is deliberate: the Hagga Basin South crop contains three of the wiki's
## trainer markers, and on a synthetic region there are none at all, so the
## alternative is a skill tree that silently cannot be used.
static func check(pos: Vector3, skill_id: String) -> Dictionary:
	var wanted := SkillDB.trainer_for(skill_id)
	if wanted.is_empty():
		return {"ok": true, "trainer": "", "msg": ""}

	var poi := Pois.find_named(wanted)
	if poi.is_empty():
		return {"ok": true, "trainer": "",
			"msg": "no %s in this region -- training unrestricted" % wanted}

	var d := Vector2(float(poi["x"]) - pos.x, float(poi["z"]) - pos.z).length()
	if d <= RANGE:
		return {"ok": true, "trainer": wanted, "msg": ""}
	return {"ok": false, "trainer": wanted,
		"msg": "%s is taught by %s, %d m away" % [
			SkillDB.get_skill(skill_id).get("name", skill_id), wanted, int(d)]}


## Trainer POIs within range, for the client to show what is on offer here.
static func at(pos: Vector3) -> Array:
	var out: Array = []
	for p: Dictionary in Pois.of_role("trainer") + Pois.of_role("trade"):
		var d := Vector2(float(p["x"]) - pos.x, float(p["z"]) - pos.z).length()
		if d <= RANGE:
			out.append(p)
	return out
