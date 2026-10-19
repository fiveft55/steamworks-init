class_name ArenaView
extends Node3D
## Presentation only. Meshes never decide hits, collision, inventory, or ownership.

var camera: Camera3D
var beans: Dictionary = {} # ID -> procedural character Node3D.
var wall_meshes: Dictionary = {}
var drop_meshes: Dictionary = {}
var cursor: MeshInstance3D
var samples: Array = [] # Full snapshots for 100ms remote interpolation.
var last_arrival := 0.0
var local_position := Vector2.ZERO
var local_aim := 0.0
var local_id := 1
var initialized_local := false
var flashes: Array = [] # Tracers expire by wall-clock time, never simulation state.

func _ready() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("111b29")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("adc9de")
	settings.ambient_light_energy = 0.65
	environment.environment = settings
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-65, -25, 0)
	sun.light_energy = 1.3
	add_child(sun)
	add_box(self, Vector3(25, 0.15, 25), Vector3(0, -0.15, 0), Color("273b4b"))
	# Thin floor lines explain the same one-metre grid used by building validation.
	for grid in range(-12, 13):
		add_box(self, Vector3(0.015, 0.01, 24), Vector3(grid, -0.06, 0), Color("355060"))
		add_box(self, Vector3(24, 0.01, 0.015), Vector3(0, -0.06, grid), Color("355060"))
	for side in [-1, 1]:
		add_box(self, Vector3(0.2, 0.5, 24.4), Vector3(side * 12.2, 0.1, 0), Color("518297"))
		add_box(self, Vector3(24.4, 0.5, 0.2), Vector3(0, 0.1, side * 12.2), Color("518297"))
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 30.0
	camera.position = Vector3(0, 25, 18)
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	cursor = add_box(self, Vector3(0.92, 0.025, 0.92), Vector3.ZERO, Color(0.25, 0.95, 0.8, 0.45))
	cursor.hide()

