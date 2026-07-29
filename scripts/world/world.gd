extends Node
## World authority and replication.
##
## The client sends intent; the server simulates and replicates results.
## Movement is the only thing predicted -- everything else (pickup, drop, and
## later craft/place/drink) is request -> server validates -> replicated
## result. A 100 ms delay on a pickup is unnoticeable; a desynced inventory is
## fatal, so nothing here trusts a client-side outcome.

signal inventory_changed
signal entities_changed
signal local_state_changed(pos: Vector3, surface: int)
signal vitals_changed
signal notice(text: String)
signal nodes_changed
signal stations_changed
signal build_changed
signal container_changed
signal worm_changed
signal hostiles_changed

const PICKUP_RANGE := 3.0
## Close enough to a POI to count as having got there. A wiki marker is a pin
## dropped on a picture, not a survey point, so demanding metres would be
## testing the cartography rather than the navigation.
const ARRIVED_M := 12.0
## Rejecting inputs that claim more time than they could have taken stops a
## client speed-hacking by inflating dt. Server clamps to its own tick anyway;
## this just bounds the queue.
const MAX_QUEUED_INPUTS := 12
const SYNC_HZ := 15.0
## Vitals move slowly; no reason to spend bandwidth at movement rate.
const VITALS_HZ := 4.0
## Clients extrapolate the clock between these, so it only needs to correct
## accumulated drift.
const CLOCK_SYNC_SECONDS := 10.0
## Shade is a bounded raymarch over the heightmap -- the most expensive thing
## in the server loop. At walking pace a player crosses ~0.15 m per physics
## tick, so re-solving it 30 times a second buys nothing.
const SHADE_HZ := 4.0

# --- server state ------------------------------------------------------------
## peer id -> {identity, pos, inventory: Inventory, queue: Array, last_seq: int}
var _players: Dictionary = {}
var _entities: Dictionary = {}  ## entity id -> {item_id, count, pos}
var _next_entity_id: int = 1
var _field := NodeField.new()
var _stations := StationField.new()
var _claims := Claims.new()
var _build := BuildGrid.new()
var _worm := Sandworm.new()
var _hostiles := Hostiles.new()
var _node_accum: float = 0.0
var _produce_accum: float = 0.0
## Wall-clock of the last production tick, persisted so a restart can pay out
## what the holding earned while the server was down.
var _last_production: float = 0.0
var _sync_accum: float = 0.0
var _vitals_accum: float = 0.0
var _clock_accum: float = 0.0
var _shade_accum: float = 0.0

# --- client state ------------------------------------------------------------
var local_pos: Vector3 = Vector3.ZERO
var local_surface: int = Terrain.Surface.SAND
var inventory_mirror: Array = []
var entity_mirror: Dictionary = {}
var remote_players: Dictionary = {}  ## peer id -> Vector3
## Replicated copy of our own vitals. Display only -- never simulated here.
var vitals_mirror: Dictionary = {
	"hydration": Vitals.MAX, "heat": 0.0, "health": Vitals.MAX, "alive": true,
}
var equipped_mirror: Dictionary = {}
var shaded_mirror: bool = false
var node_mirror: Dictionary = {}     ## node id -> {kind, pos, remaining}
var station_mirror: Dictionary = {}  ## station id -> {kind, item_id, pos}
var build_mirror: Array = []         ## [{piece, pos, side}]
var claim_mirror: Array = []         ## [{owner, pos, radius}]
## Contents of whichever container we last opened, plus its id.
var container_mirror: Array = []
var open_container: int = 0
var stations_in_reach: Array = []
## Replicated worm state. Display and warning only -- the server decides.
var worm_mirror: Dictionary = {"state": 0, "pos": Vector3.ZERO,
	"target": Vector3.ZERO, "timer": 0.0}
var my_threat: float = 0.0
var npc_mirror: Dictionary = {}     ## npc id -> {pos, health}
var corpse_mirror: Dictionary = {}  ## corpse id -> {pos, blood}

var _input_seq: int = 0
var _pending: Array = []  ## unacknowledged {seq, dir, sprint, dt}
var _bot_cooldown: int = 0
var _bot_use_cd: int = 0
var _bot_dew_probes: int = 0
var _bot_orbit: float = 0.0
var _bot_dune: Vector3 = Vector3.ZERO
## Last steering decision, surfaced for --debug-steer.
var debug_goal: Vector3 = Vector3.ZERO
var debug_want: Vector2 = Vector2.ZERO
var _bot_stalled: int = 0
var _bot_unstick: int = 0
var _bot_last_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	_field.load_kinds()
	if Net.is_server():
		Net.peer_joined.connect(_on_peer_joined)
		Net.peer_left.connect(_on_peer_left)
		_restore_entities()
		_restore_world()


## Resource nodes and deployed stations. Seeded once, then persisted -- a world
## that re-seeded on every boot would hand players a fresh map each session.
func _restore_world() -> void:
	var now := _now()
	var saved_nodes := Store.get_blob("nodes")
	if saved_nodes.is_empty():
		_field.seed()
	else:
		_field.from_wire(saved_nodes, now)
		print("[nodes] restored %d node(s)" % _field.nodes.size())
	_stations.from_wire(Store.get_blob("stations"))
	if not _stations.stations.is_empty():
		print("[stations] restored %d" % _stations.stations.size())
	# Camps are static furniture, so reseeding every boot is fine and keeps
	# them out of the save.
	if not Net.peaceful:
		_hostiles.seed()
	_claims.from_wire(Store.get_blob("claims"))
	_build.from_wire(Store.get_blob("build"))
	if not _build.pieces.is_empty() or not _claims.claims.is_empty():
		print("[base] restored %d claim(s), %d piece(s)"
			% [_claims.claims.size(), _build.count()])

	# Pay out what the holding earned while the server was down. Stored as a
	# Unix time because ticks_msec resets every launch.
	var stamps := Store.get_blob("production_stamp")
	var away := 0.0
	if not stamps.is_empty():
		away = maxf(0.0, float(Time.get_unix_time_from_system()) - float(stamps[0]))
	_last_production = _now()
	if away > 1.0:
		var notes := Utilities.produce(away, _claims, _stations)
		if not notes.is_empty():
			print("[offline] %.0fs away: %s" % [away, ", ".join(notes)])
	_persist_world()


func _persist_world() -> void:
	Store.put_blob("nodes", _field.to_wire())
	Store.put_blob("stations", _stations.to_wire())
	Store.put_blob("claims", _claims.to_wire())
	Store.put_blob("build", _build.to_wire())
	Store.put_blob("production_stamp", [float(Time.get_unix_time_from_system())])


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# =============================================================================
# SERVER
# =============================================================================

