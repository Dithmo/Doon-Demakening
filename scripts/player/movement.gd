class_name Movement
extends RefCounted
## The one movement implementation, run identically on client and server.
##
## Prediction only works if both sides produce the same result from the same
## input. That rules out running the physics engine on one side and not the
## other, so locomotion is kinematic against the heightmap instead of
## CharacterBody3D: sample ground, walk on it, refuse to enter CLIFF cells.
##
## This is a real simplification, and an appropriate one for open desert. It
## does not handle player-built geometry -- Phase 3 layers collision on top
## rather than replacing this, so predicted locomotion stays deterministic.

const WALK_SPEED := 4.4
const SPRINT_SPEED := 7.6

## Vertical motion. Cliffs used to be walls: `is_walkable` refused them and that
## was the end of it, so a mesa was a hole in the map you routed around and rock
## -- the one surface a worm cannot reach through -- was only reachable where the
## terrain happened to ramp. Climbing turns every cliff into a question of
## whether you have the stamina, which is what makes rock worth the trip.
const GRAVITY := 22.0
const JUMP_SPEED := 6.2
const CLIMB_SPEED := 1.9
## Hauling yourself up costs stamina per second, and running out drops you.
const CLIMB_STAMINA_PER_S := 11.0
## How far above the ledge you must reach before you can pull onto it.
const LEDGE_CLEARANCE := 0.35
## You cannot start a climb from mid-air, and you cannot climb what you are not
## touching.
const REACH := 1.4
## Landing faster than this hurts, and every metre per second beyond it hurts
## more. A jump on the flat lands at about 6 m/s, so ordinary movement is free.
const SAFE_LANDING_SPEED := 11.0
const FALL_DAMAGE_PER_MS := 3.4


## The vertical state a player carries between steps. Both sides keep one and
## advance it with the same function, which is the whole basis of prediction --
## `step` may not read anything that is not in here or in the terrain.
static func new_motion() -> Dictionary:
	return {"vy": 0.0, "grounded": true, "climbing": false, "impact": 0.0}


## Per-axis slide resolution, so walking into a cliff at an angle glides along
## it instead of sticking.
##
## `motion` is advanced in place. `vit` may be null -- the bots and the older
## tests do not carry vitals -- in which case effort is free, which is exactly
## how this function behaved before stamina existed.
static func step(pos: Vector3, dir: Vector2, sprint: bool, dt: float,
		motion: Dictionary = {}, vit: Vitals = null,
		jump: bool = false, climb: bool = false) -> Vector3:
	if motion.is_empty():
		# A caller that does not track vertical state gets the old ground-hugging
		# behaviour rather than a surprise: no gravity, no climbing, no falling.
		return _walk(pos, dir, sprint, dt, vit)

	var out := _walk_or_climb(pos, dir, sprint, dt, motion, vit, climb)
	var ground := Terrain.sample_height(out.x, out.z)

	if bool(motion["climbing"]):
		# On a wall, gravity is held off and the climb itself sets the height.
		motion["vy"] = 0.0
		motion["grounded"] = false
		out.y = maxf(out.y, ground)
		motion["impact"] = 0.0
		return out

	if jump and bool(motion["grounded"]) and _afford(vit, Vitals.JUMP_STAMINA):
		motion["vy"] = JUMP_SPEED
		motion["grounded"] = false

	if not bool(motion["grounded"]) or out.y > ground + 0.01:
		motion["vy"] -= GRAVITY * dt
		out.y += motion["vy"] * dt

	motion["impact"] = 0.0
	if out.y <= ground:
		# Landing. The speed is handed back rather than turned into damage here:
		# Movement runs on both sides, and only the server may hurt anyone.
		if not bool(motion["grounded"]):
			motion["impact"] = maxf(0.0, -float(motion["vy"]))
		out.y = ground
		motion["vy"] = 0.0
		motion["grounded"] = true
	else:
		motion["grounded"] = false
	return out


## Ground movement with no vertical state, unchanged from Phase 0.
static func _walk(pos: Vector3, dir: Vector2, sprint: bool, dt: float,
		vit: Vitals) -> Vector3:
	var out := _slide(pos, dir, sprint, dt, vit)
	out.y = Terrain.sample_height(out.x, out.z)
	return out


