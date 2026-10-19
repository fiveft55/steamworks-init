extends Node
## Composition root: joins the model/network, input, view, and UI together.
## No gameplay rule is hidden inside a button or a rendering callback.

var session: NetSession
var arena: ArenaView
var hud: GameHUD
var sequence := 0 # Monotonic per-session input ID, NOT a trusted server timestamp.
var pending: Array = [] # Owner's unacknowledged commands for movement replay.
var recent: Array = [] # Last three inputs are resent to tolerate occasional loss.
var predicted := Vector2.ZERO
var local_feedback_tick := -GameRules.SHOT_TICKS

func _ready() -> void:
	arena = ArenaView.new()
	add_child(arena)
	hud = GameHUD.new()
	add_child(hud)
	session = NetSession.new()
	session.name = "Session" # RPC paths must be identical in every game instance.
	add_child(session)
	session.state_received.connect(_state_received)
	session.status_changed.connect(hud.show_status)
	session.action_completed.connect(hud.show_status)
	session.shot_received.connect(arena.show_shot)
	session.ended.connect(_ended)
	hud.solo_pressed.connect(session.solo)
	hud.host_pressed.connect(func(): session.host_lan())
	hud.join_pressed.connect(func(address: String): session.join_lan(address))
	hud.steam_host_pressed.connect(session.host_steam)
	hud.steam_join_pressed.connect(session.join_steam)
	hud.invite_pressed.connect(func(): session.steam_lobbies.invite_friends())
	hud.reset()
	# With both addons loaded, listen for invitations while the menu is open too.
	if Engine.has_singleton("Steam") and ClassDB.class_exists("SteamMultiplayerPeer"):
		session.steam_lobbies.initialize()
	# Steam may cold-launch a game with +connect_lobby <uint64>.
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var index := args.find("+connect_lobby")
	if index >= 0 and index + 1 < args.size():
		session.join_steam(args[index + 1])

func _state_received(state: Dictionary) -> void:
	var id := session.local_id
	if not state.players.has(id):
		return
	var player: Dictionary = state.players[id]
	predicted = player.pos # Rewind to the host's authoritative position.
	if session.authority == null:
		pending = pending.filter(func(command: Dictionary): return command.seq > player.ack)
		for command in pending:
			predicted = GameRules.move(predicted, command.move, state.walls) # Replay remaining input.
	arena.accept_state(state, id)
	arena.local_position = predicted
	hud.show_state(state, id, session.sampled_bytes)

func _physics_process(_delta: float) -> void:
	if not session.admitted or session.latest.is_empty():
		return
	if pending.size() >= 120:
		return # Bound replay work. Wait for acknowledgement rather than grow forever.
	var move := Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))).limit_length(1.0)
	var aim := (arena.aim_position() - predicted).angle()
	var firing := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	sequence += 1
	var command := {"seq": sequence, "move": move, "aim": aim, "fire": firing}
	recent.append(command)
	if recent.size() > 3:
		recent.pop_front()
	if session.authority == null:
		pending.append(command)
		predicted = GameRules.move(predicted, move, session.latest.walls)
		arena.local_position = predicted # Prediction is visual; it never commits game state.
	else:
		predicted = session.authority.players[1].pos # Host can render its 60Hz model directly.
		arena.local_position = predicted
	arena.local_aim = aim
	session.submit_inputs(recent)
	# Immediate trigger feedback is deliberately separate from confirmed damage.
	if firing and sequence - local_feedback_tick >= GameRules.SHOT_TICKS:
		local_feedback_tick = sequence
		arena.show_muzzle(predicted, aim)
		hud.feedback.text = "Trigger feedback • waiting for authoritative hit / ammo state"

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		session.leave()
		hud.show_status("Session closed.")
		return
	if not session.admitted:
		return
	match event.keycode:
		KEY_C:
			session.request_action("craft", "ammo")
		KEY_V:
			session.request_action("craft", "wall")
		KEY_B:
			session.request_action("build", arena.build_cell())
		KEY_E:
			collect_nearest()
		KEY_I:
			session.steam_lobbies.invite_friends()

func collect_nearest() -> void:
	var closest := 0
	var distance := GameRules.PICKUP_DISTANCE
	for id in session.latest.drops:
		var candidate: float = predicted.distance_to(session.latest.drops[id].pos)
		if candidate <= distance:
			distance = candidate
			closest = id
	if closest == 0:
		hud.show_status("No resource pile within reach.")
	else:
		session.request_action("collect", closest) # Host rechecks distance and existence.

func _ended() -> void:
	sequence = 0
	pending.clear()
	recent.clear()
	predicted = Vector2.ZERO
	local_feedback_tick = -GameRules.SHOT_TICKS
	arena.clear()
	hud.reset()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_instance_valid(session):
		session.leave() # Close Steam lobby and sockets when exiting normally.
