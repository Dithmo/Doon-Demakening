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
	print("\n=== Claims ===")
	_test_claims()
	print("\n=== Building ===")
	_test_building()
	print("\n=== Power and production ===")
	_test_utilities()
	print("\n=== Combat and the shield rule ===")
	_test_combat()
	print("\n=== The worm ===")
	_test_worm()
	print("\n=== Hostiles and blood ===")
	_test_hostiles()
	print("\n=== Points of interest ===")
	_test_pois()
	print("\n=== Progression ===")
	_test_progression()
	print("\n=== Journey and contracts ===")
	_test_quests()
	print("\n=== Trading ===")
	_test_vendor()
	print("\n=== Vehicles ===")
	_test_vehicles()
	print("\n=== Guilds and the Landsraad ===")
	_test_guilds()
	print("\n=== The interface ===")
	_test_interface()
	print("\n=== Traversal: jumping, climbing, stamina ===")
	_test_traversal()
	print("\n=== Spice ===")
	_test_spice()
	print("\n=== Granite and the beam ===")
	_test_granite()
	print("\n=== The first base ===")
	_test_first_base()

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
	# Phase 3 changed placement from "refuse if too close" to "snap to the
	# nearest free spot", so a second station deploys rather than being turned
	# away. The invariant worth asserting is the one that survived that change:
	# whatever spot it picks, stations never end up overlapping.
	var second := stations.place("tester", here + Vector3(1.0, 0.0, 0.0), "ore_refinery")
	_check(second["ok"], "a second station snaps to a free spot nearby")
	var a: Vector3 = stations.stations[int(placed["id"])]["pos"]
	var b: Vector3 = stations.stations[int(second["id"])]["pos"]
	_check(Vector2(a.x - b.x, a.z - b.z).length() >= StationField.MIN_SPACING - 0.01,
		"stations never end up overlapping")

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
	var bench_only := StationField.new()
	bench_only.place("tester", here, "survival_fabricator")
	_check(not bench_only.craft(here, inv, "steel_ingot")["ok"],
		"a refinery recipe needs a refinery, not a fabricator")

	# The full Phase 2 chain: gather -> refine -> craft the stillsuit.
	var chain := Inventory.new()
	chain.add("plant_fiber", 12)
	# Copper, not iron: the stillsuit is early gear, and copper is the first
	# metal you can refine. Eight ore makes the two ingots it wants.
	chain.add("copper_ore", 4)
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
	bench.craft(spot, chain, "copper_ingot")
	_check(chain.count_of("copper_ingot") == 1, "one ingot from four ore")
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


## A patch of open, flat, reachable sand to build on. Picking it from the map
## rather than assuming one keeps these tests honest about the terrain.
func _open_ground() -> Vector3:
	var best := Vector3.ZERO
	var flattest := INF
	for i in range(4000):
		var x := 12.0 + fmod(float(i) * 37.0, Terrain.size_m.x - 24.0)
		var z := 12.0 + fmod(float(i) * 61.0, Terrain.size_m.y - 24.0)
		var cell := BuildGrid.world_to_cell(Vector3(x, 0.0, z))
		var c := BuildGrid.cell_centre(cell)
		# Check the cell *centre*, since that is what gets returned, and a ring
		# around it, since these tests deploy kit several metres to the side.
		if Terrain.sample_surface(c.x, c.y) != Terrain.Surface.SAND:
			continue
		var clear := true
		for a in range(8):
			var ang := TAU * float(a) / 8.0
			if not Terrain.is_reachable(c.x + cos(ang) * 12.0, c.y + sin(ang) * 12.0):
				clear = false
				break
		if not clear or not Terrain.is_reachable(c.x, c.y):
			continue
		var lo := INF
		var hi := -INF
		for dx: float in [0.0, 1.0]:
			for dz: float in [0.0, 1.0]:
				var h := Terrain.sample_height((float(cell.x) + dx) * BuildGrid.CELL,
					(float(cell.y) + dz) * BuildGrid.CELL)
				lo = minf(lo, h)
				hi = maxf(hi, h)
		if hi - lo < flattest:
			flattest = hi - lo
			best = Vector3(c.x, Terrain.sample_height(c.x, c.y), c.y)
		if flattest < 0.2:
			break
	return best


func _test_claims() -> void:
	var claims := Claims.new()
	var here := _open_ground()
	var far := here + Vector3(300.0, 0.0, 0.0)

	# Unclaimed ground is closed to everyone now: the Construction Tool only
	# works on land a Sub-Fief has claimed, so a claim is what *opens* ground
	# rather than what shuts it.
	_check(not claims.may_build("ada", here), "unclaimed ground cannot be built on")
	var staked := claims.stake("ada", here, 20.0, 1)
	_check(staked["ok"], "a holding can be staked on open ground")
	_check(claims.owner_at(here) == "ada", "the claim reports its owner")

	# The anti-grief property: someone else's holding is closed to you.
	_check(not claims.may_build("bo", here), "another player cannot build inside it")
	_check(not claims.may_build("bo", here + Vector3(15.0, 0.0, 0.0)),
		"the whole radius is closed, not just the centre")
	_check(claims.may_build("ada", here + Vector3(15.0, 0.0, 0.0)),
		"the owner can build anywhere inside")
	_check(not claims.may_build("bo", far), "and nor can land outside any claim")

	_check(not claims.stake("bo", here + Vector3(5.0, 0.0, 0.0), 20.0, 2)["ok"],
		"a second console cannot be planted inside an existing holding")
	_check(not claims.stake("bo", here + Vector3(30.0, 0.0, 0.0), 20.0, 2)["ok"],
		"claims may not overlap at the rim either")
	_check(claims.stake("bo", far, 20.0, 3)["ok"], "a holding elsewhere is fine")

	# Height must not shrink a claim: it is a footprint on the ground.
	_check(not claims.may_build("bo", here + Vector3(0.0, 40.0, 0.0)),
		"a claim covers the air above it too")

	var cid := claims.claim_for_station(1)
	_check(cid != 0, "a claim can be found from its console")
	claims.release(cid)
	_check(not claims.may_build("bo", here),
		"releasing a holding closes the land again rather than freeing it")


func _test_building() -> void:
	var grid := BuildGrid.new()
	var claims := Claims.new()
	var here := _open_ground()
	# You build inside a holding or not at all, so the fixture stakes one first.
	# That is the sequence a player follows too: console down, then floor.
	_check(bool(claims.stake("ada", here, Claims.SIZE * 0.5, 1)["ok"]),
		"a holding can be staked to build in")
	# Cells are counted from the holding's corner, not from the world origin,
	# so the claim's edge is always a cell edge.
	var cell := BuildGrid.cell_in(here, claims.origin_of(claims.claim_at(here)))

	# Walls and ceilings need something to stand on.
	_check(not grid.build("ada", here, here, "wall", claims)["ok"],
		"a wall needs something to build onto")
	_check(not grid.build("ada", here, here, "ceiling", claims)["ok"],
		"a ceiling needs something to build onto")
	_check(not grid.build("ada", here, here, "nonsense", claims)["ok"],
		"an unknown piece is refused")

	var floor_piece := grid.build("ada", here, here, "foundation", claims)
	_check(floor_piece["ok"], "a foundation goes down on flat reachable ground")
	_check(grid.has_piece(BuildGrid.Piece.FOUNDATION, cell, 0),
		"the foundation occupies its cell")
	_check(not grid.build("ada", here, here, "foundation", claims)["ok"],
		"two foundations cannot share a cell")

	# Now the rest of the shell.
	_check(grid.build("ada", here, here, "wall", claims)["ok"],
		"a wall goes onto the foundation")
	_check(not grid.build("ada", here, here, "wall", claims)["ok"],
		"the same edge cannot take two walls")
	# Aiming at the opposite edge picks a different side.
	# Aimed at the far edge of the *same* cell, so it is a different side of one
	# cell rather than a wall in the neighbouring one. Measured from the cell's
	# own centre, since cells no longer line up with the world origin.
	var org := claims.origin_of(claims.claim_at(here))
	var mid := BuildGrid.cell_centre_in(cell, org)
	var other := Vector3(mid.x + BuildGrid.CELL * 0.4, here.y, mid.y)
	var side_now := BuildGrid.nearest_side(cell, other, org)
	var first_side := BuildGrid.nearest_side(cell, here, org)
	_check(side_now != first_side,
		"the far edge of the cell is a different side (%d vs %d)"
		% [first_side, side_now])
	_check(grid.build("ada", here, other, "wall", claims)["ok"],
		"a second wall goes on a different edge")
	_check(grid.build("ada", here, here, "ceiling", claims)["ok"], "a ceiling caps it")

	# A ceiling is the floor of the next storey -- multi-storey for free.
	var upstairs := here + Vector3(0.0, BuildGrid.CELL, 0.0)
	_check(grid.supported(cell, 1), "the ceiling supports the level above")
	_check(grid.build("ada", upstairs, here, "wall", claims)["ok"],
		"a wall can go up on the next storey")

	# Range and ownership are enforced.
	_check(not grid.build("ada", here, here + Vector3(40.0, 0.0, 0.0),
		"foundation", claims)["ok"], "building out of reach is refused")
	# Hand the ground over: boxes may not overlap, so bo cannot stake here
	# until ada's claim is released. That is the rule working, not a fixture
	# quirk -- two owners never share a volume.
	claims.release(claims.claim_for_station(1))
	claims.stake("bo", here, Claims.SIZE * 0.5, 2)
	_check(not grid.build("ada", here, here, "foundation", claims)["ok"],
		"building inside another player's holding is refused")
	_check(not grid.demolish("ada", here, here, claims)["ok"],
		"demolishing inside another player's holding is refused")
	claims.release(claims.claim_for_station(1))

	# Load-bearing pieces cannot be pulled out from under what rests on them.
	var grid2 := BuildGrid.new()
	grid2.build("ada", here, here, "foundation", claims)
	grid2.build("ada", here, here, "ceiling", claims)
	_check(not grid2.demolish("ada", here, here, claims)["ok"]
		or grid2.has_piece(BuildGrid.Piece.FOUNDATION, cell, 0),
		"a loaded foundation is not removed by accident")

	# A JSON round-trip must preserve the structure exactly.
	var copy := BuildGrid.new()
	copy.from_wire(grid.to_wire())
	_check(copy.count() == grid.count(), "a build survives a save round-trip")
	_check(copy.has_piece(BuildGrid.Piece.FOUNDATION, cell, 0),
		"pieces keep their cell across the round-trip")


