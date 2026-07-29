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

## Per-axis slide resolution, so walking into a cliff at an angle glides along
## it instead of sticking.
static func step(pos: Vector3, dir: Vector2, sprint: bool, dt: float) -> Vector3:
	var speed := SPRINT_SPEED if sprint else WALK_SPEED
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

	out.y = Terrain.sample_height(out.x, out.z)
	return out


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
					and Terrain.is_walkable(x, z):
				return Vector3(x, Terrain.sample_height(x, z), z)
		r += 6.0
	# Nowhere sandy in range; fall back to anywhere legal.
	return Vector3(near.x, Terrain.sample_height(near.x, near.z), near.z)
