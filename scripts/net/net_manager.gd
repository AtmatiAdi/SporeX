extends Node
## Autoload. LAN multiplayer skeleton:
##  - host(): ENet server + UDP broadcast beacon announcing the galaxy seed
##  - join(ip): ENet client; the server pushes its galaxy seed on connect
##  - discovery: listens for beacons and keeps a list of LAN hosts
## Because the whole universe is derived from one seed, a client only needs the
## seed to rebuild the exact same galaxy locally. Player state replication is a
## follow-up task (see TASKS.md).

const PORT := 27015
const BEACON_PORT := 27016
const BEACON_INTERVAL := 1.0
const HOST_TIMEOUT := 4.0

signal galaxy_seed_received(seed: int)
signal status_changed

var galaxy_seed := 0
var mode := "offline"   # offline | host | client
var hosts := {}         # ip -> {"seed": int, "name": String, "seen": float}
var _peer: ENetMultiplayerPeer
var _beacon: PacketPeerUDP
var _listener: PacketPeerUDP
var _beacon_timer := 0.0


func _ready() -> void:
	_listener = PacketPeerUDP.new()
	if _listener.bind(BEACON_PORT, "0.0.0.0") != OK:
		push_warning("NetManager: could not bind beacon listener on port %d" % BEACON_PORT)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.connected_to_server.connect(func(): mode = "client"; status_changed.emit())
	multiplayer.connection_failed.connect(func(): mode = "offline"; status_changed.emit())
	multiplayer.server_disconnected.connect(func(): mode = "offline"; status_changed.emit())


func host() -> bool:
	_peer = ENetMultiplayerPeer.new()
	if _peer.create_server(PORT, 8) != OK:
		push_warning("NetManager: create_server failed")
		return false
	multiplayer.multiplayer_peer = _peer
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	_beacon.set_dest_address("255.255.255.255", BEACON_PORT)
	mode = "host"
	status_changed.emit()
	return true


func join(ip: String) -> bool:
	_peer = ENetMultiplayerPeer.new()
	if _peer.create_client(ip, PORT) != OK:
		push_warning("NetManager: create_client failed")
		return false
	multiplayer.multiplayer_peer = _peer
	mode = "connecting"
	status_changed.emit()
	return true


func join_first_host() -> bool:
	for ip in hosts:
		return join(ip)
	return false


func leave() -> void:
	if _peer:
		_peer.close()
	multiplayer.multiplayer_peer = null
	_beacon = null
	mode = "offline"
	status_changed.emit()


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_sync_seed.rpc_id(id, galaxy_seed)
	status_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_seed(seed: int) -> void:
	galaxy_seed = seed
	galaxy_seed_received.emit(seed)


func peer_count() -> int:
	if multiplayer.multiplayer_peer == null or mode == "offline":
		return 0
	return multiplayer.get_peers().size()


func _process(dt: float) -> void:
	if _beacon:
		_beacon_timer -= dt
		if _beacon_timer <= 0.0:
			_beacon_timer = BEACON_INTERVAL
			var msg := JSON.stringify({"sporex": 1, "seed": galaxy_seed, "name": OS.get_environment("COMPUTERNAME")})
			_beacon.put_packet(msg.to_utf8_buffer())
	while _listener.get_available_packet_count() > 0:
		var pkt := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var data = JSON.parse_string(pkt.get_string_from_utf8())
		if data is Dictionary and data.has("sporex"):
			if mode == "host" and ip in IP.get_local_addresses():
				continue
			hosts[ip] = {"seed": int(data.get("seed", 0)), "name": str(data.get("name", "")), "seen": Time.get_ticks_msec() / 1000.0}
	var now := Time.get_ticks_msec() / 1000.0
	for ip in hosts.keys():
		if now - hosts[ip]["seen"] > HOST_TIMEOUT:
			hosts.erase(ip)
