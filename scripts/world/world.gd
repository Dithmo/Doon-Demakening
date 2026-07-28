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

const PICKUP_RANGE := 3.0
## Rejecting inputs that claim more time than they could have taken stops a
## client speed-hacking by inflating dt. Server clamps to its own tick anyway;
## this just bounds the queue.
const MAX_QUEUED_INPUTS := 12
const SYNC_HZ := 15.0

# --- server state ------------------------------------------------------------
## peer id -> {identity, pos, inventory: Inventory, queue: Array, last_seq: int}
var _players: Dictionary = {}
var _entities: Dictionary = {}  ## entity id -> {item_id, count, pos}
var _next_entity_id: int = 1
var _sync_accum: float = 0.0

# --- client state ------------------------------------------------------------
var local_pos: Vector3 = Vector3.ZERO
var local_surface: int = Terrain.Surface.SAND
var inventory_mirror: Array = []
var entity_mirror: Dictionary = {}
var remote_players: Dictionary = {}  ## peer id -> Vector3

var _input_seq: int = 0
var _pending: Array = []  ## unacknowledged {seq, dir, sprint, dt}
var _bot_cooldown: int = 0
var _bot_stalled: int = 0
var _bot_unstick: int = 0
var _bot_last_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	if Net.is_server():
		Net.peer_joined.connect(_on_peer_joined)
		Net.peer_left.connect(_on_peer_left)
		_restore_entities()


# =============================================================================
# SERVER
# =============================================================================

func _on_peer_joined(id: int) -> void:
	var who := Net.identity_of(id)
	var saved := Store.player_state(who)

	var inv := Inventory.new()
	var pos := Movement.find_spawn(Vector3(Terrain.size_m.x * 0.5, 0.0, Terrain.size_m.y * 0.5))
	if not saved.is_empty():
		var p: Array = saved.get("pos", [])
		if p.size() == 3:
			pos = Movement.find_spawn(Vector3(float(p[0]), float(p[1]), float(p[2])))
		inv.from_data(saved.get("inventory", []))
		print("[world] restored '%s' at %v" % [who, pos])
	else:
		# Seed a new arrival with just enough to prove the loop works.
		inv.add("water", 3)
		inv.add("cutteray", 1)

	_players[id] = {
		"identity": who, "pos": pos, "inventory": inv,
		"queue": [], "last_seq": 0,
	}
	_persist_player(id)

	_full_state.rpc_id(id, _entity_wire(), pos)
	_sync_inventory.rpc_id(id, inv.to_data())


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

	_sync_accum += delta
	if _sync_accum >= 1.0 / SYNC_HZ:
		_sync_accum = 0.0
		_broadcast_players()


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
	Store.put_player(p["identity"], p["pos"], (p["inventory"] as Inventory).to_data())


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
		# Sand only: a pickup on a cliff-ringed plateau is one nobody can reach.
		if Terrain.sample_surface(x, z) != Terrain.Surface.SAND:
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
		dir = _bot_direction()
		sprint = dir != Vector2.ZERO
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


@rpc("authority", "call_remote", "reliable")
func _entity_spawned(eid: int, item_id: String, count: int, pos: Vector3) -> void:
	entity_mirror[eid] = {"item_id": item_id, "count": count, "pos": pos}
	entities_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _entity_removed(eid: int) -> void:
	entity_mirror.erase(eid)
	entities_changed.emit()


# --- client intent helpers ---------------------------------------------------

## Bot steering: head for the closest known pickup, grabbing anything in range.
## Deliberately uses only replicated state, exactly like a human client would.
func _bot_direction() -> Vector2:
	var target := 0
	var best := INF
	for eid: int in entity_mirror:
		var d: float = local_pos.distance_to(entity_mirror[eid]["pos"])
		if d < best:
			best = d
			target = eid
	if target == 0:
		return Vector2.ZERO
	if best <= PICKUP_RANGE:
		_bot_cooldown -= 1
		if _bot_cooldown <= 0:
			_bot_cooldown = 8
			try_pickup()
		return Vector2.ZERO

	var to: Vector3 = entity_mirror[target]["pos"] - local_pos
	var want := Vector2(to.x, to.z).normalized()

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
