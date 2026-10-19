extends SceneTree
## Used by network_smoke.py: two real processes exchange ENet RPCs.

var session: NetSession
var role := ""
var started_at := 0
var sequence := 0
var sent_craft := false
var sent_build := false
var had_client := false
var saw_damage := false
var saw_wall := false
var snapshots := 0

func _initialize() -> void:
	call_deferred("start")

func start() -> void:
	role = OS.get_cmdline_user_args()[0]
	started_at = Time.get_ticks_msec()
	var harness := Node.new()
	harness.name = "Harness" # Same path in both processes, including Session below.
	root.add_child(harness)
	session = NetSession.new()
	session.name = "Session"
	harness.add_child(session)
	session.state_received.connect(inspect)
	if role == "host":
		if session.host_lan(24568) != OK:
			fail("Cannot bind test port 24568")
	else:
		session.join_lan("127.0.0.1", 24568)

func _physics_process(_delta: float) -> bool:
	if session == null:
		return false
	if Time.get_ticks_msec() - started_at > 14000:
		fail("Test deadline exceeded")
	if role == "client" and session.admitted:
		sequence += 1
		var direction := Vector2.LEFT if sequence <= 30 else Vector2.ZERO
		var packet := {"seq": sequence, "move": direction, "aim": PI, "fire": sequence == 50}
		session.submit_inputs([packet])
		if not sent_craft:
			sent_craft = true
			# Send an intentional replay over the actual reliable RPC boundary.
			session._action.rpc_id(1, 1, "craft", "ammo")
			session._action.rpc_id(1, 1, "craft", "ammo")
			session.request_sequence = 1
	return false

func inspect(state: Dictionary) -> void:
	snapshots += 1
	if role == "host":
		if state.players.size() == 2:
			had_client = true
			if state.players[1].hp == 75:
				saw_damage = true
			if state.walls.has("2,2"):
				saw_wall = true
		elif had_client and state.players.size() == 1:
			if saw_damage and saw_wall:
				print("HOST_PASS: admission, shot authority, wall state, disconnect cleanup")
				session.leave()
				quit(0)
			else:
				fail("Client disconnected without proving gameplay")
		return
	if not state.players.has(session.local_id):
		return
	var player: Dictionary = state.players[session.local_id]
	if player.ack >= 30 and not sent_build:
		if player.pos.distance_to(Vector2(1, 0)) > 0.15 or player.inventory.ammo != 36 or player.inventory.wood != 11:
			fail("Movement/craft/replay state differs: " + str(player))
			return
		sent_build = true
		session.request_action("build", Vector2i(2, 2))
	if sent_build and state.walls.has("2,2") and state.players[1].hp == 75:
		if player.inventory.wall != 0 or player.inventory.ammo != 35 or snapshots < 4:
			fail("Wrong final inventory/snapshot count")
			return
		print("CLIENT_PASS: full state, movement ack, craft deduplication, build, shooting")
		session.leave()
		quit(0)

func fail(message: String) -> void:
	push_error(role + ": " + message)
	if session != null:
		session.leave()
	quit(1)
