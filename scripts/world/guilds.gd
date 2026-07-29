class_name Guilds
extends RefCounted
## Guilds, and the Landsraad standing they compete for.
##
## Server-owned like everything else. A guild is deliberately thin: a name, a
## founder, a roster, and a standing score. What makes it worth having is that
## it changes exactly one rule that already existed -- a claim admits your
## guild, not only you -- which turns Phase 3's anti-grief boundary into the
## thing a group organises around rather than a wall between friends.
##
## Landsraad standing is the shared goal: members deliver goods to a
## Representative marker on the wiki map, the guild's standing rises, and the
## standing is public. It is a scoreboard with a real cost, not a tech tree.

## How close you must be to a Landsraad representative to deliver to them.
const DELIVER_RANGE := 20.0

## Standing awarded per Solari of delivered value. Deliveries are priced by the
## same item `value` the trading post uses, so contributing is always a real
## choice against selling -- you are giving up money for standing.
const STANDING_PER_VALUE := 0.5

## A guild name has to be usable in a log line and a chat message.
const MAX_NAME := 24

## guild id -> {name, founder, members: {identity: true}, standing}
var guilds: Dictionary = {}
var _next_id: int = 1


func of_member(identity: String) -> int:
	for gid: int in guilds:
		if (guilds[gid]["members"] as Dictionary).has(identity):
			return gid
	return 0


func name_taken(wanted: String) -> bool:
	var needle := wanted.strip_edges().to_lower()
	for gid: int in guilds:
		if str(guilds[gid]["name"]).to_lower() == needle:
			return true
	return false


func found(identity: String, wanted: String) -> Dictionary:
	var name := wanted.strip_edges()
	if name.is_empty() or name.length() > MAX_NAME:
		return {"ok": false, "msg": "a guild needs a name of 1 to %d characters"
			% MAX_NAME, "id": 0}
	if of_member(identity) != 0:
		return {"ok": false, "msg": "you are already in a guild", "id": 0}
	if name_taken(name):
		return {"ok": false, "msg": "'%s' is taken" % name, "id": 0}
	var gid := _next_id
	_next_id += 1
	guilds[gid] = {"name": name, "founder": identity,
		"members": {identity: true}, "standing": 0.0}
	return {"ok": true, "msg": "founded %s" % name, "id": gid}


## Invitations are not modelled: this is an eight-player demake, and a join
## request the founder never sees is worse than an open door. The founder can
## still expel.
func join(identity: String, wanted: String) -> Dictionary:
	if of_member(identity) != 0:
		return {"ok": false, "msg": "you are already in a guild", "id": 0}
	for gid: int in guilds:
		if str(guilds[gid]["name"]).to_lower() == wanted.strip_edges().to_lower():
			(guilds[gid]["members"] as Dictionary)[identity] = true
			return {"ok": true, "msg": "joined %s" % guilds[gid]["name"], "id": gid}
	return {"ok": false, "msg": "no guild called '%s'" % wanted, "id": 0}


func leave(identity: String) -> Dictionary:
	var gid := of_member(identity)
	if gid == 0:
		return {"ok": false, "msg": "you are not in a guild", "id": 0}
	var g: Dictionary = guilds[gid]
	(g["members"] as Dictionary).erase(identity)
	var name := str(g["name"])
	# A guild with nobody in it is not a guild. Dissolving it frees the name
	# and stops standing accruing to an empty scoreboard entry.
	if (g["members"] as Dictionary).is_empty():
		guilds.erase(gid)
		return {"ok": true, "msg": "left and dissolved %s" % name, "id": 0}
	if str(g["founder"]) == identity:
		# Hand the founder's seat to whoever is left, so a guild is never
		# stuck with an owner who has gone.
		g["founder"] = (g["members"] as Dictionary).keys()[0]
	return {"ok": true, "msg": "left %s" % name, "id": 0}


## True when two identities share a guild. This is the whole of what a guild
## changes about the world, and it is deliberately one function so Claims has
## exactly one thing to ask.
func allied(a: String, b: String) -> bool:
	if a == b:
		return true
	var ga := of_member(a)
	return ga != 0 and ga == of_member(b)


func standing_of(gid: int) -> float:
	return float(guilds.get(gid, {}).get("standing", 0.0))


## Hand goods to a Landsraad representative. Values the stack the way the
## trading post would, converts that to standing, and consumes it.
func deliver(identity: String, player_pos: Vector3, inv: Inventory,
		slot_index: int, count: int) -> Dictionary:
	var gid := of_member(identity)
	if gid == 0:
		return {"ok": false, "msg": "the Landsraad deals with guilds, not people"}
	var rep := representative_in_reach(player_pos)
	if rep.is_empty():
		return {"ok": false, "msg": "no Landsraad representative within reach"}
	if slot_index < 0 or slot_index >= inv.slots.size() or inv.slots[slot_index].is_empty():
		return {"ok": false, "msg": "nothing to hand over"}
	var stack: Dictionary = inv.slots[slot_index]
	var item := str(stack["id"])
	var value := Vendor.value_of(item)
	if value <= 0:
		return {"ok": false, "msg": "%s is of no interest to them"
			% ItemDB.display_name(item)}
	var n: int = inv.remove_at(slot_index, clampi(count, 1, int(stack["count"])))
	if n <= 0:
		return {"ok": false, "msg": "nothing to hand over"}
	var gained := float(value * n) * STANDING_PER_VALUE
	guilds[gid]["standing"] = standing_of(gid) + gained
	return {"ok": true, "id": gid, "standing": standing_of(gid), "gained": gained,
		"msg": "delivered %d %s to %s (+%.0f standing)"
			% [n, ItemDB.display_name(item), rep.get("name", "the Landsraad"), gained]}


## The wiki's own Representatives markers are the delivery points. Falls back to
## trading posts where a region has no representatives -- the synthetic maps
## have neither, and a guild feature that silently cannot be used on the test
## map is one nobody notices is broken.
static func representative_in_reach(pos: Vector3) -> Dictionary:
	for role: String in ["landsraad", "trade"]:
		for p: Dictionary in Pois.of_role(role):
			var d := Vector2(float(p["x"]) - pos.x, float(p["z"]) - pos.z).length()
			if d <= DELIVER_RANGE:
				return p
	return {}


## Standing table, highest first. Public on purpose: a scoreboard nobody can
## see is not a reason to do anything.
func table() -> Array:
	var rows: Array = []
	for gid: int in guilds:
		var g: Dictionary = guilds[gid]
		rows.append([gid, str(g["name"]), (g["members"] as Dictionary).size(),
			float(g["standing"])])
	rows.sort_custom(func(a, b): return float(a[3]) > float(b[3]))
	return rows


func to_data() -> Array:
	var out: Array = []
	for gid: int in guilds:
		var g: Dictionary = guilds[gid]
		out.append([gid, str(g["name"]), str(g["founder"]),
			(g["members"] as Dictionary).keys(), float(g["standing"])])
	return out


func from_data(rows: Array) -> void:
	guilds.clear()
	_next_id = 1
	for row: Array in rows:
		var gid := int(row[0])
		var members: Dictionary = {}
		for m: Variant in row[3]:
			members[str(m)] = true
		if members.is_empty():
			continue
		guilds[gid] = {"name": str(row[1]), "founder": str(row[2]),
			"members": members, "standing": float(row[4])}
		_next_id = maxi(_next_id, gid + 1)