func _test_utilities() -> void:
	var claims := Claims.new()
	var stations := StationField.new()
	var here := _open_ground()
	claims.stake("ada", here, 30.0, 0)
	var cid := claims.claim_at(here)

	# Spread the kit out: stations refuse to stack.
	var step := StationField.MIN_SPACING + 1.0
	stations.place("ada", here, "windtrap", claims)
	stations.place("ada", here + Vector3(step, 0.0, 0.0), "water_cistern", claims)

	var starved := Utilities.power_for_claim(cid, claims, stations)
	_check(starved["draw"] > 0.0, "the windtrap draws power")
	_check(not starved["satisfied"], "a holding with no generator is starved")
	_check(Utilities.produce(600.0, claims, stations).is_empty(),
		"an unpowered windtrap produces nothing")

	stations.place("ada", here + Vector3(step * 2.0, 0.0, 0.0), "fuel_generator", claims)
	var powered := Utilities.power_for_claim(cid, claims, stations)
	_check(powered["output"] > powered["draw"], "the generator covers the draw")
	_check(powered["satisfied"], "the holding is powered")

	var made := Utilities.produce(60.0, claims, stations)
	_check(not made.is_empty(), "a powered windtrap produces water")
	var cistern := 0
	for sid: int in stations.stations:
		if stations.stations[sid].has("inventory"):
			cistern = sid
	_check(cistern != 0, "the cistern is a container")
	if cistern != 0:
		var box: Inventory = stations.stations[cistern]["inventory"]
		_check(box.count_of("water") > 0, "the water lands in the cistern")

		# Production is capped, so a long outage cannot pay out a fortune.
		var before: int = box.count_of("water")
		Utilities.produce(365.0 * 24.0 * 3600.0, claims, stations)
		var capped: int = int(Utilities.MAX_OFFLINE_SECONDS * 0.25) + before
		_check(box.count_of("water") <= capped + 1,
			"offline production is capped, not unbounded")

	# Unclaimed kit is nobody's infrastructure.
	var loose := StationField.new()
	loose.place("ada", here + Vector3(400.0, 0.0, 0.0), "windtrap")
	_check(Utilities.produce(600.0, Claims.new(), loose).is_empty(),
		"a windtrap outside any holding produces nothing")

	# Containers refuse to be pocketed with something inside.
	var chest := StationField.new()
	var placed := chest.place("ada", here, "storage_chest", null)
	var box: Inventory = chest.stations[int(placed["id"])]["inventory"]
	box.add("water", 2)
	_check(not chest.pick_up(here, int(placed["id"]))["ok"],
		"a container with contents cannot be packed up")
	box.remove("water", 2)
	_check(chest.pick_up(here, int(placed["id"]))["ok"],
		"an emptied container can be packed up")




func _equip(item_id: String) -> Dictionary:
	var slot: int = int(ItemDB.get_def(item_id).get("slot", ItemDB.Slot.NONE))
	return {slot: item_id}


func _test_combat() -> void:
	var here := Vector3.ZERO
	var close := Vector3(1.5, 0.0, 0.0)

	_check(Combat.weapon_of({})["damage"] > 0.0, "bare hands still do something")
	_check(str(Combat.weapon_of(_equip("kindjal"))["attack"]) == "fast",
		"a kindjal is a fast blade")
	_check(str(Combat.weapon_of(_equip("crysknife"))["attack"]) == "slow",
		"a crysknife is a slow blade")
	_check(Combat.has_shield(_equip("body_shield")), "a shield reads as a shield")
	_check(not Combat.has_shield(_equip("stillsuit")), "a stillsuit is not a shield")

	# The rule, both ways round.
	var unshielded := Combat.strike(here, _equip("kindjal"), close, {}, {}, 100.0)
	_check(unshielded["damage"] > 0.0, "a fast blade hurts an unshielded target")

	var turned := Combat.strike(here, _equip("kindjal"), close,
		_equip("body_shield"), {}, 100.0)
	_check(turned["blocked"] and turned["damage"] == 0.0,
		"a shield turns a fast blade")
	var darts := Combat.strike(here, _equip("maula_pistol"), close,
		_equip("body_shield"), {}, 100.0)
	_check(darts["blocked"], "a shield turns darts too")
	var slow := Combat.strike(here, _equip("crysknife"), close,
		_equip("body_shield"), {}, 100.0)
	_check(not slow["blocked"] and slow["damage"] > 0.0,
		"the slow blade passes the shield")

	# Reach and cadence are enforced, not suggested.
	var far := Combat.strike(here, _equip("kindjal"), Vector3(50.0, 0.0, 0.0), {}, {}, 100.0)
	_check(not far["ok"], "a swing out of reach lands nothing")
	var cd: Dictionary = {}
	_check(Combat.strike(here, _equip("kindjal"), close, {}, cd, 100.0)["ok"],
		"the first swing lands")
	_check(not Combat.strike(here, _equip("kindjal"), close, {}, cd, 100.1)["ok"],
		"a second swing inside the cooldown is refused")
	_check(Combat.strike(here, _equip("kindjal"), close, {}, cd,
		100.0 + Combat.SWING_COOLDOWN + 0.1)["ok"], "the swing returns after cooldown")

	# A slow blade telegraphs, which is what makes carrying one a choice.
	var slow_cd: Dictionary = {}
	Combat.strike(here, _equip("crysknife"), close, {}, slow_cd, 100.0)
	var fast_cd: Dictionary = {}
	Combat.strike(here, _equip("kindjal"), close, {}, fast_cd, 100.0)
	_check(float(slow_cd["swing_at"]) > float(fast_cd["swing_at"]),
		"a slow blade leaves you exposed longer than a fast one")

	# And the cost that balances it: a running shield is loud.
	_check(Combat.threat_multiplier(_equip("body_shield")) > 1.0,
		"a shield makes you louder to a worm")
	_check(Combat.threat_multiplier({}) == 1.0, "no shield, no extra noise")


