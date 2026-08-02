extends Node
## Transport, role selection and connection lifecycle.
##
## Server-authoritative from day one (docs/game-plan.md). Solo play is a
## one-client session against a local headless server -- there is no separate
## offline path, so there is exactly one code path to get right.
##
## Launch:
##   godot --headless -- --server [--port N] [--region PATH]
##   godot -- --client [--host H] [--port N] [--identity NAME]

signal role_resolved
signal connected_to_server
signal connection_failed(reason: String)
signal server_disconnected
signal peer_joined(id: int)
signal peer_left(id: int)

enum Role { NONE, SERVER, CLIENT }

const DEFAULT_PORT := 27015
const MAX_CLIENTS := 8

## Bumped whenever the wire format changes. Mismatched clients are rejected at
## handshake rather than desyncing later.
const PROTOCOL_VERSION := 2

var role: Role = Role.NONE
## Launched with no arguments: we are the client *and* we start the server.
var solo: bool = false
var _server_pid: int = -1
## How long to give the child server before connecting. Generous: it has a
## 19 MB region to read, and a connect that fails is worse than a slow one.
const SOLO_SERVER_WAIT_MS := 2500
var port: int = DEFAULT_PORT
var host: String = "127.0.0.1"
var identity: String = ""
## Bot client: drives itself instead of reading Input. Headless clients have no
## keyboard, so this is how the integration harness exercises a real session
## rather than a mocked one.
var auto: bool = false
## Seconds to run before quitting. 0 = forever. Keeps test runs bounded.
var run_seconds: float = 0.0
## Capture the viewport to this path shortly before quitting. Lets a windowed
## client be checked under Xvfb in CI, where nobody is looking at a monitor.
var screenshot_path: String = ""
## Bot behaviour:
##   survive  -- the full loop: drink, harvest, deploy, craft
##   reckless -- neither drinks nor harvests and always sprints, which is how
##               the harness reaches death without waiting out a full day
##   forager  -- ground pickups only, ignoring nodes and stations, so the
##               Phase 0 harness keeps testing pickup exclusivity rather than
##               whatever the newest subsystem has made more attractive
##   builder  -- stakes a holding, deploys its kit and raises a shell, then
##               stops; how the Phase 3 harness gets a base built unattended
##   prey     -- sprints in circles on open sand and never seeks cover, so the
##               Phase 4 harness can get a worm roused and land a strike
##   quarry   -- the same, but runs for the nearest rock the moment the worm
##               surfaces; proves cover actually saves you
##   fighter  -- hunts hostiles, then draws water from what it kills
##   pilgrim  -- walks to a named wiki POI and stops; the Phase 5 harness uses
##               it to prove the real map is navigable by its own landmarks
##   journeyman -- plays the ordinary survival loop, and additionally walks to
##               trainers to spend points and to the post to sell
##   spicer   -- runs to the nearest live spice blow and cuts it, which is the
##               loudest thing anyone can do and the fastest way to raise a worm
##   founder  -- crafts a Construction Tool, puts it on a hotbar key, holds it,
##               crafts a Sub-Fief and sets it down: the opening build sequence
##   driver   -- unloads the vehicle it was given, fuels it, drives it, stows
##               cargo, and gets out again
var bot_profile: String = "survive"
## Named POI a `pilgrim` bot walks to. Client-side: steering is the client's
## business, and the server validates the movement that results.
var goto_poi: String = ""
## Named POI new players start at. **Server-side** -- spawn position is decided
## by the server like every other authoritative fact, so passing this to a
## client alone does nothing at all. Both take the wiki's own marker names, so
## a test reads as the journey it is making rather than a pair of coordinates.
var spawn_poi: String = ""
## Client debug: attempt to learn this skill once, shortly after joining.
## Exists so the trainer rule can be tested directly -- both the refusal at
## distance and the success at the trainer -- instead of waiting for a bot to
## reach the Journey step that asks for it.
var learn_skill: String = ""
## Client debug: found-or-join this guild shortly after joining, then hand the
## first sellable stack to the Landsraad. Same purpose as --learn: it makes the
## rule testable directly instead of via a bot that has to be talked into it.
var guild_name: String = ""
## Client debug: open this panel page at start and log its contents. Panels are
## pure text derived from the replicated mirrors, so this makes the interface
## itself assertable from a headless run rather than only from a screenshot.
var panel_page: String = ""
## Client debug: press this row on the open panel page, once. Closes the loop
## between an interface and the server for the harness.
var panel_press: int = 0
## Client debug: fire these client actions once, by name, a few seconds after
## joining -- "attack,extract". Phase 8 shipped six actions that were bound to
## keys and handled by nobody, and no test could see it, because a bot calls the
## world's methods directly and never presses anything. This runs the same
## dispatch table the keyboard runs, so a harness can prove a key does its job.
var do_actions: String = ""
## Client debug: perform drags without a pointer, "bag:1>hot:0,bag:3>bag:8".
## A mouse-driven grid is the least testable thing in the project, so the drag
## *decision* is a function the harness can call with the same arguments the
## pointer would produce. Needs a window: the grid lives in the view.
var drags: String = ""
## Client debug: which node kind a `cutter` bot walks to and beams. Without it
## the bot takes whatever is nearest, which makes "can you mine granite" a test
## of what happens to be next to the spawn.
var cut_kind: String = ""
## Server debug: bring every spice field to a blow immediately. The cycle runs
## on a 7-15 minute dormancy, which is right for play and useless for a test.
var spice_now: bool = false
var deliver_to_landsraad: bool = false
## Starting water for new players. Debug knob so a death test takes seconds
## rather than minutes; -1 means full.
var start_hydration: float = -1.0
## Server: suppress the worm and hostiles entirely. Test isolation, not a game
## mode -- the Phase 0-3 harnesses are about their own subsystems, and a worm
## eating the bot mid-run is noise rather than a finding. Same reasoning as the
## `forager` bot profile.
var peaceful: bool = false
## Extra starting items, "id:count,id:count". Lets a test reach the far end of
## a crafting chain without gathering through it first. Server-side only.
var grant: String = ""

