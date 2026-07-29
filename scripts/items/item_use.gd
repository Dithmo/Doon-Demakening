class_name ItemUse
extends RefCounted
## Server-side dispatch for the `use` hook in the item database.
##
## Dispatch is on the hook name, never on the item id, so a new consumable is a
## data change rather than a code change. Runs only on the authority -- the
## client asks, it does not decide.

## Seconds between dew harvests. Long enough that a night's water is a route
## you plan, not a button you hold.
const DEW_COOLDOWN := 12.0
const DEW_MIN_YIELD := 1
const DEW_MAX_YIELD := 4


## Returns {ok: bool, msg: String, changed: bool}.
## `changed` means inventory or equipment moved and needs replicating.
static func apply(slot_index: int, inv: Inventory, vit: Vitals,
		equipped: Dictionary, cooldowns: Dictionary) -> Dictionary:
	if slot_index < 0 or slot_index >= inv.slots.size():
		return _fail("no such slot")
	var stack: Dictionary = inv.slots[slot_index]
	if stack.is_empty():
		return _fail("empty slot")

	var def := ItemDB.get_def(stack["id"])
	var hook := str(def.get("use", ""))
	if hook.is_empty():
		return _fail("%s has no use" % def.get("name", stack["id"]))

	match hook:
		"hydrate": return _hydrate(slot_index, stack, def, inv, vit)
		"tool_dew": return _harvest_dew(def, inv, cooldowns)
		"equip": return _equip(slot_index, stack, def, inv, equipped)
		"tool_gather": return _fail("nothing here to cut")
	return _fail("unknown use '%s'" % hook)


static func _hydrate(slot_index: int, stack: Dictionary, def: Dictionary,
		inv: Inventory, vit: Vitals) -> Dictionary:
	if vit.hydration >= Vitals.MAX - 0.01:
		return _fail("not thirsty")
	var gained := vit.drink(float(def.get("use_value", 0.0)))
	# Take exactly one from the stack the player pointed at, rather than
	# Inventory.remove(), which could pull from a different slot.
	var left := int(stack["count"]) - 1
	inv.slots[slot_index] = {} if left <= 0 else {"id": stack["id"], "count": left}
	return {"ok": true, "changed": true,
		"msg": "drank %s (+%.0f water)" % [def.get("name", "?"), gained]}


## Dew condenses overnight and is richest just before sunrise. That single rule
## is what gives Phase 1 a schedule: the best water in the game is available at
## the moment furthest from safety.
static func _harvest_dew(def: Dictionary, inv: Inventory,
		cooldowns: Dictionary) -> Dictionary:
	if not Clock.is_night():
		return _fail("dew only condenses after dark")

	var now := Time.get_ticks_msec() / 1000.0
	var ready_at := float(cooldowns.get("dew", 0.0))
	if now < ready_at:
		return _fail("harvester recharging (%.0fs)" % (ready_at - now))
	cooldowns["dew"] = now + DEW_COOLDOWN

	var amount := int(round(lerpf(float(DEW_MIN_YIELD), float(DEW_MAX_YIELD),
		Clock.night_progress())))
	var leftover := inv.add("water", amount)
	if leftover >= amount:
		return _fail("no room for water")
	return {"ok": true, "changed": true,
		"msg": "harvested %d water" % (amount - leftover)}


static func _equip(slot_index: int, stack: Dictionary, def: Dictionary,
		inv: Inventory, equipped: Dictionary) -> Dictionary:
	var slot: int = int(def.get("slot", ItemDB.Slot.NONE))
	if slot == ItemDB.Slot.NONE:
		return _fail("%s cannot be worn" % def.get("name", "?"))

	var previous: String = str(equipped.get(slot, ""))
	inv.slots[slot_index] = {}
	equipped[slot] = stack["id"]
	# Put whatever came off back in the bag; if it will not fit, refuse the
	# swap rather than destroying it.
	if not previous.is_empty():
		if inv.add(previous, 1) > 0:
			equipped[slot] = previous
			inv.slots[slot_index] = stack
			return _fail("no room to stow %s" % ItemDB.display_name(previous))
	return {"ok": true, "changed": true,
		"msg": "equipped %s" % def.get("name", "?")}


## Water loss multiplier from what the player is wearing. 1.0 is bare skin.
static func insulation(equipped: Dictionary) -> float:
	var mult := 1.0
	for slot: int in equipped:
		var def := ItemDB.get_def(str(equipped[slot]))
		if str(def.get("use", "")) == "equip":
			var v := float(def.get("use_value", 0.0))
			# Garments store their multiplier in use_value; weapons reuse the
			# field for damage, so only sub-1 values count as insulation.
			if v > 0.0 and v < 1.0:
				mult *= v
	return mult


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "changed": false, "msg": msg}
