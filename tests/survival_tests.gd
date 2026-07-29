extends RefCounted
## Unit tests for the survival rules.
##
##   godot --headless -- --run-tests
##
## Run as a normal project launch rather than via --script: GDScript resolves
## autoload names at compile time, and --script does not register them, so
## anything touching Clock or ItemDB fails to compile there.
##
## The integration harness (tools/test_phase1.py) covers what this cannot:
## replication, validation across the wire, and persistence.

var _failures: Array = []


func _check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		_failures.append(msg)


func _near(a: float, b: float, eps: float = 0.001) -> bool:
	return absf(a - b) <= eps


## Returns the number of failures.
func run() -> int:
	print("\n=== Clock astronomy ===")
	_test_clock()
	print("\n=== Vitals ===")
	_test_vitals()
	print("\n=== Item use ===")
	_test_item_use()
	print("\n=== Resource nodes ===")
	_test_nodes()
	print("\n=== Stations and crafting ===")
	_test_crafting()

	print()
	if _failures.is_empty():
		print("survival rules: PASS")
	else:
		print("FAILURES:\n  " + "\n  ".join(_failures))
	return _failures.size()


func _test_item_use() -> void:
	# Drinking must take exactly one from the slot the player pointed at.
	var inv := Inventory.new()
	var vit := Vitals.new()
	vit.hydration = 20.0
	inv.add("water", 3)
	inv.add("plant_fiber", 5)
	var r := ItemUse.apply(0, inv, vit, {}, {})
	_check(r["ok"], "drinking water succeeds")
	_check(inv.count_of("water") == 2, "drinking consumes exactly one water")
	_check(vit.hydration > 20.0, "drinking restores water")

	# A full player should not waste a flask.
	var full := Vitals.new()
	var r2 := ItemUse.apply(0, inv, full, {}, {})
	_check(not r2["ok"] and inv.count_of("water") == 2,
		"drinking at full is refused and consumes nothing")

	# Non-consumables and empty slots are refused, not crashed on.
	_check(not ItemUse.apply(1, inv, vit, {}, {})["ok"], "plain materials have no use")
	_check(not ItemUse.apply(20, inv, vit, {}, {})["ok"], "an empty slot is refused")
	_check(not ItemUse.apply(-1, inv, vit, {}, {})["ok"], "a bogus slot index is refused")

	# Dew: the rule is time of day, enforced here rather than by the client.
	var dew := Inventory.new()
	dew.add("dew_harvester", 1)
	Clock.time_of_day = 0.5
	_check(not ItemUse.apply(0, dew, vit, {}, {})["ok"], "no dew at midday")
	Clock.time_of_day = 0.24
	var cd: Dictionary = {}
	var night := ItemUse.apply(0, dew, vit, {}, cd)
	_check(night["ok"], "dew harvests just before dawn")
	_check(dew.count_of("water") > 0, "harvesting yields water")
	_check(dew.count_of("dew_harvester") == 1, "the harvester is not consumed")
	_check(not ItemUse.apply(0, dew, vit, {}, cd)["ok"], "the harvester has a cooldown")

	# Dew is richer nearer dawn -- the reason to stay out.
	Clock.time_of_day = 0.76
	var early := Inventory.new()
	early.add("dew_harvester", 1)
	ItemUse.apply(0, early, vit, {}, {})
	Clock.time_of_day = 0.24
	var late := Inventory.new()
	late.add("dew_harvester", 1)
	ItemUse.apply(0, late, vit, {}, {})
	_check(late.count_of("water") > early.count_of("water"),
		"dew is richer at dawn than at dusk")

	# Equipment feeds straight back into water loss.
	var wardrobe := Inventory.new()
	wardrobe.add("stillsuit", 1)
	var worn: Dictionary = {}
	_check(ItemUse.apply(0, wardrobe, vit, worn, {})["ok"], "a stillsuit can be worn")
	_check(worn.has(ItemDB.Slot.TORSO), "the stillsuit occupies the torso slot")
	_check(wardrobe.count_of("stillsuit") == 0, "worn kit leaves the bag")
	_check(ItemUse.insulation(worn) < 1.0, "wearing a stillsuit cuts water loss")
	_check(ItemUse.insulation({}) == 1.0, "bare skin has no insulation")

	# A weapon reuses use_value for damage; it must not read as insulation.
	_check(ItemUse.insulation({ItemDB.Slot.HANDS: "kindjal"}) == 1.0,
		"a blade is not insulation")


