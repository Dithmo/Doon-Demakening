class_name Vitals
extends RefCounted
## Per-player survival state. Server-owned; clients receive a replicated copy
## and never simulate it.
##
## Water is the clock. Everything else in this class exists to make water loss
## depend on decisions the player is making -- where they stand, how fast they
## move, what time it is -- rather than ticking down uniformly.

const MAX := 100.0

## Baseline loss per second before any modifier. Every other constant here is
## expressed as a multiplier on this, so retuning difficulty is one number.
const BASE_DRAIN := 0.12

## Exposure multiplier runs from NIGHT_MULT at full dark to DAY_MULT at zenith.
const NIGHT_MULT := 0.5
const DAY_MULT := 3.0
## Shade does not stop the sun, it blunts it.
const SHADE_RELIEF := 0.35
## Activity multiplier while sprinting. Lives here rather than in Movement
## because it is a survival cost, not a locomotion parameter.
const SPRINT_DRAIN_MULT := 2.2

## Heat builds in the open and sheds in shade or after dark. Heat is the
## warning, dehydration is the killer, so these are paced against BASE_DRAIN:
## full sun pins heat in ~125 s but takes ~280 s to empty a full water bar.
## You get uncomfortable, then alarmed, then dead -- in that order, with time
## to react between each. Shade sheds a full heat bar in ~85 s.
const HEAT_GAIN := 0.8
const HEAT_LOSS := 1.2

## Damage per second while fully dehydrated, and while heat is pinned.
const DEHYDRATION_DAMAGE := 4.0
const HEATSTROKE_DAMAGE := 2.5
## Health only returns when you are not actively dying.
const HEAL_RATE := 1.5

var hydration: float = MAX
var heat: float = 0.0
var health: float = MAX
var alive: bool = true


## Advance one server tick. `exposure` is 0..1 from the clock, `shaded` from the
## terrain, `activity` the movement multiplier, `insulation` the stillsuit's
## contribution (1.0 = none). Returns true if this tick killed the player.
## `heat_gain_mult` is Sun Reader; insulation already carries both the worn
## stillsuit and Night Work. Defaulted so callers and tests written before
## skills existed keep meaning what they meant.
func tick(delta: float, exposure: float, shaded: bool, activity: float,
		insulation: float, heat_gain_mult: float = 1.0) -> bool:
	if not alive:
		return false

	var effective := exposure * (SHADE_RELIEF if shaded else 1.0)
	var env := lerpf(NIGHT_MULT, DAY_MULT, clampf(effective, 0.0, 1.0))
	hydration = maxf(0.0, hydration - BASE_DRAIN * env * activity * insulation * delta)

	# Heat tracks exposure directly, and shade is the only relief available
	# before Phase 3 gives players somewhere to shelter.
	var heat_delta := effective * HEAT_GAIN * heat_gain_mult - HEAT_LOSS * (1.0 - effective)
	heat = clampf(heat + heat_delta * delta, 0.0, MAX)

	var dying := 0.0
	if hydration <= 0.0:
		dying += DEHYDRATION_DAMAGE
	if heat >= MAX:
		dying += HEATSTROKE_DAMAGE

	if dying > 0.0:
		health = maxf(0.0, health - dying * delta)
		if health <= 0.0:
			alive = false
			return true
	else:
		health = minf(MAX, health + HEAL_RATE * delta)
	return false


func drink(amount: float) -> float:
	var before := hydration
	hydration = minf(MAX, hydration + amount)
	# Water cools as well as rehydrates, which is the only reason to drink
	# before you are desperate.
	heat = maxf(0.0, heat - amount * 0.5)
	return hydration - before


func revive() -> void:
	hydration = MAX * 0.5
	heat = 0.0
	health = MAX
	alive = true


## Rough danger read for the HUD, 0 = fine, 1 = about to die.
func severity() -> float:
	return clampf(maxf(1.0 - hydration / MAX, heat / MAX), 0.0, 1.0)


func to_data() -> Dictionary:
	return {"hydration": hydration, "heat": heat, "health": health, "alive": alive}


func from_data(d: Dictionary) -> void:
	hydration = clampf(float(d.get("hydration", MAX)), 0.0, MAX)
	heat = clampf(float(d.get("heat", 0.0)), 0.0, MAX)
	health = clampf(float(d.get("health", MAX)), 0.0, MAX)
	alive = bool(d.get("alive", true))
	if not alive:
		# Never restore a corpse -- a player who logs in dead can do nothing.
		revive()