func _test_worm() -> void:
	var sand := Vector3(10.0, 0.0, 10.0)

	# Threat is about what you are doing on the sand.
	var w := Sandworm.new()
	w.accrue(1, 10.0, true, true, false, 1.0)
	var walking := w.threat_of(1)
	_check(walking > 0.0, "moving on sand attracts attention")

	var s := Sandworm.new()
	s.accrue(1, 10.0, true, true, true, 1.0)
	_check(s.threat_of(1) > walking, "sprinting is louder than walking")

	var shielded := Sandworm.new()
	shielded.accrue(1, 10.0, true, true, false, 3.0)
	_check(shielded.threat_of(1) > walking, "a running shield is louder still")

	# Standing still is the classic answer, and rock is the real one.
	var quiet := Sandworm.new()
	quiet.threat[1] = 40.0
	quiet.accrue(1, 5.0, true, false, false, 1.0)
	_check(quiet.threat_of(1) < 40.0, "standing still bleeds threat off")
	var onrock := Sandworm.new()
	onrock.threat[1] = 40.0
	onrock.accrue(1, 5.0, false, true, true, 1.0)
	_check(onrock.threat_of(1) < quiet.threat_of(1),
		"rock sheds threat faster than standing still on sand")

	# The full encounter.
	var hunt := Sandworm.new()
	hunt.threat[1] = Sandworm.WAKE_THRESHOLD + 5.0
	var loud := {1: {"pos": sand, "on_sand": true, "alive": true}}
	var woke := hunt.tick(0.1, loud, [])
	_check(not woke.is_empty() and str(woke[0]["kind"]) == "wake",
		"enough noise wakes it")
	_check(hunt.state == Sandworm.State.ALERTED, "it comes for the loudest thing")

	# It must be faster than a sprint, or the answer would be "run further".
	_check(Sandworm.SPEED > Movement.SPRINT_SPEED,
		"the worm outruns a sprinting player")

	var surfaced := false
	for i in range(400):
		for e: Dictionary in hunt.tick(0.1, loud, []):
			if str(e["kind"]) == "surface":
				surfaced = true
		if surfaced:
			break
	_check(surfaced, "it arrives and surfaces")
	_check(hunt.timer > 0.0, "surfacing gives a warning window")

	# Reaching rock during the warning has to actually save you.
	var saved := hunt.tick(0.1, {1: {"pos": sand, "on_sand": false, "alive": true}}, [])
	_check(not saved.is_empty() and str(saved[0]["kind"]) == "lost",
		"reaching rock during the warning saves you")

	# And staying on sand does not.
	var doomed := Sandworm.new()
	doomed.threat[1] = Sandworm.WAKE_THRESHOLD + 5.0
	var caught: Array = []
	for i in range(600):
		for e: Dictionary in doomed.tick(0.1, loud, []):
			if str(e["kind"]) == "strike":
				caught = e["caught"]
		if not caught.is_empty():
			break
	_check(caught.has(1), "staying on open sand gets you taken")

	# A bystander on rock inside the blast radius is spared.
	var mixed := Sandworm.new()
	mixed.threat[1] = Sandworm.WAKE_THRESHOLD + 5.0
	var both := {
		1: {"pos": sand, "on_sand": true, "alive": true},
		2: {"pos": sand + Vector3(2.0, 0.0, 0.0), "on_sand": false, "alive": true},
	}
	var taken: Array = []
	for i in range(600):
		for e: Dictionary in mixed.tick(0.1, both, []):
			if str(e["kind"]) == "strike":
				taken = e["caught"]
		if not taken.is_empty():
			break
	_check(taken.has(1) and not taken.has(2),
		"the strike takes who is on sand and spares who is on rock")

	# A thumper buys safety by being louder than you are.
	var lured := Sandworm.new()
	lured.threat[1] = Sandworm.WAKE_THRESHOLD + 1.0
	var decoy := Vector3(200.0, 0.0, 200.0)
	lured.tick(0.1, loud, [{"pos": decoy, "threat": Sandworm.MAX_THREAT}])
	_check(lured.target_pos.distance_to(decoy) < 1.0,
		"a thumper outbids a noisy player")
	_check(lured.target_peer == 0, "and the worm is chasing the thumper, not them")


func _test_hostiles() -> void:
	var h := Hostiles.new()
	var here := _open_ground()
	var id: int = h._spawn(here)
	_check(h.npcs.has(id), "a hostile can be spawned")

	# It notices you, and it gives up if you leave.
	var far := {1: {"pos": here + Vector3(100.0, 0.0, 0.0), "alive": true}}
	h.tick(0.1, far, 0.0)
	_check(int(h.npcs[id]["target"]) == 0, "a distant player is ignored")
	var near := {1: {"pos": here + Vector3(2.0, 0.0, 0.0), "alive": true}}
	h.tick(0.1, near, 0.0)
	_check(int(h.npcs[id]["target"]) == 1, "a close player is noticed")

	var hits: Array = []
	for e: Dictionary in h.tick(0.1, near, 10.0):
		if str(e["kind"]) == "hit":
			hits.append(e)
	_check(not hits.is_empty(), "a hostile in reach hits you")
	_check(float(hits[0]["damage"]) > 0.0, "and it hurts")

	# Killing one leaves a body, which is water.
	var half := h.damage(id, Hostiles.NPC_HEALTH * 0.5, 0.0)
	_check(not half["killed"] and h.npcs.has(id), "a wounded hostile is still alive")
	var dead := h.damage(id, Hostiles.NPC_HEALTH, 0.0)
	_check(dead["killed"] and not h.npcs.has(id), "enough damage kills it")
	_check(h.corpses.size() == 1, "a kill leaves a body")

	var cid := h.nearest_corpse(here, 3.0)
	_check(cid != 0, "the body can be found")
	var empty_handed := Inventory.new()
	_check(not h.extract(here, empty_handed, cid, {}, 100.0)["ok"],
		"drawing water needs an extractor")
	var kit := Inventory.new()
	kit.add("blood_extractor", 1)
	# One cooldown dict across the calls -- it is per-player state, and passing
	# a fresh one each time would test nothing.
	var cd: Dictionary = {}
	var drawn := h.extract(here, kit, cid, cd, 100.0)
	_check(drawn["ok"] and kit.count_of("blood_sack") == 1,
		"an extractor draws a blood sack")
	_check(not h.extract(here, kit, cid, cd, 100.1)["ok"],
		"extraction has a cooldown")
	_check(h.extract(here, kit, cid, cd, 100.0 + Hostiles.EXTRACT_COOLDOWN + 0.1)["ok"],
		"and it returns once the cooldown passes")
	_check(not h.extract(here + Vector3(50.0, 0.0, 0.0), kit, cid, cd, 400.0)["ok"],
		"a body out of reach yields nothing")

	# And that blood is drinkable -- the loop back to Phase 1.
	var thirsty := Vitals.new()
	thirsty.hydration = 40.0
	var slot := -1
	for i in kit.slots.size():
		if not kit.slots[i].is_empty() and str(kit.slots[i]["id"]) == "blood_sack":
			slot = i
	_check(slot >= 0 and ItemUse.apply(slot, kit, thirsty, {}, {})["ok"],
		"a blood sack can be drunk")
	_check(thirsty.hydration > 40.0, "and it restores water")


func _test_pois() -> void:
	# The POI store is loaded from whichever region the run is using, and the
	# unit suite runs on whatever the default is -- so these test the *rules*
	# against a set built here, not the shipped data. Whether the shipped data
	# is right is tools/test_phase5.py's job, and it checks it by round-tripping
	# world coordinates back to the wiki's own CRS.
	var p := preload("res://scripts/world/pois.gd").new()
	p.all = []
	p._by_role = {}
	p._shelters = PackedVector2Array()
	for spec: Array in [
			["shelter", "Deep Hole", 100.0, 100.0],
			["shelter", "Second Hole", 400.0, 100.0],
			["threat", "A Camp", 250.0, 250.0],
			["loot", "A Wreck", 700.0, 300.0]]:
		var poi := {"role": spec[0], "group": "", "name": spec[1],
			"x": spec[2], "z": spec[3]}
		p.all.append(poi)
		if not p._by_role.has(spec[0]):
			p._by_role[spec[0]] = []
		(p._by_role[spec[0]] as Array).append(poi)
		if spec[0] == "shelter":
			p._shelters.append(Vector2(spec[2], spec[3]))
	p.loaded = true

	_check(p.of_role("shelter").size() == 2, "POIs are indexed by role")
	_check(p.of_role("nothing").is_empty(), "an unknown role is empty, not an error")

	# Shelter is a hard radius, because the worm reads it as a hard boundary --
	# the same reason sample_surface is nearest-neighbour rather than smoothed.
	_check(p.shelter_at(100.0, 100.0), "standing on a cave is shelter")
	_check(p.shelter_at(100.0, 100.0 + Pois.SHELTER_RADIUS - 0.5),
		"and so is the edge of its mouth")
	_check(not p.shelter_at(100.0, 100.0 + Pois.SHELTER_RADIUS + 0.5),
		"a step outside it is not")
	_check(not p.shelter_at(250.0, 250.0), "a camp is not shelter")

	# Nearest is horizontal: a marker up a mesa is as far as it walks, not as
	# far as it flies.
	var near: Dictionary = p.nearest("shelter", 380.0, 110.0)
	_check(not near.is_empty() and str(near["name"]) == "Second Hole",
		"nearest picks the closer marker of a role")
	_check(p.nearest("spice", 0.0, 0.0).is_empty(),
		"nearest of an absent role is empty")

	_check(str(p.find_named("a wreck").get("name", "")) == "A Wreck",
		"markers are found by name, case-insensitively")
	_check(p.find_named("No Such Place").is_empty(),
		"and an unknown name finds nothing")


