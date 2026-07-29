class_name Hostiles
extends RefCounted
## Enemy camps, and the bodies they leave.
##
## Combat exists in this demake mainly to feed the water economy: a corpse is
## water you can reclaim with an extractor. That closes the loop back to Phase 1
## rather than bolting a fight system onto the side.
##
## Server-owned. Positions, health and death all resolve on the authority; the
## client is told, never asked.

## How close before a camp's occupants notice you.
const AGGRO_RANGE := 18.0
## They give up past this, so a fight is escapable.
const LEASH_RANGE := 34.0
const NPC_SPEED := 3.4
const NPC_HEALTH := 60.0
const NPC_DAMAGE := 9.0
const NPC_REACH := 2.4
const ATTACK_COOLDOWN := 1.6
## Bodies linger long enough to be worth walking back for, then dry out.
const CORPSE_SECONDS := 120.0
## Blood a body yields, and how long between extractions.
const BLOOD_PER_BODY := 2
const EXTRACT_COOLDOWN := 2.0

## npc id -> {pos, home, health, target, attack_at}
var npcs: Dictionary = {}
## corpse id -> {pos, blood, expires_at}
var corpses: Dictionary = {}

var _next_id: int = 1
var _rng := RandomNumberGenerator.new()


## Scatter camps of hostiles. Phase 5 replaces this with the 263 real camp
## positions from the wiki data (docs/terrain-plan.md).
func seed(camps: int = 6, per_camp: int = 3, seed_value: int = 91177) -> void:
	_rng.seed = seed_value
	var placed := 0
	var tries := 0
	while placed < camps and tries < 3000:
		tries += 1
		var x := _rng.randf_range(20.0, Terrain.size_m.x - 20.0)
		var z := _rng.randf_range(20.0, Terrain.size_m.y - 20.0)
		if not Terrain.is_reachable(x, z):
			continue
		for i in range(per_camp):
			var a := TAU * float(i) / float(per_camp)
			var nx := x + cos(a) * 3.0
			var nz := z + sin(a) * 3.0
			if not Terrain.is_reachable(nx, nz):
				continue
			_spawn(Vector3(nx, Terrain.sample_height(nx, nz), nz))
		placed += 1
	print("[hostiles] seeded %d npc(s) across %d camp(s)" % [npcs.size(), placed])


func _spawn(pos: Vector3) -> int:
	var id := _next_id
	_next_id += 1
	npcs[id] = {"pos": pos, "home": pos, "health": NPC_HEALTH,
		"target": 0, "attack_at": 0.0}
	return id


## Advance every NPC. `players` is peer -> {pos, alive}.
## Returns events: {kind: "hit", peer, damage} and {kind: "died", id, pos}.
func tick(delta: float, players: Dictionary, now: float) -> Array:
	var events: Array = []

	for id: int in npcs.keys():
		var n: Dictionary = npcs[id]

		# Pick or drop a target. Leashing to home is what makes a camp a place
		# rather than a pack that follows you across the map.
		var target: int = int(n["target"])
		if target != 0:
			var t: Dictionary = players.get(target, {})
			if t.is_empty() or not bool(t["alive"]) \
					or (n["home"] as Vector3).distance_to(t["pos"]) > LEASH_RANGE:
				n["target"] = 0
				target = 0
		if target == 0:
			var best := INF
			for peer: int in players:
				var p: Dictionary = players[peer]
				if not bool(p["alive"]):
					continue
				var d: float = (n["pos"] as Vector3).distance_to(p["pos"])
				if d < AGGRO_RANGE and d < best:
					best = d
					target = peer
			n["target"] = target

		if target == 0:
			# Drift home so a camp reassembles after a fight.
			n["pos"] = (n["pos"] as Vector3).move_toward(n["home"], NPC_SPEED * delta)
			continue

		var tp: Vector3 = players[target]["pos"]
		var dist: float = (n["pos"] as Vector3).distance_to(tp)
		if dist > NPC_REACH:
			var step := (n["pos"] as Vector3).move_toward(tp, NPC_SPEED * delta)
			# Hostiles obey the same terrain rules the player does.
			if Terrain.is_reachable(step.x, step.z):
				step.y = Terrain.sample_height(step.x, step.z)
				n["pos"] = step
		elif now >= float(n["attack_at"]):
			n["attack_at"] = now + ATTACK_COOLDOWN
			events.append({"kind": "hit", "peer": target, "damage": NPC_DAMAGE})

	for id: int in corpses.keys():
		if now >= float(corpses[id]["expires_at"]):
			corpses.erase(id)

	return events


