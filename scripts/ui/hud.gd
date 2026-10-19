class_name GameHUD
extends CanvasLayer
## Lightweight UI built in one place. Replace with scenes without changing networking.

signal solo_pressed
signal host_pressed
signal join_pressed(address: String)
signal steam_host_pressed
signal steam_join_pressed(id_text: String)
signal invite_pressed

var menu: PanelContainer
var info: Label
var stats: Label
var feedback: Label
var address: LineEdit
var lobby: LineEdit

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	info = make_label(root, Vector2(24, 20), 27)
	info.text = "BEAN WORKSHOP  /  NETWORK LAB"
	stats = make_label(root, Vector2(24, 62), 19)
	feedback = make_label(root, Vector2(24, 96), 17)
	menu = PanelContainer.new()
	menu.position = Vector2(24, 145)
	menu.custom_minimum_size = Vector2(440, 0)
	root.add_child(menu)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	menu.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var heading := Label.new()
	heading.text = "Pick a route. The game rules stay the same."
	column.add_child(heading)
	button(column, "Solo sandbox", func(): solo_pressed.emit())
	button(column, "Host LAN  •  UDP 24567", func(): host_pressed.emit())
	address = LineEdit.new()
	address.text = "127.0.0.1"
	address.placeholder_text = "Host LAN IP or DNS name"
	column.add_child(address)
	button(column, "Join LAN / IP", func(): join_pressed.emit(address.text))
	button(column, "Host Steam friends lobby", func(): steam_host_pressed.emit())
	lobby = LineEdit.new()
	lobby.placeholder_text = "Paste Steam lobby ID (digits)"
	column.add_child(lobby)
	button(column, "Join Steam lobby", func(): steam_join_pressed.emit(lobby.text))
	var help := Label.new()
	help.text = "Steam requires optional native addons.\nSee docs/INTEGRATION.md for setup and limits."
	column.add_child(help)
	var controls := make_label(root, Vector2(24, 710), 17)
	controls.text = "WASD move   •   Mouse aim / LMB shoot   •   E collect\nC craft ammo   •   V craft wall kit   •   B build at cursor   •   I invite   •   Esc leave"

func make_label(parent: Control, at: Vector2, size: int) -> Label:
	var label := Label.new()
	label.position = at
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func button(parent: Control, text: String, callback: Callable) -> void:
	var item := Button.new()
	item.text = text
	item.custom_minimum_size.y = 36
	item.pressed.connect(callback)
	parent.add_child(item)

func show_status(text: String) -> void:
	feedback.text = text
	print("[session] ", text) # Also useful when running headlessly.

func show_state(state: Dictionary, id: int, bytes: int) -> void:
	if not state.players.has(id):
		return
	menu.hide()
	var player: Dictionary = state.players[id]
	var inventory: Dictionary = player.inventory
	stats.text = "HP %d   |   Ammo %d   Wood %d   Metal %d   Walls %d   |   Kills %d   |   %d players   |   Snapshot %d B" % [
		player.hp, inventory.ammo, inventory.wood, inventory.metal, inventory.wall,
		player.kills, state.players.size(), bytes]

func reset() -> void:
	menu.show()
	stats.text = "Solo + LAN available in plain Godot. Steam is optional."
