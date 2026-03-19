extends Control

# ===========================
# 调试场景脚本（M0 验证用）
# ===========================
# 作用：
# 1. 验证场景切换机制（与 main.tscn 双向切换）。
# 2. 展示当前 Mod 加载信息，确认 load_order 流程可用。

@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var tip_label: Label = $MarginContainer/VBoxContainer/TipLabel


func _ready() -> void:
	_refresh_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_F1:
		var event_bus: Node = _get_event_bus()
		if event_bus != null:
			event_bus.call("emit_scene_change_requested", "res://scenes/main/main.tscn")
	elif key_event.keycode == KEY_F2:
		var event_bus_m1: Node = _get_event_bus()
		if event_bus_m1 != null:
			event_bus_m1.call("emit_scene_change_requested", "res://scenes/battle/battlefield_m1.tscn")
	elif key_event.keycode == KEY_F5:
		var game_manager: Node = _get_game_manager()
		if game_manager != null:
			game_manager.call("reload_game_data")
		_refresh_ui()


func _refresh_ui() -> void:
	var loaded_mods: Array[Dictionary] = []
	var mod_loader: Node = _get_mod_loader()
	if mod_loader != null:
		var mod_value: Variant = mod_loader.call("get_loaded_mods")
		if mod_value is Array:
			for item in mod_value:
				if item is Dictionary:
					loaded_mods.append(item)

	var mod_lines: Array[String] = []
	if loaded_mods.is_empty():
		mod_lines.append("已加载 Mod: 0")
	else:
		mod_lines.append("已加载 Mod: %d" % loaded_mods.size())
		for mod_info in loaded_mods:
			mod_lines.append("- [%d] %s (%s)" % [
				int(mod_info.get("load_order", 0)),
				str(mod_info.get("name", "unknown")),
				str(mod_info.get("id", "unknown"))
			])

	status_label.text = "\n".join(mod_lines)
	tip_label.text = "调试场景：F1 主场景 | F2 M1战场 | F5 重载数据"


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("EventBus")


func _get_game_manager() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("GameManager")


func _get_mod_loader() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("ModLoader")
