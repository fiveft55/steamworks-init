extends SceneTree
## No testing addon needed. Explicit failures also work in release builds.

var checks := 0
var failures := 0

func expect(condition: bool, explanation: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + explanation)

func command(sequence: int, move: Vector2 = Vector2.ZERO, aim: float = 0.0, fire: bool = false) -> Dictionary:
	return {"seq": sequence, "move": move, "aim": aim, "fire": fire}

func _initialize() -> void:
	call_deferred("run") # Nodes must be attached to a live SceneTree for RPC tests.

func run() -> void:
	var sim := GameSimulation.new()
	sim.add_player(1)
	sim.add_player(2)
	var initial: Vector2 = sim.players[1].pos
	for index in range(60):
		sim.step({1: command(index + 1, Vector2(100, 100))})
	expect(is_equal_approx(initial.distance_to(sim.players[1].pos), GameRules.SPEED), "Diagonal input cannot exceed movement speed")
	expect(not GameRules.finite_vector(Vector2(NAN, 1)), "NaN is rejected")
	expect(not GameRules.finite_vector(Vector2(INF, 1)), "Infinity is rejected")
	expect(not GameRules.finite_vector("wrong"), "Wrong movement type is rejected")
	expect(GameRules.move(Vector2(11.6, 0), Vector2.RIGHT, {}) == Vector2(11.6, 0), "Arena boundary blocks movement")
	expect(GameRules.move(Vector2(0, -0.91), Vector2.DOWN, {"0,0": 100}).y < -0.9, "Walls block player circles")
	expect(is_equal_approx(GameSimulation.ray_box(Vector2(-2, 0), Vector2.RIGHT, Vector2.ZERO), 1.5), "Ray intersects wall at its face")
	expect(GameSimulation.ray_box(Vector2(-2, 2), Vector2.RIGHT, Vector2.ZERO) < 0, "Parallel ray misses wall")
	sim = GameSimulation.new()
	sim.add_player(1)
	sim.add_player(2)
	var before: Dictionary = sim.players[1].inventory.duplicate()
	expect(sim.action(1, "craft", "ammo") == "Crafted ammo.", "Known recipe succeeds")
	expect(sim.players[1].inventory.ammo == before.ammo + 12, "Craft output has correct quantity")
	expect(sim.players[1].inventory.wood == before.wood - 1 and sim.players[1].inventory.metal == before.metal - 1, "Recipe pays every cost")
	sim.players[1].inventory.metal = 0
	before = sim.players[1].inventory.duplicate()
	sim.action(1, "craft", "ammo")
	expect(sim.players[1].inventory == before, "Failed craft makes no partial deduction")
	expect(sim.action(1, "craft", "money") == "Unknown recipe.", "Client cannot invent recipe")
	expect(sim.action(99, "craft", "ammo") == "Player is not admitted.", "Unknown player cannot mutate state")
	sim.action(1, "collect", 1)
	expect(sim.drops.has(1), "Remote pickup is rejected")
	sim.players[1].pos = sim.drops[1].pos
	before = sim.players[1].inventory.duplicate()
	sim.action(1, "collect", 1)
	sim.action(2, "collect", 1)
	expect(not sim.drops.has(1) and sim.players[1].inventory.wood == before.wood + 4, "A pickup can be collected only once")
	sim.players[1].pos = Vector2(6, 6)
	before = sim.players[1].inventory.duplicate()
	expect(sim.action(1, "build", Vector2i(7, 7)) == "Wall placed.", "Valid grid wall can be placed")
	expect(sim.walls.has("7,7") and sim.players[1].inventory.wall == before.wall - 1, "Wall consumes exactly one kit")
	sim.players[1].inventory.wall = 3
	sim.action(1, "build", Vector2i(7, 7))
	expect(sim.players[1].inventory.wall == 3, "Duplicate placement does not spend a kit")
	sim.action(1, "build", Vector2i(100, 100))
	expect(sim.walls.size() == 1, "Out-of-range building rejected")
	sim.action(1, "build", Vector2(7, 7))
	expect(sim.walls.size() == 1, "Wrong build payload rejected")
	sim.players[1].pos = Vector2(4, 2)
	sim.action(1, "build", Vector2i(4, 0))
	expect(not sim.walls.has("4,0"), "Spawn areas stay clear")
	for index in range(GameRules.MAX_WALLS):
		sim.walls[str(index) + ",10"] = 100
	sim.players[1].pos = Vector2(6, 6)
	sim.action(1, "build", Vector2i(6, 7))
	expect(not sim.walls.has("6,7"), "Maximum wall count enforced")
	sim = GameSimulation.new()
	sim.add_player(1)
	sim.add_player(2)
	sim.step({1: command(1, Vector2.ZERO, 0, true)})
	expect(sim.players[2].hp == 75 and sim.players[1].inventory.ammo == 23, "Hitscan damages the nearest bean and spends ammo")
	sim.step({1: command(2, Vector2.ZERO, 0, true)})
	expect(sim.players[2].hp == 75, "Cooldown rejects an immediate second shot")
	for index in range(35):
		sim.step({1: command(index + 3, Vector2.ZERO, 0, true)})
	expect(sim.players[1].kills == 1 and sim.players[2].hp == 100, "Four legal hits cause one kill and respawn")
	sim = GameSimulation.new()
	sim.add_player(1)
	sim.add_player(2)
	sim.walls["0,0"] = 100
	sim.step({1: command(1, Vector2.ZERO, 0, true)})
	expect(sim.players[2].hp == 100 and sim.walls["0,0"] == 75, "Wall occludes target and takes damage")
	sim.players[1].inventory.ammo = 0
	sim.tick += 100
	sim.shoot(1)
	expect(sim.walls["0,0"] == 75, "Empty gun cannot cause damage")
	var frozen := sim.snapshot()
	sim.players[1].inventory.wood = 999
	expect(frozen.players[1].inventory.wood != 999, "Snapshots deep-copy nested state")
	# Exercise the actual transport boundary without a network dependency.
	var session := NetSession.new()
	root.add_child(session)
	session.solo()
	session._ingest(1, [command(1, Vector2(INF, 0)), command(2, Vector2.ONE), command(999)])
	expect(session.queues[1].size() == 1 and session.queues[1].has(2), "Ingress rejects non-finite and far-future input")
	session._ingest(123, [command(1)])
	expect(not session.queues.has(123), "Unadmitted peer cannot enqueue commands")
	session._apply_action(1, 1, "craft", "ammo")
	session._apply_action(1, 1, "craft", "ammo")
	expect(session.authority.players[1].inventory.ammo == 36, "Duplicate request ID applies once")
	session.authority.players[1].ack = 10
	session.queues[1].clear()
	session._ingest(1, [command(2)])
	expect(session.queues[1].is_empty(), "Acknowledged movement cannot be replayed")
	session.leave()
	session.queue_free()
	print("MODEL_TEST: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
