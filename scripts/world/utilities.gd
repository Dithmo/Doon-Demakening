class_name Utilities
extends RefCounted
## Power and production across a holding.
##
## Power is pooled per claim rather than wired piece to piece: a generator
## anywhere inside a holding runs everything inside it. That skips a whole
## cable-graph system for a result players read the same way, and it means the
## claim is the unit of infrastructure as well as of ownership.
##
## Production is what turns water from a per-trip crisis into infrastructure.
## It ticks on the server whether or not the owner is connected, and accrues
## across a server restart from a stored timestamp -- "come back to stored
## water" only means something if the world kept working while you were gone.

## Never bank more than this much elapsed time in one go. A server that was
## down for a week should not hand back a week of water.
const MAX_OFFLINE_SECONDS := 6.0 * 3600.0


## Power balance for one claim: {output, draw, satisfied}.
static func power_for_claim(claim_id: int, claims: Claims,
		stations: StationField) -> Dictionary:
	var output := 0.0
	var draw := 0.0
	for sid: int in stations.stations:
		var s: Dictionary = stations.stations[sid]
		if claims.claim_at(s["pos"]) != claim_id:
			continue
		var def := ItemDB.get_def(str(s["item_id"]))
		output += float(def.get("power_output", 0.0))
		draw += float(def.get("power_draw", 0.0))
	return {"output": output, "draw": draw, "satisfied": output >= draw}


## Advance production by `elapsed` seconds. Returns a list of human-readable
## notes about what was produced, for logging.
##
## A producer needs three things: to be inside a claim, for that claim to have
## the power to run it, and for there to be somewhere to put the output.
## Missing any of them stalls it rather than voiding the production.
static func produce(elapsed: float, claims: Claims, stations: StationField) -> Array:
	if elapsed <= 0.0:
		return []
	elapsed = minf(elapsed, MAX_OFFLINE_SECONDS)

	var notes: Array = []
	var power_cache: Dictionary = {}

	for sid: int in stations.stations:
		var s: Dictionary = stations.stations[sid]
		var def := ItemDB.get_def(str(s["item_id"]))
		var product := str(def.get("produces", ""))
		if product.is_empty():
			continue

		var claim_id := claims.claim_at(s["pos"])
		if claim_id == 0:
			continue  # unclaimed kit is nobody's infrastructure
		if not power_cache.has(claim_id):
			power_cache[claim_id] = power_for_claim(claim_id, claims, stations)
		if not bool(power_cache[claim_id]["satisfied"]):
			continue

		# Fractional output is carried between ticks, so a slow producer still
		# yields rather than rounding to nothing every time.
		var rate := float(def.get("produce_rate", 0.0))
		var carried := float(s.get("carry", 0.0)) + rate * elapsed
		var whole := int(floor(carried))
		if whole <= 0:
			s["carry"] = carried
			continue

		var stored := _store_in_claim(claim_id, claims, stations, product, whole)
		s["carry"] = carried - float(stored)
		if stored > 0:
			notes.append("%s produced %s x%d" % [s["kind"], product, stored])
	return notes


## Put `count` of `item_id` into any container in the claim. Returns how many
## actually landed.
static func _store_in_claim(claim_id: int, claims: Claims, stations: StationField,
		item_id: String, count: int) -> int:
	var left := count
	for sid: int in stations.stations:
		if left <= 0:
			break
		var s: Dictionary = stations.stations[sid]
		if not s.has("inventory"):
			continue
		if claims.claim_at(s["pos"]) != claim_id:
			continue
		left = (s["inventory"] as Inventory).add(item_id, left)
	return count - left