func _on_peer_joined(id: int) -> void:
	var who := Net.identity_of(id)
	var saved := Store.player_state(who)

	var inv := Inventory.new()
	var vit := Vitals.new()
	var equipped: Dictionary = {}
	var pos := Movement.find_spawn(Vector3(Terrain.size_m.x * 0.5, 0.0, Terrain.size_m.y * 0.5))
	if not Net.spawn_poi.is_empty():
		var at: Dictionary = Pois.find_named(Net.spawn_poi)
		if at.is_empty():
			push_warning("world: no POI named '%s' to spawn at" % Net.spawn_poi)
		else:
			pos = Movement.find_spawn(Vector3(float(at["x"]), 0.0, float(at["z"])))
	if not saved.is_empty():
		var p: Array = saved.get("pos", [])
		if p.size() == 3:
			pos = Movement.find_spawn(Vector3(float(p[0]), float(p[1]), float(p[2])))
		inv.from_data(saved.get("inventory", []))
		vit.from_data(saved.get("vitals", {}))
		for k: Variant in saved.get("equipped", {}):
			equipped[int(k)] = str(saved["equipped"][k])
		print("[world] restored '%s' at %v" % [who, pos])
	else:
		# Seed a new arrival with just enough to prove the loop works.
		inv.add("water", 3)
		inv.add("cutteray", 1)
		inv.add("dew_harvester", 1)
		# A fabricator in the starting kit: everything else is craftable, but
		# the first station cannot be, or there is no way in.
		inv.add("survival_fabricator", 1)
		if Net.start_hydration >= 0.0:
			vit.hydration = clampf(Net.start_hydration, 0.0, Vitals.MAX)
		_apply_grant(inv)

	_players[id] = {
		"identity": who, "pos": pos, "inventory": inv, "vitals": vit,
		"equipped": equipped, "cooldowns": {}, "spawn": pos,
		"queue": [], "last_seq": 0,
	}
	_persist_player(id)

	_full_state.rpc_id(id, _entity_wire(), pos)
	_sync_nodes.rpc_id(id, _field.to_wire())
	_sync_stations.rpc_id(id, _stations.to_wire())
	_sync_base.rpc_id(id, _build.to_wire(), _claims.to_wire())
	var hw := _hostiles.to_wire()
	_sync_hostiles.rpc_id(id, hw[0], hw[1])
	_sync_inventory.rpc_id(id, inv.to_data())
	_sync_equipment.rpc_id(id, equipped)
	_push_vitals(id)
	_sync_clock.rpc_id(id, Clock.time_of_day, Clock.day_number)


## Debug: hand a fresh player extra stock so a test can start partway along a
## crafting chain. Ignored unless --grant was passed to the server.
func _apply_grant(inv: Inventory) -> void:
	if Net.grant.is_empty():
		return
	for pair: String in Net.grant.split(",", false):
		var bits := pair.split(":")
		var id := bits[0].strip_edges()
		var n := int(bits[1]) if bits.size() > 1 else 1
		if ItemDB.has(id):
			inv.add(id, n)
			print("[grant] %s x%d" % [id, n])
		else:
			push_warning("grant: unknown item '%s'" % id)


func _on_peer_left(id: int) -> void:
	if _players.has(id):
		_persist_player(id)
		_players.erase(id)
	Store.save_all()


func _physics_process(delta: float) -> void:
	if Net.is_server():
		_server_tick(delta)
	elif Net.is_client():
		_client_tick(delta)


func _server_tick(delta: float) -> void:
	for id: int in _players:
		var p: Dictionary = _players[id]
		var queue: Array = p["queue"]
		while not queue.is_empty():
			var cmd: Dictionary = queue.pop_front()
			# Server uses its own tick length, never the client's claim.
			p["pos"] = Movement.step(p["pos"], cmd["dir"], cmd["sprint"], delta)
			p["last_seq"] = int(cmd["seq"])

	_simulate_vitals(delta)

	_sync_accum += delta
	if _sync_accum >= 1.0 / SYNC_HZ:
		_sync_accum = 0.0
		_broadcast_players()

	_vitals_accum += delta
	if _vitals_accum >= 1.0 / VITALS_HZ:
		_vitals_accum = 0.0
		for id: int in _players:
			_push_vitals(id)

	_node_accum += delta
	if _node_accum >= 1.0:
		_node_accum = 0.0
		var regrown := _field.tick(_now())
		if not regrown.is_empty():
			_persist_world()
			for nid: int in regrown:
				_node_state.rpc(nid, int(_field.nodes[nid]["remaining"]))

	_threat_tick(delta)

	# Production runs on the server whether or not anyone is connected -- that
	# is what makes a windtrap infrastructure rather than a button.
	_produce_accum += delta
	if _produce_accum >= 5.0:
		var since := _now() - _last_production
		_last_production = _now()
		_produce_accum = 0.0
		var made := Utilities.produce(since, _claims, _stations)
		if not made.is_empty():
			_persist_world()
			print("[produce] %s" % ", ".join(made))
			for pid: int in _players:
				_sync_stations.rpc_id(pid, _stations.to_wire())

	_clock_accum += delta
	if _clock_accum >= CLOCK_SYNC_SECONDS:
		_clock_accum = 0.0
		_sync_clock.rpc(Clock.time_of_day, Clock.day_number)


## The worm reads the same mask the player walks on: sand is exposure, rock is
## refuge. Threat, targeting and the strike all resolve here.
func _threat_tick(delta: float) -> void:
	if Net.peaceful:
		return
	var players: Dictionary = {}
	for id: int in _players:
		var p: Dictionary = _players[id]
		var pos: Vector3 = p["pos"]
		# A cave mouth counts as being off the sand. Hagga Basin South is mostly
		# open dune with rock in scattered clumps, so on the real map there are
		# stretches where the nearest outcrop is further than the worm's warning
		# gives you -- the 20 caves are what makes those stretches crossable
		# rather than simply fatal.
		var on_sand := Terrain.sample_surface(pos.x, pos.z) == Terrain.Surface.SAND \
			and not Pois.shelter_at(pos.x, pos.z)
		var moving := bool(p.get("moving", false))
		_worm.accrue(id, delta, on_sand, moving, bool(p.get("sprinting", false)),
			Combat.threat_multiplier(p["equipped"]))
		players[id] = {"pos": pos, "on_sand": on_sand,
			"alive": (p["vitals"] as Vitals).alive}

	# Thumpers pound whether or not anyone is near them -- that is the point of
	# deploying one and walking away.
	var lures: Array = []
	for sid: int in _stations.stations:
		var s: Dictionary = _stations.stations[sid]
		var noise := float(ItemDB.get_def(str(s["item_id"])).get("worm_threat", 0.0))
		if noise > 0.0:
			lures.append({"pos": s["pos"], "threat": noise * Sandworm.WAKE_THRESHOLD / 6.0})

	for e: Dictionary in _worm.tick(delta, players, lures):
		match str(e["kind"]):
			"wake":
				print("[worm] roused toward %v" % e["pos"])
			"surface":
				print("[worm] surfacing at %v -- %.0fs" % [e["pos"], Sandworm.WARNING_SECONDS])
			"strike":
				var caught: Array = e["caught"]
				print("[worm] strikes at %v, taking %d" % [e["pos"], caught.size()])
				for peer: int in caught:
					if _players.has(peer):
						var v: Vitals = _players[peer]["vitals"]
						v.health = 0.0
						v.alive = false
						_kill(peer, "Shai-Hulud")
			"lost":
				print("[worm] loses interest")
			"sated":
				print("[worm] submerges")

	for id: int in _players:
		_worm_state.rpc_id(id, _worm.to_wire(), _worm.threat_of(id))

	# Hostiles: server-side aggro, movement and damage.
	for e: Dictionary in _hostiles.tick(delta, players, _now()):
		var peer := int(e["peer"])
		if not _players.has(peer):
			continue
		var vit: Vitals = _players[peer]["vitals"]
		vit.health = maxf(0.0, vit.health - float(e["damage"]))
		if vit.health <= 0.0 and vit.alive:
			vit.alive = false
			_kill(peer, "a blade")
		else:
			_push_vitals(peer)


