class_name InventoryView
extends Control
## The bag as a grid you can drag things around, and the hotbar you drag them
## onto. The first mouse-driven interface in the project.
##
## Everything before this was text and number keys, deliberately: a grid is a
## lot of scaffolding, and a numbered list is quicker to build and quicker to
## use. What changed is that the hotbar makes "which of these ten things is in
## my hand" a spatial question, and answering it by typing row numbers at a text
## list is worse than answering it by putting the thing where you want it.
##
## Drawn immediately rather than built from Control nodes. Thirty-four slots of
## rectangle-and-label is less code as one _draw() than as thirty-four scene
## nodes with themes, and it keeps hit-testing and rendering reading off the
## same geometry -- which is the bug this kind of UI usually has.
##
## The *decisions* live in `drop()` and `slot_at()`, not in the mouse handler,
## so a harness can exercise a drag without a pointer. Phase 9 was about an
## interface nothing could test; this one is testable from the day it lands.

## Geometry. Slots are square; everything else is derived.
const SLOT := 74.0
const GAP := 6.0
const COLS := 6
const HOT_SLOT := 62.0

var world: Node

var _font: Font
var _open: bool = false
## What the pointer picked up: {"kind": "bag"|"hot", "index": int} or {}.
var _carry: Dictionary = {}
var _mouse: Vector2 = Vector2.ZERO
## Rect for each slot, rebuilt whenever the panel is laid out. Hit-testing and
## drawing both read this, so they cannot disagree.
var _bag_rects: Array = []
var _hot_rects: Array = []


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_layout()


func is_open() -> bool:
	return _open


## Opening frees the pointer; closing gives it back to the camera. A grid you
## cannot point at is not a grid.
func set_open(on: bool) -> void:
	_open = on
	if not on:
		_carry = {}
	queue_redraw()


func toggle() -> void:
	set_open(not _open)


func _layout() -> void:
	var vp := get_viewport_rect().size
	var rows := int(ceil(float(Inventory.DEFAULT_SLOTS) / float(COLS)))
	var w := COLS * SLOT + (COLS - 1) * GAP
	var h := rows * SLOT + (rows - 1) * GAP
	var x0 := (vp.x - w) * 0.5
	var y0 := (vp.y - h) * 0.5 - 60.0

	_bag_rects.clear()
	for i in Inventory.DEFAULT_SLOTS:
		var c := i % COLS
		var r := i / COLS
		_bag_rects.append(Rect2(
			x0 + float(c) * (SLOT + GAP), y0 + float(r) * (SLOT + GAP), SLOT, SLOT))

	# The hotbar sits along the bottom and stays on screen with the grid shut:
	# it is the thing you read while playing, not while sorting.
	var hw := 10.0 * HOT_SLOT + 9.0 * GAP
	var hx := (vp.x - hw) * 0.5
	var hy := vp.y - HOT_SLOT - 18.0
	_hot_rects.clear()
	for k in 10:
		_hot_rects.append(Rect2(hx + float(k) * (HOT_SLOT + GAP), hy, HOT_SLOT, HOT_SLOT))


## Which slot a point is over, or {}. The one place that turns pixels into slots.
func slot_at(p: Vector2) -> Dictionary:
	for k in _hot_rects.size():
		if (_hot_rects[k] as Rect2).has_point(p):
			return {"kind": "hot", "index": k}
	if not _open:
		return {}
	for i in _bag_rects.size():
		if (_bag_rects[i] as Rect2).has_point(p):
			return {"kind": "bag", "index": i}
	return {}


## Resolve a drag. Returns true if it asked the server for anything.
##
## Every branch is a *request*: the client decides what the gesture meant, the
## server decides whether it happens. Dropping a bag slot on a hotbar key is the
## whole of "drag the cutteray onto slot 1".
func drop(from: Dictionary, to: Dictionary) -> bool:
	if from.is_empty():
		return false
	var fk := str(from["kind"])
	var fi := int(from["index"])

	# Dropped on nothing: a hotbar key being dragged off the bar clears it, and
	# a bag slot dragged into space stays where it was. Throwing your gear on
	# the floor by missing a slot would be a cruel way to lose a cutteray.
	if to.is_empty():
		if fk == "hot":
			world.assign_hotbar(fi, -1)
			return true
		return false

	var tk := str(to["kind"])
	var ti := int(to["index"])
	if fk == tk and fi == ti:
		return false

	match [fk, tk]:
		["bag", "hot"]:
			world.assign_hotbar(ti, fi)
			return true
		["hot", "hot"]:
			# Swap two keys by reading what the source points at first.
			var src := int(world.hotbar_mirror[fi]) if fi < world.hotbar_mirror.size() else -1
			var dst := int(world.hotbar_mirror[ti]) if ti < world.hotbar_mirror.size() else -1
			world.assign_hotbar(ti, src)
			world.assign_hotbar(fi, dst)
			return true
		["hot", "bag"]:
			# Pulling a key off the bar onto the grid just clears the key. The
			# item never moved -- the bar only ever pointed at it.
			world.assign_hotbar(fi, -1)
			return true
		["bag", "bag"]:
			world.move_item(fi, ti)
			return true
	return false


