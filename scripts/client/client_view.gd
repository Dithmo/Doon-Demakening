extends Node3D
## Client presentation. Reads replicated state and draws it; owns no game state
## of its own. Deliberately crude -- Phase 0 is about proving the spine, and
## anything spent on looks here is spent twice when Phase 5 brings real terrain.

var world: Node

## Guild name used by the [N] key. Typing one needs a text field, which is more
## UI scaffolding than this demake's interface has earned; the name is a
## placeholder, not a design decision.
const DEFAULT_GUILD := "House Doon"

var _cam: Camera3D
var _player_mesh: MeshInstance3D
var _hud: Label
var _remote_root: Node3D
var _entity_root: Node3D
var _remote_nodes: Dictionary = {}
var _entity_nodes: Dictionary = {}
var _node_meshes: Dictionary = {}
var _station_meshes: Dictionary = {}
var _craft_root: Node3D
var _build_root: Node3D
var _threat_root: Node3D
var _worm_mesh: MeshInstance3D
var _npc_meshes: Dictionary = {}
var _corpse_meshes: Dictionary = {}
var _alarm: Label
var _sun: DirectionalLight3D
var _env: Environment
var _notice: Label
var _notice_until: float = 0.0
var _terrain: TerrainView
var _cam_yaw: float = 0.0
var _cam_last: Vector3 = Vector3.ZERO
var _vehicle_root: Node3D
var _vehicle_meshes: Dictionary = {}
var _panel: Label
var _page: int = -1          ## -1 = closed
var _actions: Array = []

## Mouse-look. Until Phase 9 the camera was pinned to your direction of travel,
## so you could not look at anything you were not walking at -- no glancing up a
## slope before climbing it, no checking behind you for a worm. `_look` is only
## authoritative while the pointer is captured; a bot client never captures it
## and keeps the old follow-the-travel camera, which is what its screenshots
## have always shown.
var _look_yaw: float = 0.0
var _look_pitch: float = -0.35
var _mouse_look: bool = false
## The node the crosshair is on, or 0. Aiming is a cone test against the
## camera's forward vector rather than a physics ray: the terrain and the nodes
## are drawn meshes with no collision bodies, so there is nothing for a ray to
## hit. A cone is also more forgiving, which is what you want for a beam.
var _aimed_node: int = 0
var _beaming: int = 0
const AIM_COS := 0.94        ## about a 20-degree cone
var _crosshair: Label
var _grid: InventoryView
const LOOK_SENS := 0.0032
const PITCH_MIN := -1.15
const PITCH_MAX := 0.45

## action name -> what pressing it does. A table rather than an if/elif chain so
## that the set of keys the client answers to is a value the program can check
## against the set of keys it registers. Phase 8 shipped six actions that were
## bound, hinted in the HUD, and handled by nobody -- build, demolish, container,
## attack, extract and the debug toggle -- and no test could see it, because
## every test drives bots that call the world methods directly and never press a
## key. `_check_coverage` below is the fix for the whole class.
var _dispatch: Dictionary = {}

## Handled in world.gd's input gathering rather than here: these are sampled
## every tick and sent with the movement command, not fired as events.
const MOTION := ["move_forward", "move_back", "move_left", "move_right", "sprint",
	"jump", "climb"]
## Handled by press *and* release rather than as a single fired action, so it
## cannot live in the dispatch table -- the whole point of the trigger is that
## holding it keeps the beam running. Listed here so the coverage guard knows it
## is answered; it caught this the moment the action left the table, which is
## what the guard is for.
const HELD := ["attack"]