## A detached clock instance, so astronomy can be checked at arbitrary times
## without disturbing the running one.
func _clock_at(t: float) -> Node:
	var c: Node = load("res://scripts/world/world_clock.gd").new()
	c.time_of_day = t
	return c


func _test_clock() -> void:
	_check(_near(_clock_at(0.25).sun_altitude(), 0.0), "sun sits on the horizon at dawn")
	_check(_near(_clock_at(0.50).sun_altitude(), 1.0), "sun is at zenith at noon")
	_check(_near(_clock_at(0.75).sun_altitude(), 0.0, 0.002), "sun returns to the horizon at dusk")
	_check(_clock_at(0.00).sun_altitude() < -0.99, "sun is far below the horizon at midnight")

	_check(not _clock_at(0.50).is_night(), "noon is not night")
	_check(_clock_at(0.95).is_night(), "late evening is night")
	_check(_clock_at(0.05).is_night(), "small hours are night")

	# The sun must rise in the east and set in the west, or shade will move the
	# wrong way across the terrain.
	var dawn: Vector3 = _clock_at(0.26).sun_to()
	var dusk: Vector3 = _clock_at(0.74).sun_to()
	_check(dawn.x > 0.9, "sun rises in the east (+x)")
	_check(dusk.x < -0.9, "sun sets in the west (-x)")
	_check(_near(_clock_at(0.5).sun_to().y, 1.0), "sun is overhead at noon")

	# Dew yield curve: nothing at dusk, richest just before dawn.
	_check(_near(_clock_at(0.75).night_progress(), 0.0, 0.01), "no dew at dusk")
	_check(_clock_at(0.24).night_progress() > 0.95, "dew peaks just before dawn")
	_check(_clock_at(0.0).night_progress() > 0.45 and _clock_at(0.0).night_progress() < 0.55,
		"dew is half-built at midnight")
	_check(_near(_clock_at(0.5).night_progress(), 0.0), "no dew during the day")


func _test_vitals() -> void:
	var VitalsScript: GDScript = load("res://scripts/player/vitals.gd")

	# Baseline: exposure drives water loss.
	var night: Vitals = VitalsScript.new()
	var noon: Vitals = VitalsScript.new()
	night.tick(10.0, 0.0, false, 1.0, 1.0)
	noon.tick(10.0, 1.0, false, 1.0, 1.0)
	_check(noon.hydration < night.hydration, "midday costs more water than night")
	_check(_near(100.0 - night.hydration, 10.0 * Vitals.BASE_DRAIN * Vitals.NIGHT_MULT, 0.01),
		"night drain matches NIGHT_MULT")
	_check(_near(100.0 - noon.hydration, 10.0 * Vitals.BASE_DRAIN * Vitals.DAY_MULT, 0.01),
		"midday drain matches DAY_MULT")

	# Shade is the only relief available before shelter exists.
	var shaded: Vitals = VitalsScript.new()
	shaded.tick(10.0, 1.0, true, 1.0, 1.0)
	_check(shaded.hydration > noon.hydration, "shade slows water loss at midday")
	_check(shaded.heat < noon.heat, "shade slows heat accumulation")

	# Sprinting and stillsuits move the same dial in opposite directions.
	var sprinting: Vitals = VitalsScript.new()
	sprinting.tick(10.0, 1.0, false, Vitals.SPRINT_DRAIN_MULT, 1.0)
	_check(sprinting.hydration < noon.hydration, "sprinting costs extra water")
	var suited: Vitals = VitalsScript.new()
	suited.tick(10.0, 1.0, false, 1.0, 0.45)
	_check(suited.hydration > noon.hydration, "insulation cuts water loss")

	# Heat rises in the open and sheds after dark.
	var hot: Vitals = VitalsScript.new()
	hot.tick(20.0, 1.0, false, 1.0, 1.0)
	_check(hot.heat > 0.0, "heat builds under an open sun")
	var cooling: Vitals = VitalsScript.new()
	cooling.heat = 50.0
	cooling.tick(5.0, 0.0, false, 1.0, 1.0)
	_check(cooling.heat < 50.0, "heat sheds at night")

	# Dehydration kills; the tick that kills reports it exactly once.
	var dying: Vitals = VitalsScript.new()
	dying.hydration = 0.0
	dying.health = 1.0
	var died := dying.tick(1.0, 0.5, false, 1.0, 1.0)
	_check(died, "running dry kills")
	_check(not dying.alive, "the dead are marked dead")
	_check(not dying.tick(1.0, 0.5, false, 1.0, 1.0), "a corpse does not die twice")

	# Drinking restores water and takes the edge off heat.
	var thirsty: Vitals = VitalsScript.new()
	thirsty.hydration = 40.0
	thirsty.heat = 60.0
	var gained := thirsty.drink(25.0)
	_check(_near(gained, 25.0), "drinking returns what it restored")
	_check(_near(thirsty.hydration, 65.0), "drinking restores water")
	_check(thirsty.heat < 60.0, "drinking cools")
	var full: Vitals = VitalsScript.new()
	_check(_near(full.drink(25.0), 0.0), "drinking at full restores nothing")

	# Revive must leave a survivable state, not a fresh one.
	var revived: Vitals = VitalsScript.new()
	revived.alive = false
	revived.hydration = 0.0
	revived.revive()
	_check(revived.alive and revived.hydration > 0.0 and revived.health == Vitals.MAX,
		"revive returns a living, watered player")

	# A save written while dead must not restore a corpse.
	var corpse: Vitals = VitalsScript.new()
	corpse.alive = false
	corpse.health = 0.0
	var loaded: Vitals = VitalsScript.new()
	loaded.from_data(corpse.to_data())
	_check(loaded.alive, "loading a dead save revives rather than stranding the player")