## Water is the clock. Everything the player decides -- where to stand, how
## fast to move, what to wear -- reaches the simulation through here.
func _simulate_vitals(delta: float) -> void:
	var exposure := Clock.exposure()
	var sun := Clock.sun_to()
	_shade_accum += delta
	var resolve_shade := _shade_accum >= 1.0 / SHADE_HZ
	if resolve_shade:
		_shade_accum = 0.0

	for id: int in _players:
		var p: Dictionary = _players[id]
		var vit: Vitals = p["vitals"]
		var pos: Vector3 = p["pos"]
		if resolve_shade or not p.has("shaded"):
			p["shaded"] = Terrain.is_shaded(pos.x, pos.z, sun)
		var shaded: bool = p["shaded"]
		var activity: float = 1.0
		if bool(p.get("sprinting", false)):
			activity = Vitals.SPRINT_DRAIN_MULT
		if vit.tick(delta, exposure, shaded, activity, ItemUse.insulation(p["equipped"])):
			_kill(id)


## `cause` is passed by whatever did the killing; only the survival tick has to
## infer it from vitals. Without that, a worm strike reported itself twice --
## once correctly, then again as heatstroke.
func _kill(id: int, cause: String = "") -> void:
	var p: Dictionary = _players[id]
	if cause.is_empty():
		cause = "dehydration" if p["vitals"].hydration <= 0.0 else "heatstroke"
	print("[death] %s died of %s at %s" % [p["identity"], cause, Clock.hhmm()])
	p["vitals"].revive()
	p["pos"] = Movement.find_spawn(p["spawn"])
	_persist_player(id)
	_player_died.rpc_id(id, cause, p["pos"])
	_push_vitals(id)


func _push_vitals(id: int) -> void:
	var p: Dictionary = _players[id]
	var v: Vitals = p["vitals"]
	_sync_vitals.rpc_id(id, v.hydration, v.heat, v.health, bool(p.get("shaded", false)))


func _broadcast_players() -> void:
	if _players.is_empty():
		return
	var wire: Array = []
	for id: int in _players:
		var p: Dictionary = _players[id]
		var pos: Vector3 = p["pos"]
		wire.append([id, pos.x, pos.y, pos.z, int(p["last_seq"])])
	_sync_players.rpc(wire)


func _persist_player(id: int) -> void:
	var p: Dictionary = _players[id]
	Store.put_player(p["identity"], p["pos"], (p["inventory"] as Inventory).to_data(),
		(p["vitals"] as Vitals).to_data(), p["equipped"])


func _entity_wire() -> Array:
	var out: Array = []
	for eid: int in _entities:
		var e: Dictionary = _entities[eid]
		var pos: Vector3 = e["pos"]
		out.append([eid, e["item_id"], e["count"], pos.x, pos.y, pos.z])
	return out


func spawn_entity(item_id: String, count: int, pos: Vector3) -> int:
	if not Net.is_server() or not ItemDB.has(item_id):
		return 0
	var eid := _next_entity_id
	_next_entity_id += 1
	var grounded := Vector3(pos.x, Terrain.sample_height(pos.x, pos.z), pos.z)
	_entities[eid] = {"item_id": item_id, "count": count, "pos": grounded}
	_persist_entities()
	_entity_spawned.rpc(eid, item_id, count, grounded)
	return eid


func _persist_entities() -> void:
	Store.put_entities(_entity_wire())


func _restore_entities() -> void:
	var saved := Store.entities()
	if saved.is_empty():
		_seed_entities()
		return
	for row: Array in saved:
		var eid := int(row[0])
		_entities[eid] = {
			"item_id": str(row[1]), "count": int(row[2]),
			"pos": Vector3(float(row[3]), float(row[4]), float(row[5])),
		}
		_next_entity_id = maxi(_next_entity_id, eid + 1)
	print("[world] restored %d entity(ies)" % _entities.size())


## Scatter pickups so a fresh world has something to interact with. Phase 2
## replaces this with real resource nodes.
func _seed_entities() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20250728
	var kinds := ["water", "plant_fiber", "salvaged_metal", "granite_stone"]
	var placed := 0
	var tries := 0
	while placed < 24 and tries < 2000:
		tries += 1
		var x := rng.randf_range(8.0, Terrain.size_m.x - 8.0)
		var z := rng.randf_range(8.0, Terrain.size_m.y - 8.0)
		# Sand only, and reachable: a pickup nobody can walk to is not loot.
		if Terrain.sample_surface(x, z) != Terrain.Surface.SAND \
				or not Terrain.is_reachable(x, z):
			continue
		var id: String = kinds[rng.randi() % kinds.size()]
		_entities[_next_entity_id] = {
			"item_id": id, "count": rng.randi_range(1, 3),
			"pos": Vector3(x, Terrain.sample_height(x, z), z),
		}
		_next_entity_id += 1
		placed += 1
	_persist_entities()
	print("[world] seeded %d entity(ies)" % placed)


# --- client -> server requests ------------------------------------------------

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _submit_input(seq: int, dx: float, dz: float, sprint: bool) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var queue: Array = _players[id]["queue"]
	if queue.size() >= MAX_QUEUED_INPUTS:
		return  # flooding or a stalled client; drop rather than let it bank time
	queue.append({"seq": seq, "dir": Vector2(dx, dz), "sprint": sprint})
	# Sprinting costs water, so the simulation needs to know about it even
	# though movement itself is resolved from the queue.
	var is_moving := dx != 0.0 or dz != 0.0
	_players[id]["moving"] = is_moving
	_players[id]["sprinting"] = sprint and is_moving


@rpc("any_peer", "call_remote", "reliable")
func _request_pickup(entity_id: int) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id) or not _entities.has(entity_id):
		return
	var p: Dictionary = _players[id]
	var e: Dictionary = _entities[entity_id]
	# Range is checked against the server's position, not a client claim.
	if (p["pos"] as Vector3).distance_to(e["pos"]) > PICKUP_RANGE:
		return
	var inv: Inventory = p["inventory"]
	var leftover := inv.add(e["item_id"], e["count"])
	if leftover == e["count"]:
		return  # bag full, entity stays put
	if leftover > 0:
		e["count"] = leftover
		_persist_entities()
	else:
		_entities.erase(entity_id)
		_persist_entities()
		_entity_removed.rpc(entity_id)
	# Audit line: one entity must never be banked twice. The harness asserts on
	# this, and it is the cheapest evidence that authority is actually holding.
	print("[pickup] %s took %s x%d entity=%d"
		% [p["identity"], e["item_id"], int(e["count"]) - leftover, entity_id])
	_persist_player(id)
	_sync_inventory.rpc_id(id, inv.to_data())