func _test_progression() -> void:
	var p := Progression.new()
	_check(p.level == 1 and p.xp == 0.0, "a new character starts at level 1")
	_check(Progression.xp_for_level(1) == 0.0, "level 1 costs nothing")
	_check(Progression.xp_for_level(3) > Progression.xp_for_level(2),
		"each level costs more than the last")

	# Levelling must be able to cross more than one boundary at once: a quest
	# reward can be worth more than a whole level, and swallowing the extra
	# would quietly rob the player.
	var gained := p.award(Progression.xp_for_level(3))
	_check(gained == 2 and p.level == 3, "one award can cross two levels")
	_check(p.award(-50.0) == 0, "negative experience is ignored")

	# The cap has to hold, or xp_to_next() below reads as a negative wall.
	var maxed := Progression.new()
	maxed.award(Progression.xp_for_level(Progression.MAX_LEVEL) * 10.0)
	_check(maxed.level == Progression.MAX_LEVEL, "level is capped")
	_check(maxed.xp_to_next() == 0.0, "and there is nothing left to reach")

	# Points and skills.
	_check(p.points_available() == 3, "three levels means three points")
	var learn := p.learn("blade_training")
	_check(learn["ok"] and p.has_skill("blade_training"), "a skill can be learned")
	_check(p.points_available() == 2, "learning spends a point")
	_check(not p.learn("blade_training")["ok"], "the same skill twice is refused")
	_check(not p.learn("no_such_skill")["ok"], "an unknown skill is refused")
	_check(not p.learn("trophy_hunter")["ok"],
		"a skill above your level is refused")
	_check(not p.learn("night_work")["ok"],
		"a skill whose prerequisite is missing is refused")

	var broke := Progression.new()
	broke.learn("blade_training")
	_check(broke.points_available() == 0 and not broke.learn("light_step")["ok"],
		"you cannot spend a point you do not have")

	# Effects. The identity is what makes callers able to multiply blind.
	var plain := Progression.new()
	_check(plain.mult("melee_damage") == 1.0, "no skills means no multiplier")
	_check(plain.bonus("node_yield") == 0.0, "and no flat bonus")
	_check(p.mult("melee_damage") > 1.0, "Blade Training raises melee damage")
	_check(p.mult("threat_rate") == 1.0,
		"and touches nothing it was not meant to")

	var gatherer := Progression.new()
	gatherer.award(Progression.xp_for_level(2))
	gatherer.learn("deep_harvest")
	_check(gatherer.bonus("node_yield") == 1.0, "Deep Harvest is a flat bonus")
	_check(gatherer.mult("node_yield") == 1.0,
		"a flat bonus does not leak into the multiplier")

	# Solari.
	var purse := Progression.new()
	purse.earn_solari(100)
	_check(purse.solari == 100, "solari can be earned")
	_check(purse.spend_solari(40) and purse.solari == 60, "and spent")
	_check(not purse.spend_solari(1000) and purse.solari == 60,
		"overspending is refused and changes nothing")
	purse.earn_solari(-50)
	_check(purse.solari == 60, "negative earnings are ignored")

	# Discovery pays once.
	_check(purse.discover("Wali Hole"), "somewhere new is a discovery")
	_check(not purse.discover("Wali Hole"), "the second visit is not")
	_check(not purse.discover(""), "an unnamed marker is never a discovery")

	# Round-trip, including a skill that no longer exists.
	var saved := p.to_data()
	saved["skills"] = (saved["skills"] as Array) + ["deleted_skill"]
	var loaded := Progression.new()
	loaded.from_data(saved)
	_check(loaded.level == p.level and loaded.xp == p.xp, "progression persists")
	_check(loaded.has_skill("blade_training"), "skills persist")
	_check(not loaded.has_skill("deleted_skill"),
		"a skill that no longer exists is dropped, not carried")
	_check(loaded.points_available() == p.points_available(),
		"and dropping it returns the point")


func _test_quests() -> void:
	var q := QuestLog.new()
	_check(q.step == 0, "the Journey starts at its first step")

	# The first step is "drink one water". Anything else must not advance it.
	var first := QuestDB.step(0)
	_check(not first.is_empty(), "the Journey has a first step")
	_check(q.observe("gather", "plant_fiber", 3).is_empty(),
		"an unrelated action does not advance the Journey")
	_check(q.step == 0, "and leaves it where it was")

	var done := q.observe(str(first["kind"]), str(first["target"]),
		int(first["count"]))
	_check(done.size() == 1 and str(done[0]["id"]) == str(first["id"]),
		"doing what the step asks completes it")
	_check(q.step == 1, "and moves on to the next")

	# Contracts: taken from a giver, refused below level, progressed by the
	# same observations.
	var c := QuestDB.contract("c_water_1")
	_check(not c.is_empty(), "the contract board loaded")
	_check(not q.accept("c_water_1", 0)["ok"], "an under-level contract is refused")
	_check(q.accept("c_water_1", 5)["ok"], "and accepted at level")
	_check(not q.accept("c_water_1", 5)["ok"], "the same contract twice is refused")
	_check(not q.accept("no_such_contract", 5)["ok"], "an unknown contract is refused")

	var part := q.observe("gather", "water", 2)
	_check(part.is_empty() and int(q.active["c_water_1"]) == 2,
		"partial progress is recorded but does not complete")
	var rest := q.observe("gather", "water", int(c["count"]))
	_check(rest.size() == 1 and q.done.has("c_water_1"),
		"reaching the count completes the contract")
	_check(not q.active.has("c_water_1"), "and it leaves the active list")
	_check(q.observe("gather", "water", 9).is_empty(),
		"a settled contract does not keep paying out")

	# Chains only appear once their predecessor is settled.
	var offers := QuestDB.offered_by("Griffin's Reach Trading Post", 5, q.done, q.active)
	var ids: Array = []
	for o: Dictionary in offers:
		ids.append(str(o["id"]))
	_check(ids.has("c_water_2"), "the next link appears once the first is done")
	_check(not ids.has("c_water_1"), "and the settled one does not")
	var fresh := QuestLog.new()
	var early := QuestDB.offered_by("Griffin's Reach Trading Post", 5,
		fresh.done, fresh.active)
	var early_ids: Array = []
	for o: Dictionary in early:
		early_ids.append(str(o["id"]))
	_check(not early_ids.has("c_water_2"),
		"a chain link is hidden until its predecessor is settled")
	_check(QuestDB.offered_by("Nobody At All", 5, fresh.done, fresh.active).is_empty(),
		"a stranger offers nothing")

	# `carrying` objectives need the item in hand, not merely the place.
	var carry_step := {}
	for s: Variant in QuestDB.journey:
		if not str((s as Dictionary)["carrying"]).is_empty():
			carry_step = s
	if not carry_step.is_empty():
		var empty_handed := QuestLog.new()
		empty_handed.step = QuestDB.journey.find(carry_step)
		var bag := Inventory.new()
		_check(empty_handed.observe(str(carry_step["kind"]),
			str(carry_step["target"]), 1, bag).is_empty(),
			"arriving without what the step asked for does not complete it")
		bag.add(str(carry_step["carrying"]), 1)
		_check(not empty_handed.observe(str(carry_step["kind"]),
			str(carry_step["target"]), 1, bag).is_empty(),
			"and arriving with it does")

	var round_trip := QuestLog.new()
	round_trip.from_data(q.to_data())
	_check(round_trip.step == q.step, "the Journey position persists")
	_check(round_trip.done.has("c_water_1"), "settled contracts persist")


func _test_vendor() -> void:
	# The spread is the economy's only friction, so it is the thing to assert.
	_check(Vendor.buy_price("water") > Vendor.sell_price("water"),
		"the post sells dearer than it buys")
	_check(Vendor.sell_price("water") > 0, "ordinary goods have a value")
	_check(Vendor.sell_price("no_such_item") == 0, "an unknown item is worth nothing")
	_check(Vendor.MARKUP > 1.0, "and the markup is a markup")

	# Round-tripping an item through the post must lose money, or a vendor is
	# an infinite solari faucet and every other economy rule stops mattering.
	var before := 1000
	var after := before - Vendor.buy_price("steel_ingot") + Vendor.sell_price("steel_ingot")
	_check(after < before, "buying then selling loses money")