static func add_box(parent: Node3D, size: Vector3, at: Vector3, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = at
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	instance.material_override = material
	parent.add_child(instance)
	return instance

func make_bean(id: int) -> Node3D:
	var bean := Node3D.new()
	add_child(bean)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = GameRules.RADIUS
	capsule.height = 1.5
	body.mesh = capsule
	body.position.y = 0.75
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("51e0b5") if id == local_id else Color.from_hsv(fposmod(id * 0.19, 1.0), 0.65, 1.0)
	body.material_override = material
	bean.add_child(body)
	# Gun points along local +X, matching cos(aim),sin(aim) in simulation.
	add_box(bean, Vector3(0.8, 0.17, 0.2), Vector3(0.53, 0.85, 0), Color("253044"))
	add_box(bean, Vector3(0.18, 0.27, 0.16), Vector3(0.25, 0.69, 0), Color("be8e5e"))
	add_box(bean, Vector3(0.1, 0.08, 0.22), Vector3(0.92, 0.85, 0), Color("f9cc6a"))
	var label := Label3D.new()
	label.name = "Nameplate"
	label.position.y = 2.05
	label.font_size = 32
	label.pixel_size = 0.008
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bean.add_child(label)
	return bean

func accept_state(state: Dictionary, owner_id: int) -> void:
	local_id = owner_id
	samples.append(state)
	if samples.size() > 16:
		samples.pop_front()
	last_arrival = Time.get_ticks_msec() / 1000.0
	for id in beans.keys():
		if not state.players.has(id):
			beans[id].queue_free()
			beans.erase(id)
	for id in state.players:
		if not beans.has(id):
			beans[id] = make_bean(id)
		var player: Dictionary = state.players[id]
		beans[id].get_node("Nameplate").text = "%s  •  %d HP" % ["YOU" if id == local_id else str(id), player.hp]
		if id == local_id and not initialized_local:
			local_position = player.pos
			initialized_local = true
	_sync_props(state.walls, wall_meshes, true)
	_sync_props(state.drops, drop_meshes, false)
	cursor.show()

func _sync_props(source: Dictionary, meshes: Dictionary, is_wall: bool) -> void:
	for key in meshes.keys():
		if not source.has(key):
			meshes[key].queue_free()
			meshes.erase(key)
	for key in source:
		if meshes.has(key):
			continue
		var pos: Vector2 = GameRules.cell_position(key) if is_wall else source[key].pos
		meshes[key] = add_box(self, Vector3(1, 1.4, 1) if is_wall else Vector3(0.5, 0.5, 0.5),
			Vector3(pos.x, 0.7 if is_wall else 0.25, pos.y), Color("bc875f") if is_wall else Color("ffcb69"))

func aim_position() -> Vector2:
	var mouse := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	var point: Vector3 = origin + direction * (-origin.y / direction.y)
	return Vector2(point.x, point.z) # Project mouse onto the flat game plane.

func build_cell() -> Vector2i:
	return Vector2i(aim_position().round())

func _process(delta: float) -> void:
	if samples.is_empty():
		return
	var latest: Dictionary = samples.back()
	# Display other players two snapshots behind, so usually two known samples exist.
	var render_tick: float = minf(latest.tick, latest.tick - 6.0 + (Time.get_ticks_msec() / 1000.0 - last_arrival) * GameRules.TICK_RATE)
	var before: Dictionary = samples.front()
	var after: Dictionary = latest
	for sample in samples:
		if sample.tick <= render_tick:
			before = sample
		if sample.tick >= render_tick:
			after = sample
			break
	var weight := clampf((render_tick - float(before.tick)) / maxf(1.0, float(after.tick - before.tick)), 0.0, 1.0)
	for id in beans:
		var bean: Node3D = beans[id]
		var position_2d: Vector2
		var aim: float
		if id == local_id:
			position_2d = local_position # Owner sees prediction immediately.
			aim = local_aim
		else:
			var end: Dictionary = after.players.get(id, latest.players[id])
			var start: Dictionary = before.players.get(id, end)
			position_2d = start.pos.lerp(end.pos, weight)
			aim = lerp_angle(start.aim, end.aim, weight)
			if start.pos.distance_to(end.pos) > 2.0:
				position_2d = end.pos # Respawns snap instead of sliding across the arena.
		bean.position = Vector3(position_2d.x, 0, position_2d.y)
		bean.rotation.y = -aim # Godot's 3D Y rotation has the opposite X/Z sign.
	var cell := build_cell()
	cursor.position = Vector3(cell.x, 0.015, cell.y)
	for entry in flashes.duplicate():
		if Time.get_ticks_msec() >= entry.until:
			entry.mesh.queue_free()
			flashes.erase(entry)

func show_shot(event: Dictionary) -> void:
	var start := Vector3(event.from.x, 0.85, event.from.y)
	var finish := Vector3(event.to.x, 0.85, event.to.y)
	if start.distance_to(finish) < 0.01:
		return
	var tracer := add_box(self, Vector3(0.035, 0.035, start.distance_to(finish)), (start + finish) * 0.5, Color("ffe7a0"))
	tracer.look_at(finish)
	flashes.append({"mesh": tracer, "until": Time.get_ticks_msec() + 70})

func show_muzzle(pos: Vector2, aim: float) -> void:
	# Speculative flash only: even an empty gun may flash until ammo is confirmed.
	var tip := pos + Vector2(cos(aim), sin(aim)) * 0.98
	var flash := add_box(self, Vector3.ONE * 0.22, Vector3(tip.x, 0.85, tip.y), Color("fff1ac"))
	flashes.append({"mesh": flash, "until": Time.get_ticks_msec() + 45})

func clear() -> void:
	for group in [beans, wall_meshes, drop_meshes]:
		for mesh in group.values():
			mesh.queue_free()
		group.clear()
	for entry in flashes:
		entry.mesh.queue_free()
	flashes.clear()
	samples.clear()
	initialized_local = false
	cursor.hide()
