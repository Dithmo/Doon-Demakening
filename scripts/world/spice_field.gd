class_name SpiceField
extends RefCounted
## Spice blows: the one thing on Arrakis worth the risk.
##
## The wiki describes the cycle rather than a resource node, and the cycle is
## what makes it interesting. Sandtrout excrete pre-spice mass underground;
## carbon dioxide pressure builds until it erupts; the mass dries in the sun
## and becomes melange. So a spice field is not a rock you hit -- it is a place
## that is *sometimes* worth being, and knowing when is the game.
##
## Three states, on a timer the server owns:
##
##   DORMANT   nothing there. Most fields, most of the time.
##   BLOWING   erupting. Announced to every player on the server, because a
##             blow is visible for miles and a race is the point.
##   DRYING    the mass has dried to melange sand and can be harvested, until
##             it is picked clean or the sand takes it back.
##
## Harvesting is the loudest thing a player can do. That is not a balance knob
## bolted on afterwards -- it is the trade the whole game is built around, and
## it is why spice is worth what it is worth.

enum State { DORMANT, BLOWING, DRYING }

## How close you must be to work a blow.
const REACH := 6.0
const SWING_COOLDOWN := 1.4

## The eruption itself, before anything can be taken. Long enough that a player
## who sees the announcement can get there.
const BLOW_SECONDS := 45.0
## How long the dried mass lasts once it is takeable.
const DRYING_SECONDS := 240.0
## Between blows at one field. Randomised per field so the map does not pulse
## in unison.
const DORMANT_MIN := 420.0
const DORMANT_MAX := 900.0

## Harvests available from one blow, and what each one gives.
const HARVESTS := 8
const YIELD_PER_HARVEST := 3

## Threat multiplier while standing on a live blow, on top of everything else.
## Spice harvesting is the single loudest act in the game -- a cutteray in open
## sand over a fresh eruption is exactly the situation worms exist for.
const HARVEST_THREAT := 34.0

## field id -> {pos, name, state, until, remaining}
var fields: Dictionary = {}

var _next_id: int = 1
var _rng := RandomNumberGenerator.new()

## Debug only (--spice-now): fields re-erupt the moment they are spent instead
## of going dormant. The real cycle is 7-15 minutes of nothing followed by a
## four-minute window, which is right for play and useless for a harness --
## the first run of this test walked a bot 750 m and arrived to find the blow
## had dried up and blown away.
var always_on: bool = false


## How many fields a region should have if the wiki gives us too few.
const TARGET_FIELDS := 9
## No blow within this of the trading post: spice you can reach without
## crossing open sand is spice without a decision attached.
const MIN_FROM_TOWN := 420.0


## Seed the cycle. Deterministic from `seed_value`, so a restart brings back the
## same map rather than reshuffling it.
##
## The wiki's eight Spiceblows markers all sit in the *north-west* of Hagga
## Basin, outside the southern crop this region is built from, so using them
## alone would leave the map with no spice at all. That is a fact about the crop
## rather than about the game: a blow is an eruption on open sand, not a
## landmark, and the markers only record where people have seen them. So we take
## every marker that does fall inside the region and make up the shortfall on
## real open sand, out where crossing to it costs something.
func seed(seed_value: int = 90210) -> void:
	_rng.seed = seed_value
	fields.clear()
	_next_id = 1

	for poi: Dictionary in Pois.of_role("spice"):
		_add(Vector3(float(poi["x"]), 0.0, float(poi["z"])),
			str(poi.get("name", "Spice field")))

	var town := Pois.nearest("trade", Terrain.size_m.x * 0.5, Terrain.size_m.y * 0.5)
	var town_xz := Vector2(Terrain.size_m.x * 0.5, Terrain.size_m.y * 0.5)
	if not town.is_empty():
		town_xz = Vector2(float(town["x"]), float(town["z"]))

	# Distances are capped against the region rather than assumed: the real map
	# is 4.5 km across and the synthetic test region is a few hundred metres, so
	# a flat 420 m exclusion placed exactly zero fields on the small one. Try the
	# full spacing first and relax it until the map can hold them -- the intent
	# ("out where crossing to it costs something") survives at any scale.
	var span := minf(Terrain.size_m.x, Terrain.size_m.y)
	var keep_out := minf(MIN_FROM_TOWN, span * 0.18)
	var apart := minf(300.0, span * 0.12)
	var edge := minf(60.0, span * 0.06)

	for relax in 5:
		var guard := 0
		while fields.size() < TARGET_FIELDS and guard < 4000:
			guard += 1
			var x := _rng.randf_range(edge, Terrain.size_m.x - edge)
			var z := _rng.randf_range(edge, Terrain.size_m.y - edge)
			# Open sand, reachable on foot, and far enough out to be a journey.
			if Terrain.sample_surface(x, z) != Terrain.Surface.SAND:
				continue
			if not Terrain.is_reachable(x, z):
				continue
			if Vector2(x, z).distance_to(town_xz) < keep_out:
				continue
			if _too_close(x, z, apart):
				continue
			_add(Vector3(x, 0.0, z), "Spice field")
		if fields.size() >= TARGET_FIELDS:
			break
		keep_out *= 0.55
		apart *= 0.55