## Nearest live NPC within `reach` of a point, or 0.
func nearest(pos: Vector3, reach: float) -> int:
	var best := 0
	var best_d := reach
	for id: int in npcs:
		var d: float = (npcs[id]["pos"] as Vector3).distance_to(pos)
		if d <= best_d:
			best_d = d
			best = id
	return best


## Apply damage. Returns {killed, pos}.
func damage(npc_id: int, amount: float, now: float) -> Dictionary:
	if not npcs.has(npc_id) or amount <= 0.0:
		return {"killed": false, "pos": Vector3.ZERO}
	var n: Dictionary = npcs[npc_id]
	n["health"] = float(n["health"]) - amount
	if float(n["health"]) > 0.0:
		return {"killed": false, "pos": n["pos"]}

	var at: Vector3 = n["pos"]
	npcs.erase(npc_id)
	var cid := _next_id
	_next_id += 1
	corpses[cid] = {"pos": at, "blood": BLOOD_PER_BODY,
		"expires_at": now + CORPSE_SECONDS}
	return {"killed": true, "pos": at}


func nearest_corpse(pos: Vector3, reach: float) -> int:
	var best := 0
	var best_d := reach
	for id: int in corpses:
		var d: float = (corpses[id]["pos"] as Vector3).distance_to(pos)
		if d <= best_d:
			best_d = d
			best = id
	return best


## Draw water from a body. Needs the extractor in hand: this is the step that
## turns a kill into hydration, and it should cost a tool slot to do.
func extract(player_pos: Vector3, inv: Inventory, corpse_id: int,
		cooldowns: Dictionary, now: float) -> Dictionary:
	if not corpses.has(corpse_id):
		return {"ok": false, "msg": "nothing to draw from"}
	var c: Dictionary = corpses[corpse_id]
	if player_pos.distance_to(c["pos"]) > 3.0:
		return {"ok": false, "msg": "too far from the body"}
	if now < float(cooldowns.get("extract_at", 0.0)):
		return {"ok": false, "msg": ""}
	if not _has_extractor(inv):
		return {"ok": false, "msg": "need a blood extractor"}
	if int(c["blood"]) <= 0:
		return {"ok": false, "msg": "already drained"}

	if inv.add("blood_sack", 1) > 0:
		return {"ok": false, "msg": "no room"}
	cooldowns["extract_at"] = now + EXTRACT_COOLDOWN
	c["blood"] = int(c["blood"]) - 1
	if int(c["blood"]) <= 0:
		corpses.erase(corpse_id)
	return {"ok": true, "msg": "drew a blood sack"}


func _has_extractor(inv: Inventory) -> bool:
	for s: Dictionary in inv.slots:
		if s.is_empty():
			continue
		if str(ItemDB.get_def(s["id"]).get("use", "")) == "tool_blood":
			return true
	return false


## Wire form: npcs as [id, x, y, z, health], corpses as [id, x, y, z, blood].
func to_wire() -> Array:
	var out_npcs: Array = []
	for id: int in npcs:
		var p: Vector3 = npcs[id]["pos"]
		out_npcs.append([id, p.x, p.y, p.z, float(npcs[id]["health"])])
	var out_corpses: Array = []
	for id: int in corpses:
		var p: Vector3 = corpses[id]["pos"]
		out_corpses.append([id, p.x, p.y, p.z, int(corpses[id]["blood"])])
	return [out_npcs, out_corpses]