## Server: peer id -> {"identity": String, "ready": bool}
var peers: Dictionary = {}
## Client: true once the server has accepted the handshake. Nothing may RPC
## before this -- ENet reports the peer as connected a few frames before the
## handshake resolves, and RPCing into that window errors every tick.
var ready_to_play: bool = false


func is_server() -> bool:
	return role == Role.SERVER


func is_client() -> bool:
	return role == Role.CLIENT


func _ready() -> void:
	_parse_args()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connect_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if solo:
		# A private port per launch, not the shared default. Solo always hosted
		# on 27015, so if a server from an earlier session was still alive --
		# a hard-closed window, a crash, a run that outlived its client -- the
		# new client silently connected to *that*, and played its world. Every
		# fix to world data since then was invisible, because the world being
		# played was the old process's, not the new build's. Randomising means
		# a solo launch can only ever reach the server it just started.
		port = 30000 + (randi() % 20000)
		_host_own_server()
	match role:
		Role.SERVER: _start_server()
		Role.CLIENT: _start_client()
		_: push_warning("Net: no --server or --client given; idling")
	role_resolved.emit()


## Solo play, with no arguments at all: start our own headless server as a child
## process and connect to it.
##
## The game is server-authoritative with no offline path -- solo is a one-client
## session against a local server, which is what keeps a single set of rules to
## get right. That is a good decision about the *architecture* and it should
## never have been the player's problem. It was: launching the game meant
## launching two processes in the right order, which is why a shell script stood
## in for the front door.
##
## The child is the same binary we are. From an export that is the game itself;
## from the editor binary it needs --path, because a bare `godot --headless` in
## some other directory has no project to run.
func _host_own_server() -> void:
	var exe := OS.get_executable_path()
	var argv: PackedStringArray = ["--headless"]
	if OS.has_feature("editor"):
		argv.append_array(["--path", ProjectSettings.globalize_path("res://")])
	argv.append("--")
	argv.append_array(["--server", "--port", str(port)])
	# World-shaping flags belong to the world, so they have to reach the process
	# that owns it. Without this, `--peaceful` on a solo launch was accepted,
	# ignored, and the worm ate you anyway.
	for flag: String in ["--region", "--day-seconds", "--start-time",
			"--grant", "--spawn-at", "--start-hydration"]:
		var v := Args.value(flag, "")
		if not v.is_empty():
			argv.append_array([flag, v])
	for flag2: String in ["--peaceful", "--spice-now"]:
		if Args.has(flag2):
			argv.append(flag2)

	_server_pid = OS.create_process(exe, argv)
	if _server_pid <= 0:
		push_error("Net: could not start a local server (%s)" % exe)
		return
	print("[net] solo: hosting a local server (pid %d) on :%d" % [_server_pid, port])
	# Blocking, deliberately. The alternative is restructuring startup around an
	# await for something that takes about a second once, at launch, before
	# there is anything on screen to be blocked.
	OS.delay_msec(SOLO_SERVER_WAIT_MS)


