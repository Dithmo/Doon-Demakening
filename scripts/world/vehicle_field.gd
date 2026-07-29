class_name VehicleField
extends RefCounted
## Deployed vehicles: server-owned, driven by one player at a time.
##
## The registry and every rule about it live here; VehicleMotion holds the
## physics, because that half has to run on the driver too. Nothing in this
## file is ever executed on a client.
##
## A vehicle is closer to a station than to a player: it persists, it sits in
## the world when nobody is in it, and it carries an inventory. What makes it
## different is that while someone is driving, their position *is* the
## vehicle's -- which is why exiting has to put them back on legal ground.

## How close you must be to climb in.
const ENTER_RANGE := 4.5
## Where you are put down when you get out.
const EXIT_OFFSET := 3.0

## vehicle id -> {kind, item_id, owner, pos, heading, speed, altitude, fuel,
##                driver, inventory}
var vehicles: Dictionary = {}
var _next_id: int = 1


func def_of(vehicle_id: int) -> Dictionary:
	if not vehicles.has(vehicle_id):
		return {}
	return ItemDB.get_def(str(vehicles[vehicle_id]["item_id"]))


## Put a vehicle into the world. Refuses ground a vehicle could not stand on,
## so nobody deploys a groundcar inside a cliff and loses it.
func deploy(owner: String, at: Vector3, item_id: String) -> Dictionary:
	var def := ItemDB.get_def(item_id)
	var kind := str(def.get("vehicle", ""))
	if kind.is_empty():
		return {"ok": false, "msg": "%s is not a vehicle" % def.get("name", item_id), "id": 0}
	if not Terrain.is_reachable(at.x, at.z):
		return {"ok": false, "msg": "no room to unload here", "id": 0}

	var id := _next_id
	_next_id += 1
	var pos := Vector3(at.x, Terrain.sample_height(at.x, at.z), at.z)
	vehicles[id] = {
		"kind": kind, "item_id": item_id, "owner": owner,
		"pos": pos, "heading": 0.0, "speed": 0.0, "altitude": 0.0,
		# Delivered dry. Fuel is a separate craft and a separate decision --
		# a vehicle that arrived full would make the fuel economy decorative.
		"fuel": 0.0,
		"driver": 0,
		"inventory": Inventory.new(int(def.get("cargo_slots", 8))),
	}
	return {"ok": true, "msg": "unloaded %s" % def.get("name", item_id), "id": id}


func nearest(pos: Vector3, reach: float = ENTER_RANGE) -> int:
	var best := 0
	var best_d := reach
	for id: int in vehicles:
		var d: float = (vehicles[id]["pos"] as Vector3).distance_to(pos)
		if d <= best_d:
			best_d = d
			best = id
	return best


func driven_by(peer: int) -> int:
	for id: int in vehicles:
		if int(vehicles[id]["driver"]) == peer:
			return id
	return 0


func enter(peer: int, player_pos: Vector3, vehicle_id: int) -> Dictionary:
	if not vehicles.has(vehicle_id):
		return {"ok": false, "msg": "nothing to get into"}
	var v: Dictionary = vehicles[vehicle_id]
	if int(v["driver"]) != 0:
		return {"ok": false, "msg": "someone is already driving it"}
	if driven_by(peer) != 0:
		return {"ok": false, "msg": "you are already driving"}
	if player_pos.distance_to(v["pos"]) > ENTER_RANGE:
		return {"ok": false, "msg": "too far from it"}
	v["driver"] = peer
	return {"ok": true, "msg": "took the controls of %s"
		% ItemDB.display_name(str(v["item_id"])), "pos": v["pos"]}


## Get out. Returns where the player ends up, which is beside the vehicle on
## ground they can stand on -- an ornithopter set down on a mesa top is a
## legitimate place to be, but the inside of a cliff is not.
func exit(peer: int) -> Dictionary:
	var id := driven_by(peer)
	if id == 0:
		return {"ok": false, "msg": "you are not driving"}
	var v: Dictionary = vehicles[id]
	if float(v["altitude"]) > 2.0:
		return {"ok": false, "msg": "land it first"}
	v["driver"] = 0
	v["speed"] = 0.0
	var base: Vector3 = v["pos"]
	var out := Movement.find_spawn(Vector3(base.x + EXIT_OFFSET, 0.0, base.z))
	return {"ok": true, "msg": "climbed out", "pos": out, "id": id}


## Advance every occupied vehicle by one command. Returns the fuel burned, so
## the caller can report running dry once rather than every tick.
func drive(vehicle_id: int, steer: float, throttle: float, dt: float) -> Dictionary:
	var v: Dictionary = vehicles[vehicle_id]
	var def := def_of(vehicle_id)
	var before: Vector3 = v["pos"]
	var r := VehicleMotion.step(def, before, float(v["heading"]), float(v["speed"]),
		float(v["altitude"]), steer, throttle, dt, float(v["fuel"]))
	v["pos"] = r["pos"]
	v["heading"] = r["heading"]
	v["speed"] = r["speed"]
	v["altitude"] = r["altitude"]

	var travelled: float = Vector2(r["pos"].x - before.x, r["pos"].z - before.z).length()
	var used: float = minf(float(v["fuel"]), VehicleMotion.burn(def, travelled))
	var was_dry := float(v["fuel"]) <= 0.0
	v["fuel"] = maxf(0.0, float(v["fuel"]) - used)
	return {"burned": used, "ran_dry": not was_dry and float(v["fuel"]) <= 0.0,
		"pos": r["pos"], "speed": r["speed"]}


