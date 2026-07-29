class_name VehicleMotion
extends RefCounted
## The one vehicle movement implementation, run identically on driver and server.
##
## Same contract as Movement, and for the same reason: the driver predicts, the
## server simulates, and the two must produce the same result from the same
## input or the car rubber-bands. So this is kinematic against the heightmap,
## deterministic, and free of the physics engine.
##
## It is *not* the same code as Movement, because a vehicle does not strafe. A
## groundcar turns and accelerates, which is what makes driving one feel like a
## decision rather than walking faster -- you commit to a heading, and getting
## it wrong near an outcrop costs you the time it takes to swing round.

## Speed below which a vehicle is treated as stopped, for threat and for the
## "is it moving" question. Small enough that idling does not count.
const IDLE_SPEED := 0.4

## How fast an ornithopter climbs to and descends from cruise, in metres/second.
const CLIMB_RATE := 14.0

## Ground clearance for a driving vehicle. Keeps it visibly on the surface
## rather than buried in it.
const RIDE_HEIGHT := 0.6


## Advance one vehicle. Returns the new {pos, heading, speed, altitude}.
##
## `steer` is -1..1 (left/right) and `throttle` is -1..1 (reverse/forward),
## which is the whole of a vehicle's input -- deliberately narrower than the
## player's two-axis direction, because that difference is the handling.
static func step(def: Dictionary, pos: Vector3, heading: float, speed: float,
		altitude: float, steer: float, throttle: float, dt: float,
		fuel: float) -> Dictionary:
	var top: float = float(def.get("top_speed", 12.0))
	var accel: float = float(def.get("accel", 6.0))
	var turn: float = float(def.get("turn_rate", 1.6))
	var flies: bool = bool(def.get("flies", false))

	# Out of fuel is not "slower", it is "coasting to a halt". A vehicle you
	# cannot refuel is a walk home, and that is the point of carrying spares.
	var dry := fuel <= 0.0
	var want: float = 0.0 if dry else clampf(throttle, -1.0, 1.0) * top
	# Reverse is deliberately feeble; a groundcar is not a forklift.
	if want < 0.0:
		want *= 0.35
	speed = move_toward(speed, want, accel * dt * (2.0 if dry else 1.0))

	# Steering authority scales with speed, so a stationary vehicle cannot spin
	# on the spot and a fast one turns wide.
	var authority: float = clampf(absf(speed) / maxf(top, 0.001), 0.0, 1.0)
	heading += clampf(steer, -1.0, 1.0) * turn * authority * dt * signf(speed if speed != 0.0 else 1.0)
	heading = wrapf(heading, -PI, PI)

	var fwd := Vector2(sin(heading), -cos(heading))
	var delta := fwd * speed * dt
	var nx := pos.x + delta.x
	var nz := pos.z + delta.y

	var out := Vector3(pos.x, 0.0, pos.z)
	if flies:
		# Airborne, the mask does not apply. That is the whole reason to own
		# one: an ornithopter crosses the ground the traversability mask says
		# you cannot, and nothing under the sand can hear it.
		out.x = clampf(nx, 0.0, Terrain.size_m.x)
		out.z = clampf(nz, 0.0, Terrain.size_m.y)
	else:
		# Per-axis like the player, so clipping an outcrop slides rather than
		# stopping dead.
		if Terrain.is_walkable(nx, out.z):
			out.x = nx
		else:
			speed *= 0.4
		if Terrain.is_walkable(out.x, nz):
			out.z = nz
		else:
			speed *= 0.4

	var ground := Terrain.sample_height(out.x, out.z)
	var target_alt := 0.0
	if flies:
		# Under power it climbs to cruise; off the throttle it settles. Landing
		# is just throttle off, which keeps the control surface to two axes.
		var cruise: float = float(def.get("cruise_altitude", 30.0))
		target_alt = cruise if absf(throttle) > 0.05 and not dry else 0.0
		altitude = move_toward(altitude, target_alt, CLIMB_RATE * dt)
	else:
		altitude = 0.0
	out.y = ground + altitude + RIDE_HEIGHT

	return {"pos": out, "heading": heading, "speed": speed, "altitude": altitude}


## Fuel burned covering `distance` metres.
static func burn(def: Dictionary, distance: float) -> float:
	return absf(distance) * float(def.get("fuel_per_metre", 0.01))


## How loudly this vehicle is calling the worm right now.
##
## Scaled by how fast it is actually going rather than by whether it is
## occupied: a parked groundcar is furniture. An ornithopter clear of the
## ground contributes nothing at all, which is exactly what it is for.
static func threat_multiplier(def: Dictionary, speed: float, altitude: float) -> float:
	if bool(def.get("flies", false)) and altitude > 2.0:
		return 0.0
	var top: float = maxf(float(def.get("top_speed", 12.0)), 0.001)
	var fraction: float = clampf(absf(speed) / top, 0.0, 1.0)
	return float(def.get("worm_threat_mult", 1.0)) * fraction


static func is_moving(speed: float) -> bool:
	return absf(speed) > IDLE_SPEED