func _ready() -> void:
	_terrain = TerrainView.new()
	add_child(_terrain)
	_build_lighting()

	_player_mesh = _capsule(Color(0.86, 0.74, 0.52))
	add_child(_player_mesh)

	_remote_root = Node3D.new()
	_entity_root = Node3D.new()
	add_child(_remote_root)
	add_child(_entity_root)

	_cam = Camera3D.new()
	_cam.fov = 65.0
	add_child(_cam)

	_hud = Label.new()
	_hud.position = Vector2(12, 10)
	_hud.add_theme_color_override("font_color", Color(1, 0.95, 0.85))
	_hud.add_theme_font_size_override("font_size", 14)
	var layer := CanvasLayer.new()
	layer.add_child(_hud)
	add_child(layer)

	_panel = Label.new()
	_panel.position = Vector2(12, 300)
	_panel.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	_panel.add_theme_font_size_override("font_size", 13)
	layer.add_child(_panel)

	# A beam needs somewhere to point. Centre of the screen, drawn under
	# everything else that matters.
	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_crosshair.add_theme_font_size_override("font_size", 22)
	layer.add_child(_crosshair)

	_notice = Label.new()
	_notice.position = Vector2(12, 200)
	_notice.add_theme_color_override("font_color", Color(1.0, 0.86, 0.6))
	_notice.add_theme_font_size_override("font_size", 17)
	layer.add_child(_notice)

	_craft_root = Node3D.new()
	add_child(_craft_root)
	_build_root = Node3D.new()
	add_child(_build_root)
	_threat_root = Node3D.new()
	add_child(_threat_root)
	_vehicle_root = Node3D.new()
	add_child(_vehicle_root)
	_worm_mesh = MeshInstance3D.new()
	var mound := SphereMesh.new()
	mound.radius = Sandworm.STRIKE_RADIUS * 0.5
	mound.height = Sandworm.STRIKE_RADIUS
	_worm_mesh.mesh = mound
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.42, 0.31, 0.22)
	_worm_mesh.material_override = wmat
	_worm_mesh.visible = false
	_threat_root.add_child(_worm_mesh)

	# The worm warning is the most important text on screen: it is the whole
	# difference between an unfair death and a decision.
	_alarm = Label.new()
	_alarm.position = Vector2(12, 250)
	_alarm.add_theme_color_override("font_color", Color(1.0, 0.42, 0.28))
	_alarm.add_theme_font_size_override("font_size", 26)
	layer.add_child(_alarm)

	# The grid draws over everything, so it goes on the layer last.
	_grid = InventoryView.new()
	_grid.world = world
	layer.add_child(_grid)
	world.hotbar_changed.connect(func() -> void: _grid.queue_redraw())

	_build_dispatch()
	_check_coverage()
	# A bot has no pointer and its screenshots have always used the
	# follow-the-travel camera; capturing for one would change what every
	# existing harness looks at, for no gain.
	if not Net.auto:
		_set_mouse_look(true)

	# --panel opens a page for a screenshot or a manual look.
	if not Net.panel_page.is_empty():
		_page = Panels.PAGE_NAMES.find(Net.panel_page.to_upper())

	# --do fires actions through the same table the keyboard uses, once, after
	# enough of a delay for the first station and hostile syncs to arrive --
	# and before the --press tick at 3 s, so "open the chest then take from it"
	# is expressible in one run.
	if not Net.do_actions.is_empty():
		var t := get_tree().create_timer(2.5)
		t.timeout.connect(_run_debug_actions)
	if not Net.drags.is_empty():
		# After --do, so a run can select a hotbar key and then drag onto it.
		var dt := get_tree().create_timer(2.8)
		dt.timeout.connect(_run_debug_drags)

	world.vehicles_changed.connect(_refresh_vehicles)
	world.worm_changed.connect(_refresh_worm)
	world.hostiles_changed.connect(_refresh_hostiles)
	world.build_changed.connect(_refresh_build)
	world.nodes_changed.connect(_refresh_nodes)
	world.stations_changed.connect(_refresh_stations)
	world.entities_changed.connect(_refresh_entities)
	world.inventory_changed.connect(_refresh_hud)
	world.vitals_changed.connect(_refresh_hud)
	world.notice.connect(_show_notice)


func _show_notice(text: String) -> void:
	_notice.text = text
	_notice_until = Time.get_ticks_msec() / 1000.0 + 3.0


func _process(_delta: float) -> void:
	var p: Vector3 = world.local_pos
	_terrain.update_around(p)
	_player_mesh.position = p + Vector3.UP * 0.9

	# With the pointer captured the camera is yours: orbit it with the mouse and
	# walk relative to it. Without one -- a bot, or after Escape -- it falls back
	# to following your direction of travel, which is what it did before Phase 9
	# and what every existing harness screenshot shows.
	var focus := p + Vector3.UP * 1.5
	var dist := 10.0 if world.driving == 0 else 15.0
	if _mouse_look:
		var look := Vector3(
			sin(_look_yaw) * cos(_look_pitch),
			sin(_look_pitch),
			-cos(_look_yaw) * cos(_look_pitch))
		_cam.position = focus - look * dist
		# Never let the camera sink into the dune behind you.
		var ground := Terrain.sample_height(_cam.position.x, _cam.position.z) + 1.2
		_cam.position.y = maxf(_cam.position.y, ground)
	else:
		var travelled := Vector2(p.x - _cam_last.x, p.z - _cam_last.z)
		if world.driving != 0 and world.vehicle_mirror.has(world.driving):
			_cam_yaw = float(world.vehicle_mirror[world.driving]["heading"])
		elif travelled.length() > 0.05:
			_cam_yaw = lerp_angle(_cam_yaw, atan2(travelled.x, -travelled.y), 0.12)
		var back := Vector3(-sin(_cam_yaw), 0.0, cos(_cam_yaw))
		var high := 7.5 if world.driving == 0 else 10.0
		_cam.position = p + back * dist + Vector3.UP * high
	_cam_last = p
	_cam.look_at(focus, Vector3.UP)

	for id: int in world.remote_players:
		if not _remote_nodes.has(id):
			var m := _capsule(Color(0.45, 0.62, 0.78))
			_remote_root.add_child(m)
			_remote_nodes[id] = m
		# Remote peers arrive at SYNC_HZ, so smooth toward the last known point
		# instead of snapping 15 times a second.
		var node: MeshInstance3D = _remote_nodes[id]
		var want: Vector3 = world.remote_players[id] + Vector3.UP * 0.9
		node.position = node.position.lerp(want, 0.25)

	for id: int in _remote_nodes.keys():
		if not world.remote_players.has(id):
			(_remote_nodes[id] as Node).queue_free()
			_remote_nodes.erase(id)

	if _crosshair != null:
		var vp := get_viewport().get_visible_rect().size
		_crosshair.position = vp * 0.5 - Vector2(7.0, 15.0)
	_update_aim()

	_advance_sky()
	_refresh_panel()
	_refresh_vehicles()
	_refresh_worm()
	if Time.get_ticks_msec() / 1000.0 > _notice_until and not _notice.text.is_empty():
		_notice.text = ""
	_refresh_hud()


