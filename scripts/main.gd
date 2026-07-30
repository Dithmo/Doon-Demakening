extends Node3D
## Entry point. Builds the world authority on both sides and, on a client that
## has a window, the view on top of it. The server runs the identical World
## node with no view attached.

const WORLD_SCRIPT := preload("res://scripts/world/world.gd")
const VIEW_SCRIPT := preload("res://scripts/client/client_view.gd")
## Region the rules suite runs against. See --run-tests below.
const TEST_REGION := "res://data/regions/synthetic_test"

var world: Node
var _pressed: bool = false


func _ready() -> void:
	_register_input()

	if Args.has("--run-tests"):
		# Pin the rules suite to the small synthetic region unless told
		# otherwise. These are tests of rules, and they should not change
		# meaning because the world did: Phase 5 swapped the default region to
		# the real 4500 m map, where a fixture standing at (20, 20) sits 11 m
		# above sea level instead of 2 m, which silently pushed deployed
		# stations out of a reach check that measures in three dimensions.
		if not Args.has("--region"):
			Terrain.load_region(TEST_REGION)
			Pois.load_from(Terrain.region_dir)
		var suite: RefCounted = load("res://tests/survival_tests.gd").new()
		get_tree().quit(1 if suite.run() > 0 else 0)
		return

	world = WORLD_SCRIPT.new()
	world.name = "World"
	add_child(world)

	if Net.is_client() and DisplayServer.get_name() != "headless":
		var view: Node = VIEW_SCRIPT.new()
		view.name = "View"
		view.world = world
		add_child(view)

	if Net.run_seconds > 0.0:
		var t := get_tree().create_timer(Net.run_seconds)
		t.timeout.connect(_on_run_elapsed)
		if not Net.screenshot_path.is_empty():
			var shot := get_tree().create_timer(maxf(1.0, Net.run_seconds - 1.0))
			shot.timeout.connect(_capture)

	# Headless clients still need to log enough for the harness to assert on.
	if Net.is_client():
		world.inventory_changed.connect(_log_inventory)
		# Notices are the only channel for a refusal the client settles itself,
		# which is otherwise invisible to a harness reading the server's log.
		world.notice.connect(func(t: String) -> void:
			print("[notice] %s | %s" % [Net.identity, t]))
	# Panels render from the replicated mirrors and nothing else, so logging one
	# tests the interface without needing a window. The view draws the same text.
	if Net.is_client() and not Net.panel_page.is_empty():
		var beat2 := Timer.new()
		beat2.wait_time = 3.0
		beat2.timeout.connect(_log_panel)
		add_child(beat2)
		beat2.start()
	if Net.auto:
		var beat := Timer.new()
		beat.wait_time = 2.0
		beat.timeout.connect(_log_position)
		add_child(beat)
		beat.start()


func _capture() -> void:
	var img := get_viewport().get_texture().get_image()
	if img.save_png(Net.screenshot_path) == OK:
		print("[main] wrote %s" % Net.screenshot_path)
	else:
		push_error("main: could not write %s" % Net.screenshot_path)


func _log_position() -> void:
	var v: Dictionary = world.vitals_mirror
	print("[bot] %s t=%.3f %s water=%.1f heat=%.1f hp=%.1f stam=%.1f %s pos %.1f,%.1f seen %d nodes %d stations %d build %d claims %d threat=%.1f worm=%d on=%s"
		% [Net.identity, Clock.time_of_day, Clock.phase_name(),
		v["hydration"], v["heat"], v["health"],
		float(v.get("stamina", -1.0)),
		"shade" if world.shaded_mirror else "sun",
		world.local_pos.x, world.local_pos.z, world.entity_mirror.size(),
		world.node_mirror.size(), world.station_mirror.size(),
		world.build_mirror.size(), world.claim_mirror.size(),
		world.my_threat, int(world.worm_mirror["state"]),
		Terrain.surface_name(Terrain.sample_surface(world.local_pos.x, world.local_pos.z))])
	var pr: Dictionary = world.progress_mirror
	var q: Dictionary = world.quest_mirror
	print("[prog] %s lvl=%d xp=%.0f next=%.0f pts=%d solari=%d skills=%d "
		% [Net.identity, pr["level"], pr["xp"], pr["next"], pr["points"],
		pr["solari"], (pr["skills"] as Array).size()]
		+ "step=%d/%d '%s' %d/%d contracts=%d done=%d"
		% [q["step"], QuestDB.journey.size(), q["step_name"], q["step_have"],
		q["step_need"], (q["active"] as Dictionary).size(), q["done"]])
	if world.driving != 0 or not world.vehicle_mirror.is_empty():
		# Report the vehicle we are in, or failing that the fleet's first --
		# after climbing out, `driving` is 0 and keying on it printed zeros for
		# a vehicle that was sitting there with most of a tank.
		var car: Dictionary = world.vehicle_mirror.get(world.driving, {})
		if car.is_empty() and not world.vehicle_mirror.is_empty():
			car = world.vehicle_mirror[world.vehicle_mirror.keys()[0]]
		print("[veh] %s driving=%d fleet=%d fuel=%.1f alt=%.1f speed=%.1f hold=%d"
			% [Net.identity, world.driving, world.vehicle_mirror.size(),
			float(car.get("fuel", 0.0)), float(car.get("altitude", 0.0)),
			float(car.get("speed", 0.0)), world.hold_mirror.size()])
	if Net.bot_profile == "pilgrim":
		var dest: Dictionary = Pois.find_named(Net.goto_poi)
		if not dest.is_empty():
			var d := Vector2(float(dest["x"]) - world.local_pos.x,
				float(dest["z"]) - world.local_pos.z).length()
			print("[pilgrim] %s -> %s dist=%.1f %s"
				% [Net.identity, dest["name"], d,
				"ARRIVED" if d < world.ARRIVED_M else "walking"])
	if Args.has("--debug-steer"):
		var g: Vector3 = world.debug_goal
		print("      steer goal=%v dist=%.1f want=%v  walkX=%s walkZ=%s"
			% [g, world.local_pos.distance_to(g), world.debug_want,
			Terrain.is_walkable(world.local_pos.x + 1.0, world.local_pos.z),
			Terrain.is_walkable(world.local_pos.x, world.local_pos.z + 1.0)])