@rpc("any_peer", "call_remote", "reliable")
func _request_use(slot_index: int) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	if not (p["vitals"] as Vitals).alive:
		return
	# All validation -- time of day, cooldown, capacity -- happens here. The
	# client only ever asks which slot.
	# Deploying is the one use hook that touches world state, so it is resolved
	# here rather than inside ItemUse, which knows nothing about the world.
	var stack: Dictionary = (p["inventory"] as Inventory).slots[slot_index] \
		if slot_index >= 0 and slot_index < (p["inventory"] as Inventory).slots.size() \
		else {}
	if not stack.is_empty() and str(ItemDB.get_def(stack["id"]).get("use", "")) == "place":
		_deploy(id, slot_index, str(stack["id"]))
		return

	var result := ItemUse.apply(slot_index, p["inventory"], p["vitals"],
		p["equipped"], p["cooldowns"])
	if result["changed"]:
		_persist_player(id)
		_sync_inventory.rpc_id(id, (p["inventory"] as Inventory).to_data())
		_sync_equipment.rpc_id(id, p["equipped"])
		_push_vitals(id)
	print("[use] %s %s: %s"
		% [p["identity"], "ok" if result["ok"] else "refused", result["msg"]])
	_notice.rpc_id(id, result["msg"])


func _deploy(id: int, slot_index: int, item_id: String) -> void:
	var p: Dictionary = _players[id]
	var inv: Inventory = p["inventory"]
	var def := ItemDB.get_def(item_id)

	# A Sub-Fief console stakes the claim, so the land must be free before the
	# station goes down -- otherwise a refused claim would leave a stray console.
	var radius := float(def.get("claim_radius", 0.0))
	if radius > 0.0:
		var probe := _claims.stake(p["identity"], p["pos"], radius, 0)
		if not probe["ok"]:
			print("[place] %s refused: %s" % [p["identity"], probe["msg"]])
			_notice.rpc_id(id, str(probe["msg"]))
			return
		_claims.release(int(probe["id"]))

	var r := _stations.place(p["identity"], p["pos"], item_id, _claims)
	if r["ok"]:
		if radius > 0.0:
			_claims.stake(p["identity"], p["pos"], radius, int(r["id"]))
			_sync_base.rpc(_build.to_wire(), _claims.to_wire())
		inv.take_slot(slot_index)
		_persist_player(id)
		_persist_world()
		_sync_inventory.rpc_id(id, inv.to_data())
		_sync_stations.rpc(_stations.to_wire())
	print("[place] %s %s: %s at %.1f,%.1f"
		% [p["identity"], "ok" if r["ok"] else "refused", r["msg"],
		(p["pos"] as Vector3).x, (p["pos"] as Vector3).z])
	_notice.rpc_id(id, r["msg"])


@rpc("any_peer", "call_remote", "reliable")
func _request_harvest(node_id: int) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	if not (p["vitals"] as Vitals).alive:
		return
	# The node's remaining count is the lock. Two players swinging at the same
	# vein both land here, one at a time, and it can only be decremented to zero.
	var r := _field.harvest(p["pos"], p["inventory"], node_id, p["cooldowns"], _now())
	if r["ok"]:
		_persist_player(id)
		_persist_world()
		_sync_inventory.rpc_id(id, (p["inventory"] as Inventory).to_data())
		_node_state.rpc(node_id, int(r["remaining"]))
		print("[harvest] %s node=%d %s x%d remaining=%d"
			% [p["identity"], node_id, r["item"], r["count"], r["remaining"]])
	if not str(r["msg"]).is_empty():
		_notice.rpc_id(id, r["msg"])


@rpc("any_peer", "call_remote", "reliable")
func _request_craft(recipe_id: String) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	if not (p["vitals"] as Vitals).alive:
		return
	var r := _stations.craft(p["pos"], p["inventory"], recipe_id)
	if r["ok"]:
		_persist_player(id)
		_sync_inventory.rpc_id(id, (p["inventory"] as Inventory).to_data())
	print("[craft] %s %s: %s" % [p["identity"], "ok" if r["ok"] else "refused", r["msg"]])
	_notice.rpc_id(id, r["msg"])


@rpc("any_peer", "call_remote", "reliable")
func _request_pack_up(station_id: int) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	var inv: Inventory = p["inventory"]
	var r := _stations.pick_up(p["pos"], station_id, p["identity"], _claims)
	if r["ok"]:
		if inv.add(str(r["item_id"]), 1) > 0:
			# Put it back rather than destroy it.
			_stations.place(p["identity"], p["pos"], str(r["item_id"]), _claims)
			_notice.rpc_id(id, "no room to pack that up")
			return
		var freed := _claims.claim_for_station(station_id)
		if freed != 0:
			_claims.release(freed)
			_sync_base.rpc(_build.to_wire(), _claims.to_wire())
		_persist_player(id)
		_persist_world()
		_sync_inventory.rpc_id(id, inv.to_data())
		_sync_stations.rpc(_stations.to_wire())
	_notice.rpc_id(id, r["msg"])


@rpc("any_peer", "call_remote", "reliable")
func _request_attack() -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	if not (p["vitals"] as Vitals).alive:
		return
	# The client asks to swing; reach, cooldown and the shield rule are all
	# resolved against the server's own state.
	var weapon := Combat.weapon_of(p["equipped"])
	var npc_id := _hostiles.nearest(p["pos"], float(weapon["reach"]))
	if npc_id == 0:
		_notice.rpc_id(id, "nothing in reach")
		return
	var target_pos: Vector3 = _hostiles.npcs[npc_id]["pos"]
	# NPCs carry no shields yet, so the rule only bites player-versus-player;
	# the resolution path is shared so it cannot drift.
	var r := Combat.strike(p["pos"], p["equipped"], target_pos, {},
		p["cooldowns"], _now())
	if not r["ok"]:
		if not str(r["msg"]).is_empty():
			_notice.rpc_id(id, str(r["msg"]))
		return
	var out := _hostiles.damage(npc_id, float(r["damage"]), _now())
	print("[combat] %s: %s%s" % [p["identity"], r["msg"],
		" (killed)" if out["killed"] else ""])
	_notice.rpc_id(id, str(r["msg"]))
	var hw := _hostiles.to_wire()
	_sync_hostiles.rpc(hw[0], hw[1])


@rpc("any_peer", "call_remote", "reliable")
func _request_extract() -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	var cid := _hostiles.nearest_corpse(p["pos"], 3.0)
	if cid == 0:
		return
	var r := _hostiles.extract(p["pos"], p["inventory"], cid, p["cooldowns"], _now())
	if r["ok"]:
		_persist_player(id)
		_sync_inventory.rpc_id(id, (p["inventory"] as Inventory).to_data())
		var hw := _hostiles.to_wire()
		_sync_hostiles.rpc(hw[0], hw[1])
		print("[blood] %s %s" % [p["identity"], r["msg"]])
	if not str(r["msg"]).is_empty():
		_notice.rpc_id(id, str(r["msg"]))


