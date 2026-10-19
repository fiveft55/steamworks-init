extends SceneTree
## Exercise the shipped composition and procedural presentation, not only the model.

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.session.solo()
	scene.session.request_action("craft", "ammo")
	scene.session.request_action("build", Vector2i(-6, 1))
	# Add a simulated remote bean to exercise interpolation and node creation/removal.
	scene.session.authority.add_player(20)
	scene.session._publish()
	await physics_frame
	await process_frame
	if scene.arena.beans.size() != 2 or scene.arena.wall_meshes.size() != 1 or scene.hud.menu.visible:
		push_error("Scene failed to render players, shared wall, or hide the menu")
		quit(1)
		return
	scene.arena.show_muzzle(Vector2.ZERO, 0)
	scene.arena.show_shot({"from": Vector2.ZERO, "to": Vector2(2, 0)})
	scene.session.leave()
	await process_frame
	if not scene.hud.menu.visible or not scene.arena.beans.is_empty():
		push_error("Leaving failed to reset the shipped UI/view")
		quit(1)
		return
	print("SCENE_TEST: solo, crafting, wall mesh, beans, interpolation, effects, leave passed")
	quit(0)