## Horizontal resolution, plus the decision to go *up* a cliff instead of
## sliding along it.
static func _walk_or_climb(pos: Vector3, dir: Vector2, sprint: bool, dt: float,
		motion: Dictionary, vit: Vitals, climb: bool) -> Vector3:
	var speed := _speed(sprint, dt, vit)
	var want := dir
	if want.length_squared() > 1.0:
		want = want.normalized()
	var delta := want * speed * dt
	var nx := pos.x + delta.x
	var nz := pos.z + delta.y
	var out := pos

	var blocked_x := not Terrain.is_walkable(nx, pos.z)
	var blocked_z := not Terrain.is_walkable(pos.x, nz)
	var pressing := want.length_squared() > 0.0001

	# Climbing only engages when you are held up by something you are pushing
	# into. Everything else is ordinary sliding.
	if climb and pressing and (blocked_x or blocked_z):
		var target := Vector3(nx if blocked_x else pos.x, 0.0, nz if blocked_z else pos.z)
		var top := Terrain.sample_height(target.x, target.z)
		var here := Terrain.sample_height(pos.x, pos.z)
		var on_wall := pos.y >= here - REACH and top > pos.y - LEDGE_CLEARANCE
		if on_wall and _afford(vit, CLIMB_STAMINA_PER_S * dt):
			motion["climbing"] = true
			out.y = pos.y + CLIMB_SPEED * dt
			if out.y >= top + LEDGE_CLEARANCE:
				# Over the lip: take the horizontal move that was refused.
				out.x = target.x if blocked_x else out.x
				out.z = target.z if blocked_z else out.z
				motion["climbing"] = false
			return out
	motion["climbing"] = false

	if Terrain.is_walkable(nx, pos.z):
		out.x = nx
	if Terrain.is_walkable(out.x, nz):
		out.z = nz
	return out


static func _slide(pos: Vector3, dir: Vector2, sprint: bool, dt: float,
		vit: Vitals) -> Vector3:
	var speed := _speed(sprint, dt, vit)
	if dir.length_squared() > 1.0:
		dir = dir.normalized()
	var delta := dir * speed * dt
	var nx := pos.x + delta.x
	var nz := pos.z + delta.y
	var out := Vector3(pos.x, 0.0, pos.z)
	if Terrain.is_walkable(nx, out.z):
		out.x = nx
	if Terrain.is_walkable(out.x, nz):
		out.z = nz
	return out


## Sprinting costs stamina, and an empty player simply walks. Charged per
## second so the cost does not depend on the tick rate.
static func _speed(sprint: bool, dt: float, vit: Vitals) -> float:
	if not sprint:
		return WALK_SPEED
	if vit != null and not vit.spend_stamina(Vitals.SPRINT_STAMINA * dt):
		return WALK_SPEED
	return SPRINT_SPEED


static func _afford(vit: Vitals, cost: float) -> bool:
	return true if vit == null else vit.spend_stamina(cost)


## Snap a spawn point to open sand. Spirals outward rather than
## rejection-sampling so it terminates on dense-cliff regions too.
##
## SAND specifically, not merely walkable: a rock plateau is walkable but is
## usually ringed by CLIFF, so spawning on one strands the player on top of it.
static func find_spawn(near: Vector3, max_radius: float = 160.0) -> Vector3:
	if Terrain.sample_surface(near.x, near.z) == Terrain.Surface.SAND:
		return Vector3(near.x, Terrain.sample_height(near.x, near.z), near.z)
	var r := 4.0
	while r <= max_radius:
		var steps := maxi(12, int(r))
		for i in range(steps):
			var a := TAU * float(i) / float(steps)
			var x := near.x + cos(a) * r
			var z := near.z + sin(a) * r
			if Terrain.sample_surface(x, z) == Terrain.Surface.SAND \
					and Terrain.is_reachable(x, z):
				return Vector3(x, Terrain.sample_height(x, z), z)
		r += 6.0
	# Nowhere sandy in range; fall back to anywhere legal.
	return Vector3(near.x, Terrain.sample_height(near.x, near.z), near.z)