@rpc("any_peer", "call_remote", "reliable")
func _request_build(slot_index: int, aim: Vector3) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	var inv: Inventory = p["inventory"]
	if slot_index < 0 or slot_index >= inv.slots.size() or inv.slots[slot_index].is_empty():
		return
	var stack: Dictionary = inv.slots[slot_index]
	var kind := str(ItemDB.get_def(stack["id"]).get("build", ""))
	if kind.is_empty():
		return

	# The client sends where it is aiming; the cell, level and wall side are
	# all derived server-side from that plus the server's own player position.
	var r := _build.build(p["identity"], p["pos"], aim, kind, _claims)
	if r["ok"]:
		inv.remove(str(stack["id"]), 1)
		_persist_player(id)
		_persist_world()
		_sync_inventory.rpc_id(id, inv.to_data())
		_sync_base.rpc(_build.to_wire(), _claims.to_wire())
		print("[build] %s %s" % [p["identity"], r["msg"]])
	else:
		print("[build] %s refused: %s" % [p["identity"], r["msg"]])
	_notice.rpc_id(id, str(r["msg"]))


@rpc("any_peer", "call_remote", "reliable")
func _request_demolish(aim: Vector3) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	var r := _build.demolish(p["identity"], p["pos"], aim, _claims)
	if r["ok"]:
		# Give the piece back; a build that cannot be undone is a trap.
		(p["inventory"] as Inventory).add(str(r["build_kind"]), 1)
		_persist_player(id)
		_persist_world()
		_sync_inventory.rpc_id(id, (p["inventory"] as Inventory).to_data())
		_sync_base.rpc(_build.to_wire(), _claims.to_wire())
	_notice.rpc_id(id, str(r["msg"]))


@rpc("any_peer", "call_remote", "reliable")
func _request_container(station_id: int, slot_index: int, to_container: bool) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	# slot_index < 0 means "just show me what is in there".
	if slot_index >= 0:
		var r := _stations.transfer(p["pos"], p["inventory"], station_id,
			slot_index, to_container)
		if r["ok"]:
			_persist_player(id)
			_persist_world()
			_sync_inventory.rpc_id(id, (p["inventory"] as Inventory).to_data())
			print("[container] %s %s" % [p["identity"], r["msg"]])
		else:
			_notice.rpc_id(id, str(r["msg"]))
	var box: Dictionary = _stations.stations.get(station_id, {})
	if box.has("inventory"):
		_sync_container.rpc_id(id, station_id, (box["inventory"] as Inventory).to_data())


@rpc("any_peer", "call_remote", "reliable")
func _request_drop(slot_index: int) -> void:
	if not Net.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not _players.has(id):
		return
	var p: Dictionary = _players[id]
	var inv: Inventory = p["inventory"]
	var taken := inv.take_slot(slot_index)
	if taken.is_empty():
		return
	spawn_entity(taken["id"], taken["count"], p["pos"])
	_persist_player(id)
	_sync_inventory.rpc_id(id, inv.to_data())


# =============================================================================
# CLIENT
# =============================================================================

func _client_tick(delta: float) -> void:
	# Nothing may be sent before the handshake resolves.
	if not Net.ready_to_play:
		return
	var dir := Vector2.ZERO
	var sprint := false
	if Net.auto:
		_bot_survive()
		dir = _bot_direction()
		# Sprinting doubles water loss, so the bot only does it with water spare.
		sprint = dir != Vector2.ZERO and (Net.bot_profile == "reckless"
			or Net.bot_profile == "prey" or Net.bot_profile == "quarry"
			or Net.bot_profile == "pilgrim"
			or float(vitals_mirror["hydration"]) > 60.0)
	else:
		if Input.is_action_pressed("move_forward"): dir.y -= 1.0
		if Input.is_action_pressed("move_back"): dir.y += 1.0
		if Input.is_action_pressed("move_left"): dir.x -= 1.0
		if Input.is_action_pressed("move_right"): dir.x += 1.0
		sprint = Input.is_action_pressed("sprint")

	_input_seq += 1
	# Predict locally, then let the server correct us.
	local_pos = Movement.step(local_pos, dir, sprint, delta)
	_pending.append({"seq": _input_seq, "dir": dir, "sprint": sprint})
	if _pending.size() > 120:
		_pending.pop_front()

	_submit_input.rpc_id(1, _input_seq, dir.x, dir.y, sprint)

	var s := Terrain.sample_surface(local_pos.x, local_pos.z)
	if s != local_surface:
		local_surface = s
	local_state_changed.emit(local_pos, local_surface)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_players(wire: Array) -> void:
	var me := multiplayer.get_unique_id()
	for row: Array in wire:
		var id := int(row[0])
		var pos := Vector3(float(row[1]), float(row[2]), float(row[3]))
		if id == me:
			_reconcile(pos, int(row[4]))
		else:
			remote_players[id] = pos


## Snap to the authoritative position, then replay every input the server had
## not yet seen. Without the replay, prediction would visibly rubber-band.
func _reconcile(server_pos: Vector3, acked_seq: int) -> void:
	while not _pending.is_empty() and int(_pending[0]["seq"]) <= acked_seq:
		_pending.pop_front()
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var pos := server_pos
	for cmd: Dictionary in _pending:
		pos = Movement.step(pos, cmd["dir"], cmd["sprint"], dt)
	local_pos = pos


@rpc("authority", "call_remote", "reliable")
func _full_state(entities: Array, spawn: Vector3) -> void:
	local_pos = spawn
	entity_mirror.clear()
	for row: Array in entities:
		entity_mirror[int(row[0])] = {
			"item_id": str(row[1]), "count": int(row[2]),
			"pos": Vector3(float(row[3]), float(row[4]), float(row[5])),
		}
	entities_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_inventory(data: Array) -> void:
	inventory_mirror = data
	inventory_changed.emit()


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_vitals(hydration: float, heat: float, health: float, shaded: bool) -> void:
	vitals_mirror["hydration"] = hydration
	vitals_mirror["heat"] = heat
	vitals_mirror["health"] = health
	shaded_mirror = shaded
	vitals_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_equipment(data: Dictionary) -> void:
	equipped_mirror = data
	inventory_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_clock(t: float, day: int) -> void:
	Clock.sync_from_server(t, day)


@rpc("authority", "call_remote", "reliable")
func _player_died(cause: String, respawn: Vector3) -> void:
	local_pos = respawn
	_pending.clear()
	notice.emit("You died of %s." % cause)
	print("[death] %s died of %s" % [Net.identity, cause])


@rpc("authority", "call_remote", "reliable")
func _notice(text: String) -> void:
	notice.emit(text)


@rpc("authority", "call_remote", "reliable")
func _sync_nodes(rows: Array) -> void:
	node_mirror.clear()
	for row: Array in rows:
		node_mirror[int(row[0])] = {
			"kind": str(row[1]),
			"pos": Vector3(float(row[2]), float(row[3]), float(row[4])),
			"remaining": int(row[5]),
		}
	nodes_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _node_state(node_id: int, remaining: int) -> void:
	if node_mirror.has(node_id):
		node_mirror[node_id]["remaining"] = remaining
		nodes_changed.emit()