## Drive the visible sun from the same Clock the server charges water against,
## so what looks like shade is shade.
func _advance_sky() -> void:
	var sun := Clock.sun_to()
	if sun.length_squared() > 0.001:
		_sun.look_at_from_position(Vector3.ZERO, -sun, Vector3.UP)
	var alt := Clock.sun_altitude()
	var day := clampf(alt, 0.0, 1.0)
	_sun.light_energy = lerpf(0.0, 1.3, day)
	_sun.light_color = Color(1.0, 0.94, 0.82).lerp(Color(1.0, 0.72, 0.45),
		clampf(1.0 - day * 2.5, 0.0, 1.0))
	var sky := Color(0.05, 0.06, 0.11).lerp(Color(0.78, 0.68, 0.55), clampf(alt * 2.0 + 0.35, 0.0, 1.0))
	_env.background_color = sky
	_env.fog_light_color = sky
	_env.ambient_light_energy = lerpf(0.12, 0.62, clampf(alt * 2.0 + 0.3, 0.0, 1.0))


func _build_dispatch() -> void:
	_dispatch = {
		"interact": func() -> void: world.try_pickup(),
		"drink": func() -> void: _use_hook("hydrate"),
		"harvest": func() -> void: _use_hook("tool_dew"),
		"craft_menu": func() -> void:
			_page = -1 if _page == Panels.Page.CRAFT else Panels.Page.CRAFT
			_refresh_panel(),
		# One "work what is in front of me" key. A blow wins over a node when
		# both are in reach: you are standing in spice, that is what you meant.
		"work": func() -> void:
			if world.nearest_spice() != 0:
				world.cut_spice()
			else:
				world.try_harvest(),
		"craft": _craft_first,
		"drop": _drop_first,
		"panel": _cycle_page,
		"ask": func() -> void: world.ask_contracts(),
		"refuel": func() -> void: world.refuel_vehicle(),
		"pack": func() -> void: world.pack_vehicle(),
		"vehicle": _toggle_vehicle,
		"guild": _toggle_guild,
		# Phase 9. Every one of these was already implemented, replicated and
		# tested server-side; none of them had a key that reached it.
		"build": func() -> void: world.try_build(),
		"demolish": func() -> void: world.try_demolish(),

		"extract": func() -> void: world.try_extract(),
		"container": _toggle_container,
		# Not a key: the trigger is a mouse button held down, and a harness
		# cannot press one. Phase 9's lesson was that an action no test can
		# reach is an action that quietly stops working, so the trigger gets an
		# entry here and the mouse calls the same two functions.
		"trigger": _pull_trigger,
		"release": _release_trigger,
		"toggle_debug": func() -> void: _hud.visible = not _hud.visible,
		# The grid, not the text page. The text BAG page is still on the Tab
		# cycle and is what the headless harness reads, but a person opening
		# their bag should get the thing they can drag items around in.
		"bag": _toggle_grid,
	}
	for n in range(1, Panels.HOTBAR_KEYS + 1):
		_dispatch["row_%d" % n] = _act_on_row.bind(n - 1)


## Warn about any registered action nothing answers to. The registration list
## lives in main.gd and the handling lives here, and nothing used to hold the
## two against each other -- which is exactly how six keys came to be advertised
## in the HUD while doing nothing at all.
func _run_debug_actions() -> void:
	for name: String in Net.do_actions.split(",", false):
		var action := name.strip_edges()
		if not _dispatch.has(action):
			print("[do] no action called '%s'" % action)
			continue
		(_dispatch[action] as Callable).call()
		print("[do] fired '%s'" % action)