## Take the server down with us. A solo session's server is ours alone, so
## leaving it running would hold the port and quietly serve the next launch a
## stale world.
func _exit_tree() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


func _parse_args() -> void:
	if Args.has("--server"):
		role = Role.SERVER
	elif Args.has("--client"):
		role = Role.CLIENT
	elif not Args.has("--run-tests"):
		# No role asked for means somebody double-clicked the game. That is the
		# commonest way it will ever be started, and it used to be the one way
		# that did nothing at all: "no --server or --client given; idling".
		role = Role.CLIENT
		solo = true
	port = Args.integer("--port", DEFAULT_PORT)
	host = Args.value("--host", "127.0.0.1")
	identity = Args.value("--identity", "")
	auto = Args.has("--auto")
	screenshot_path = Args.value("--screenshot", "")
	run_seconds = Args.number("--run-seconds", 0.0)
	bot_profile = Args.value("--bot-profile", "survive")
	goto_poi = Args.value("--goto", "")
	spawn_poi = Args.value("--spawn-at", "")
	learn_skill = Args.value("--learn", "")
	guild_name = Args.value("--guild", "")
	panel_page = Args.value("--panel", "")
	panel_press = Args.integer("--press", 0)
	do_actions = Args.value("--do", "")
	drags = Args.value("--drag", "")
	cut_kind = Args.value("--cut", "")
	spice_now = Args.has("--spice-now")
	deliver_to_landsraad = Args.has("--deliver")
	start_hydration = Args.number("--start-hydration", -1.0)
	grant = Args.value("--grant", "")
	peaceful = Args.has("--peaceful")
	if identity.is_empty():
		identity = "player-%d" % (OS.get_process_id() % 100000)


func _start_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		push_error("Net: cannot bind port %d (%s)" % [port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	print("[net] server listening on %d (max %d)" % [port, MAX_CLIENTS])


func _start_client() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		push_error("Net: cannot reach %s:%d (%s)" % [host, port, error_string(err)])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	print("[net] connecting to %s:%d as '%s'" % [host, port, identity])


# --- lifecycle ---------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_server():
		return
	peers[id] = {"identity": "", "ready": false}
	print("[net] peer %d connected, awaiting handshake" % id)


func _on_peer_disconnected(id: int) -> void:
	if not is_server():
		return
	peers.erase(id)
	print("[net] peer %d disconnected" % id)
	peer_left.emit(id)


func _on_connected() -> void:
	# Terrain must match byte-for-byte or predicted movement diverges silently.
	_handshake.rpc_id(1, PROTOCOL_VERSION, identity, Terrain.fingerprint)


func _on_connect_failed() -> void:
	connection_failed.emit("could not reach %s:%d" % [host, port])


func _on_server_disconnected() -> void:
	ready_to_play = false
	server_disconnected.emit()


# --- handshake ---------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _handshake(version: int, who: String, terrain_fp: String) -> void:
	if not is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if version != PROTOCOL_VERSION:
		_reject(id, "protocol %d, server speaks %d" % [version, PROTOCOL_VERSION])
		return
	if terrain_fp != Terrain.fingerprint:
		_reject(id, "terrain %s, server has %s" % [terrain_fp, Terrain.fingerprint])
		return

	peers[id] = {"identity": who, "ready": true}
	print("[net] peer %d handshook as '%s'" % [id, who])
	_handshake_accepted.rpc_id(id)
	peer_joined.emit(id)


## Tell the client why before dropping it. A plain disconnect_peer() discards
## the queued reliable RPC, so the client would just see the socket close;
## peer_disconnect_later() flushes the send queue first.
func _reject(id: int, reason: String) -> void:
	print("[net] rejecting peer %d: %s" % [id, reason])
	_handshake_rejected.rpc_id(id, reason)
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var pp := enet.get_peer(id) if enet != null else null
	if pp != null:
		pp.peer_disconnect_later()
	else:
		multiplayer.multiplayer_peer.disconnect_peer(id)


@rpc("authority", "call_remote", "reliable")
func _handshake_accepted() -> void:
	ready_to_play = true
	print("[net] handshake accepted")
	connected_to_server.emit()


@rpc("authority", "call_remote", "reliable")
func _handshake_rejected(reason: String) -> void:
	push_error("Net: rejected by server -- %s" % reason)
	connection_failed.emit(reason)


func identity_of(id: int) -> String:
	return str(peers.get(id, {}).get("identity", ""))


func ready_peers() -> Array:
	var out: Array = []
	for id: int in peers:
		if peers[id]["ready"]:
			out.append(id)
	return out