@rpc("authority", "call_remote", "unreliable_ordered")
func _worm_state(wire: Array, threat: float) -> void:
	worm_mirror = {
		"state": int(wire[0]),
		"pos": Vector3(float(wire[1]), float(wire[2]), float(wire[3])),
		"target": Vector3(float(wire[4]), 0.0, float(wire[5])),
		"timer": float(wire[6]),
	}
	my_threat = threat
	worm_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_hostiles(npc_rows: Array, corpse_rows: Array) -> void:
	npc_mirror.clear()
	for row: Array in npc_rows:
		npc_mirror[int(row[0])] = {
			"pos": Vector3(float(row[1]), float(row[2]), float(row[3])),
			"health": float(row[4]),
		}
	corpse_mirror.clear()
	for row: Array in corpse_rows:
		corpse_mirror[int(row[0])] = {
			"pos": Vector3(float(row[1]), float(row[2]), float(row[3])),
			"blood": int(row[4]),
		}
	hostiles_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_base(build_rows: Array, claim_rows: Array) -> void:
	# Positions are recomputed locally from the same grid maths the server
	# used, so only the cell coordinates cross the wire.
	var grid := BuildGrid.new()
	grid.from_wire(build_rows)
	build_mirror.clear()
	for key: String in grid.pieces:
		var piece: Dictionary = grid.pieces[key]
		build_mirror.append({
			"piece": int(piece["piece"]),
			"pos": grid.piece_position(piece),
			"side": int(piece["side"]),
			"owner": str(piece["owner"]),
		})
	claim_mirror.clear()
	for row: Array in claim_rows:
		claim_mirror.append({
			"owner": str(row[1]),
			"pos": Vector3(float(row[2]), float(row[3]), float(row[4])),
			"radius": float(row[5]),
		})
	build_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_container(station_id: int, contents: Array) -> void:
	open_container = station_id
	container_mirror = contents
	container_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_stations(rows: Array) -> void:
	station_mirror.clear()
	for row: Array in rows:
		station_mirror[int(row[0])] = {
			"kind": str(row[1]), "item_id": str(row[2]),
			"pos": Vector3(float(row[3]), float(row[4]), float(row[5])),
			"owner": str(row[6]),
		}
	stations_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _entity_spawned(eid: int, item_id: String, count: int, pos: Vector3) -> void:
	entity_mirror[eid] = {"item_id": item_id, "count": count, "pos": pos}
	entities_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _entity_removed(eid: int) -> void:
	entity_mirror.erase(eid)
	entities_changed.emit()


# --- client intent helpers ---------------------------------------------------

## Bot survival: drink before dying, harvest dew while it is dark, otherwise
## keep gathering. Crude, but it exercises the whole water loop unattended --
## which is the only way to test a 20-minute day in a 60-second run.
func _bot_survive() -> void:
	if Net.bot_profile == "reckless":
		return
	if Net.bot_profile == "builder":
		_bot_use_cd -= 1
		if _bot_use_cd > 0:
			return
		_bot_use_cd = 10
		_bot_build_base()
		return
	if Net.bot_profile == "fighter":
		_bot_use_cd -= 1
		if _bot_use_cd > 0:
			return
		_bot_use_cd = 6
		if nearest_corpse() != 0:
			try_extract()
			return
		if nearest_hostile() != 0:
			try_attack()
			return
		var blade := find_use("equip")
		if blade >= 0:
			use_slot(blade)
		return
	if Net.bot_profile == "prey" or Net.bot_profile == "quarry":
		# Prey still uses what it was given: a thumper goes down, a shield goes
		# on. Both change how the worm treats it, which is the point of testing
		# them on a bot that is otherwise doing nothing clever.
		_bot_use_cd -= 1
		if _bot_use_cd > 0:
			return
		_bot_use_cd = 20
		var kit := find_use("place")
		if kit >= 0:
			use_slot(kit)
			return
		var gear := find_use("equip")
		if gear >= 0:
			use_slot(gear)
		return
	if Net.bot_profile == "forager":
		# Phase 0 behaviour only: drink to stay alive, ignore the economy.
		_bot_use_cd -= 1
		if _bot_use_cd <= 0 and float(vitals_mirror["hydration"]) < 55.0:
			var sip := find_use("hydrate")
			if sip >= 0:
				_bot_use_cd = 8
				use_slot(sip)
		return
	_bot_use_cd -= 1
	if _bot_use_cd > 0:
		return
	# One action per cooldown whatever the outcome, so a refused action cannot
	# starve everything below it.
	_bot_use_cd = 8

	if float(vitals_mirror["hydration"]) < 55.0:
		var drink := find_use("hydrate")
		if drink >= 0:
			use_slot(drink)
			return

	# Dew: ask, do not decide. A few daylight probes keep the server's refusal
	# path exercised; after that stop spending turns on it until dark.
	var dew := find_use("tool_dew")
	if dew >= 0 and (Clock.is_night() or _bot_dew_probes < 3):
		if not Clock.is_night():
			_bot_dew_probes += 1
		use_slot(dew)
		return

	# Deploy the starting fabricator so there is somewhere to craft.
	if reachable_stations().is_empty():
		var kit := find_use("place")
		if kit >= 0:
			use_slot(kit)
			return

	# Craft the deepest recipe available, so the chain runs to its end rather
	# than stalling on intermediates.
	for rid: String in ["stillsuit", "steel_ingot", "fiber_weave", "ore_refinery"]:
		if RecipeDB.has(rid) and available_recipes().has(rid) and has_inputs_for(rid):
			craft(rid)
			return

	var suit := find_use("equip")
	if suit >= 0:
		use_slot(suit)
		return

	if nearest_node() != 0:
		try_harvest()
		_bot_use_cd = 4


func _held(item_id: String) -> int:
	if item_id.is_empty():
		return 0
	var n := 0
	for s: Dictionary in inventory_mirror:
		if not s.is_empty() and s["id"] == item_id:
			n += int(s["count"])
	return n


## Station kind needed by a recipe the bot could run right now but cannot
## reach. Empty when there is nothing waiting to be made.
func _pending_craft_station() -> String:
	for rid: String in ["stillsuit", "steel_ingot", "fiber_weave", "ore_refinery"]:
		if not RecipeDB.has(rid) or not has_inputs_for(rid):
			continue
		var kind := str(RecipeDB.get_recipe(rid)["station"])
		if not kind.is_empty() and not reachable_stations().has(kind):
			return kind
	return ""


## Raise a holding in a fixed order: console first so the land is ours, then
## the kit that makes it work, then a shell around it. Deliberately dumb -- it
## exists so the Phase 3 harness can build a base without a human.
const BOT_BUILD_ORDER := ["sub_fief", "fuel_generator", "water_cistern",
	"windtrap", "storage_chest", "stilltent"]

func _bot_build_base() -> void:
	# One console only: a second would be refused on our own doorstep.
	for item_id: String in BOT_BUILD_ORDER:
		if item_id == "sub_fief" and not claim_here().is_empty():
			continue
		var have := _slot_of(item_id)
		if have < 0:
			continue
		if _deployed(item_id):
			continue
		use_slot(have)
		return

	# Then the shell, one piece per turn.
	for piece: String in ["foundation", "wall", "ceiling"]:
		if _slot_of(piece) >= 0:
			try_build()
			return

	# Finally, stow spare water in the chest -- exercises the container path.
	if nearest_container() != 0:
		if open_container == 0:
			open_nearest_container()
			return
		var spare := _slot_of("water")
		if spare >= 0:
			put_in_container(spare)