func _check_coverage() -> void:
	for action: StringName in InputMap.get_actions():
		var name := str(action)
		if name.begins_with("ui_") or MOTION.has(name) or HELD.has(name) \
				or _dispatch.has(name):
			continue
		push_warning("input: '%s' is bound to a key but nothing handles it" % name)


func _use_hook(hook: String) -> void:
	var i: int = world.find_use(hook)
	if i >= 0:
		world.use_slot(i)


func _craft_first() -> void:
	# Cycles the first craftable recipe. The panel is the considered way to do
	# this; the key stays for speed.
	for rid: String in world.available_recipes():
		if world.has_inputs_for(rid):
			world.craft(rid)
			return


func _drop_first() -> void:
	for i in (world.inventory_mirror as Array).size():
		if not (world.inventory_mirror[i] as Dictionary).is_empty():
			world.drop_slot(i)
			return


## Tab cycles pages and wraps round to closed, so one key both opens and
## dismisses it.
func _cycle_page() -> void:
	_page += 1
	if _page >= Panels.PAGE_NAMES.size():
		_page = -1
	_refresh_panel()


func _toggle_vehicle() -> void:
	if world.driving != 0:
		world.exit_vehicle()
	else:
		world.enter_vehicle()


func _toggle_guild() -> void:
	if world.my_guild == 0:
		world.found_guild(DEFAULT_GUILD)
	else:
		world.leave_guild()


## Opening a chest also turns to its page, because a container you cannot see
## the contents of is not open in any sense that matters.
func _toggle_container() -> void:
	if world.open_container != 0:
		world.close_container()
		if _page == Panels.Page.CONTAINER:
			_page = -1
	else:
		world.open_nearest_container()
		_page = Panels.Page.CONTAINER
	_refresh_panel()


func _input(event: InputEvent) -> void:
	# While the bag is open the pointer belongs to the grid, not the camera.
	if _grid != null and _grid.is_open():
		if event is InputEventMouseButton or event is InputEventMouseMotion:
			if _grid.handle_mouse(event):
				get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion and _mouse_look:
		var mm := event as InputEventMouseMotion
		_look_yaw -= mm.relative.x * LOOK_SENS
		_look_pitch = clampf(_look_pitch - mm.relative.y * LOOK_SENS,
			PITCH_MIN, PITCH_MAX)
		# The server is told a direction in world space, exactly as before, so
		# moving relative to the camera is purely a client-side rotation of the
		# same vector and prediction stays byte-identical to the server's step.
		world.look_yaw = _look_yaw
	elif event.is_action_pressed("ui_cancel"):
		_set_mouse_look(false)
	elif event.is_action_pressed("attack") and _mouse_look:
		_pull_trigger()
	elif event.is_action_released("attack"):
		_release_trigger()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and not _mouse_look:
		# The first click reclaims the pointer rather than swinging: otherwise
		# clicking back into the window after Esc would attack whatever happened
		# to be standing there.
		_set_mouse_look(true)
		get_viewport().set_input_as_handled()


func _set_mouse_look(on: bool) -> void:
	_mouse_look = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE
	# Handing control back must also hand back the movement frame, or releasing
	# the pointer would silently leave W pointing somewhere other than the way
	# the camera is now facing.
	world.look_yaw = _look_yaw if on else 0.0


func _unhandled_input(event: InputEvent) -> void:
	for action: String in _dispatch:
		if event.is_action_pressed(action):
			(_dispatch[action] as Callable).call()
			return


## What a number key does depends on the open page. The dispatch itself lives in
## Panels, next to the pages that define the rows, so the keyboard and the
## harness go through one implementation.
func _act_on_row(i: int) -> void:
	if _page < 0:
		# No page open: the number keys are the hotbar, which is what they are
		# for most of the time you are playing.
		world.hold_key(i)
		return
	Panels.act(_page, world, i, _actions)


func _refresh_panel() -> void:
	if _panel == null:
		return
	if _page < 0:
		_panel.text = ""
		_actions = []
		return
	var body: Dictionary = Panels.render(_page, world)
	_actions = body["actions"]
	_panel.text = "%s\n%s\n[Tab] next page" % [Panels.header(_page, world), body["text"]]


