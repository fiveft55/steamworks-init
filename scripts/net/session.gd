class_name NetSession
extends Node
## The coded networking API. Authority always has Godot peer ID 1.
## Steam IDs are transport identities; Godot IDs identify players in RPCs.

signal state_received(state: Dictionary)
signal status_changed(text: String)
signal shot_received(event: Dictionary)
signal action_completed(text: String)
signal ended

var steam_lobbies: SteamLobbies
var active := false # A transport exists; admission may still be pending.
var admitted := false # Client has received a protocol-compatible welcome.
var local_id := 1
var authority: GameSimulation # Exists only on a host, never on a remote client.
var latest: Dictionary = {} # Last full state, suitable for late join and replay.
var queues: Dictionary = {} # peer_id -> {sequence_number: validated command}.
var waiting: Dictionary = {} # Unadmitted peer_id -> arrival wall-clock milliseconds.
var action_sequences: Dictionary = {} # Last accepted request ID, per admitted peer.
var budgets: Dictionary = {} # Bounded per-peer/per-message-family rate windows.
var request_sequence := 0
var connect_deadline := 0
var last_state_at := 0
var sampled_bytes := 0 # Godot Variant bytes, not transport/UDP/relay overhead.

func _ready() -> void:
	steam_lobbies = SteamLobbies.new()
	add_child(steam_lobbies)
	steam_lobbies.peer_ready.connect(_on_steam_peer)
	steam_lobbies.message.connect(func(text: String): status_changed.emit(text))
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(func(): _fail("Connection failed."))
	multiplayer.server_disconnected.connect(func(): _fail("Host left. Host migration is not implemented."))

func solo() -> void:
	leave()
	_start_host() # OfflineMultiplayerPeer runs the same authoritative rules locally.
	status_changed.emit("Solo sandbox. Host LAN to add another player.")

func host_lan(port: int = GameRules.PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, GameRules.MAX_PLAYERS - 1)
	if error != OK:
		status_changed.emit("Host failed: " + error_string(error))
		return error
	multiplayer.multiplayer_peer = peer
	_start_host()
	status_changed.emit("LAN host on UDP " + str(port) + ". Share your LAN IP with friends.")
	return OK

func join_lan(address: String, port: int = GameRules.PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address.strip_edges(), port)
	if error != OK:
		status_changed.emit("Join failed: " + error_string(error))
		return error
	multiplayer.multiplayer_peer = peer
	active = true
	connect_deadline = Time.get_ticks_msec() + 10000
	status_changed.emit("Connecting to " + address + "…")
	return OK

func host_steam() -> void:
	leave()
	steam_lobbies.host_lobby()

func join_steam(id_text: String) -> void:
	leave()
	steam_lobbies.join_lobby(id_text)

func _on_steam_peer(peer: MultiplayerPeer, hosting: bool) -> void:
	# An invitation cannot silently replace an active LAN or solo game.
	if active:
		peer.close()
		steam_lobbies.leave()
		status_changed.emit("Leave the active session before accepting a Steam invite.")
		return
	multiplayer.multiplayer_peer = peer
	if hosting:
		_start_host()
	else:
		active = true
		connect_deadline = Time.get_ticks_msec() + 15000

func _start_host() -> void:
	authority = GameSimulation.new()
	authority.add_player(1)
	queues[1] = {}
	active = true
	admitted = true
	local_id = 1
	_publish() # Local renderer can immediately display the authoritative world.

func leave() -> void:
	if is_instance_valid(steam_lobbies):
		steam_lobbies.leave()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	active = false
	admitted = false
	authority = null
	queues.clear()
	waiting.clear()
	budgets.clear()
	action_sequences.clear()
	latest.clear()
	request_sequence = 0
	sampled_bytes = 0
	local_id = 1
	ended.emit()

func _fail(text: String) -> void:
	leave()
	status_changed.emit(text)

func _connected() -> void:
	local_id = multiplayer.get_unique_id()
	_hello.rpc_id(1, GameRules.PROTOCOL) # Server derives identity from the connection.

func _peer_connected(id: int) -> void:
	if authority != null:
		waiting[id] = Time.get_ticks_msec() # Five seconds to complete the hello.