## A patch of sand with no rock anywhere near it -- the middle of a dune
## field, where a worm has nothing to interrupt it and you have nowhere to run.
func _open_sand(max_radius: float = 160.0) -> Vector3:
	var r := 20.0
	while r <= max_radius:
		var steps: int = maxi(10, int(r / 3.0))
		for i in range(steps):
			var a := TAU * float(i) / float(steps) + _bot_orbit
			var x := local_pos.x + cos(a) * r
			var z := local_pos.z + sin(a) * r
			if Terrain.sample_surface(x, z) != Terrain.Surface.SAND:
				continue
			if not Terrain.is_reachable(x, z):
				continue
			var clear := true
			for j in range(8):
				var b := TAU * float(j) / 8.0
				if Terrain.sample_surface(x + cos(b) * 22.0, z + sin(b) * 22.0) \
						!= Terrain.Surface.SAND:
					clear = false
					break
			if clear:
				return Vector3(x, Terrain.sample_height(x, z), z)
		r += 15.0
	return Vector3.ZERO


## Closest rock the bot knows about. Uses the same mask the server reads, so
## "run for cover" means the same thing on both sides.
func _nearest_rock(max_radius: float = 90.0) -> Vector3:
	var r := 4.0
	while r <= max_radius:
		var steps: int = maxi(8, int(r))
		for i in range(steps):
			var a := TAU * float(i) / float(steps)
			var x := local_pos.x + cos(a) * r
			var z := local_pos.z + sin(a) * r
			if Terrain.sample_surface(x, z) == Terrain.Surface.ROCK \
					and Terrain.is_reachable(x, z):
				return Vector3(x, Terrain.sample_height(x, z), z)
		r += 4.0
	return Vector3.ZERO


func _nearest_npc_anywhere() -> int:
	var best := 0
	var best_d := INF
	for nid: int in npc_mirror:
		var d: float = local_pos.distance_to(npc_mirror[nid]["pos"])
		if d < best_d:
			best_d = d
			best = nid
	return best


func _nearest_corpse_anywhere() -> int:
	var best := 0
	var best_d := INF
	for cid: int in corpse_mirror:
		var d: float = local_pos.distance_to(corpse_mirror[cid]["pos"])
		if d < best_d:
			best_d = d
			best = cid
	return best


func _slot_of(item_id: String) -> int:
	for i in inventory_mirror.size():
		var s: Dictionary = inventory_mirror[i]
		if not s.is_empty() and str(s["id"]) == item_id:
			return i
	return -1


func _deployed(item_id: String) -> bool:
	for sid: int in station_mirror:
		if str(station_mirror[sid]["item_id"]) == item_id:
			return true
	return false


## Bot steering: head for the nearest worthwhile thing and act on it.
## Uses only replicated state, exactly like a human client would.
func _bot_direction() -> Vector2:
	var goal := Vector3.ZERO
	var goal_dist := INF
	var goal_is_node := false
	var best_score := INF

	# Prey never seeks cover; quarry bolts for rock the moment it is warned.
	# The pair is how the harness proves the worm both kills and can be escaped.
	if Net.bot_profile == "prey" or Net.bot_profile == "quarry":
		if Net.bot_profile == "quarry" \
				and int(worm_mirror["state"]) >= Sandworm.State.ALERTED:
			var rock := _nearest_rock()
			if rock != Vector3.ZERO:
				return _steer_to(rock)
		# Get out into open desert first: circling next to the outcrop you
		# spawned beside keeps you on rock, where nothing can hear you.
		if _bot_dune == Vector3.ZERO or local_pos.distance_to(_bot_dune) < 6.0:
			var dune := _open_sand()
			if dune != Vector3.ZERO:
				_bot_dune = dune
		if _bot_dune != Vector3.ZERO and local_pos.distance_to(_bot_dune) > 5.0:
			return _steer_to(_bot_dune)
		_bot_orbit += 0.03
		return Vector2(cos(_bot_orbit), sin(_bot_orbit))

	if Net.bot_profile == "pilgrim":
		# Navigate by the map's own landmarks. Deliberately dead simple steering
		# with no pathfinding: the point of the test is that the region is
		# *crossable* -- that the mask leaves open ground between the places the
		# wiki names -- and a pathfinder would hide exactly the failure worth
		# knowing about.
		var dest: Dictionary = Pois.find_named(Net.goto_poi)
		if dest.is_empty():
			return Vector2.ZERO
		var target := Vector3(float(dest["x"]), 0.0, float(dest["z"]))
		if Vector2(target.x - local_pos.x, target.z - local_pos.z).length() < ARRIVED_M:
			return Vector2.ZERO
		return _steer_to(target)

	if Net.bot_profile == "fighter":
		var nid := _nearest_npc_anywhere()
		if nid != 0:
			return _steer_to(npc_mirror[nid]["pos"])
		var cid := _nearest_corpse_anywhere()
		if cid != 0:
			return _steer_to(corpse_mirror[cid]["pos"])
		return Vector2.ZERO

	if Net.bot_profile == "builder":
		# Drift only while there is still kit to spread out -- stations refuse
		# to stack, so they need a few metres between them. Once the last one
		# is down, stand still: build pieces are aimed relative to the player,
		# and a drifting bot scatters them one per cell, so the ceiling never
		# finds a foundation under it.
		if find_use("place") >= 0:
			_bot_orbit += 0.02
			return Vector2(cos(_bot_orbit), sin(_bot_orbit)) * 0.5
		return Vector2.ZERO

	var forager := Net.bot_profile == "forager"

	# Something is ready to make: head home. This outranks gathering outright,
	# because a node underfoot would always win on distance and the bot would
	# gather forever with a bag full of finished inputs.
	var pending := "" if forager else _pending_craft_station()
	if not pending.is_empty():
		var near_d := INF
		for sid: int in station_mirror:
			if str(station_mirror[sid]["kind"]) != pending:
				continue
			var d: float = local_pos.distance_to(station_mirror[sid]["pos"])
			if d < near_d:
				near_d = d
				goal = station_mirror[sid]["pos"]
		if near_d < INF:
			if near_d <= StationField.USE_RANGE:
				return Vector2.ZERO  # in reach; _bot_survive does the crafting
			return _steer_to(goal)

	for eid: int in entity_mirror:
		var d: float = local_pos.distance_to(entity_mirror[eid]["pos"])
		if d < best_score:
			best_score = d
			goal_dist = d
			goal = entity_mirror[eid]["pos"]
			goal_is_node = false

	# Nodes outrank loose pickups -- they are the renewable half of the economy
	# -- so they get a scoring discount. The discount must not leak into the
	# range check below, or the bot stops short and stands there forever.
	# Scarcity biases the choice, otherwise the bot mines whatever it is stood
	# next to until the bag is full of one thing and no recipe can run.
	for nid: int in (({} as Dictionary) if forager else node_mirror):
		var n: Dictionary = node_mirror[nid]
		if int(n["remaining"]) <= 0:
			continue
		var k: Dictionary = _field.kinds.get(str(n["kind"]), {})
		var held := _held(str(k.get("yield_id", "")))
		var score: float = local_pos.distance_to(n["pos"]) * 0.6 * (1.0 + float(held) * 0.08)
		if score < best_score:
			best_score = score
			goal_dist = local_pos.distance_to(n["pos"])
			goal = n["pos"]
			goal_is_node = true



	if goal_dist == INF:
		return Vector2.ZERO

	var reach := NodeField.REACH if goal_is_node else PICKUP_RANGE
	if goal_dist <= reach:
		_bot_cooldown -= 1
		if _bot_cooldown <= 0:
			_bot_cooldown = 8
			if goal_is_node:
				try_harvest()
			elif nearest_entity() != 0:
				try_pickup()
		return Vector2.ZERO

	return _steer_to(goal)