func _test_vehicles() -> void:
	var car := ItemDB.get_def("groundcar")
	var thopter := ItemDB.get_def("ornithopter")
	_check(not car.is_empty() and not thopter.is_empty(), "vehicles are in the item table")
	_check(str(car.get("vehicle", "")) == "groundcar", "and name the kind they become")

	# Acceleration, not teleportation: a vehicle from rest reaches part of its
	# top speed in a tick, and its top speed eventually.
	var pos := Vector3(60.0, 0.0, 60.0)
	var r := VehicleMotion.step(car, pos, 0.0, 0.0, 0.0, 0.0, 1.0, 0.1, 30.0)
	_check(float(r["speed"]) > 0.0 and float(r["speed"]) < float(car["top_speed"]),
		"a vehicle accelerates rather than jumping to speed")
	# Top speed is asserted on the thopter, which ignores the traversability
	# mask: a groundcar driven in a straight line for twenty seconds hits an
	# outcrop and is slowed by it, which is the mask working rather than the
	# throttle failing.
	var speed := 0.0
	var p2 := pos
	for i in range(400):
		var s := VehicleMotion.step(thopter, p2, 0.0, speed, 30.0, 0.0, 1.0, 0.05, 30.0)
		p2 = s["pos"]
		speed = float(s["speed"])
	_check(_near(speed, float(thopter["top_speed"]), 0.5), "and tops out where it should")
	_check(p2.distance_to(pos) > 10.0, "and actually covers ground")

	# The groundcar is slowed by ground it cannot cross, which is what makes the
	# thopter worth its fuel.
	var into_rock := VehicleMotion.step(car, pos, 0.0, float(car["top_speed"]), 0.0,
		0.0, 1.0, 0.1, 30.0)
	_check(float(into_rock["speed"]) > 0.0, "a groundcar keeps moving on open ground")

	# Out of fuel is a stop, not a slowdown. This is the whole reason fuel is a
	# separate craft rather than a number that ticks down invisibly.
	var dry := VehicleMotion.step(car, pos, 0.0, 12.0, 0.0, 0.0, 1.0, 0.5, 0.0)
	_check(float(dry["speed"]) < 12.0, "a dry vehicle slows down")
	var stopped := 12.0
	for i in range(200):
		stopped = float(VehicleMotion.step(car, pos, 0.0, stopped, 0.0, 0.0, 1.0,
			0.05, 0.0)["speed"])
	_check(_near(stopped, 0.0, 0.01), "and comes to a complete halt")

	# Steering authority scales with speed, so a parked car cannot pirouette.
	var still := VehicleMotion.step(car, pos, 0.0, 0.0, 0.0, 1.0, 0.0, 0.5, 30.0)
	_check(_near(float(still["heading"]), 0.0, 0.001),
		"a stationary vehicle cannot turn on the spot")
	var rolling := VehicleMotion.step(car, pos, 0.0, float(car["top_speed"]), 0.0,
		1.0, 1.0, 0.5, 30.0)
	_check(absf(float(rolling["heading"])) > 0.1, "a moving one turns")

	# Fuel burn is per metre, so a longer trip costs more and an idle one is free.
	_check(VehicleMotion.burn(car, 100.0) > VehicleMotion.burn(car, 10.0),
		"fuel burn scales with distance")
	_check(_near(VehicleMotion.burn(car, 0.0), 0.0), "and standing still is free")
	_check(VehicleMotion.burn(thopter, 100.0) > VehicleMotion.burn(car, 100.0),
		"the ornithopter is thirstier per metre than the groundcar")

	# The worm rule is the point of vehicles existing at all.
	_check(VehicleMotion.threat_multiplier(car, float(car["top_speed"]), 0.0) > 1.0,
		"a groundcar at speed is louder than a person")
	_check(_near(VehicleMotion.threat_multiplier(car, 0.0, 0.0), 0.0),
		"a parked one is silent")
	_check(_near(VehicleMotion.threat_multiplier(thopter, 20.0, 30.0), 0.0),
		"an airborne ornithopter is silent whatever it is doing")
	_check(VehicleMotion.threat_multiplier(car, 8.0, 0.0)
		< VehicleMotion.threat_multiplier(car, 16.0, 0.0),
		"and driving faster is louder than driving slowly")

	# A thopter climbs under power and settles without it.
	var climbed := VehicleMotion.step(thopter, pos, 0.0, 10.0, 0.0, 0.0, 1.0, 1.0, 30.0)
	_check(float(climbed["altitude"]) > 0.0, "an ornithopter climbs under power")
	var landed := VehicleMotion.step(thopter, pos, 0.0, 0.0, 20.0, 0.0, 0.0, 5.0, 30.0)
	_check(_near(float(landed["altitude"]), 0.0, 0.01), "and settles when idle")

	# The field: deploy, occupancy, fuel, cargo, packing up.
	var field := VehicleField.new()
	var here := Movement.find_spawn(Vector3(80.0, 0.0, 80.0))
	var made := field.deploy("ada", here, "groundcar")
	_check(made["ok"], "a vehicle can be unloaded")
	var vid := int(made["id"])
	_check(not field.deploy("ada", here, "water")["ok"], "an ordinary item cannot be")
	_check(_near(float(field.vehicles[vid]["fuel"]), 0.0),
		"it arrives dry, so fuel stays a decision")

	var bag := Inventory.new()
	_check(not field.refuel(vid, bag)["ok"], "no cells means no fuel")
	bag.add("fuel_cell", 2)
	_check(field.refuel(vid, bag)["ok"] and bag.count_of("fuel_cell") == 1,
		"a cell fuels it and is consumed")

	_check(field.enter(7, here, vid)["ok"], "a player can climb in")
	_check(field.driven_by(7) == vid, "and is recorded as the driver")
	_check(not field.enter(9, here, vid)["ok"], "a second player cannot")
	_check(not field.enter(7, here, vid)["ok"], "and the driver cannot re-enter")
	_check(not field.enter(9, here + Vector3(500.0, 0.0, 0.0), vid)["ok"],
		"nor can someone far away")

	# Cargo goes in and comes back out.
	bag.add("granite_stone", 4)
	var slot := -1
	for i in bag.slots.size():
		if not bag.slots[i].is_empty() and str(bag.slots[i]["id"]) == "granite_stone":
			slot = i
	_check(field.transfer(7, bag, slot, true)["ok"], "cargo goes into the hold")
	_check(bag.count_of("granite_stone") == 0, "and leaves the bag")
	_check((field.vehicles[vid]["inventory"] as Inventory).count_of("granite_stone") == 4,
		"all of it, not a copy")
	_check(not field.pack_up(here, vid, "ada")["ok"],
		"a loaded vehicle refuses to be packed up")
	_check(field.transfer(7, bag, 0, false)["ok"], "cargo comes back out")

	_check(field.exit(7)["ok"], "the driver can climb out")
	_check(field.driven_by(7) == 0, "and stops being the driver")
	_check(not field.exit(7)["ok"], "getting out twice is refused")

	# Ownership, and the flying case for exiting.
	_check(not field.pack_up(here, vid, "bo")["ok"], "someone else cannot pack it up")
	_check(field.pack_up(here, vid, "ada")["ok"], "the owner can")
	_check(field.vehicles.is_empty(), "and it leaves the world")

	var sky := VehicleField.new()
	var flight := sky.deploy("ada", here, "ornithopter")
	var fid := int(flight["id"])
	sky.enter(7, here, fid)
	sky.vehicles[fid]["altitude"] = 25.0
	_check(not sky.exit(7)["ok"], "you cannot step out of a thopter in flight")
	sky.vehicles[fid]["altitude"] = 0.0
	_check(sky.exit(7)["ok"], "but you can once it is down")

	# Round trip.
	var saved := VehicleField.new()
	saved.deploy("ada", here, "groundcar")
	saved.vehicles[1]["fuel"] = 12.0
	var loaded := VehicleField.new()
	loaded.from_data(saved.to_data())
	_check(loaded.vehicles.size() == 1, "vehicles persist")
	_check(_near(float(loaded.vehicles[1]["fuel"]), 12.0), "with their fuel")
	_check(int(loaded.vehicles[1]["driver"]) == 0,
		"and nobody is still at the wheel after a restart")