func _test_nodes() -> void:
	var field := NodeField.new()
	_check(field.load_kinds(), "node kinds load")
	_check(field.kinds.has("iron_vein"), "iron veins are defined")

	# A node holds several harvests and empties exactly once.
	var inv := Inventory.new()
	var cd: Dictionary = {}
	var pos := Vector3(10.0, 0.0, 10.0)
	var nid: int = field._spawn("agave", pos)
	var k: Dictionary = field.kinds["agave"]
	var swings := 0
	var now := 0.0
	var depleted_reports := 0
	for i in range(int(k["harvests"]) + 2):
		now += NodeField.SWING_COOLDOWN + 0.1
		var r := field.harvest(pos, inv, nid, cd, now)
		if r["ok"]:
			swings += 1
			if r["depleted"]:
				depleted_reports += 1
	_check(swings == int(k["harvests"]),
		"a node gives exactly its harvest count (%d)" % swings)
	_check(depleted_reports == 1, "depletion is reported once, not repeatedly")
	_check(inv.count_of(str(k["yield_id"])) == swings * int(k["yield_count"]),
		"total yield matches swings x per-swing amount")
	_check(not field.harvest(pos, inv, nid, cd, now + 10.0)["ok"],
		"a spent node gives nothing")

	# Regrowth is on a timer, not immediate.
	_check(field.tick(now + 1.0).is_empty(), "a node does not regrow instantly")
	var respawn: float = now + float(k["respawn_seconds"]) + 1.0
	_check(field.tick(respawn).has(nid), "a node regrows once its timer elapses")
	_check(int(field.nodes[nid]["remaining"]) == int(k["harvests"]),
		"regrowth restores the full harvest count")

	# Reach and tooling are enforced server-side.
	var far := Vector3(200.0, 0.0, 200.0)
	_check(not field.harvest(far, inv, nid, {}, respawn)["ok"],
		"a node out of reach is refused")
	var bare := Inventory.new()
	var vein: int = field._spawn("iron_vein", pos)
	_check(not field.harvest(pos, bare, vein, {}, respawn)["ok"],
		"an iron vein needs a cutting tool")
	var toolbelt := Inventory.new()
	toolbelt.add("cutteray", 1)
	_check(field.harvest(pos, toolbelt, vein, {}, respawn)["ok"],
		"a cutteray unlocks the vein")

	# The swing cooldown is what paces gathering.
	var cd2: Dictionary = {}
	var quick: int = field._spawn("agave", pos)
	_check(field.harvest(pos, inv, quick, cd2, 100.0)["ok"], "first swing lands")
	_check(not field.harvest(pos, inv, quick, cd2, 100.1)["ok"],
		"a second swing inside the cooldown is refused")
	_check(field.harvest(pos, inv, quick, cd2, 100.0 + NodeField.SWING_COOLDOWN + 0.1)["ok"],
		"the swing lands again once the cooldown passes")