func _refresh_hud() -> void:
	if _hud == null:
		return
	var lines: Array = []
	var s: int = world.local_surface
	var v: Dictionary = world.vitals_mirror
	lines.append("%s  |  peers %d  |  day %d  %s  %s"
		% [Net.identity, world.remote_players.size() + 1, Clock.day_number,
		Clock.hhmm(), Clock.phase_name()])
	lines.append("WATER  %s %3.0f" % [_bar(float(v["hydration"]) / Vitals.MAX), v["hydration"]])
	lines.append("HEAT   %s %3.0f" % [_bar(float(v["heat"]) / Vitals.MAX), v["heat"]])
	lines.append("HEALTH %s %3.0f" % [_bar(float(v["health"]) / Vitals.MAX), v["health"]])
	# Stamina gates sprinting, jumping and climbing, so it belongs next to the
	# other three rather than buried in a panel.
	var smax := maxf(1.0, float(v.get("max_stamina", Vitals.STAMINA_MAX)))
	lines.append("VIGOUR %s %3.0f" % [_bar(float(v.get("stamina", smax)) / smax),
		float(v.get("stamina", smax))])
	# Threat sits next to the surface reading on purpose: the two together are
	# the decision the player is making.
	lines.append("THREAT %s %3.0f   %s"
		% [_bar(world.my_threat / Sandworm.MAX_THREAT), world.my_threat,
		"EXPOSED" if world.local_surface == Terrain.Surface.SAND else "sheltered"])
	lines.append("pos %.1f, %.1f   surface %s   %s"
		% [world.local_pos.x, world.local_pos.z, Terrain.surface_name(s),
		"IN SHADE" if world.shaded_mirror else "EXPOSED"])

	var worn: Array = []
	for slot: int in world.equipped_mirror:
		worn.append(ItemDB.display_name(str(world.equipped_mirror[slot])))
	if worn:
		lines.append("worn: " + ", ".join(worn))

	var carried: Array = []
	for slot: Dictionary in world.inventory_mirror:
		if not slot.is_empty():
			carried.append("%s x%d" % [ItemDB.display_name(slot["id"]), slot["count"]])
	lines.append("bag: " + (", ".join(carried) if carried else "(empty)"))

	var claim: Dictionary = world.claim_here()
	if not claim.is_empty():
		lines.append("holding: %s%s" % [claim["owner"],
			"  (yours)" if str(claim["owner"]) == Net.identity else "  -- keep out"])

	if world.open_container != 0:
		var inside: Array = []
		for slot: Dictionary in world.container_mirror:
			if not slot.is_empty():
				inside.append("%s x%d" % [ItemDB.display_name(slot["id"]), slot["count"]])
		lines.append("container: " + (", ".join(inside) if inside else "(empty)"))

	var reach: Array = world.reachable_stations()
	if reach:
		var craftable: Array = []
		for rid: String in world.available_recipes():
			if world.has_inputs_for(rid):
				craftable.append(RecipeDB.get_recipe(rid)["name"])
		lines.append("at %s -- can make: %s"
			% [", ".join(reach), ", ".join(craftable) if craftable else "(nothing yet)"])

	# A live blow is time-critical and worth more than anything else on screen,
	# so it gets its own line rather than a hint at the end.
	var blows: Array = []
	for fid: int in world.spice_mirror:
		var f: Dictionary = world.spice_mirror[fid]
		var d: int = int(world.local_pos.distance_to(f["pos"]))
		blows.append("%s %s %d m" % [f["name"], SpiceField.state_name(int(f["state"])), d])
	if blows:
		lines.append("SPICE: " + "   ".join(blows))

	# What the crosshair is on, and how much is left in it. This is the readout
	# the beam is played against.
	if _aimed_node != 0 and world.node_mirror.has(_aimed_node):
		var an: Dictionary = world.node_mirror[_aimed_node]
		var kn := str(world._field.kinds.get(str(an["kind"]), {}).get("name", an["kind"]))
		lines.append("AIM: %s -- %d left%s"
			% [kn, int(an.get("units", 0)), "   CUTTING" if _beaming != 0 else ""])

	var hints: Array = []
	var nid: int = world.nearest_node()
	if nid != 0:
		var n: Dictionary = world.node_mirror[nid]
		var kname := str(world._field.kinds.get(str(n["kind"]), {}).get("name", n["kind"]))
		hints.append("[R] work %s (%d left)" % [kname, int(n["remaining"])])
	if world.nearest_entity() != 0:
		hints.append("[E] pick up")
	if world.find_use("hydrate") >= 0:
		hints.append("[F] drink")
	if world.find_use("tool_dew") >= 0:
		hints.append("[G] harvest dew" + ("" if Clock.is_night() else " (needs dark)"))
	if world.find_use("place") >= 0:
		hints.append("[B] deploy")
	if world.find_use("build") >= 0:
		hints.append("[V] build  [X] remove")
	if world.nearest_spice() != 0:
		hints.append("[R] cut spice")
	if world.nearest_container() != 0:
		hints.append("[T] %s chest" % ("close" if world.open_container != 0 else "open"))
	if world.nearest_hostile() != 0:
		hints.append("[Space] attack")
	if world.nearest_corpse() != 0:
		hints.append("[Z] draw water")
	if world.nearest_vehicle() != 0 or world.driving != 0:
		hints.append("[Y] %s" % ("get out" if world.driving != 0 else "climb in"))
	if reach:
		hints.append("[C] craft")
	hints.append("[Q] drop")
	lines.append(" ".join(hints))
	# The bar itself. Ten slots, the selected one in brackets.
	var bar: Array = []
	for k in Panels.HOTBAR_KEYS:
		var stack: Dictionary = world.hotbar_item(k)
		var label: String = ItemDB.display_name(str(stack["id"])) if not stack.is_empty() else "-"
		var key := "0" if k == 9 else str(k + 1)
		bar.append(("[%s:%s]" if k == int(world.held_key) else " %s:%s ") % [key, label])
	lines.append("HAND " + "".join(bar))
	lines.append("[I] bag  [Tab] pages  %s"
		% ("[Esc] free the mouse" if _mouse_look else "[click] look around"))
	_hud.text = "\n".join(lines)


