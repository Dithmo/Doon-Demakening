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
const PROTOCOL_VERSION := 1

var role: Role = Role.NONE
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

	match role:
		Role.SERVER: _start_server()
		Role.CLIENT: _start_client()
		_: push_warning("Net: no --server or --client given; idling")
	role_resolved.emit()


func _parse_args() -> void:
	if Args.has("--server"):
		role = Role.SERVER
	elif Args.has("--client"):
		role = Role.CLIENT
	port = Args.integer("--port", DEFAULT_PORT)
	host = Args.value("--host", "127.0.0.1")
	identity = Args.value("--identity", "")
	auto = Args.has("--auto")
	screenshot_path = Args.value("--screenshot", "")
	run_seconds = Args.number("--run-seconds", 0.0)
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