func _test_guilds() -> void:
	var g := Guilds.new()
	_check(g.of_member("ada") == 0, "a new player is in no guild")

	var made := g.found("ada", "House Doon")
	_check(made["ok"], "a guild can be founded")
	_check(g.of_member("ada") == int(made["id"]), "the founder is a member")
	_check(not g.found("ada", "Another")["ok"], "you cannot found a second")
	_check(not g.found("bo", "house doon")["ok"], "names are unique, case-insensitively")
	_check(not g.found("bo", "")["ok"], "and cannot be empty")
	_check(not g.found("bo", "x".repeat(Guilds.MAX_NAME + 1))["ok"],
		"nor absurdly long")

	_check(g.join("bo", "House Doon")["ok"], "someone else can join by name")
	_check(not g.join("cy", "No Such House")["ok"], "an unknown guild is refused")

	# The one rule a guild changes.
	_check(g.allied("ada", "bo"), "guildmates are allies")
	_check(g.allied("ada", "ada"), "and everyone is their own ally")
	_check(not g.allied("ada", "cy"), "an outsider is not")

	# And it must actually reach Claims, or a guild is only a name.
	var claims := Claims.new()
	var spot := Movement.find_spawn(Vector3(120.0, 0.0, 120.0))
	claims.stake("ada", spot, 24.0, 1)
	_check(not claims.may_build("bo", spot),
		"without the register, another player is refused on ada's land")
	claims.allies = g
	_check(claims.may_build("bo", spot), "with it, a guildmate may build")
	_check(not claims.may_build("cy", spot), "and an outsider still may not")

	# Leaving, and the founder's seat.
	_check(g.leave("ada")["ok"], "a member can leave")
	_check(g.of_member("ada") == 0, "and stops being a member")
	var gid := g.of_member("bo")
	_check(str(g.guilds[gid]["founder"]) == "bo",
		"the founder's seat passes to whoever is left")
	_check(g.leave("bo")["ok"] and g.guilds.is_empty(),
		"and the last one out dissolves it")
	_check(not g.leave("cy")["ok"], "leaving a guild you are not in is refused")

	# Standing. Delivering is priced by the same value the vendor pays, so it is
	# always a real choice against selling.
	var g2 := Guilds.new()
	g2.found("ada", "House Doon")
	var id2 := g2.of_member("ada")
	_check(_near(g2.standing_of(id2), 0.0), "a new guild has no standing")
	g2.guilds[id2]["standing"] = 40.0
	_check(_near(g2.standing_of(id2), 40.0), "standing is readable")
	var rows := g2.table()
	_check(rows.size() == 1 and _near(float(rows[0][3]), 40.0),
		"and appears in the public table")

	var solo := Guilds.new()
	var bag := Inventory.new()
	bag.add("steel_ingot", 2)
	_check(not solo.deliver("ada", Vector3.ZERO, bag, 0, 1)["ok"],
		"the Landsraad will not deal with someone who has no guild")

	var round_trip := Guilds.new()
	round_trip.from_data(g2.to_data())
	_check(round_trip.of_member("ada") != 0, "guild membership persists")
	_check(_near(round_trip.standing_of(round_trip.of_member("ada")), 40.0),
		"and so does standing")


## The camera frame. Mouse-look works by rotating the movement vector on the
## client before it is predicted and before it is sent, so the server keeps
## receiving a plain world-space direction. If this convention is wrong, W walks
## sideways -- and no server-side test would ever notice, because the server
## sees a perfectly valid direction either way.
func _test_interface() -> void:
	var forward := Vector2(0.0, -1.0)
	_check(forward.rotated(0.0).is_equal_approx(forward),
		"with no mouse-look, forward is unchanged")
	var east := forward.rotated(-PI / 2.0)
	_check(_near(east.x, -1.0) and _near(east.y, 0.0, 0.001),
		"facing a quarter turn one way sends you along -x")
	var west := forward.rotated(PI / 2.0)
	_check(_near(west.x, 1.0) and _near(west.y, 0.0, 0.001),
		"and the other way along +x")
	_check(_near(forward.rotated(PI).y, 1.0),
		"turning right round sends you back the way you came")
	# Rotation must not change how far you are asking to go, or looking
	# diagonally would be a speed bonus.
	for a: float in [0.3, 1.1, 2.7, -0.8]:
		_check(_near(Vector2(1.0, -1.0).normalized().rotated(a).length(), 1.0),
			"looking about does not change your speed (%.1f rad)" % a)

	# Every page must render for a player who has nothing and has done nothing:
	# that is the state a new character is in for most of them, and a page that
	# only works once it has data is a page that crashes on first open.
	_check(Panels.PAGE_NAMES.size() == Panels.Page.size(),
		"every panel page has a name")
	_check(Panels.PAGE_NAMES.find("BAG") == Panels.Page.BAG,
		"and the names line up with the enum")


## Vertical traversal. Cliffs were walls for nine phases: `is_walkable` refused
## them, so a mesa was a hole in the map and rock -- the one surface a worm
## cannot strike through -- was reachable only where the ground happened to
## ramp. These tests are against the real terrain contract, not a mock, because
## the thing that can break is the relationship between the two.
func _test_traversal() -> void:
	# Find a real cliff edge: a walkable cell with an unwalkable neighbour that
	# stands above it. Searched rather than hard-coded, so this keeps working
	# when the region is rebuilt.
	var foot := Vector3.ZERO
	var into := Vector2.ZERO
	var found := false
	var step_m := 7.0
	var x := step_m
	while x < Terrain.size_m.x - step_m and not found:
		var z := step_m
		while z < Terrain.size_m.y - step_m:
			if Terrain.is_walkable(x, z):
				for d: Vector2 in [Vector2(step_m, 0.0), Vector2(-step_m, 0.0),
						Vector2(0.0, step_m), Vector2(0.0, -step_m)]:
					var tx := x + d.x
					var tz := z + d.y
					if not Terrain.is_walkable(tx, tz) \
							and Terrain.sample_height(tx, tz) > Terrain.sample_height(x, z) + 1.5:
						foot = Vector3(x, Terrain.sample_height(x, z), z)
						into = d.normalized()
						found = true
						break
			if found:
				break
			z += step_m
		x += step_m

	_check(found, "the region has a cliff to climb")
	if not found:
		return

	# Walking into it does nothing, which is the behaviour every earlier phase
	# depended on and must not change.
	var m := Movement.new_motion()
	var walked := Movement.step(foot, into, false, 0.1, m, null, false, false)
	_check(_near(walked.y, foot.y, 0.6), "walking into a cliff does not climb it")

	# Holding climb does.
	var pos := foot
	m = Movement.new_motion()
	var rose := false
	for i in 200:
		pos = Movement.step(pos, into, false, 0.1, m, null, false, true)
		if pos.y > foot.y + 1.5:
			rose = true
			break
	_check(rose, "holding climb takes you up the face")

	# And it costs. Compared against the same walk with climb *off* rather than
	# against a fixed height: the search only guarantees a cliff within a few
	# metres, so a walker can gain some ground legitimately on the way to it.
	# What must hold is that an exhausted climber gains no more than a walker.
	var tired := Vitals.new()
	tired.stamina = 0.0
	var stuck := foot
	var walker := foot
	var mt := Movement.new_motion()
	var mw := Movement.new_motion()
	for i in 40:
		stuck = Movement.step(stuck, into, false, 0.1, mt, tired, false, true)
		walker = Movement.step(walker, into, false, 0.1, mw, null, false, false)
	_check(_near(stuck.y, walker.y, 0.05),
		"with no stamina, holding climb does exactly nothing")
	# And with stamina, the same approach gets you higher than walking does.
	var fresh := Vitals.new()
	var climber := foot
	var mc := Movement.new_motion()
	for i in 40:
		climber = Movement.step(climber, into, false, 0.1, mc, fresh, false, true)
	_check(climber.y > walker.y + 0.5, "with stamina, it gets you above the walker")
	_check(fresh.stamina < Vitals.STAMINA_MAX, "and the climb was paid for")

	# Jumping, and coming back down.
	var flat := Movement.find_spawn(Vector3(Terrain.size_m.x * 0.5, 0.0, Terrain.size_m.y * 0.5))
	m = Movement.new_motion()
	var up := Movement.step(flat, Vector2.ZERO, false, 0.05, m, null, true, false)
	_check(up.y > flat.y, "a jump leaves the ground")
	_check(not bool(m["grounded"]), "and knows it is airborne")
	var airborne := 0
	var landed := up
	for i in 200:
		landed = Movement.step(landed, Vector2.ZERO, false, 0.05, m, null, false, false)
		if bool(m["grounded"]):
			break
		airborne += 1
	_check(bool(m["grounded"]), "and gravity brings you back")
	_check(airborne > 4 and airborne < 60,
		"in a sensible amount of time (%d ticks)" % airborne)
	_check(_near(landed.y, Terrain.sample_height(landed.x, landed.z), 0.05),
		"landing puts you exactly on the ground")

	# A jump on the flat must never hurt, or ordinary movement bleeds health.
	_check(float(m["impact"]) <= Movement.SAFE_LANDING_SPEED,
		"a jump on the flat is a safe landing (%.1f m/s)" % float(m["impact"]))

	# Stamina: sprinting spends it, resting returns it, and an empty player
	# cannot sprint. This is the budget the whole traversal system runs on.
	var v := Vitals.new()
	var before := v.stamina
	for i in 20:
		Movement.step(flat, Vector2(0.0, -1.0), true, 0.1, Movement.new_motion(), v)
	_check(v.stamina < before, "sprinting spends stamina")
	v.stamina = 0.0
	var slow := Movement.step(flat, Vector2(0.0, -1.0), true, 1.0, Movement.new_motion(), v)
	var fast := Movement.step(flat, Vector2(0.0, -1.0), true, 1.0, Movement.new_motion(), null)
	_check(flat.distance_to(slow) < flat.distance_to(fast),
		"and an exhausted player cannot sprint")
	# Regeneration waits, then returns -- otherwise tapping sprint is free.
	v.tick(0.5, 0.0, false, 1.0, 1.0)
	_check(_near(v.stamina, 0.0, 0.01), "stamina does not come back instantly")
	v.tick(3.0, 0.0, false, 1.0, 1.0)
	_check(v.stamina > 10.0, "but it does come back")
	# Holding sprint with an empty bar must still recover. The first cut of this
	# charged the recovery delay on *refused* spends too, so a player leaning on
	# Shift never regenerated a single point -- they simply walked for ever.
	var held := Vitals.new()
	held.stamina = 0.0
	held.spend_stamina(1.0)      # bottom out, marking it exhausted
	var sprinted := 0
	var peak := 0.0
	for i in 120:
		if held.spend_stamina(Vitals.SPRINT_STAMINA * 0.1):
			sprinted += 1
		held.tick(0.1, 0.0, false, 1.0, 1.0)
		peak = maxf(peak, held.stamina)
	# The high-water mark, not the level at an arbitrary instant: the whole
	# point is that it cycles, so sampling the end tells you only where in the
	# cycle the loop happened to stop.
	_check(peak > Vitals.STAMINA_MAX * Vitals.EXHAUST_RECOVER,
		"holding sprint on an empty bar still recovers (peak %.1f)" % peak)
	_check(sprinted > 10,
		"and you get to run again once it has (%d of 120 ticks)" % sprinted)
	_check(sprinted < 110, "but not the whole way (%d)" % sprinted)

	# Thirst caps the ceiling: a dry player cannot keep running.
	var dry := Vitals.new()
	dry.hydration = 0.0
	dry.stamina = 0.0
	dry.tick(30.0, 0.0, false, 1.0, 1.0)
	_check(dry.stamina < Vitals.STAMINA_MAX * 0.5,
		"and thirst caps how much of it you get")