func _bar(frac: float) -> String:
	var filled := int(round(clampf(frac, 0.0, 1.0) * 20.0))
	return "[" + "#".repeat(filled) + "-".repeat(20 - filled) + "]"


func _refresh_entities() -> void:
	for eid: int in world.entity_mirror:
		if _entity_nodes.has(eid):
			continue
		var m := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.5, 0.5, 0.5)
		m.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.95, 0.78, 0.32)
		mat.emission_enabled = true
		mat.emission = Color(0.5, 0.35, 0.1)
		m.material_override = mat
		m.position = world.entity_mirror[eid]["pos"] + Vector3.UP * 0.35
		_entity_root.add_child(m)
		_entity_nodes[eid] = m

	for eid: int in _entity_nodes.keys():
		if not world.entity_mirror.has(eid):
			(_entity_nodes[eid] as Node).queue_free()
			_entity_nodes.erase(eid)


## Resource nodes. Colour carries the yield so a patch is readable at distance,
## and a spent node dims rather than vanishing -- it is still somewhere to come
## back to once it regrows.
func _refresh_nodes() -> void:
	for nid: int in world.node_mirror:
		var n: Dictionary = world.node_mirror[nid]
		var live := int(n["remaining"]) > 0
		if not _node_meshes.has(nid):
			var m := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.35
			cyl.bottom_radius = 0.6
			cyl.height = 1.2
			m.mesh = cyl
			m.material_override = StandardMaterial3D.new()
			m.position = n["pos"] + Vector3.UP * 0.6
			_craft_root.add_child(m)
			_node_meshes[nid] = m
		var mat: StandardMaterial3D = _node_meshes[nid].material_override
		mat.albedo_color = _node_colour(str(n["kind"])) if live \
			else Color(0.28, 0.26, 0.24)
	for nid: int in _node_meshes.keys():
		if not world.node_mirror.has(nid):
			(_node_meshes[nid] as Node).queue_free()
			_node_meshes.erase(nid)


## Structural pieces. Rebuilt wholesale on change: a base is tens of pieces,
## not thousands, and correctness beats incremental bookkeeping here.
func _refresh_build() -> void:
	for child in _build_root.get_children():
		child.queue_free()
	for piece: Dictionary in world.build_mirror:
		var m := MeshInstance3D.new()
		var box := BoxMesh.new()
		match int(piece["piece"]):
			BuildGrid.Piece.FOUNDATION:
				box.size = Vector3(BuildGrid.CELL, 0.3, BuildGrid.CELL)
			BuildGrid.Piece.CEILING:
				box.size = Vector3(BuildGrid.CELL, 0.25, BuildGrid.CELL)
			_:
				var side := int(piece["side"])
				var thin := 0.25
				box.size = Vector3(thin, BuildGrid.CELL, BuildGrid.CELL) \
					if side == 1 or side == 3 \
					else Vector3(BuildGrid.CELL, BuildGrid.CELL, thin)
		m.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.60, 0.55, 0.47)
		mat.roughness = 0.85
		m.material_override = mat
		m.position = piece["pos"]
		_build_root.add_child(m)


## The worm is only visible once it has surfaced. Before that the player has
## the threat meter and the warning line, which is deliberate -- you are meant
## to read the sand, not watch a dot approach.

