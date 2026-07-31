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

enum Page { BAG, CRAFT, JOURNEY, SKILLS, CONTRACTS, MARKET, GUILD, HOLD, CONTAINER }

const PAGE_NAMES := ["BAG", "CRAFT", "JOURNEY", "SKILLS", "CONTRACTS", "MARKET",
	"GUILD", "HOLD", "CONTAINER"]

## How many rows a page offers to the number keys. 1-9 plus 0 would be ten, but
## nine is enough for every list here and keeps 0 free.
const MAX_ROWS := 9
## Hotbar keys, which is one more than a page ever offers.
const HOTBAR_KEYS := 10


## The panel body for a page, plus the ids the number keys map to.
## Returns {"text": String, "actions": Array} where actions[i] is what pressing
## key i+1 should act on.
static func render(page: int, world: Node) -> Dictionary:
	match page:
		Page.BAG: return _bag(world)
		Page.CRAFT: return _craft(world)
		Page.JOURNEY: return _journey(world)
		Page.SKILLS: return _skills(world)
		Page.CONTRACTS: return _contracts(world)
		Page.MARKET: return _market(world)
		Page.GUILD: return _guild(world)
		Page.HOLD: return _hold(world)
		Page.CONTAINER: return _container(world)
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
		# Using a slot is how everything in the bag is operated: a stillsuit
		# equips, water drinks, a fabricator deploys. The item's own `use` hook
		# decides which, so there is no separate "equip" verb to get wrong.
		Page.BAG: world.use_slot(int(target))
		Page.CRAFT: world.craft(str(target))
		Page.SKILLS: world.learn(str(target))
		Page.CONTRACTS: world.ask_contracts(str(target))
		Page.MARKET: world.sell(int(target), 1)
		Page.GUILD: world.deliver_to_landsraad(int(target))
		Page.HOLD: world.stow_in_hold(int(target))
		# The one page whose rows mean two different things, so each row carries
		# its own verb rather than relying on where it sits in the list.
		Page.CONTAINER:
			var row: Dictionary = target
			if row.has("take"):
				world.take_from_container(int(row["take"]))
			else:
				world.put_in_container(int(row["put"]))
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


## What each `use` hook does when you press a row, in the player's words. Hooks
## missing from this table are tools worked with a dedicated key rather than
## from the bag -- a cutteray cuts the node in front of you, not itself.
const USE_VERB := {
	"equip": "wear", "hydrate": "drink", "place": "deploy",
	"deploy_vehicle": "unload",
}
const TOOL_KEY := {
	"build": "[V] to build with it", "tool_gather": "[R] at a node",
	"tool_dew": "[G] at night", "tool_blood": "[Z] at a corpse",
}


## The bag. This page is how a person equips anything: pressing a row uses the
## slot, and "use" on a stillsuit means wear it. Before this existed the only
## way to put on a stillsuit was to be a bot.
static func _bag(world: Node) -> Dictionary:
	var lines: Array = []
	var actions: Array = []

	var worn: Array = []
	for slot: int in world.equipped_mirror:
		worn.append(ItemDB.display_name(str(world.equipped_mirror[slot])))
	lines.append("worn: " + (", ".join(worn) if worn else "(nothing)"))
	lines.append("")

	var empty := true
	for i in (world.inventory_mirror as Array).size():
		var slot: Dictionary = world.inventory_mirror[i]
		if slot.is_empty():
			continue
		empty = false
		var id := str(slot["id"])
		var hook := str(ItemDB.get_def(id).get("use", ""))
		var note := ""
		var mark := "   -"
		if USE_VERB.has(hook) and actions.size() < MAX_ROWS:
			actions.append(i)
			mark = "[%d]" % actions.size()
			note = str(USE_VERB[hook])
		elif TOOL_KEY.has(hook):
			note = str(TOOL_KEY[hook])
		else:
			note = "no use"
		lines.append("  %-4s %-24s x%-3d %s"
			% [mark, ItemDB.display_name(id), int(slot["count"]), note])
	if empty:
		lines.append("  (your bag is empty)")
	lines.append("")
	lines.append("[Q] drop the first thing you are carrying.")
	return {"text": "\n".join(lines), "actions": actions}


## What you can make standing here.
##
## Recipes with no station are personal crafting -- the wiki's "Personal
## Fabricator" -- and are always available. Everything else needs its station
## within reach, and is listed greyed rather than hidden so you can see what a
## bench would buy you before you build one.
static func _craft(world: Node) -> Dictionary:
	var lines: Array = []
	var actions: Array = []
	var reach: Array = world.reachable_stations()
	lines.append("At hand: personal crafting%s"
		% ("" if reach.is_empty() else "   In reach: " + ", ".join(reach)))
	lines.append("")

	for rid: String in RecipeDB.ids():
		var r := RecipeDB.get_recipe(rid)
		var station := str(r["station"])
		var here := station.is_empty() or reach.has(station)
		var have: bool = world.has_inputs_for(rid)
		var cost: Array = []
		for raw: Variant in r["inputs"]:
			var i: Dictionary = raw
			cost.append("%d %s" % [int(i["count"]),
				ItemDB.display_name(str(i["id"]))])
		var mark := "   -"
		if here and have and actions.size() < MAX_ROWS:
			actions.append(rid)
			mark = "[%d]" % actions.size()
		var where := "" if station.is_empty() else "  (%s)" % station
		lines.append("  %-4s %-24s %s%s%s"
			% [mark, str(r["name"]), ", ".join(cost), where,
			"" if here else "  -- no station"])
	if actions.is_empty():
		lines.append("")
		lines.append("(nothing you have the parts for)")
	return {"text": "\n".join(lines), "actions": actions}


## A deployed chest, once [T] has opened it. Rows mean two things here -- take
## the ones inside, put the ones you are carrying -- so each row says which.
static func _container(world: Node) -> Dictionary:
	var lines: Array = []
	var actions: Array = []
	if int(world.open_container) == 0:
		lines.append("No container open.")
		if int(world.nearest_container()) != 0:
			lines.append("One is within reach -- press [T] to open it.")
		else:
			lines.append("Deploy a chest from your bag, then stand at it and press [T].")
		return {"text": "\n".join(lines), "actions": actions}

	lines.append("Inside:")
	var any := false
	for i in (world.container_mirror as Array).size():
		var slot: Dictionary = world.container_mirror[i]
		if slot.is_empty() or actions.size() >= MAX_ROWS:
			continue
		any = true
		actions.append({"take": i})
		lines.append("  [%d] take %s x%d" % [actions.size(),
			ItemDB.display_name(str(slot["id"])), int(slot["count"])])
	if not any:
		lines.append("  (empty)")
	lines.append("")
	lines.append("From your bag:")
	for i in (world.inventory_mirror as Array).size():
		var slot: Dictionary = world.inventory_mirror[i]
		if slot.is_empty() or actions.size() >= MAX_ROWS:
			continue
		actions.append({"put": i})
		lines.append("  [%d] store %s x%d" % [actions.size(),
			ItemDB.display_name(str(slot["id"])), int(slot["count"])])
	return {"text": "\n".join(lines), "actions": actions}


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