## Pour a fuel cell in. One at a time, because it is a decision about how much
## of your bag is fuel and how much is water.
func refuel(vehicle_id: int, inv: Inventory) -> Dictionary:
	if not vehicles.has(vehicle_id):
		return {"ok": false, "msg": "nothing to fuel"}
	var v: Dictionary = vehicles[vehicle_id]
	var def := def_of(vehicle_id)
	var cap: float = float(def.get("fuel_capacity", 30.0))
	if float(v["fuel"]) >= cap - 0.01:
		return {"ok": false, "msg": "tank is full"}
	if inv.count_of("fuel_cell") <= 0:
		return {"ok": false, "msg": "no fuel cells"}
	inv.remove("fuel_cell", 1)
	# One cell is a quarter of a tank whatever the vehicle, so the thopter's
	# thirst shows up as needing more of them rather than as a second number.
	v["fuel"] = minf(cap, float(v["fuel"]) + cap * 0.25)
	return {"ok": true, "msg": "fuelled to %.0f%%" % (float(v["fuel"]) / cap * 100.0),
		"fuel": float(v["fuel"])}


## Move a stack between a driver's bag and the vehicle's hold.
func transfer(peer: int, inv: Inventory, slot_index: int,
		to_vehicle: bool) -> Dictionary:
	var id := driven_by(peer)
	if id == 0:
		return {"ok": false, "msg": "you are not driving"}
	var hold: Inventory = vehicles[id]["inventory"]
	var from: Inventory = inv if to_vehicle else hold
	var into: Inventory = hold if to_vehicle else inv
	if slot_index < 0 or slot_index >= from.slots.size() or from.slots[slot_index].is_empty():
		return {"ok": false, "msg": "nothing there"}
	var stack: Dictionary = from.slots[slot_index]
	var item := str(stack["id"])
	var count := int(stack["count"])
	if not into.can_accept(item, count):
		return {"ok": false, "msg": "no room for %s" % ItemDB.display_name(item)}
	var taken := from.remove_at(slot_index, count)
	var leftover := into.add(item, taken)
	if leftover > 0:
		# can_accept said otherwise; put it back rather than void it.
		from.add(item, leftover)
	return {"ok": true, "msg": "moved %s x%d" % [ItemDB.display_name(item), taken - leftover],
		"id": id}


## Take a vehicle back into the bag. Refuses one that still has cargo in it,
## same rule as a container station -- packing it should never eat anything.
func pack_up(player_pos: Vector3, vehicle_id: int, who: String) -> Dictionary:
	if not vehicles.has(vehicle_id):
		return {"ok": false, "msg": "nothing there", "item_id": ""}
	var v: Dictionary = vehicles[vehicle_id]
	if int(v["driver"]) != 0:
		return {"ok": false, "msg": "someone is in it", "item_id": ""}
	if player_pos.distance_to(v["pos"]) > ENTER_RANGE:
		return {"ok": false, "msg": "too far away", "item_id": ""}
	if not who.is_empty() and str(v["owner"]) != who:
		return {"ok": false, "msg": "that is %s's" % v["owner"], "item_id": ""}
	var hold: Inventory = v["inventory"]
	for s: Dictionary in hold.slots:
		if not s.is_empty():
			return {"ok": false, "msg": "empty it first", "item_id": ""}
	var item := str(v["item_id"])
	vehicles.erase(vehicle_id)
	return {"ok": true, "msg": "packed up %s" % ItemDB.display_name(item),
		"item_id": item}


## Wire form: [id, item_id, x, y, z, heading, fuel, altitude, driver, speed].
##
## Speed is replicated even though only the server integrates it, because the
## driver reconciles *from* it: the alternative -- carrying the client's last
## predicted speed forward -- cannot survive the mirror being rebuilt, and
## silently resets the driver to a standstill on every sync.
func to_wire() -> Array:
	var out: Array = []
	for id: int in vehicles:
		var v: Dictionary = vehicles[id]
		var p: Vector3 = v["pos"]
		out.append([id, str(v["item_id"]), p.x, p.y, p.z, float(v["heading"]),
			float(v["fuel"]), float(v["altitude"]), int(v["driver"]),
			float(v["speed"])])
	return out


## Disk form keeps the owner and the hold, which the wire does not need.
func to_data() -> Array:
	var out: Array = []
	for id: int in vehicles:
		var v: Dictionary = vehicles[id]
		var p: Vector3 = v["pos"]
		out.append([id, str(v["item_id"]), str(v["owner"]), p.x, p.y, p.z,
			float(v["heading"]), float(v["fuel"]),
			(v["inventory"] as Inventory).to_data()])
	return out


func from_data(rows: Array) -> void:
	vehicles.clear()
	_next_id = 1
	for row: Array in rows:
		var id := int(row[0])
		var item_id := str(row[1])
		if not ItemDB.has(item_id):
			continue
		var def := ItemDB.get_def(item_id)
		var hold := Inventory.new(int(def.get("cargo_slots", 8)))
		hold.from_data(row[8])
		vehicles[id] = {
			"kind": str(def.get("vehicle", "")), "item_id": item_id,
			"owner": str(row[2]),
			"pos": Vector3(float(row[3]), float(row[4]), float(row[5])),
			"heading": float(row[6]), "speed": 0.0, "altitude": 0.0,
			"fuel": float(row[7]),
			# Nobody is driving anything across a restart.
			"driver": 0,
			"inventory": hold,
		}
		_next_id = maxi(_next_id, id + 1)
