class_name Panels
extends RefCounted
## Text for the paged panel: Journey, Skills, Contracts, Market, Guild, Hold.
##
## Phases 6 and 7 built progression, trading, guilds and vehicle cargo, wired
## them to the server, replicated every one of them to the client -- and drew
## none of it. All the state was already in `world`'s mirrors; there was simply
## no way for a person to read it or act on it, so the only things that had ever
## used those systems were bots and debug flags.
##
## This is deliberately text. A mouse-driven inventory is a lot of scaffolding
## for a demake, and a numbered list you act on with the number keys is both
## quicker to build and quicker to use. Every page renders from the replicated
## mirrors and never from a local guess.

enum Page { JOURNEY, SKILLS, CONTRACTS, MARKET, GUILD, HOLD }

const PAGE_NAMES := ["JOURNEY", "SKILLS", "CONTRACTS", "MARKET", "GUILD", "HOLD"]

## How many rows a page offers to the number keys. 1-9 plus 0 would be ten, but
## nine is enough for every list here and keeps 0 free.
const MAX_ROWS := 9


## The panel body for a page, plus the ids the number keys map to.
## Returns {"text": String, "actions": Array} where actions[i] is what pressing
## key i+1 should act on.
static func render(page: int, world: Node) -> Dictionary:
	match page:
		Page.JOURNEY: return _journey(world)
		Page.SKILLS: return _skills(world)
		Page.CONTRACTS: return _contracts(world)
		Page.MARKET: return _market(world)
		Page.GUILD: return _guild(world)
		Page.HOLD: return _hold(world)
	return {"text": "", "actions": []}


## Fire the action a number key maps to. Lives here beside the pages that
## define those rows, rather than in the view, so a headless client can exercise
## the same dispatch the keyboard does -- otherwise "the interface works" is a
## claim no test can reach.
##
## Every branch sends a request and waits. The server decides whether it
## happened, exactly as it does for a swing or a Journey step.
static func act(page: int, world: Node, index: int, actions: Array) -> bool:
	if index < 0 or index >= actions.size():
		return false
	var target: Variant = actions[index]
	match page:
		Page.SKILLS: world.learn(str(target))
		Page.CONTRACTS: world.ask_contracts(str(target))
		Page.MARKET: world.sell(int(target), 1)
		Page.GUILD: world.deliver_to_landsraad(int(target))
		Page.HOLD: world.stow_in_hold(int(target))
		_: return false
	return true


static func header(page: int, world: Node) -> String:
	var pr: Dictionary = world.progress_mirror
	# Two separate numbers, not a fraction: total experience earned, and how much
	# more buys the next level. Printing them as "75/45" read as a progress bar
	# running backwards.
	return "=== %s ===   level %d   %d xp (%d to next)   %d point(s)   %d solari" % [
		PAGE_NAMES[page], int(pr["level"]), int(pr["xp"]), int(pr["next"]),
		int(pr["points"]), int(pr["solari"])]


static func _journey(world: Node) -> Dictionary:
	var q: Dictionary = world.quest_mirror
	var lines: Array = []
	var step := int(q["step"])
	var total := QuestDB.journey.size()
	if step >= total:
		lines.append("The Journey is finished. The basin is yours to work.")
	else:
		lines.append("Step %d of %d:  %s" % [step + 1, total, q["step_name"]])
		lines.append("  %s" % q["step_text"])
		lines.append("  progress %d / %d" % [int(q["step_have"]), int(q["step_need"])])
	lines.append("")
	lines.append("contracts in hand: %d      settled: %d"
		% [(q["active"] as Dictionary).size(), int(q["done"])])
	return {"text": "\n".join(lines), "actions": []}


static func _skills(world: Node) -> Dictionary:
	var known: Array = world.progress_mirror.get("skills", [])
	var level := int(world.progress_mirror["level"])
	var lines: Array = []
	var actions: Array = []
	for track: String in SkillDB.tracks():
		var t := SkillDB.get_track(track)
		lines.append("%s -- taught by %s" % [t["name"], t["trainer"]])
		for sid: String in SkillDB.skills_in(track):
			var d := SkillDB.get_skill(sid)
			var mark := "*"
			if known.has(sid):
				mark = "="
			elif actions.size() < MAX_ROWS and level >= int(d["level"]):
				# Only offer what could actually be learned. The server still
				# has the last word -- it also checks you are at the trainer.
				var needs := str(d["requires"])
				if needs.is_empty() or known.has(needs):
					actions.append(sid)
					mark = "[%d]" % actions.size()
			lines.append("   %-4s %-22s lvl %d  %s"
				% [mark, d["name"], int(d["level"]), d["desc"]])
	lines.append("")
	lines.append("= owned.  press a number at the right trainer to learn.")
	return {"text": "\n".join(lines), "actions": actions}


