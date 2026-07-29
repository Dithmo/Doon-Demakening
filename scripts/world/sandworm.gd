class_name Sandworm
extends RefCounted
## One shared sandworm, and the threat that calls it.
##
## This is what the traversability mask has existed for since Phase 0. Sand is
## exposure; rock is refuge. The worm reads the same mask the terrain pipeline
## produces, so the safety a player can see in the ground is exactly the safety
## the server enforces.
##
## Server-owned throughout: threat accrues here, the worm decides here, and the
## client is told what happened. A client that could edit its own threat could
## simply never be hunted.
##
## The shape of the encounter is deliberate:
##   threat builds while you move on open sand, faster if you sprint or run a
##   shield; standing still bleeds it off, and rock bleeds it off fast
##   -> the worm wakes and comes, and it is faster than a sprint
##   -> it surfaces, which is a warning with enough seconds in it to reach rock
##   -> it strikes, and anything still on sand inside the radius is gone
##
## Being faster than a sprinting player is the whole design: you cannot outrun
## it, so the answer is never "run further", it is "get off the sand". A worm
## you could outrun would make the mask decorative.

enum State { DORMANT, ALERTED, SURFACING, STRIKING, SATED }

## Threat needed to wake it, and the ceiling threat is clamped to.
const WAKE_THRESHOLD := 25.0
const MAX_THREAT := 100.0

## Per-second threat while on sand.
const THREAT_MOVING := 1.6
const THREAT_SPRINTING := 4.0
## Standing still on sand is the classic answer, so it has to actually work.
const THREAT_STILL := -2.5
## Rock is refuge: threat drains fast and the worm cannot strike you on it.
const THREAT_ON_ROCK := -8.0

## Metres per second. Above Movement.SPRINT_SPEED on purpose.
const SPEED := 11.0
## Seconds between surfacing and striking. This is the player's window, and it
## is the single most important number in the phase: too short and the worm is
## unfair, too long and it is scenery.
const WARNING_SECONDS := 5.0
const STRIKE_RADIUS := 11.0
## How long it stays down afterwards.
const SATED_SECONDS := 20.0
## Close enough to the target to begin surfacing.
const ARRIVAL_RANGE := 8.0

var state: State = State.DORMANT
var pos: Vector3 = Vector3.ZERO
## Peer id, or 0 when the worm is heading for a thumper instead.
var target_peer: int = 0
var target_pos: Vector3 = Vector3.ZERO
var timer: float = 0.0
## peer id -> accumulated threat
var threat: Dictionary = {}


func threat_of(peer: int) -> float:
	return float(threat.get(peer, 0.0))


## Accrue threat for one player. `moving` and `sprinting` come from the input
## the server already applied, not from a client claim.
func accrue(peer: int, delta: float, on_sand: bool, moving: bool,
		sprinting: bool, equip_mult: float) -> void:
	var rate: float
	if not on_sand:
		rate = THREAT_ON_ROCK
	elif sprinting and moving:
		rate = THREAT_SPRINTING * equip_mult
	elif moving:
		rate = THREAT_MOVING * equip_mult
	else:
		rate = THREAT_STILL
	threat[peer] = clampf(threat_of(peer) + rate * delta, 0.0, MAX_THREAT)


func forget(peer: int) -> void:
	threat.erase(peer)


## Advance the worm. `players` is peer -> {pos, on_sand, alive}; `lures` is a
## list of {pos, threat} from deployed thumpers.
##
## Returns a list of events for the caller to log and replicate:
## {kind: "wake"|"surface"|"strike"|"lost"|"sated", ...}
func tick(delta: float, players: Dictionary, lures: Array) -> Array:
	var events: Array = []

	match state:
		State.DORMANT:
			var best := _loudest(players, lures)
			if best.is_empty():
				return events
			if float(best["threat"]) >= WAKE_THRESHOLD:
				state = State.ALERTED
				target_peer = int(best["peer"])
				target_pos = best["pos"]
				# Comes in from off the edge of whatever it was called to.
				pos = target_pos + Vector3(60.0, 0.0, 60.0)
				events.append({"kind": "wake", "peer": target_peer, "pos": target_pos})

		State.ALERTED:
			var best := _loudest(players, lures)
			if best.is_empty() or float(best["threat"]) < WAKE_THRESHOLD * 0.4:
				# Everyone went quiet or made it to rock.
				state = State.SATED
				timer = SATED_SECONDS
				events.append({"kind": "lost"})
				return events
			# It re-targets: a thumper thrown mid-approach really does pull it.
			target_peer = int(best["peer"])
			target_pos = best["pos"]
			pos = pos.move_toward(target_pos, SPEED * delta)
			if pos.distance_to(target_pos) <= ARRIVAL_RANGE:
				state = State.SURFACING
				timer = WARNING_SECONDS
				events.append({"kind": "surface", "peer": target_peer, "pos": target_pos})

		State.SURFACING:
			timer -= delta
			# Keep tracking during the warning, but do not chase a target that
			# has already reached rock -- reaching rock has to actually save you.
			var t: Dictionary = players.get(target_peer, {})
			if target_peer != 0 and not t.is_empty() and not bool(t["on_sand"]):
				state = State.SATED
				timer = SATED_SECONDS
				events.append({"kind": "lost"})
				return events
			if timer <= 0.0:
				state = State.STRIKING
				var caught: Array = []
				for peer: int in players:
					var p: Dictionary = players[peer]
					if not bool(p["alive"]) or not bool(p["on_sand"]):
						continue
					if (p["pos"] as Vector3).distance_to(target_pos) <= STRIKE_RADIUS:
						caught.append(peer)
						threat[peer] = 0.0
				events.append({"kind": "strike", "pos": target_pos, "caught": caught})
				state = State.SATED
				timer = SATED_SECONDS

		State.SATED:
			timer -= delta
			if timer <= 0.0:
				state = State.DORMANT
				target_peer = 0
				events.append({"kind": "sated"})

	return events


## Whatever is making the most noise: a player, or a thumper pounding away.
## Thumpers are the point of the item -- they let a player buy safety by giving
## the worm somewhere better to be.
func _loudest(players: Dictionary, lures: Array) -> Dictionary:
	var best: Dictionary = {}
	var loudest := 0.0
	for peer: int in players:
		var p: Dictionary = players[peer]
		if not bool(p["alive"]) or not bool(p["on_sand"]):
			continue
		var t := threat_of(peer)
		if t > loudest:
			loudest = t
			best = {"peer": peer, "pos": p["pos"], "threat": t}
	for lure: Dictionary in lures:
		var t := float(lure["threat"])
		if t > loudest:
			loudest = t
			best = {"peer": 0, "pos": lure["pos"], "threat": t}
	return best


## What a client needs to draw and fear it.
func to_wire() -> Array:
	return [int(state), pos.x, pos.y, pos.z, target_pos.x, target_pos.z,
		maxf(0.0, timer)]