func _too_close(x: float, z: float, limit: float) -> bool:
	for fid: int in fields:
		var p: Vector3 = fields[fid]["pos"]
		if Vector2(x - p.x, z - p.z).length() < limit:
			return true
	return false


func _add(pos: Vector3, name: String) -> void:
	pos.y = Terrain.sample_height(pos.x, pos.z)
	fields[_next_id] = {
		"pos": pos,
		"name": name,
		"state": State.DORMANT,
		# Stagger the first blow across the whole dormant window, or every field
		# on the map erupts at once a few minutes after boot.
		"until": _rng.randf_range(30.0, DORMANT_MAX),
		"remaining": 0,
	}
	_next_id += 1


## Advance every field. `now` is server seconds.
##
## Returns {"erupted": ids that just started blowing, "changed": any transition
## at all}. The two are not the same and conflating them was a real bug: only
## eruptions were replicated, so a client watched a field go BLOWING and never
## heard it had dried. A bot walked 750 m, stood on the spice, and could not cut
## it, because as far as the client knew it was still erupting.
func tick(now: float) -> Dictionary:
	var erupted: Array = []
	var changed := false
	for fid: int in fields:
		var f: Dictionary = fields[fid]
		if now < float(f["until"]):
			continue
		changed = true
		match int(f["state"]):
			State.DORMANT:
				f["state"] = State.BLOWING
				f["until"] = now + BLOW_SECONDS
				erupted.append(fid)
			State.BLOWING:
				f["state"] = State.DRYING
				f["until"] = now + DRYING_SECONDS
				f["remaining"] = HARVESTS
			State.DRYING:
				_sleep(f, now)
	return {"erupted": erupted, "changed": changed}


func _sleep(f: Dictionary, now: float) -> void:
	if always_on:
		f["state"] = State.DRYING
		f["remaining"] = HARVESTS
		f["until"] = now + DRYING_SECONDS
		return
	f["state"] = State.DORMANT
	f["remaining"] = 0
	f["until"] = now + _rng.randf_range(DORMANT_MIN, DORMANT_MAX)


## True when the player is standing on a blow that can be worked. Used by the
## survival tick to decide how much noise they are making, so it must be cheap.
func harvestable_at(pos: Vector3) -> int:
	for fid: int in fields:
		var f: Dictionary = fields[fid]
		if int(f["state"]) != State.DRYING or int(f["remaining"]) <= 0:
			continue
		if Vector2(pos.x - f["pos"].x, pos.z - f["pos"].z).length() <= REACH:
			return fid
	return 0