static func _contracts(world: Node) -> Dictionary:
	var q: Dictionary = world.quest_mirror
	var lines: Array = []
	var actions: Array = []

	var active: Dictionary = q["active"]
	if active.is_empty():
		lines.append("(nothing in hand)")
	else:
		for cid: Variant in active:
			var c := QuestDB.contract(str(cid))
			lines.append("  %-28s %d / %d" % [c.get("name", cid),
				int(active[cid]), int(c.get("count", 1))])
	lines.append("")
	lines.append("on offer here:")
	if (world.offers_mirror as Array).is_empty():
		lines.append("  (nobody here is hiring -- stand at a trainer or the post)")
	for row: Array in world.offers_mirror:
		if actions.size() >= MAX_ROWS:
			break
		actions.append(str(row[0]))
		lines.append("  [%d] %-26s %4d solari  -- %s"
			% [actions.size(), row[1], int(row[3]), row[2]])
	lines.append("")
	lines.append("[H] ask who is hiring here.")
	return {"text": "\n".join(lines), "actions": actions}


static func _market(world: Node) -> Dictionary:
	var lines: Array = []
	var actions: Array = []
	var post := Vendor.post_in_reach(world.local_pos)
	if post.is_empty():
		lines.append("No trading post within reach.")
		var nearest := Pois.nearest("trade", world.local_pos.x, world.local_pos.z)
		if not nearest.is_empty():
			var d := Vector2(float(nearest["x"]) - world.local_pos.x,
				float(nearest["z"]) - world.local_pos.z).length()
			lines.append("Nearest is %s, %d m away." % [nearest["name"], int(d)])
		return {"text": "\n".join(lines), "actions": actions}

	lines.append("Trading at %s.  it pays %d%% of value and charges %d%%."
		% [post["name"], 100, int(Vendor.MARKUP * 100.0)])
	lines.append("")
	for i in (world.inventory_mirror as Array).size():
		var slot: Dictionary = world.inventory_mirror[i]
		if slot.is_empty() or actions.size() >= MAX_ROWS:
			continue
		var unit := Vendor.sell_price(str(slot["id"]))
		if unit <= 0:
			continue
		actions.append(i)
		lines.append("  [%d] sell 1 %-22s for %d solari  (have %d)"
			% [actions.size(), ItemDB.display_name(str(slot["id"])), unit,
			int(slot["count"])])
	if actions.is_empty():
		lines.append("  (nothing in your bag is worth anything here)")
	return {"text": "\n".join(lines), "actions": actions}


static func _guild(world: Node) -> Dictionary:
	var lines: Array = []
	var actions: Array = []
	if int(world.my_guild) == 0:
		lines.append("You are in no guild.")
		lines.append("[N] found or join 'House Doon'   (a real name entry is UI work)")
	else:
		lines.append("Your guild is #%d." % int(world.my_guild))
		lines.append("[N] leave it.")
		var give := -1
		for i in (world.inventory_mirror as Array).size():
			var slot: Dictionary = world.inventory_mirror[i]
			if not slot.is_empty() and Vendor.value_of(str(slot["id"])) > 0:
				give = i
				break
		var rep := Guilds.representative_in_reach(world.local_pos)
		if rep.is_empty():
			lines.append("No Landsraad representative within reach.")
		elif give >= 0:
			actions.append(give)
			lines.append("  [1] deliver 1 %s to %s for standing"
				% [ItemDB.display_name(str((world.inventory_mirror[give] as Dictionary)["id"])),
				rep["name"]])
	lines.append("")
	lines.append("Landsraad standing:")
	if (world.guild_table as Array).is_empty():
		lines.append("  (no houses have declared)")
	for row: Array in world.guild_table:
		lines.append("  %-24s %2d member(s)  %6.0f" % [row[1], int(row[2]), float(row[3])])
	return {"text": "\n".join(lines), "actions": actions}


static func _hold(world: Node) -> Dictionary:
	var lines: Array = []
	var actions: Array = []
	if int(world.driving) == 0:
		lines.append("You are not in a vehicle.")
		# Explicitly typed: `world` is a plain Node here, so the compiler cannot
		# infer what its methods return.
		var vid: int = world.nearest_vehicle()
		if vid != 0:
			var v: Dictionary = world.vehicle_mirror[vid]
			lines.append("%s is within reach. [Y] climb in, [U] refuel, [P] pack up."
				% ItemDB.display_name(str(v["item_id"])))
		return {"text": "\n".join(lines), "actions": actions}

	var v: Dictionary = world.vehicle_mirror[int(world.driving)]
	var def := ItemDB.get_def(str(v["item_id"]))
	var cap := float(def.get("fuel_capacity", 30.0))
	lines.append("Driving %s.  fuel %.0f%%  altitude %.0f m  [Y] get out  [U] refuel"
		% [ItemDB.display_name(str(v["item_id"])), float(v["fuel"]) / cap * 100.0,
		float(v["altitude"])])
	lines.append("")
	lines.append("in the hold:")
	if (world.hold_mirror as Array).is_empty():
		lines.append("  (empty)")
	for row: Variant in world.hold_mirror:
		var s: Dictionary = row
		if not s.is_empty():
			lines.append("  %s x%d" % [ItemDB.display_name(str(s["id"])), int(s["count"])])
	lines.append("")
	lines.append("stow from your bag:")
	for i in (world.inventory_mirror as Array).size():
		var slot: Dictionary = world.inventory_mirror[i]
		if slot.is_empty() or actions.size() >= MAX_ROWS:
			continue
		actions.append(i)
		lines.append("  [%d] stow %s x%d" % [actions.size(),
			ItemDB.display_name(str(slot["id"])), int(slot["count"])])
	return {"text": "\n".join(lines), "actions": actions}