## Head toward a point, strafing when terrain traps us. The bot has no
## pathfinding, so this is test infrastructure rather than AI -- Phase 4 gives
## real threats real steering.
func _steer_to(goal: Vector3) -> Vector2:
	var to: Vector3 = goal - local_pos
	var want := Vector2(to.x, to.z).normalized()
	debug_goal = goal
	debug_want = want

	# The bot has no pathfinding, so terrain will trap it against outcrops.
	# Detect a stall and strafe for a while instead of grinding along the rim.
	# Test infrastructure, not AI -- Phase 4 gives real threats real steering.
	if _bot_unstick > 0:
		_bot_unstick -= 1
		return want.rotated(PI * 0.5)
	if local_pos.distance_to(_bot_last_pos) < 0.25:
		_bot_stalled += 1
		if _bot_stalled > 6:
			_bot_stalled = 0
			_bot_unstick = 20
	else:
		_bot_stalled = 0
	_bot_last_pos = local_pos
	return want


func nearest_entity() -> int:
	var best := 0
	var best_d := PICKUP_RANGE
	for eid: int in entity_mirror:
		var d: float = local_pos.distance_to(entity_mirror[eid]["pos"])
		if d <= best_d:
			best_d = d
			best = eid
	return best


func try_pickup() -> void:
	var eid := nearest_entity()
	if eid != 0:
		_request_pickup.rpc_id(1, eid)


func drop_slot(i: int) -> void:
	_request_drop.rpc_id(1, i)


func use_slot(i: int) -> void:
	_request_use.rpc_id(1, i)


## Closest live node within reach, or 0.
func nearest_node() -> int:
	var best := 0
	var best_d := NodeField.REACH
	for nid: int in node_mirror:
		var n: Dictionary = node_mirror[nid]
		if int(n["remaining"]) <= 0:
			continue
		var d: float = local_pos.distance_to(n["pos"])
		if d <= best_d:
			best_d = d
			best = nid
	return best


func nearest_station() -> int:
	var best := 0
	var best_d := StationField.USE_RANGE
	for sid: int in station_mirror:
		var d: float = local_pos.distance_to(station_mirror[sid]["pos"])
		if d <= best_d:
			best_d = d
			best = sid
	return best


## Station kinds the client believes are in reach. Display only -- the server
## re-checks before it consumes anything.
func reachable_stations() -> Array:
	var out: Array = []
	for sid: int in station_mirror:
		var s: Dictionary = station_mirror[sid]
		if local_pos.distance_to(s["pos"]) <= StationField.USE_RANGE \
				and not out.has(s["kind"]):
			out.append(s["kind"])
	return out


## Recipes craftable right now, as far as the client can tell.
func available_recipes() -> Array:
	var out: Array = []
	var reach := reachable_stations()
	for rid: String in RecipeDB.ids():
		var r := RecipeDB.get_recipe(rid)
		if str(r["station"]).is_empty() or reach.has(str(r["station"])):
			out.append(rid)
	return out


func has_inputs_for(recipe_id: String) -> bool:
	var r := RecipeDB.get_recipe(recipe_id)
	if r.is_empty():
		return false
	for i: Dictionary in r["inputs"]:
		var held := 0
		for s: Dictionary in inventory_mirror:
			if not s.is_empty() and s["id"] == i["id"]:
				held += int(s["count"])
		if held < int(i["count"]):
			return false
	return true


func try_harvest() -> void:
	var nid := nearest_node()
	if nid != 0:
		_request_harvest.rpc_id(1, nid)


func craft(recipe_id: String) -> void:
	_request_craft.rpc_id(1, recipe_id)


## Where the player is building: a couple of metres ahead of them. A real aim
## ray comes with a proper camera; this is enough to pick a cell.
func build_aim() -> Vector3:
	var ahead := local_pos + Vector3(0.0, 0.0, -BuildGrid.CELL * 0.75)
	ahead.y = Terrain.sample_height(ahead.x, ahead.z)
	return ahead


func try_attack() -> void:
	_request_attack.rpc_id(1, )


func try_extract() -> void:
	_request_extract.rpc_id(1, )


## Nearest live hostile within weapon reach, or 0. Display only.
func nearest_hostile() -> int:
	var best := 0
	var best_d := 3.0
	for nid: int in npc_mirror:
		var d: float = local_pos.distance_to(npc_mirror[nid]["pos"])
		if d <= best_d:
			best_d = d
			best = nid
	return best


func nearest_corpse() -> int:
	var best := 0
	var best_d := 3.0
	for cid: int in corpse_mirror:
		var d: float = local_pos.distance_to(corpse_mirror[cid]["pos"])
		if d <= best_d:
			best_d = d
			best = cid
	return best


## How much trouble the player is in, for the HUD.
func worm_warning() -> String:
	match int(worm_mirror["state"]):
		Sandworm.State.ALERTED:
			return "SOMETHING IS COMING"
		Sandworm.State.SURFACING:
			return "THE SAND IS MOVING -- %.0fs" % float(worm_mirror["timer"])
		Sandworm.State.STRIKING:
			return "SHAI-HULUD"
	if my_threat >= Sandworm.WAKE_THRESHOLD * 0.6:
		return "you are making too much noise"
	return ""


func try_build() -> void:
	var i := find_use("build")
	if i >= 0:
		_request_build.rpc_id(1, i, build_aim())


func try_demolish() -> void:
	_request_demolish.rpc_id(1, build_aim())


func open_nearest_container() -> void:
	var sid := nearest_container()
	if sid != 0:
		_request_container.rpc_id(1, sid, -1, false)


func take_from_container(slot_index: int) -> void:
	if open_container != 0:
		_request_container.rpc_id(1, open_container, slot_index, false)


func put_in_container(slot_index: int) -> void:
	if open_container != 0:
		_request_container.rpc_id(1, open_container, slot_index, true)


func nearest_container() -> int:
	var best := 0
	var best_d := StationField.USE_RANGE
	for sid: int in station_mirror:
		var s: Dictionary = station_mirror[sid]
		if int(ItemDB.get_def(str(s["item_id"])).get("container_slots", 0)) <= 0:
			continue
		var d: float = local_pos.distance_to(s["pos"])
		if d <= best_d:
			best_d = d
			best = sid
	return best


## Claim the player is standing in: {} when on open ground.
func claim_here() -> Dictionary:
	for c: Dictionary in claim_mirror:
		if Vector2(c["pos"].x - local_pos.x, c["pos"].z - local_pos.z).length() \
				<= float(c["radius"]):
			return c
	return {}


func pack_up_station() -> void:
	var sid := nearest_station()
	if sid != 0:
		_request_pack_up.rpc_id(1, sid)


## First slot holding an item with the given use hook, or -1.
func find_use(hook: String) -> int:
	for i in inventory_mirror.size():
		var s: Dictionary = inventory_mirror[i]
		if s.is_empty():
			continue
		if str(ItemDB.get_def(s["id"]).get("use", "")) == hook:
			return i
	return -1