func _on_run_elapsed() -> void:
	if Net.is_server():
		Store.save_all()
		print("[main] server saw %d entity(ies) remaining" % world._entities.size())
		print("[main] run window elapsed, saved and exiting")
	else:
		# Final mirror size, so the harness can prove despawns reached every
		# client and not just the one that did the picking up.
		print("[mirror] %s entities=%d" % [Net.identity, world.entity_mirror.size()])
		print("[main] run window elapsed, exiting")
	get_tree().quit(0)


func _log_panel() -> void:
	var page := Panels.PAGE_NAMES.find(Net.panel_page.to_upper())
	if page < 0:
		push_warning("main: no panel page called '%s'" % Net.panel_page)
		return
	var body: Dictionary = Panels.render(page, world)
	print("[panel] %s" % Panels.header(page, world))
	for line: String in str(body["text"]).split("\n"):
		print("[panel] %s" % line)
	print("[panel] rows=%d" % (body["actions"] as Array).size())
	if Net.panel_press > 0 and not _pressed:
		_pressed = true
		var ok: bool = Panels.act(page, world, Net.panel_press - 1, body["actions"])
		print("[panel] pressed row %d: %s" % [Net.panel_press, "sent" if ok else "no such row"])


func _log_inventory() -> void:
	var summary: Array = []
	for s: Dictionary in world.inventory_mirror:
		if not s.is_empty():
			summary.append("%s x%d" % [s["id"], s["count"]])
	print("[inv] %s | %s" % [Net.identity, ", ".join(summary)])


## Actions are registered in code rather than serialised into project.godot --
## the .tscn/.godot encoding for InputEvent is verbose and near-unreviewable in
## a diff, and this keeps the binding list readable.
func _register_input() -> void:
	var binds := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT],
		# Phase 10: the desert has a vertical axis now. Climb is held, not
		# tapped -- Ctrl rather than a second Space -- because letting go is
		# how you come back down.
		"jump": [KEY_SPACE],
		"climb": [KEY_CTRL],
		"interact": [KEY_E],
		"drink": [KEY_F],
		"harvest": [KEY_G],
		"work": [KEY_R],
		"deploy": [KEY_B],
		"craft": [KEY_C],
		"build": [KEY_V],
		"demolish": [KEY_X],
		"container": [KEY_T],
		"extract": [KEY_Z],
		"drop": [KEY_Q],
		"toggle_debug": [KEY_F3],
		# Phase 8: the interface for everything Phases 6 and 7 built.
		"panel": [KEY_TAB],
		# Straight to the bag, because cycling eight pages to put a stillsuit on
		# is not an interface.
		"bag": [KEY_I],
		# H, not R: R is already "work the node in front of you", and two actions
		# on one key means every harvest also pesters the trader.
		"ask": [KEY_H],
		"vehicle": [KEY_Y],
		"refuel": [KEY_U],
		"pack": [KEY_P],
		"guild": [KEY_N],
	}
	for n in range(1, 10):
		binds["row_%d" % n] = [KEY_1 + n - 1]
	# The tenth hotbar key. Panels only ever offer nine rows, so 0 does nothing
	# while a page is open.
	binds["row_10"] = [KEY_0]

	# Swinging belongs on the mouse now that the mouse aims the camera. It used
	# to be Space, which Phase 10 needed for jumping -- and a key doing two jobs
	# is the bug this file already guards against.
	var mouse_binds := {"attack": [MOUSE_BUTTON_LEFT]}
	# Two actions on one key is a bug that does not announce itself: both fire,
	# and the one you did not want happens quietly. Phase 8 bound "ask the trader
	# what is on offer" to R, which was already "work the node in front of you",
	# and every harvest also pestered the trader. Caught by hand; now caught here.
	var claimed: Dictionary = {}
	for action: String in binds:
		for key: int in binds[action]:
			if claimed.has(key):
				push_warning("input: key %s is bound to both '%s' and '%s'"
					% [OS.get_keycode_string(key), claimed[key], action])
			else:
				claimed[key] = action

	for action: String in binds:
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
		else:
			InputMap.add_action(action)
		for key: int in binds[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)

	for action: String in mouse_binds:
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
		else:
			InputMap.add_action(action)
		for button: int in mouse_binds[action]:
			var mb := InputEventMouseButton.new()
			mb.button_index = button as MouseButton
			InputMap.action_add_event(action, mb)