## Vehicles were replicated from Phase 7 and drawn by nobody, so driving one
## looked exactly like sprinting very fast across empty sand. Refreshed every
## frame rather than on signal, because a driven vehicle moves continuously and
## the signal only fires at the sync rate.
func _refresh_vehicles() -> void:
	if _vehicle_root == null:
		return
	for vid: int in world.vehicle_mirror:
		var v: Dictionary = world.vehicle_mirror[vid]
		var def := ItemDB.get_def(str(v["item_id"]))
		if not _vehicle_meshes.has(vid):
			var flies := bool(def.get("flies", false))
			var body := BoxMesh.new()
			# A thopter reads as wings: wide, thin and long. A groundcar is a
			# blockier, taller box. Crude, but you can tell them apart at
			# a hundred metres, which is the whole job.
			body.size = Vector3(6.5, 1.1, 3.2) if flies else Vector3(2.6, 1.5, 4.4)
			var mi := MeshInstance3D.new()
			mi.mesh = body
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.36, 0.42, 0.46) if flies \
				else Color(0.55, 0.45, 0.30)
			mat.metallic = 0.5
			mat.roughness = 0.55
			mi.material_override = mat
			_vehicle_root.add_child(mi)
			_vehicle_meshes[vid] = mi
		var node: MeshInstance3D = _vehicle_meshes[vid]
		node.position = v["pos"] as Vector3
		node.rotation = Vector3(0.0, float(v["heading"]), 0.0)

	for vid: int in _vehicle_meshes.keys():
		if not world.vehicle_mirror.has(vid):
			(_vehicle_meshes[vid] as Node).queue_free()
			_vehicle_meshes.erase(vid)


func _refresh_worm() -> void:
	var state := int(world.worm_mirror["state"])
	var showing := state == Sandworm.State.SURFACING or state == Sandworm.State.STRIKING
	_worm_mesh.visible = showing
	if showing:
		var at: Vector3 = world.worm_mirror["target"]
		at.y = Terrain.sample_height(at.x, at.z)
		_worm_mesh.position = at
	_alarm.text = world.worm_warning()


func _refresh_hostiles() -> void:
	for nid: int in world.npc_mirror:
		if not _npc_meshes.has(nid):
			var m := _capsule(Color(0.55, 0.24, 0.24))
			_threat_root.add_child(m)
			_npc_meshes[nid] = m
		_npc_meshes[nid].position = world.npc_mirror[nid]["pos"] + Vector3.UP * 0.9
	for nid: int in _npc_meshes.keys():
		if not world.npc_mirror.has(nid):
			(_npc_meshes[nid] as Node).queue_free()
			_npc_meshes.erase(nid)

	for cid: int in world.corpse_mirror:
		if not _corpse_meshes.has(cid):
			var m := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(1.4, 0.3, 0.6)
			m.mesh = box
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.36, 0.20, 0.18)
			m.material_override = mat
			m.position = world.corpse_mirror[cid]["pos"] + Vector3.UP * 0.15
			_threat_root.add_child(m)
			_corpse_meshes[cid] = m
	for cid: int in _corpse_meshes.keys():
		if not world.corpse_mirror.has(cid):
			(_corpse_meshes[cid] as Node).queue_free()
			_corpse_meshes.erase(cid)


func _node_colour(kind: String) -> Color:
	match kind:
		"agave": return Color(0.45, 0.62, 0.30)
		"iron_vein": return Color(0.66, 0.34, 0.22)
		"stone_outcrop": return Color(0.55, 0.53, 0.50)
		"wreck_debris": return Color(0.38, 0.55, 0.60)
	return Color(0.7, 0.7, 0.7)


func _refresh_stations() -> void:
	for sid: int in world.station_mirror:
		if _station_meshes.has(sid):
			continue
		var s: Dictionary = world.station_mirror[sid]
		var m := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.4, 1.1, 1.4)
		m.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.30, 0.42, 0.50) if str(s["kind"]) == "refinery" \
			else Color(0.52, 0.45, 0.30)
		mat.metallic = 0.4
		m.material_override = mat
		m.position = s["pos"] + Vector3.UP * 0.55
		_craft_root.add_child(m)
		_station_meshes[sid] = m
	for sid: int in _station_meshes.keys():
		if not world.station_mirror.has(sid):
			(_station_meshes[sid] as Node).queue_free()
			_station_meshes.erase(sid)


func _capsule(col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var c := CapsuleMesh.new()
	c.radius = 0.35
	c.height = 1.8
	m.mesh = c
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	m.material_override = mat
	return m


## Build a mesh straight from the heightmap. Vertex colour encodes the surface
## mask so the sand/rock boundary the worm will read in Phase 4 is visible now
## -- being able to see the mask is what makes it debuggable.
func _build_lighting() -> void:
	_sun = DirectionalLight3D.new()
	_sun.light_energy = 1.15
	_sun.light_color = Color(1.0, 0.94, 0.82)
	_sun.shadow_enabled = true
	add_child(_sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.78, 0.68, 0.55)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.47, 0.4)
	e.ambient_light_energy = 0.6
	e.fog_enabled = true
	e.fog_light_color = Color(0.82, 0.71, 0.56)
	# Tuned to TerrainView.VIEW_M: the ground now ends at a finite radius, and
	# fog is what makes that read as haze rather than as a cliff into the void.
	# 0.0075 was too strong -- it flattened the near field into featureless
	# beige, hiding the dunes as well as the edge. This fogs the horizon by
	# roughly half and leaves the ground in front of you legible.
	e.fog_density = 0.002
	e.fog_aerial_perspective = 0.5
	env.environment = e
	_env = e
	add_child(env)


