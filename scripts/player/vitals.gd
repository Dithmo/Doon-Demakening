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

## Stamina gates effort: sprinting, jumping and hauling yourself up a rock face
## all spend it, and it only comes back when you ease off. Water is still the
## clock -- stamina is the second-to-second budget inside it, and the reason a
## cliff is a decision rather than a ramp. The Combat specialization raises the
## ceiling, which is why `max_stamina` is a variable and not a constant.
const STAMINA_MAX := 100.0
const STAMINA_REGEN := 14.0
## Delay before regeneration restarts, so spending is not free the instant you
## stop. Without it, tapping sprint costs nothing at all.
const STAMINA_REGEN_DELAY := 1.1
const SPRINT_STAMINA := 9.0
## A jump is a lump cost; climbing is a rate. Both are charged by Movement, the
## one place that knows what the player actually managed to do.
const JUMP_STAMINA := 12.0
const CLIMB_STAMINA := 16.0
## Fraction of the bar you must recover after bottoming out before effort is
## available again.
const EXHAUST_RECOVER := 0.30
## Exhaustion is not damage -- it is being unable to run away, which on open
## sand with a worm listening is quite bad enough.

var hydration: float = MAX
var heat: float = 0.0
var health: float = MAX
var alive: bool = true
var stamina: float = STAMINA_MAX
var max_stamina: float = STAMINA_MAX
var _regen_hold: float = 0.0
## True once you have run the bar to nothing, until it comes back far enough
## to be worth anything. See spend_stamina.
var _exhausted: bool = false


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

	# Stamina recovers only after a pause, and thirst caps how much of it you
	# can get back: a dry player cannot keep sprinting, which is the same rule
	# the whole game runs on expressed one layer down.
	# The hold is spent out of this tick and the remainder regenerates, rather
	# than the whole tick going to one or the other: with a single `else` a
	# three-second tick consumed the one-second delay and recovered nothing,
	# which made recovery depend on the tick rate.
	var spare := delta
	if _regen_hold > 0.0:
		var used := minf(_regen_hold, spare)
		_regen_hold -= used
		spare -= used
	if spare > 0.0:
		var ceiling := max_stamina * clampf(0.35 + 0.65 * (hydration / MAX), 0.0, 1.0)
		stamina = minf(ceiling, stamina + STAMINA_REGEN * spare)

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


## Spend stamina if there is enough. Returns false and spends nothing when
## there is not, so the caller can refuse the sprint rather than half-do it.
## Called from Movement, which runs identically on both sides -- so this has to
## be a pure function of the state both sides hold, with no clock of its own.
func spend_stamina(amount: float) -> bool:
	if amount <= 0.0:
		return true
	# Once you have run yourself out you have to get some of it back before you
	# can push again. Without this an exhausted player holding sprint spends
	# every point the instant it arrives and never accumulates any -- they get a
	# tick of running per second and no recovery, which is neither a sprint nor
	# a rest. The threshold turns it into a proper cycle: run, blow up, walk it
	# off, run again.
	if _exhausted:
		if stamina < max_stamina * EXHAUST_RECOVER:
			return false
		_exhausted = false
	if stamina < amount:
		# A refused spend must not restart the hold, or recovery never begins.
		_exhausted = true
		return false
	stamina -= amount
	_regen_hold = STAMINA_REGEN_DELAY
	return true


func revive() -> void:
	hydration = MAX * 0.5
	heat = 0.0
	health = MAX
	alive = true
	stamina = max_stamina
	_regen_hold = 0.0
	_exhausted = false


## Rough danger read for the HUD, 0 = fine, 1 = about to die.
func severity() -> float:
	return clampf(maxf(1.0 - hydration / MAX, heat / MAX), 0.0, 1.0)


func to_data() -> Dictionary:
	return {"hydration": hydration, "heat": heat, "health": health, "alive": alive,
		"stamina": stamina, "max_stamina": max_stamina}


func from_data(d: Dictionary) -> void:
	hydration = clampf(float(d.get("hydration", MAX)), 0.0, MAX)
	heat = clampf(float(d.get("heat", 0.0)), 0.0, MAX)
	health = clampf(float(d.get("health", MAX)), 0.0, MAX)
	max_stamina = maxf(1.0, float(d.get("max_stamina", STAMINA_MAX)))
	stamina = clampf(float(d.get("stamina", max_stamina)), 0.0, max_stamina)
	alive = bool(d.get("alive", true))
	if not alive:
		# Never restore a corpse -- a player who logs in dead can do nothing.
		revive()
