extends Node3D
## Client presentation. Reads replicated state and draws it; owns no game state
## of its own. Deliberately crude -- Phase 0 is about proving the spine, and
## anything spent on looks here is spent twice when Phase 5 brings real terrain.

var world: Node

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
var _sun: DirectionalLight3D
var _env: Environment
var _notice: Label
var _notice_until: float = 0.0


func _ready() -> void:
	_build_terrain()
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

	_notice = Label.new()
	_notice.position = Vector2(12, 200)
	_notice.add_theme_color_override("font_color", Color(1.0, 0.86, 0.6))
	_notice.add_theme_font_size_override("font_size", 17)
	layer.add_child(_notice)

	_craft_root = Node3D.new()
	add_child(_craft_root)
	_build_root = Node3D.new()
	add_child(_build_root)
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
	_player_mesh.position = p + Vector3.UP * 0.9
	# Fixed over-the-shoulder framing; a proper orbit camera is not Phase 0 work.
	_cam.position = p + Vector3(0.0, 6.5, 9.0)
	_cam.look_at(p + Vector3.UP * 1.2, Vector3.UP)

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

	_advance_sky()
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


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		world.try_pickup()
	elif event.is_action_pressed("drink"):
		var i: int = world.find_use("hydrate")
		if i >= 0:
			world.use_slot(i)
	elif event.is_action_pressed("harvest"):
		var i: int = world.find_use("tool_dew")
		if i >= 0:
			world.use_slot(i)
	elif event.is_action_pressed("work"):
		world.try_harvest()
	elif event.is_action_pressed("deploy"):
		var i: int = world.find_use("place")
		if i >= 0:
			world.use_slot(i)
	elif event.is_action_pressed("craft"):
		# Cycles the first craftable recipe. A proper menu is Phase 6 polish.
		for rid: String in world.available_recipes():
			if world.has_inputs_for(rid):
				world.craft(rid)
				break
	elif event.is_action_pressed("drop"):
		for i in (world.inventory_mirror as Array).size():
			if not (world.inventory_mirror[i] as Dictionary).is_empty():
				world.drop_slot(i)
				break


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
	if world.nearest_container() != 0:
		hints.append("[T] container")
	if reach:
		hints.append("[C] craft")
	hints.append("[Q] drop")
	lines.append(" ".join(hints))
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
func _build_terrain() -> void:
	var step := 2.0
	var nx := int(Terrain.size_m.x / step)
	var nz := int(Terrain.size_m.y / step)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for jz in range(nz):
		for ix in range(nx):
			var x0 := float(ix) * step
			var z0 := float(jz) * step
			var x1 := x0 + step
			var z1 := z0 + step
			var corners := [
				Vector3(x0, Terrain.sample_height(x0, z0), z0),
				Vector3(x1, Terrain.sample_height(x1, z0), z0),
				Vector3(x1, Terrain.sample_height(x1, z1), z1),
				Vector3(x0, Terrain.sample_height(x0, z1), z1),
			]
			for tri: Array in [[0, 2, 1], [0, 3, 2]]:
				for k: int in tri:
					var v: Vector3 = corners[k]
					st.set_color(_surface_color(Terrain.sample_surface(v.x, v.z)))
					st.add_vertex(v)
	st.generate_normals()

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mi.material_override = mat
	add_child(mi)


func _surface_color(s: int) -> Color:
	match s:
		Terrain.Surface.ROCK: return Color(0.42, 0.33, 0.26)
		Terrain.Surface.CLIFF: return Color(0.25, 0.19, 0.16)
	return Color(0.83, 0.66, 0.42)


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
	e.fog_density = 0.004
	env.environment = e
	_env = e
	add_child(env)