## Spice: the cycle, the tool, and the fact that it is worth something.
##
## A blow is not a resource node -- it has a state and a window rather than a
## stock, and being on it at the wrong time is the whole mechanic. These are
## the rules the server enforces, tested without waiting out a real cycle.
func _test_spice() -> void:
	var sf := SpiceField.new()
	sf.seed(1234)
	_check(sf.fields.size() == SpiceField.TARGET_FIELDS,
		"the region gets a full set of spice fields (%d)" % sf.fields.size())

	var town := Pois.nearest("trade", Terrain.size_m.x * 0.5, Terrain.size_m.y * 0.5)
	if not town.is_empty() and Terrain.size_m.x > 2000.0:
		var near_town := 0
		for fid: int in sf.fields:
			var p: Vector3 = sf.fields[fid]["pos"]
			if Vector2(p.x - float(town["x"]), p.z - float(town["z"])).length() \
					< SpiceField.MIN_FROM_TOWN:
				near_town += 1
		_check(near_town == 0, "and none of them is on the town's doorstep")

	var all_sand := true
	for fid: int in sf.fields:
		var p: Vector3 = sf.fields[fid]["pos"]
		if Terrain.sample_surface(p.x, p.z) != Terrain.Surface.SAND:
			all_sand = false
	_check(all_sand, "every blow is out on open sand, where the worm can hear you")

	# Seeding is deterministic: a restart must bring back the same map.
	var again := SpiceField.new()
	again.seed(1234)
	var same := true
	for fid: int in sf.fields:
		if not again.fields.has(fid) or again.fields[fid]["pos"] != sf.fields[fid]["pos"]:
			same = false
	_check(same, "and the same seed lays them out the same way")

	if sf.fields.is_empty():
		return

	# The cycle. Drive it by hand rather than waiting.
	var fid1: int = sf.fields.keys()[0]
	var f: Dictionary = sf.fields[fid1]
	f["until"] = 0.0
	var r := sf.tick(1.0)
	_check((r["erupted"] as Array).has(fid1), "a dormant field erupts when its time comes")
	_check(int(f["state"]) == SpiceField.State.BLOWING, "and is blowing, not ready")
	_check(bool(r["changed"]), "and the tick reports that something changed")

	var inv := Inventory.new()
	inv.add("cutteray", 1)
	var cd := {}
	var mid: Vector3 = f["pos"]
	var during := sf.harvest(mid, inv, fid1, cd, 2.0)
	_check(not bool(during["ok"]), "you cannot cut it while it is still erupting")

	# ... and once it dries, you can.
	f["until"] = 0.0
	var r2 := sf.tick(50.0)
	_check(int(f["state"]) == SpiceField.State.DRYING, "it dries into cuttable spice")
	_check((r2["erupted"] as Array).is_empty() and bool(r2["changed"]),
		"drying is a change but not an eruption -- the bug that made a blow "
		+ "uncuttable from the client")

	var got := sf.harvest(mid, inv, fid1, cd, 51.0)
	_check(bool(got["ok"]) and int(got["count"]) > 0,
		"and cutting it yields spice sand (%d)" % int(got["count"]))
	_check(inv.count_of("spice_sand") > 0, "which lands in the bag")

	# Reach, tools and cooldown are all server rules.
	var far := mid + Vector3(SpiceField.REACH * 3.0, 0.0, 0.0)
	_check(not bool(sf.harvest(far, inv, fid1, cd, 60.0)["ok"]),
		"you have to be standing on it")
	var barehanded := Inventory.new()
	_check(not bool(sf.harvest(mid, barehanded, fid1, {}, 60.0)["ok"]),
		"and you need a cutteray")

	# It runs out.
	var guard := 0
	while int(sf.fields[fid1]["state"]) == SpiceField.State.DRYING and guard < 40:
		guard += 1
		sf.harvest(mid, inv, fid1, cd, 60.0 + float(guard) * 2.0)
	_check(guard < 40, "a blow is finite and gets picked clean")

	# Spice is the point of all of it: worth far more than a day of ore.
	_check(Vendor.value_of("spice_sand") > Vendor.value_of("iron_ore") * 10,
		"raw spice is worth more than ten ore")
	_check(Vendor.value_of("melange") > Vendor.value_of("spice_sand") * 4,
		"and refining it is worth doing")
	_check(RecipeDB.get_recipe("melange").get("station", "") == "refinery",
		"melange is refined, at a refinery")
	# Major traits cost melange, which is what makes spice a progression
	# currency rather than an expensive rock.
	var majors := 0
	for sid: String in SkillDB.all_ids():
		if int(SkillDB.get_skill(sid).get("melange", 0)) > 0:
			majors += 1
	_check(majors == 5, "each specialization has a trait that costs melange (%d)" % majors)
	_check(SpiceField.HARVEST_THREAT > 10.0,
		"and cutting it is the loudest thing you can do (x%.0f)" % SpiceField.HARVEST_THREAT)


## Granite, and the beam that takes it.
##
## Granite is the first thing the build chain needs -- foundations are granite
## and salvage -- and until now it was the one node kind you could strip with
## your bare hands, which made the cutteray pointless for two thirds of what
## the wiki says it is for.
func _test_granite() -> void:
	var field := NodeField.new()
	field.load_kinds()
	_check(field.kinds.has("stone_outcrop"), "there is a granite node kind")
	var k: Dictionary = field.kinds["stone_outcrop"]
	_check(str(k["yield_id"]) == "granite_stone", "and it yields granite")
	_check(str(k["tool"]) == "tool_gather",
		"and it takes a cutting tool, as the wiki says it should")
	_check(int(k["amount"]) > 0, "and holds a pool of units (%d)" % int(k["amount"]))

	# The tool the player starts with must actually be able to cut it.
	var start := ItemDB.get_def("improvised_cutteray")
	_check(str(start.get("use", "")) == "tool_gather",
		"the Improvised Cutteray is a cutting tool")
	_check(float(start.get("beam_rate", 0.0)) > 0.0,
		"and it is a beam (%.0f/s)" % float(start.get("beam_rate", 0.0)))
	_check(float(ItemDB.get_def("cutteray").get("beam_rate", 0.0))
		> float(start.get("beam_rate", 0.0)),
		"and the full Cutteray is the upgrade, not a rename")

	# Beam it bare-handed and it must refuse; with the tool it must not.
	field.seed()
	var nid := 0
	for id: int in field.nodes:
		if str(field.nodes[id]["kind"]) == "stone_outcrop":
			nid = id
			break
	_check(nid != 0, "granite is seeded on the map")
	if nid == 0:
		return
	var at: Vector3 = field.nodes[nid]["pos"]

	var barehanded := Inventory.new()
	var refused := field.beam(at, barehanded, nid, 4.0, 5.0, 1.0)
	_check(not bool(refused["ok"]), "bare hands cannot cut granite")

	var kitted := Inventory.new()
	kitted.add("improvised_cutteray", 1)
	var got := field.beam(at, kitted, nid, 4.0, 5.0, 1.0)
	_check(bool(got["ok"]) and int(got["count"]) == 4,
		"a second of beam takes four units (%d)" % int(got["count"]))
	_check(kitted.count_of("granite_stone") == 4, "which land in the bag")

	# Out of range is refused even with the tool in hand.
	var far := at + Vector3(50.0, 0.0, 0.0)
	_check(not bool(field.beam(far, kitted, nid, 4.0, 5.0, 1.0)["ok"]),
		"and you have to be standing at it")

	# Strip it and it goes on the respawn timer rather than staying at zero.
	var guard := 0
	while int(field.nodes[nid]["units"]) > 0 and guard < 200:
		guard += 1
		field.beam(at, kitted, nid, 4.0, 5.0, 1.0)
	_check(int(field.nodes[nid]["units"]) == 0, "an outcrop can be stripped bare")
	_check(float(field.nodes[nid]["respawn_at"]) > 0.0, "and then it regrows")

	# Granite is what foundations are made of: the chain has to close.
	var found := RecipeDB.get_recipe("foundation")
	_check(not found.is_empty(), "there is a foundation recipe")
	var uses_granite := false
	for i: Dictionary in found.get("inputs", []):
		if str(i["id"]) == "granite_stone":
			uses_granite = true
	_check(uses_granite, "and it is built from granite")


