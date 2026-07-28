class_name Inventory
extends RefCounted
## A slotted container. Server-owned: clients hold a mirror of this built from
## replicated state and never mutate it locally.
##
## Used for player bags now, and for storage containers and fabricator input in
## Phase 2-3, so it deliberately knows nothing about who owns it.

const DEFAULT_SLOTS := 24

## Array of either {} (empty) or {"id": String, "count": int}.
var slots: Array[Dictionary] = []


func _init(slot_count: int = DEFAULT_SLOTS) -> void:
	slots.resize(slot_count)
	for i in slots.size():
		slots[i] = {}


func is_empty_slot(i: int) -> bool:
	return i >= 0 and i < slots.size() and slots[i].is_empty()


func count_of(id: String) -> int:
	var n := 0
	for s in slots:
		if not s.is_empty() and s["id"] == id:
			n += int(s["count"])
	return n


## Add up to `count`, filling partial stacks before empty slots.
## Returns the number that did NOT fit, so callers can decide what to do with
## the remainder rather than silently destroying it.
func add(id: String, count: int = 1) -> int:
	if not ItemDB.has(id) or count <= 0:
		return count
	var cap := ItemDB.stack_size(id)
	var left := count

	for i in slots.size():
		if left <= 0:
			break
		var s := slots[i]
		if s.is_empty() or s["id"] != id:
			continue
		var space: int = cap - int(s["count"])
		if space <= 0:
			continue
		var take: int = mini(space, left)
		s["count"] = int(s["count"]) + take
		slots[i] = s
		left -= take

	for i in slots.size():
		if left <= 0:
			break
		if not slots[i].is_empty():
			continue
		var take: int = mini(cap, left)
		slots[i] = {"id": id, "count": take}
		left -= take

	return left


## Remove up to `count`. Returns how many were actually removed.
func remove(id: String, count: int = 1) -> int:
	var left := count
	for i in slots.size():
		if left <= 0:
			break
		var s := slots[i]
		if s.is_empty() or s["id"] != id:
			continue
		var take: int = mini(int(s["count"]), left)
		var rem: int = int(s["count"]) - take
		slots[i] = {} if rem <= 0 else {"id": id, "count": rem}
		left -= take
	return count - left


## Take everything out of one slot. Returns {} if it was already empty.
func take_slot(i: int) -> Dictionary:
	if i < 0 or i >= slots.size() or slots[i].is_empty():
		return {}
	var s := slots[i]
	slots[i] = {}
	return s


func total_weight() -> float:
	var w := 0.0
	for s in slots:
		if s.is_empty():
			continue
		w += float(ItemDB.get_def(s["id"]).get("weight", 0.0)) * float(s["count"])
	return w


## Wire/disk form. One representation for both replication and persistence, so
## the two cannot drift apart.
func to_data() -> Array:
	var out: Array = []
	for s in slots:
		out.append({} if s.is_empty() else {"id": s["id"], "count": s["count"]})
	return out


func from_data(data: Array) -> void:
	slots.resize(maxi(data.size(), DEFAULT_SLOTS))
	for i in slots.size():
		slots[i] = {}
	for i in mini(data.size(), slots.size()):
		var s: Variant = data[i]
		if typeof(s) != TYPE_DICTIONARY or s.is_empty():
			continue
		var id := str(s.get("id", ""))
		var n := int(s.get("count", 0))
		# Drop anything the current item DB no longer defines rather than
		# carrying a dangling id forward through a save migration.
		if n > 0 and ItemDB.has(id):
			slots[i] = {"id": id, "count": n}
