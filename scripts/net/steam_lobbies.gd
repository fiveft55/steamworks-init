class_name SteamLobbies
extends Node
## Optional adapter: GodotSteam lobby API + Expresso SteamMultiplayerPeer socket API.
## Dynamic lookup lets plain Godot parse and run this entire project without addons.
## This adapter is NOT for GodotSteam's differently shaped lobby/message peer API.

signal peer_ready(peer: MultiplayerPeer, hosting: bool)
signal message(text: String)

var steam: Object # Singleton supplied by a compatible GodotSteam installation.
var initialized := false
var lobby_id := 0 # Steam uint64 IDs stay integers; never convert them through float.
var hosting := false
var busy := false
var deadline := 0
var app_id := int(ProjectSettings.get_setting("steam/app_id", 480)) # Spacewar development only.

func _process(_delta: float) -> void:
	if initialized:
		steam.call("run_callbacks") # Steam delivers asynchronous lobby events here.
	if busy and Time.get_ticks_msec() > deadline:
		leave()
		message.emit("Steam lobby request timed out; check Steam and permissions.")

func initialize() -> bool:
	if initialized:
		return true
	if not Engine.has_singleton("Steam") or not ClassDB.class_exists("SteamMultiplayerPeer"):
		message.emit("Install GodotSteam and the compatible socket peer; see docs/INTEGRATION.md.")
		return false
	steam = Engine.get_singleton("Steam")
	var result: Dictionary = steam.call("steamInitEx", false, app_id)
	if int(result.get("status", -1)) != 0:
		message.emit("Steam init failed: " + str(result.get("verbal", "Check client, App ID, and libraries.")))
		return false
	# Connect once. Manual callback pumping is used; do not enable a second pump.
	steam.connect("lobby_created", _on_created)
	steam.connect("lobby_joined", _on_joined)
	steam.connect("join_requested", _on_join_requested)
	initialized = true
	return true

func host_lobby() -> void:
	if not initialize():
		return
	hosting = true
	busy = true
	deadline = Time.get_ticks_msec() + 15000
	steam.call("createLobby", 1, GameRules.MAX_PLAYERS) # 1 = friends-only, not public.
	message.emit("Creating Steam friends lobby…")

func join_lobby(id_text: String) -> void:
	# Text entry avoids truncating a 64-bit lobby ID in a floating-point UI widget.
	if not id_text.is_valid_int() or int(id_text) <= 0:
		message.emit("Paste a positive numeric Steam lobby ID.")
		return
	if not initialize():
		return
	hosting = false
	busy = true
	deadline = Time.get_ticks_msec() + 15000
	steam.call("joinLobby", int(id_text))
	message.emit("Joining Steam lobby…")

func invite_friends() -> void:
	if initialized and lobby_id != 0:
		steam.call("activateGameOverlayInviteDialog", lobby_id)
	else:
		message.emit("Host or join a Steam lobby first.")

func _on_created(result: int, id: int) -> void:
	if not busy or not hosting:
		# A canceled asynchronous create must not strand an invisible lobby.
		if result == 1:
			steam.call("leaveLobby", id)
		return
	if result != 1:
		busy = false
		message.emit("Steam createLobby failed, result " + str(result))
		return
	lobby_id = id
	steam.call("setLobbyData", id, "protocol", GameRules.PROTOCOL)
	steam.call("setLobbyData", id, "host", str(steam.call("getSteamID")))
	steam.call("setLobbyData", id, "name", "Bean Workshop friends")
	_open_peer(true, 0) # Host socket first; then friends may connect to its owner ID.

func _on_joined(id: int, _permissions: int, _locked: bool, result: int) -> void:
	if hosting:
		return # Creating a lobby also produces a joined callback; do not open twice.
	if not busy:
		if result == 1:
			steam.call("leaveLobby", id)
		return
	if result != 1:
		busy = false
		message.emit("Steam joinLobby failed, response " + str(result))
		return
	lobby_id = id
	var protocol := str(steam.call("getLobbyData", id, "protocol"))
	if protocol != GameRules.PROTOCOL:
		leave()
		message.emit("Lobby uses a different protocol/build.")
		return
	var owner := int(steam.call("getLobbyOwner", id))
	if str(owner) != str(steam.call("getLobbyData", id, "host")):
		leave()
		message.emit("Original host has left. Create a new lobby; host migration is not supported.")
		return
	_open_peer(false, owner) # Lobby ID locates the room; owner Steam ID routes traffic.

func _open_peer(as_host: bool, owner: int) -> void:
	var candidate: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	if candidate == null or not candidate is MultiplayerPeer:
		leave()
		message.emit("SteamMultiplayerPeer is not a compatible MultiplayerPeer.")
		return
	if not candidate.has_method("create_host") or not candidate.has_method("create_client") or not candidate.has_method("get_steam64_from_peer_id"):
		leave()
		message.emit("Wrong Steam peer API. This adapter requires create_host(port)/create_client(owner, port).")
		return
	var error: int
	if as_host:
		error = candidate.call("create_host", 0) # Steam virtual port; not the LAN UDP port.
	else:
		error = candidate.call("create_client", owner, 0)
	busy = false
	if error != OK:
		leave()
		message.emit("Steam socket creation failed: " + error_string(error))
		return
	peer_ready.emit(candidate as MultiplayerPeer, as_host)
	message.emit("Steam lobby " + str(lobby_id) + ". Copy this ID or invite friends.")

func is_lobby_peer(peer: MultiplayerPeer, id: int) -> bool:
	# Transport identity is read from the socket; never accept a Steam ID in an RPC.
	if not initialized or lobby_id == 0 or not peer.has_method("get_steam64_from_peer_id"):
		return false
	var steam_id := int(peer.call("get_steam64_from_peer_id", id))
	var count := int(steam.call("getNumLobbyMembers", lobby_id))
	for index in range(count):
		if int(steam.call("getLobbyMemberByIndex", lobby_id, index)) == steam_id:
			return true
	return false

func _on_join_requested(id: int, _friend_id: int) -> void:
	# Running-game invitations are supported. Cold-launch +connect_lobby is in main.gd.
	if lobby_id != 0 or busy:
		message.emit("Leave your current session before accepting another invitation.")
		return
	join_lobby(str(id))

func leave() -> void:
	if initialized and lobby_id != 0:
		steam.call("leaveLobby", lobby_id)
	lobby_id = 0
	busy = false
	hosting = false