func _test_crafting() -> void:
	var stations := StationField.new()
	var inv := Inventory.new()
	var here := Vector3(20.0, 0.0, 20.0)

	# Crafting needs a station within reach, and refuses cleanly without one.
	inv.add("plant_fiber", 3)
	var no_bench := stations.craft(here, inv, "fiber_weave")
	_check(not no_bench["ok"], "crafting without a station is refused")
	_check(inv.count_of("plant_fiber") == 3, "a refused craft consumes nothing")

	var placed := stations.place("tester", here, "survival_fabricator")
	_check(placed["ok"], "a fabricator can be deployed")
	_check(stations.station_in_reach(here, "fabricator") != 0, "the fabricator is in reach")
	_check(not stations.place("tester", here, "water")["ok"],
		"an ordinary item cannot be deployed")
	_check(not stations.place("tester", here + Vector3(1.0, 0.0, 0.0),
		"ore_refinery")["ok"], "stations cannot be stacked on each other")

	# The happy path consumes inputs and produces output.
	var made := stations.craft(here, inv, "fiber_weave")
	_check(made["ok"], "crafting at a station succeeds")
	_check(inv.count_of("plant_fiber") == 0, "crafting consumes its inputs")
	_check(inv.count_of("fiber_weave") == 1, "crafting produces its output")
	_check(not stations.craft(here, inv, "fiber_weave")["ok"],
		"crafting without materials is refused")
	_check(not stations.craft(here, inv, "no_such_thing")["ok"],
		"an unknown recipe is refused")

	# Out of range is out of range, even with materials in hand.
	inv.add("plant_fiber", 3)
	_check(not stations.craft(Vector3(300.0, 0.0, 300.0), inv, "fiber_weave")["ok"],
		"crafting away from the station is refused")

	# A recipe bound to another station is not satisfied by this one.
	inv.add("iron_ore", 2)
	_check(not stations.craft(here, inv, "steel_ingot")["ok"],
		"a refinery recipe needs a refinery, not a fabricator")

	# The full Phase 2 chain: gather -> refine -> craft the stillsuit.
	var chain := Inventory.new()
	chain.add("plant_fiber", 12)
	chain.add("iron_ore", 4)
	chain.add("salvaged_metal", 4)
	chain.add("granite_stone", 6)
	var bench := StationField.new()
	bench.place("tester", here, "survival_fabricator")
	for i in range(4):
		bench.craft(here, chain, "fiber_weave")
	_check(chain.count_of("fiber_weave") == 4, "four weaves from twelve fibre")
	_check(bench.craft(here, chain, "ore_refinery")["ok"], "the refinery is craftable")
	# Deploy it a little away, so both stations are reachable but not stacked.
	var spot := here + Vector3(StationField.MIN_SPACING + 0.5, 0.0, 0.0)
	_check(bench.place("tester", spot, "ore_refinery")["ok"], "the refinery deploys")
	for i in range(2):
		bench.craft(spot, chain, "steel_ingot")
	_check(chain.count_of("steel_ingot") == 2, "two ingots from four ore")
	var suit := bench.craft(here, chain, "stillsuit")
	_check(suit["ok"], "the stillsuit is craftable at the end of the chain")
	_check(chain.count_of("stillsuit") == 1, "the stillsuit lands in the bag")

	# And it must actually be worth making.
	var worn: Dictionary = {}
	var slot := -1
	for i in chain.slots.size():
		if not chain.slots[i].is_empty() and chain.slots[i]["id"] == "stillsuit":
			slot = i
			break
	_check(ItemUse.apply(slot, chain, Vitals.new(), worn, {})["ok"], "the stillsuit can be worn")
	var bare := Vitals.new()
	var suited := Vitals.new()
	bare.tick(30.0, 1.0, false, 1.0, 1.0)
	suited.tick(30.0, 1.0, false, 1.0, ItemUse.insulation(worn))
	_check(suited.hydration > bare.hydration,
		"a crafted stillsuit measurably slows water loss")

	# Packing a station back up returns the item that made it.
	var taken := bench.pick_up(spot, bench.station_in_reach(spot, "refinery"))
	_check(taken["ok"] and taken["item_id"] == "ore_refinery",
		"a station packs back into the item that placed it")
