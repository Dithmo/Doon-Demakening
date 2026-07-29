class_name Combat
extends RefCounted
## Damage resolution, and the Holtzman shield rule.
##
## The rule is the whole reason combat here is not generic: a shield turns a
## fast blade and a dart, but a *slow* blade passes straight through it. So a
## shielded opponent is not invulnerable, they are a puzzle -- you either carry
## something slow, or you make them drop the shield.
##
## The cost is the other half of it. A running shield is a beacon to a worm
## (`worm_threat_mult` on the item), so the thing that keeps you alive in a
## fight is the thing that gets you eaten crossing open sand. That trade is the
## point; do not let either side of it quietly stop mattering.

## How long after a block before the shield can turn another blow. Without
## this, a shield would make fast weapons useless rather than costly.
const SHIELD_RECOVERY := 0.6
## Seconds between swings, per attacker.
const SWING_COOLDOWN := 0.9
## A slow blade telegraphs. That window is what makes it a choice under
## pressure rather than a strictly better weapon.
const SLOW_WINDUP := 1.4


## What the attacker is holding: {damage, attack, reach}. Bare hands if nothing
## equipped, so a disarmed player is still dangerous, barely.
static func weapon_of(equipped: Dictionary) -> Dictionary:
	for slot: int in equipped:
		var def := ItemDB.get_def(str(equipped[slot]))
		if float(def.get("damage", 0.0)) > 0.0:
			return {
				"id": str(def.get("id", "")),
				"name": str(def.get("name", "?")),
				"damage": float(def["damage"]),
				"attack": str(def.get("attack", "fast")),
				"reach": float(def.get("reach", 2.0)),
			}
	return {"id": "", "name": "fists", "damage": 5.0, "attack": "fast", "reach": 1.8}


## True when the defender has a shield running.
static func has_shield(equipped: Dictionary) -> bool:
	for slot: int in equipped:
		if bool(ItemDB.get_def(str(equipped[slot])).get("shield", false)):
			return true
	return false


## Worm-threat multiplier from what the defender is wearing. A running shield
## is loud.
static func threat_multiplier(equipped: Dictionary) -> float:
	var mult := 1.0
	for slot: int in equipped:
		mult *= float(ItemDB.get_def(str(equipped[slot])).get("worm_threat_mult", 1.0))
	return mult


## Resolve one attack. Returns {ok, msg, damage, blocked}.
##
## Range is measured against the server's own positions, and the cooldown lives
## in the attacker's own state -- neither is taken from the client.
static func strike(attacker_pos: Vector3, attacker_equipped: Dictionary,
		target_pos: Vector3, target_equipped: Dictionary,
		cooldowns: Dictionary, now: float) -> Dictionary:
	var weapon := weapon_of(attacker_equipped)

	if now < float(cooldowns.get("swing_at", 0.0)):
		return {"ok": false, "msg": "", "damage": 0.0, "blocked": false}
	if attacker_pos.distance_to(target_pos) > float(weapon["reach"]):
		return {"ok": false, "msg": "out of reach", "damage": 0.0, "blocked": false}

	var windup := SLOW_WINDUP if str(weapon["attack"]) == "slow" else 0.0
	cooldowns["swing_at"] = now + SWING_COOLDOWN + windup

	# The rule: a shield turns anything fast, and nothing slow.
	if has_shield(target_equipped) and str(weapon["attack"]) != "slow":
		if now >= float(cooldowns.get("their_shield_ready", 0.0)):
			cooldowns["their_shield_ready"] = now + SHIELD_RECOVERY
			return {"ok": true, "msg": "%s turned by a shield" % weapon["name"],
				"damage": 0.0, "blocked": true}

	return {"ok": true, "msg": "%s hits for %.0f" % [weapon["name"], weapon["damage"]],
		"damage": float(weapon["damage"]), "blocked": false}