func _gui_input(_event: InputEvent) -> void:
	pass


## Mouse handling, kept to the mechanics of picking up and letting go. What a
## drag *means* is `drop()`, which the harness calls directly.
func handle_mouse(event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
		if not _carry.is_empty():
			queue_redraw()
		return false
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return false
	_mouse = mb.position
	if mb.pressed:
		var hit := slot_at(_mouse)
		if hit.is_empty():
			return false
		# An empty slot has nothing to pick up.
		if str(hit["kind"]) == "bag" and _bag_item(int(hit["index"])).is_empty():
			return false
		if str(hit["kind"]) == "hot" and world.hotbar_item(int(hit["index"])).is_empty():
			return false
		_carry = hit
		queue_redraw()
		return true
	# Released.
	if _carry.is_empty():
		return false
	var landed := slot_at(_mouse)
	var moved := drop(_carry, landed)
	_carry = {}
	queue_redraw()
	return moved


func _bag_item(i: int) -> Dictionary:
	var inv: Array = world.inventory_mirror
	return {} if i < 0 or i >= inv.size() else inv[i]


func _process(_delta: float) -> void:
	# Cheap, and the alternative is a resize signal plus a first-frame special
	# case. The layout only recomputes when the window actually changed.
	var vp := get_viewport_rect().size
	if _hot_rects.is_empty() or not is_equal_approx((_hot_rects[0] as Rect2).position.y,
			vp.y - HOT_SLOT - 18.0):
		_layout()
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	if _open:
		_draw_bag()
	_draw_hotbar()
	if not _carry.is_empty():
		_draw_carried()


func _draw_bag() -> void:
	var pad := 14.0
	if not _bag_rects.is_empty():
		var first: Rect2 = _bag_rects[0]
		var last: Rect2 = _bag_rects[_bag_rects.size() - 1]
		var back := Rect2(first.position - Vector2(pad, pad + 26.0),
			Vector2(last.end.x - first.position.x + pad * 2.0,
				last.end.y - first.position.y + pad * 2.0 + 26.0))
		draw_rect(back, Color(0.09, 0.08, 0.07, 0.92))
		draw_rect(back, Color(0.62, 0.54, 0.42, 0.8), false, 2.0)
		draw_string(_font, first.position + Vector2(2.0, -8.0),
			"BAG   drag onto the bar below", HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			Color(0.92, 0.86, 0.72))

	for i in _bag_rects.size():
		var r: Rect2 = _bag_rects[i]
		var stack := _bag_item(i)
		_draw_slot(r, stack, false, _carry.get("kind", "") == "bag"
			and int(_carry.get("index", -1)) == i)


func _draw_hotbar() -> void:
	for k in _hot_rects.size():
		var r: Rect2 = _hot_rects[k]
		var stack: Dictionary = world.hotbar_item(k)
		_draw_slot(r, stack, k == int(world.held_key),
			_carry.get("kind", "") == "hot" and int(_carry.get("index", -1)) == k)
		# The key that selects it, in the corner.
		draw_string(_font, r.position + Vector2(4.0, 14.0),
			"0" if k == 9 else str(k + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(0.75, 0.70, 0.60))


func _draw_slot(r: Rect2, stack: Dictionary, selected: bool, lifted: bool) -> void:
	draw_rect(r, Color(0.16, 0.14, 0.12, 0.88))
	# The selected key is what is in your hand, so it is the one thing on this
	# screen that has to be readable at a glance.
	draw_rect(r, Color(1.0, 0.82, 0.45) if selected else Color(0.45, 0.40, 0.34),
		false, 3.0 if selected else 1.0)
	if stack.is_empty() or lifted:
		return
	var name := ItemDB.display_name(str(stack["id"]))
	# Two short lines beat one clipped one at this size.
	var words := name.split(" ")
	var y := r.position.y + 26.0
	for w: String in words:
		if y > r.end.y - 14.0:
			break
		draw_string(_font, Vector2(r.position.x + 5.0, y), w,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 10.0, 12, Color(0.93, 0.90, 0.84))
		y += 13.0
	var n := int(stack["count"])
	if n > 1:
		draw_string(_font, Vector2(r.position.x + 5.0, r.end.y - 6.0), "x%d" % n,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.92, 0.70))


func _draw_carried() -> void:
	var stack: Dictionary = {}
	if str(_carry["kind"]) == "bag":
		stack = _bag_item(int(_carry["index"]))
	else:
		stack = world.hotbar_item(int(_carry["index"]))
	if stack.is_empty():
		return
	var r := Rect2(_mouse - Vector2(SLOT, SLOT) * 0.35, Vector2(SLOT, SLOT) * 0.7)
	draw_rect(r, Color(0.22, 0.20, 0.16, 0.9))
	draw_rect(r, Color(1.0, 0.86, 0.5), false, 2.0)
	draw_string(_font, r.position + Vector2(4.0, 18.0),
		ItemDB.display_name(str(stack["id"])), HORIZONTAL_ALIGNMENT_LEFT,
		r.size.x - 8.0, 12, Color(1, 1, 1))
