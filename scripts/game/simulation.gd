class_name GameSimulation
extends RefCounted
## Pure authoritative model: no rendering, sockets, Steam, or client-owned state.
## Vector2.y means the 3D world's Z coordinate in every network message.

var tick := 0 # Server clock; never supplied by a client.
var players: Dictionary = {} # peer_id -> player dictionary.
var walls: Dictionary = {} # "x,z" -> hit points.
var drops: Dictionary = {} # Stable drop_id -> position and resource quantities.
var events: Array = [] # Shots; consumed after each server step.

func _init() -> void:
	# Resource piles are finite; collecting removes a pile atomically.
	for index in range(8):
		drops[index + 1] = {"pos": Vector2(-8 + (index % 4) * 5, -7 + floori(index / 4.0) * 14), "wood": 4, "metal": 2}

func add_player(id: int) -> void:
	if players.has(id):
		return # Admission is idempotent.
	players[id] = {"pos": GameRules.spawn(players.size()), "aim": 0.0,
		"hp": 100, "inventory": {"wood": 12, "metal": 6, "ammo": 24, "wall": 1},
		"ack": 0, "last_shot": -GameRules.SHOT_TICKS, "kills": 0}

func remove_player(id: int) -> void:
	players.erase(id) # Departures appear in the next full snapshot.

func step(commands: Dictionary) -> void:
	tick += 1 # One step per physics tick, regardless of packet count.
	events.clear() # Previous frame's cosmetic events were already published.
	for id in players:
		if not commands.has(id):
			continue # Missing commands do not grant repeated movement or shots.
		var command: Dictionary = commands[id]
		var player: Dictionary = players[id]
		player.pos = GameRules.move(player.pos, command.move, walls)
		player.aim = command.aim
		player.ack = command.seq # Owner discards predictions through this sequence.
		if command.fire:
			shoot(id) # Ammo, cooldown, ray, and damage belong to authority.

func shoot(id: int) -> void:
	var player: Dictionary = players[id]
	if tick - int(player.last_shot) < GameRules.SHOT_TICKS or player.inventory.ammo <= 0:
		return # Holding the trigger cannot bypass cooldown.
	player.last_shot = tick
	player.inventory.ammo -= 1
	var origin: Vector2 = player.pos
	var direction := Vector2(cos(player.aim), sin(player.aim))
	var closest := GameRules.RANGE
	var target := 0 # Zero means no bean hit.
	var wall_target := ""
	# Exact ray/AABB math prevents shooting through diagonal wall corners.
	for key in walls:
		var distance := ray_box(origin, direction, GameRules.cell_position(key))
		if distance >= 0.0 and distance < closest:
			closest = distance
			wall_target = key
	for other_id in players:
		if other_id == id:
			continue # No self damage.
		var offset: Vector2 = players[other_id].pos - origin
		var along := offset.dot(direction)
		var across_squared := offset.length_squared() - along * along
		if across_squared > GameRules.RADIUS * GameRules.RADIUS:
			continue
		var distance := along - sqrt(maxf(0.0, GameRules.RADIUS * GameRules.RADIUS - across_squared))
		if distance >= 0.0 and distance < closest:
			closest = distance
			target = other_id
			wall_target = "" # Nearer bean beats a farther wall.
	if target != 0:
		players[target].hp -= GameRules.DAMAGE
		if players[target].hp <= 0:
			player.kills += 1
			players[target].hp = 100 # Immediate respawn for this sandbox.
			players[target].pos = safe_spawn(target)
	if not wall_target.is_empty():
		walls[wall_target] -= GameRules.DAMAGE
		if walls[wall_target] <= 0:
			walls.erase(wall_target)
	events.append({"owner": id, "from": origin, "to": origin + direction * closest, "hit": target})

static func ray_box(origin: Vector2, direction: Vector2, center: Vector2) -> float:
	# Slab algorithm: distance to entry into a 1m square; -1 means no hit.
	var near := 0.0
	var far := GameRules.RANGE
	for axis in range(2):
		var low: float = center[axis] - 0.5
		var high: float = center[axis] + 0.5
		if absf(direction[axis]) < 0.00001:
			if origin[axis] < low or origin[axis] > high:
				return -1.0
		else:
			var first: float = (low - origin[axis]) / direction[axis]
			var second: float = (high - origin[axis]) / direction[axis]
			near = maxf(near, minf(first, second))
			far = minf(far, maxf(first, second))
			if near > far:
				return -1.0
	return near

func safe_spawn(id: int) -> Vector2:
	for slot in range(4):
		var pos := GameRules.spawn((id + slot) % 4)
		if GameRules.free_position(pos, walls):
			return pos
	return Vector2.ZERO # All spawn zones and origin are protected from building.

func action(id: int, kind: String, payload: Variant) -> String:
	if not players.has(id):
		return "Player is not admitted."
	var player: Dictionary = players[id]
	var inventory: Dictionary = player.inventory
	match kind:
		"craft":
			if not payload is String or not GameRules.RECIPES.has(payload):
				return "Unknown recipe."
			var recipe: Dictionary = GameRules.RECIPES[payload]
			for item in recipe.cost:
				if inventory[item] < recipe.cost[item]:
					return "Not enough " + item + "."
			for item in recipe.cost:
				inventory[item] -= recipe.cost[item] # Spend only after every cost passes.
			inventory[recipe.item] += recipe.amount
			return "Crafted " + payload + "."
		"collect":
			if not payload is int or not drops.has(payload):
				return "Drop no longer exists."
			var drop: Dictionary = drops[payload]
			if player.pos.distance_to(drop.pos) > GameRules.PICKUP_DISTANCE:
				return "Move closer to the resource pile."
			inventory.wood += drop.wood
			inventory.metal += drop.metal
			drops.erase(payload) # Authority serializes simultaneous requests.
			return "Collected wood and metal."
		"build":
			if not payload is Vector2i:
				return "Invalid grid cell."
			var pos := Vector2(payload)
			var key := GameRules.cell_key(payload)
			if absf(pos.x) > 10 or absf(pos.y) > 10 or player.pos.distance_to(pos) > 3.0:
				return "Build within 3m and inside the arena."
			if walls.has(key) or walls.size() >= GameRules.MAX_WALLS or inventory.wall <= 0:
				return "Occupied cell, wall limit, or no wall kit."
			for other in players.values():
				if other.pos.distance_to(pos) < 1.2:
					return "A player is standing there."
			for slot in range(4):
				if GameRules.spawn(slot).distance_to(pos) < 1.5 or pos.length() < 1.5:
					return "Keep respawn areas clear."
			walls[key] = 100
			inventory.wall -= 1 # Spend only after placement succeeds.
			return "Wall placed."
	return "Unknown action."

func snapshot() -> Dictionary:
	# Deep-copy prevents simulation from mutating a packet or interpolation sample.
	return {"tick": tick, "players": players.duplicate(true), "walls": walls.duplicate(true), "drops": drops.duplicate(true)}