## The first base has to be buildable out of the ground.
##
## The Sub-Fief console cost two Steel Ingots, and steel comes out of a
## refinery, and a refinery is a thing you build on a holding you have staked
## with a Sub-Fief. That is a loop: the item that lets you claim ground required
## a building you could not put anywhere yet. It went unnoticed because bots are
## granted their kit and never walk the chain in order.
##
## So this is a test of the *ordering* rather than of any one recipe: everything
## needed to stake a claim, raise a shell and stand up a refinery must be
## craftable from things a player can gather with the tool they start with.
func _test_first_base() -> void:
	var refined := {}
	for rid: String in RecipeDB.ids():
		var r := RecipeDB.get_recipe(rid)
		if str(r.get("station", "")) == "refinery":
			refined[str((r["output"] as Dictionary)["id"])] = true
	_check(not refined.is_empty(), "the refinery makes something (%d)" % refined.size())

	# Everything the wiki's opening sequence asks for, in order.
	for rid: String in ["improvised_cutteray", "sub_fief", "foundation",
			"ore_refinery"]:
		var r := RecipeDB.get_recipe(rid)
		if r.is_empty():
			_check(false, "'%s' has a recipe" % rid)
			continue
		var blocked: Array = []
		for raw: Variant in r["inputs"]:
			var i: Dictionary = raw
			if refined.has(str(i["id"])):
				blocked.append(str(i["id"]))
		_check(blocked.is_empty(),
			"%s can be made before you own a refinery%s"
			% [rid, "" if blocked.is_empty() else " -- needs " + ", ".join(blocked)])

	# Nothing a player can reach before they own a refinery may need steel.
	# Steel was the only refined material in the game for ten phases, so
	# everything that wanted "some refined metal" was written against it --
	# which quietly put a three-tier material into a first-afternoon recipe.
	for rid: String in ["sub_fief", "foundation", "wall", "ore_refinery",
			"storage_chest", "improvised_cutteray", "cutteray", "dew_harvester"]:
		var r := RecipeDB.get_recipe(rid)
		var wants_steel := false
		for raw: Variant in r.get("inputs", []):
			if str((raw as Dictionary)["id"]) == "steel_ingot":
				wants_steel = true
		_check(not wants_steel, "%s does not need steel" % rid)

	# The ladder, as the wiki lays it out. Each rung may only ask for the ones
	# below it, so a tier cannot quietly collapse into the one under it again.
	var tier := {
		"salvaged_metal": 0, "granite_stone": 0, "plant_fiber": 0,
		"copper_ore": 0, "iron_ore": 0, "carbon_ore": 0, "water": 0,
		"copper_ingot": 1, "iron_ingot": 1,
		"steel_ingot": 2,
	}
	for rid: String in ["copper_ingot", "iron_ingot", "steel_ingot"]:
		var r := RecipeDB.get_recipe(rid)
		_check(not r.is_empty(), "%s has a recipe" % rid)
		if r.is_empty():
			continue
		_check(str(r["station"]) == "refinery", "%s is refined, not fabricated" % rid)
		var mine := int(tier.get(rid, 99))
		var ok := true
		for raw: Variant in r["inputs"]:
			var id := str((raw as Dictionary)["id"])
			if int(tier.get(id, 99)) >= mine:
				ok = false
		_check(ok, "%s is made only from things below it" % rid)

	# Steel specifically: carbon and iron, per the wiki, not iron alone.
	var st := RecipeDB.get_recipe("steel_ingot")
	var st_ins := {}
	for raw: Variant in st.get("inputs", []):
		st_ins[str((raw as Dictionary)["id"])] = true
	_check(st_ins.has("carbon_ore") and st_ins.has("iron_ingot"),
		"steel is carbon plus an iron ingot")

	# And the console specifically: staking ground is the first thing you do,
	# so it must be the cheapest thing in the chain.
	var fief := RecipeDB.get_recipe("sub_fief")
	var total := 0
	for raw: Variant in fief.get("inputs", []):
		total += int((raw as Dictionary)["count"])
	_check(total <= 6, "and a Sub-Fief is cheap enough to stake early (%d parts)" % total)

	_test_opening_is_not_a_deadlock()


## The first five minutes, walked through with the real rules rather than
## reasoned about. Once unclaimed ground stopped being open to build on, the
## opening became a ring: no Sub-Fief without the fabricator to craft it at, no
## fabricator on the ground without a claim, no claim without the Sub-Fief. It
## cost a whole run to find, and it is one function to catch.
func _test_opening_is_not_a_deadlock() -> void:
	var fief := RecipeDB.get_recipe("sub_fief")
	var bench := str(fief.get("station", ""))
	var field := StationField.new()
	var claims := Claims.new()
	var here := _open_ground()

	if not bench.is_empty():
		# Whatever station the console is crafted at has to be one you can put
		# down on open desert, or you can never craft the console.
		var need := ""
		for iid: String in ItemDB.ids():
			if str(ItemDB.get_def(iid).get("station", "")) == bench:
				need = iid
				break
		_check(not need.is_empty(),
			"the Sub-Fief's station ('%s') is a deployable item" % bench)
		if not need.is_empty():
			_check(field.place("ada", here, need, claims)["ok"],
				"%s goes down on open ground, so the console can be crafted"
				% ItemDB.display_name(need))

	# And the console itself.
	var staked := field.place("ada", here + Vector3(6.0, 0.0, 0.0), "sub_fief", claims)
	_check(staked["ok"], "the Sub-Fief goes down on open ground")
	if staked["ok"]:
		claims.stake("ada", field.stations[int(staked["id"])]["pos"],
			float(ItemDB.get_def("sub_fief").get("claim_radius", 0.0)),
			int(staked["id"]))

	# Everything else still needs land. That is the rule the exemption is an
	# exception to, and an exemption that swallowed it would be worse than the
	# deadlock it fixed. Well clear of the claim just staked, so "refused" means
	# unclaimed ground and not proximity to something already down.
	var away := here + Vector3(Claims.SIZE * 3.0, 0.0, 0.0)
	away.y = Terrain.sample_height(away.x, away.z)
	_check(claims.claim_at(away) == 0, "the far spot really is unclaimed")
	_check(not field.place("ada", away, "ore_refinery", claims)["ok"],
		"a refinery still may not go on unclaimed ground")

	_test_field_kit_goes_anywhere()


## Field kit is not a building. A thumper is bait you throw into open sand, a
## stilltent is shade you pitch where the sun caught you, and a Survival
## Fabricator is the bench you carry. Making the whole game need claimed land
## swept all three up with the base stations, and each one is useless the moment
## it can only be used at home -- the thumper especially, whose entire purpose
## is to be somewhere you are not.
##
## The split is stated in the data, so this checks the data means what it says
## in both directions: what is marked portable really does go down on open
## desert, and what is not really is refused there.
func _test_field_kit_goes_anywhere() -> void:
	var portable: Array = ["survival_fabricator", "stilltent", "thumper"]
	var housed: Array = ["ore_refinery", "windtrap", "water_cistern",
		"storage_chest", "fuel_generator", "wind_turbine"]

	for iid: String in portable:
		var def := ItemDB.get_def(iid)
		if def.is_empty():
			continue
		_check(bool(def.get("open_ground", false)),
			"%s is marked portable" % ItemDB.display_name(iid))
		# Each on its own field and its own patch, so "refused" can never mean
		# "something else is already standing there".
		var f := StationField.new()
		_check(f.place("ada", _open_ground(), iid, Claims.new())["ok"],
			"%s can be set down on open desert" % ItemDB.display_name(iid))

	for iid: String in housed:
		var def2 := ItemDB.get_def(iid)
		if def2.is_empty():
			continue
		_check(not bool(def2.get("open_ground", false)),
			"%s is not portable" % ItemDB.display_name(iid))
		var f2 := StationField.new()
		_check(not f2.place("ada", _open_ground(), iid, Claims.new())["ok"],
			"%s needs a holding to stand in" % ItemDB.display_name(iid))