func _peer_disconnected(id: int) -> void:
	if authority != null:
		authority.remove_player(id)
	queues.erase(id)
	waiting.erase(id)
	action_sequences.erase(id)
	budgets.erase(id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _hello(protocol: String) -> void:
	if authority == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not waiting.has(sender):
		return # A repeated hello cannot reset inventory or spawn a second player.
	if protocol != GameRules.PROTOCOL or authority.players.size() >= GameRules.MAX_PLAYERS:
		multiplayer.multiplayer_peer.disconnect_peer(sender)
		return
	if steam_lobbies.lobby_id != 0 and not steam_lobbies.is_lobby_peer(multiplayer.multiplayer_peer, sender):
		multiplayer.multiplayer_peer.disconnect_peer(sender)
		return # Friends-only discovery alone does not authorize a direct socket connection.
	waiting.erase(sender)
	authority.add_player(sender)
	queues[sender] = {}
	_welcome.rpc_id(sender, authority.snapshot())

@rpc("authority", "call_remote", "reliable", 0)
func _welcome(state: Dictionary) -> void:
	admitted = true
	last_state_at = Time.get_ticks_msec()
	_accept_state(state)
	status_changed.emit("Connected as peer " + str(local_id) + ".")

func submit_inputs(recent_commands: Array) -> void:
	if not admitted:
		return
	if authority != null:
		_ingest(local_id, recent_commands)
	else:
		_inputs.rpc_id(1, recent_commands) # Client never sends position or hit results.

@rpc("any_peer", "call_remote", "unreliable", 0)
func _inputs(batch: Array) -> void:
	if authority != null:
		_ingest(multiplayer.get_remote_sender_id(), batch)

func _allow(id: int, family: String, limit: int) -> bool:
	# This is game-level abuse control, not protection against transport-level DoS.
	if not budgets.has(id):
		budgets[id] = {}
	var window := int(Time.get_ticks_msec() / 1000.0)
	var entry: Dictionary = budgets[id].get(family, {"window": window, "count": 0})
	if entry.window != window:
		entry = {"window": window, "count": 0}
	entry.count += 1
	budgets[id][family] = entry
	return entry.count <= limit

func _ingest(sender: int, batch: Array) -> void:
	if not authority.players.has(sender) or not _allow(sender, "input", 100) or batch.size() > 3:
		return
	var ack: int = authority.players[sender].ack
	for value in batch:
		if not value is Dictionary or value.size() != 4:
			continue
		if not value.get("seq") is int or not value.get("aim") is float or not value.get("fire") is bool:
			continue
		if not GameRules.finite_vector(value.get("move")) or not is_finite(value.aim):
			continue
		if value.seq <= ack or value.seq > ack + 256 or queues[sender].size() >= 12:
			continue # Bound memory, reject replays, and constrain sequence jumps.
		queues[sender][value.seq] = {"seq": value.seq, "move": value.move.limit_length(1.0),
			"aim": wrapf(value.aim, -PI, PI), "fire": value.fire}

func request_action(kind: String, payload: Variant) -> void:
	if not admitted:
		return
	request_sequence += 1
	if authority != null:
		_apply_action(local_id, request_sequence, kind, payload)
	else:
		_action.rpc_id(1, request_sequence, kind, payload)

@rpc("any_peer", "call_remote", "reliable", 0)
func _action(sequence: int, kind: String, payload: Variant) -> void:
	if authority != null:
		_apply_action(multiplayer.get_remote_sender_id(), sequence, kind, payload)

func _apply_action(sender: int, sequence: int, kind: String, payload: Variant) -> void:
	if not authority.players.has(sender) or not _allow(sender, "action", 8):
		return
	var previous: int = action_sequences.get(sender, 0)
	if sequence <= previous or sequence > previous + 100:
		return # Duplicate IDs cannot craft, collect, or place twice.
	action_sequences[sender] = sequence
	var text := authority.action(sender, kind, payload)
	if sender == local_id:
		action_completed.emit(text)
	else:
		_action_result.rpc_id(sender, text)
	_publish() # Reliable result explains success; full state follows independently.

@rpc("authority", "call_remote", "reliable", 0)
func _action_result(text: String) -> void:
	action_completed.emit(text)

func _physics_process(_delta: float) -> void:
	if not active:
		return
	var now := Time.get_ticks_msec()
	if authority == null:
		if not admitted and now > connect_deadline:
			_fail("Timed out connecting or negotiating protocol.")
		elif admitted and now - last_state_at > 10000:
			_fail("No host snapshots for 10 seconds.")
		return
	for id in waiting.keys():
		if now - int(waiting[id]) > 5000:
			waiting.erase(id)
			multiplayer.multiplayer_peer.disconnect_peer(id)
	if steam_lobbies.lobby_id != 0 and authority.tick % GameRules.TICK_RATE == 0:
		for id in authority.players.keys():
			if id != 1 and not steam_lobbies.is_lobby_peer(multiplayer.multiplayer_peer, id):
				multiplayer.multiplayer_peer.disconnect_peer(id)
	var commands: Dictionary = {}
	for id in queues:
		var queue: Dictionary = queues[id]
		if not queue.is_empty():
			var keys: Array = queue.keys()
			keys.sort()
			commands[id] = queue[keys[0]] # At most ONE command per player per server tick.
			queue.erase(keys[0])
	authority.step(commands)
	for event in authority.events:
		shot_received.emit(event)
		if multiplayer.get_peers().size() > 0:
			_shot.rpc(event)
	if authority.tick % GameRules.SNAPSHOT_EVERY == 0:
		_publish()

func _publish() -> void:
	latest = authority.snapshot()
	sampled_bytes = var_to_bytes(latest).size()
	state_received.emit(latest)
	if multiplayer.get_peers().size() > 0:
		_snapshot.rpc(latest)

@rpc("authority", "call_remote", "unreliable", 0)
func _snapshot(state: Dictionary) -> void:
	if admitted:
		_accept_state(state)

func _accept_state(state: Dictionary) -> void:
	# Explicit ordering also works with Steam peers lacking unreliable_ordered mode.
	if not latest.is_empty() and int(state.tick) <= int(latest.tick):
		return
	latest = state
	last_state_at = Time.get_ticks_msec()
	sampled_bytes = var_to_bytes(state).size()
	state_received.emit(state)

@rpc("authority", "call_remote", "unreliable", 0)
func _shot(event: Dictionary) -> void:
	shot_received.emit(event) # Cosmetic loss is allowed; damage arrives in full state.
