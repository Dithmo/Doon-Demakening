extends RefCounted
class_name Vendor
## Buying and selling at a trading post.
##
## Prices come from each item's `value` in items.json rather than a separate
## price table, so a new item is sellable the moment it exists and there is no
## second file to forget. The spread is the whole of the economy's friction:
## the post buys at value and sells at a markup, so shuttling goods back and
## forth loses money, which is the only thing stopping a vendor being an
## infinite Solari faucet.

## What the post charges above what it pays. Also the reason gathering beats
## arbitrage.
const MARKUP := 1.6

## How close you must be to a trading post POI to deal with it.
const RANGE := 18.0


static func buy_price(item_id: String) -> int:
	var v := value_of(item_id)
	return 0 if v <= 0 else int(ceil(float(v) * MARKUP))


static func sell_price(item_id: String) -> int:
	return value_of(item_id)


static func value_of(item_id: String) -> int:
	return int(ItemDB.get_def(item_id).get("value", 0))


## True when `pos` is close enough to any trading post to trade.
static func post_in_reach(pos: Vector3) -> Dictionary:
	for p: Dictionary in Pois.of_role("trade"):
		var d := Vector2(float(p["x"]) - pos.x, float(p["z"]) - pos.z).length()
		if d <= RANGE:
			return p
	return {}


## Sell `count` of the stack in `slot_index`. Returns what to tell the player,
## and how much they earned.
static func sell(pos: Vector3, inv: Inventory, prog: Progression,
		slot_index: int, count: int) -> Dictionary:
	var post := post_in_reach(pos)
	if post.is_empty():
		return {"ok": false, "msg": "no trading post within reach", "solari": 0,
			"item": "", "count": 0}
	if slot_index < 0 or slot_index >= inv.slots.size():
		return {"ok": false, "msg": "no such slot", "solari": 0, "item": "", "count": 0}
	var slot: Dictionary = inv.slots[slot_index]
	if slot.is_empty():
		return {"ok": false, "msg": "that slot is empty", "solari": 0,
			"item": "", "count": 0}
	var item_id := str(slot["id"])
	var have := int(slot["count"])
	var n: int = clampi(count, 1, have)
	var unit := sell_price(item_id)
	if unit <= 0:
		return {"ok": false, "msg": "%s is worth nothing here"
			% ItemDB.display_name(item_id), "solari": 0, "item": "", "count": 0}
	n = inv.remove_at(slot_index, n)
	if n <= 0:
		return {"ok": false, "msg": "could not part with it", "solari": 0,
			"item": "", "count": 0}
	var earned := unit * n
	prog.earn_solari(earned)
	return {"ok": true, "item": item_id, "count": n, "solari": earned,
		"msg": "sold %d %s for %d solari"
			% [n, ItemDB.display_name(item_id), earned]}


## Buy `count` of `item_id`. Refuses before taking payment if the bag is full,
## because a purchase that charges and then drops the goods on the floor is
## worse than one that does not happen.
static func buy(pos: Vector3, inv: Inventory, prog: Progression,
		item_id: String, count: int) -> Dictionary:
	var post := post_in_reach(pos)
	if post.is_empty():
		return {"ok": false, "msg": "no trading post within reach", "solari": 0}
	if not ItemDB.has(item_id):
		return {"ok": false, "msg": "the post does not stock that", "solari": 0}
	var unit := buy_price(item_id)
	if unit <= 0:
		return {"ok": false, "msg": "the post does not stock that", "solari": 0}
	var n: int = maxi(1, count)
	var cost := unit * n
	if prog.solari < cost:
		return {"ok": false, "msg": "that costs %d solari and you have %d"
			% [cost, prog.solari], "solari": 0}
	if not inv.can_accept(item_id, n):
		return {"ok": false, "msg": "no room for %d %s"
			% [n, ItemDB.display_name(item_id)], "solari": 0}
	prog.spend_solari(cost)
	inv.add(item_id, n)
	return {"ok": true, "solari": -cost, "item": item_id, "count": n,
		"msg": "bought %d %s for %d solari"
			% [n, ItemDB.display_name(item_id), cost]}