## Take one harvest. Every check is here and on the server: distance, state,
## cooldown, tool and inventory space.
func harvest(player_pos: Vector3, inv: Inventory, field_id: int,
		cooldowns: Dictionary, now: float, yield_mult: float = 1.0) -> Dictionary:
	if not fields.has(field_id):
		return _fail("no such spice field")
	var f: Dictionary = fields[field_id]
	if Vector2(player_pos.x - f["pos"].x, player_pos.z - f["pos"].z).length() > REACH:
		return _fail("too far from the spice")
	match int(f["state"]):
		State.DORMANT:
			return _fail("the sand here is quiet")
		State.BLOWING:
			return _fail("it is still erupting -- wait for it to dry")
	if int(f["remaining"]) <= 0:
		return _fail("this blow is picked clean")

	# A cutteray is what you cut spice with; bare hands will not do.
	if not _has_tool(inv, "tool_gather"):
		return _fail("you need a cutteray to cut spice")

	var key := "spice_%d" % field_id
	if now - float(cooldowns.get(key, -999.0)) < SWING_COOLDOWN:
		return _fail("")
	cooldowns[key] = now

	var amount := maxi(1, int(round(float(YIELD_PER_HARVEST) * yield_mult)))
	# Inventory.add returns what would *not* fit, not what went in.
	var taken := amount - inv.add("spice_sand", amount)
	if taken <= 0:
		return _fail("no room for the spice")
	f["remaining"] = int(f["remaining"]) - taken_harvests(taken, amount)
	if int(f["remaining"]) <= 0:
		_sleep(f, now)
	return {"ok": true, "msg": "cut %d spice sand" % taken, "count": taken,
		"name": str(f["name"])}


## A partial pickup -- a nearly full bag -- should not cost a whole harvest.
static func taken_harvests(taken: int, offered: int) -> int:
	return 1 if taken >= offered else 0


func _has_tool(inv: Inventory, hook: String) -> bool:
	for slot: Dictionary in inv.slots:
		if slot.is_empty():
			continue
		if str(ItemDB.get_def(str(slot["id"])).get("use", "")) == hook:
			return true
	return false


## Nearest field that is doing something worth walking to, or 0.
func nearest_live(pos: Vector3) -> int:
	var best := 0
	var best_d := INF
	for fid: int in fields:
		var f: Dictionary = fields[fid]
		if int(f["state"]) == State.DORMANT:
			continue
		var d: float = Vector2(pos.x - f["pos"].x, pos.z - f["pos"].z).length()
		if d < best_d:
			best_d = d
			best = fid
	return best


static func state_name(s: int) -> String:
	match s:
		State.BLOWING: return "erupting"
		State.DRYING: return "ready"
	return "quiet"


## Only live fields go on the wire. A dormant field is not a secret, but there
## are 20-odd of them and none of them is news.
func to_wire() -> Array:
	var out: Array = []
	for fid: int in fields:
		var f: Dictionary = fields[fid]
		if int(f["state"]) == State.DORMANT:
			continue
		out.append([fid, f["pos"].x, f["pos"].y, f["pos"].z, f["name"],
			int(f["state"]), int(f["remaining"])])
	return out


## `saved_at` rides along with every row so `from_data` can turn absolute
## deadlines back into remaining time. The server clock restarts at zero, so a
## deadline restored literally would already be in the past and every field on
## the map would erupt in the first tick after a restart.
func to_data(now: float = 0.0) -> Array:
	var out: Array = []
	for fid: int in fields:
		var f: Dictionary = fields[fid]
		out.append({"id": fid, "state": int(f["state"]), "until": float(f["until"]),
			"remaining": int(f["remaining"]), "saved_at": now})
	return out


## Restore the cycle across a restart. Positions come from the POIs, which are
## fixed, so only the timers are saved.
func from_data(rows: Array, now: float) -> void:
	for raw: Variant in rows:
		var d: Dictionary = raw
		var fid := int(d["id"])
		if not fields.has(fid):
			continue
		var f: Dictionary = fields[fid]
		f["state"] = int(d.get("state", State.DORMANT))
		f["remaining"] = int(d.get("remaining", 0))
		# Timers are stored as absolute server seconds, and the server clock
		# restarts at zero, so a saved deadline is re-based on load rather than
		# restored literally -- otherwise every field fires the instant a
		# restarted server passes the old timestamp.
		f["until"] = now + maxf(5.0, float(d.get("until", 0.0)) - float(d.get("saved_at", 0.0)))


func _fail(msg: String) -> Dictionary:
	return {"ok": false, "msg": msg, "count": 0}