## What the crosshair is on. Only nodes with anything left in them, only within
## the reach of whatever is in your hand, and only inside the aim cone.
func _update_aim() -> void:
	_aimed_node = 0
	var def := _held_def()
	var reach := float(def.get("beam_range", 0.0))
	if reach <= 0.0:
		if _beaming != 0:
			_stop_beam()
		return
	var eye := _cam.global_position
	var fwd := -_cam.global_transform.basis.z
	var best := 0.0
	for nid: int in world.node_mirror:
		var n: Dictionary = world.node_mirror[nid]
		if int(n.get("units", 1)) <= 0:
			continue
		var at: Vector3 = n["pos"] + Vector3.UP * 0.6
		if world.local_pos.distance_to(at) > reach:
			continue
		var facing := eye.direction_to(at).dot(fwd)
		if facing >= AIM_COS and facing > best:
			best = facing
			_aimed_node = nid
	# Cutting something and then looking away stops the beam, rather than
	# leaving it running on a node behind you.
	if _beaming != 0 and _aimed_node != _beaming:
		_stop_beam()


## The definition of whatever is on the selected hotbar key.
func _held_def() -> Dictionary:
	var stack: Dictionary = world.hotbar_item(world.held_key)
	return {} if stack.is_empty() else ItemDB.get_def(str(stack["id"]))


func _start_beam() -> void:
	if _aimed_node == 0:
		world.notice.emit("nothing in your sights")
		return
	_beaming = _aimed_node
	world.fire_beam(_beaming, true)


func _stop_beam() -> void:
	if _beaming == 0:
		return
	world.fire_beam(_beaming, false)
	_beaming = 0


## What the left button does is decided by what is in your hand: a cutteray
## opens a beam that runs until you let go, anything else swings once. One
## implementation, called by the mouse and by --do alike.
func _pull_trigger() -> void:
	var def := _held_def()
	if float(def.get("beam_rate", 0.0)) > 0.0:
		_start_beam()
	elif float(def.get("place_range", 0.0)) > 0.0:
		# Holding the Construction Tool: the trigger sets a structure down.
		world.place_with_tool()
	else:
		world.try_attack()


func _release_trigger() -> void:
	_stop_beam()


## Open or close the bag. Opening hands the pointer to the grid; closing gives
## it back to the camera, so you are never left with a cursor you cannot use or
## a camera that spins while you are sorting.
func _toggle_grid() -> void:
	if _grid == null:
		return
	_grid.toggle()
	if _grid.is_open():
		_stop_beam()
		_set_mouse_look(false)
	else:
		_set_mouse_look(true)


## --drag "bag:1>hot:0": run drags through the grid's own drop() without a
## pointer. Mouse handling turns pixels into slots and then calls exactly this,
## so what the harness exercises is what the player's hand does.
## One drag at a time, waiting for the server's answer between them.
##
## The grid reads `hotbar_mirror`, which is the *server's* last word and arrives
## a round trip after the request. Firing four drags in one frame meant the
## second one decided what to swap from a bar the first had already changed --
## a thing no hand can do, and a wrong answer when a harness does it.
func _run_debug_drags() -> void:
	for spec: String in Net.drags.split(",", false):
		var parts := spec.strip_edges().split(">")
		if parts.size() != 2:
			print("[drag] cannot read '%s'" % spec)
			continue
		var from := _parse_slot(parts[0])
		var to := _parse_slot(parts[1])
		if from.is_empty():
			print("[drag] no such slot '%s'" % parts[0])
			continue
		var ok: bool = _grid.drop(from, to)
		print("[drag] %s -> %s: %s" % [parts[0], parts[1], "sent" if ok else "refused"])
		await get_tree().create_timer(0.45).timeout


## "bag:3" or "hot:0". An unreadable half means "dropped on nothing", which is
## itself a case the grid has to handle.
func _parse_slot(s: String) -> Dictionary:
	var bits := s.strip_edges().split(":")
	if bits.size() != 2:
		return {}
	var kind := bits[0].strip_edges().to_lower()
	if kind != "bag" and kind != "hot":
		return {}
	return {"kind": kind, "index": int(bits[1])}
