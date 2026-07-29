extends Node
## Time of day. Drives heat, shade and dew harvesting.
##
## The server owns the clock (docs/game-plan.md): if it drifted per client, two
## players would disagree about whether it is safe to be outside, and the whole
## survival loop would desync.
##
## Both sides advance it locally and the server resyncs clients periodically.
## That is a deliberate exception to "never read local state" -- time is
## monotonic and self-correcting, so extrapolating between syncs is safe in a
## way that extrapolating an inventory is not. Nothing is *decided* client-side;
## the server recomputes drain and harvest yields against its own clock.

## Real seconds per in-game day. Short on purpose: a full cycle should fit
## inside a play session so night actually arrives while you are still out.
const DEFAULT_DAY_SECONDS := 1200.0

const DAWN := 0.25
const NOON := 0.50
const DUSK := 0.75

var day_seconds: float = DEFAULT_DAY_SECONDS
## 0 = midnight, 0.25 = dawn, 0.5 = noon, 0.75 = dusk.
var time_of_day: float = 0.30
var day_number: int = 0


func _ready() -> void:
	day_seconds = maxf(10.0, Args.number("--day-seconds", DEFAULT_DAY_SECONDS))
	time_of_day = fposmod(Args.number("--start-time", 0.30), 1.0)


func _process(delta: float) -> void:
	time_of_day += delta / day_seconds
	while time_of_day >= 1.0:
		time_of_day -= 1.0
		day_number += 1


## Client-side correction from the authority.
func sync_from_server(t: float, day: int) -> void:
	time_of_day = t
	day_number = day


## Height of the sun above the horizon, -1..1. Negative means night.
func sun_altitude() -> float:
	return sin((time_of_day - DAWN) * TAU)


## Unit vector pointing *towards* the sun. Used both for lighting and for the
## terrain shade test, so they can never disagree about where the sun is.
func sun_to() -> Vector3:
	var alt := sun_altitude()
	var horizontal := sqrt(maxf(0.0, 1.0 - alt * alt))
	# Rises due east at dawn, passes south at noon, sets due west at dusk.
	var az := PI * (time_of_day - DAWN) / (DUSK - DAWN)
	return Vector3(cos(az) * horizontal, alt, sin(az) * horizontal)


func is_night() -> bool:
	return sun_altitude() <= 0.0


## 0 at night, rising to 1 with the sun. The single environmental input to heat
## and water loss.
func exposure() -> float:
	return maxf(0.0, sun_altitude())


## Fraction of the night already elapsed, 0 at dusk to 1 at dawn. Dew condenses
## through the night and is richest just before sunrise, so this *is* the
## harvest yield curve.
func night_progress() -> float:
	if not is_night():
		return 0.0
	var to_dawn := DAWN - time_of_day if time_of_day < DAWN else (1.0 + DAWN) - time_of_day
	var night_length := 1.0 - (DUSK - DAWN)
	return clampf(1.0 - to_dawn / night_length, 0.0, 1.0)


func phase_name() -> String:
	var alt := sun_altitude()
	if alt <= -0.2:
		return "NIGHT"
	if alt <= 0.0:
		return "DAWN" if time_of_day < NOON else "DUSK"
	if alt < 0.35:
		return "MORNING" if time_of_day < NOON else "EVENING"
	return "MIDDAY"


## 24h clock, for display only.
func hhmm() -> String:
	var mins := int(round(time_of_day * 1440.0)) % 1440
	return "%02d:%02d" % [mins / 60, mins % 60]
