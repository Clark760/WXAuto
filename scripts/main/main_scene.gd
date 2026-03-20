extends Node2D

# ===========================
# 主场景脚本（M0 验证用）
# ===========================
# 验证目标：
# 1. 可看到 HexGrid 可视化网格。
# 2. 可看到 DataManager 当前加载统计。
# 3. 支持 F1 场景切换、F5 数据热重载。

@onready var info_label: Label = $CanvasLayer/InfoLabel
@onready var tip_label: Label = $CanvasLayer/TipLabel
@onready var enter_m4_button: Button = $CanvasLayer/EnterM4Button


func _ready() -> void:
	_connect_event_bus()
	_bind_ui_signals()
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
			event_bus.call("emit_scene_change_requested", "res://scenes/main/debug_scene.tscn")
	elif key_event.keycode == KEY_F2:
		var event_bus_m1: Node = _get_event_bus()
		if event_bus_m1 != null:
			event_bus_m1.call("emit_scene_change_requested", "res://scenes/battle/battlefield_m1.tscn")
	elif key_event.keycode == KEY_F6:
		var event_bus_m2: Node = _get_event_bus()
		if event_bus_m2 != null:
			event_bus_m2.call("emit_scene_change_requested", "res://scenes/battle/battlefield_m2.tscn")
	elif key_event.keycode == KEY_F5:
		var game_manager: Node = _get_game_manager()
		if game_manager != null:
			game_manager.call("reload_game_data")
		_refresh_ui()


func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return

	var on_data_reloaded: Callable = Callable(self, "_on_data_reloaded")
	var on_mod_load_completed: Callable = Callable(self, "_on_mod_load_completed")
	var on_phase_changed: Callable = Callable(self, "_on_phase_changed")

	if not event_bus.is_connected("data_reloaded", on_data_reloaded):
		event_bus.connect("data_reloaded", on_data_reloaded)
	if not event_bus.is_connected("mod_load_completed", on_mod_load_completed):
		event_bus.connect("mod_load_completed", on_mod_load_completed)
	if not event_bus.is_connected("phase_changed", on_phase_changed):
		event_bus.connect("phase_changed", on_phase_changed)


func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	_refresh_ui()


func _on_mod_load_completed(_summary: Dictionary) -> void:
	_refresh_ui()


func _on_phase_changed(_previous_phase: int, _next_phase: int) -> void:
	_refresh_ui()


func _refresh_ui() -> void:
	var game_manager: Node = _get_game_manager()
	var data_manager: Node = _get_data_manager()

	var phase_name: String = "UNKNOWN"
	var scene_path: String = "未设置"
	if game_manager != null:
		phase_name = str(game_manager.call("get_phase_name", int(game_manager.get("current_phase"))))
		scene_path = str(game_manager.get("current_scene_path"))

	var summary_text: String = "DataManager 未就绪"
	if data_manager != null:
		summary_text = str(data_manager.call("get_summary_text"))

	var lines: Array[String] = []
	lines.append("M0 基础框架验证场景")
	lines.append("当前阶段: %s" % phase_name)
	lines.append("当前场景: %s" % scene_path)
	lines.append("")
	lines.append(summary_text)

	info_label.text = "\n".join(lines)
	tip_label.text = "快捷键：F1 调试场景 | F2 M1场景 | F6 M2战斗场景 | F5 重载 JSON + Mod 数据（也可点击下方按钮进入 M4）"


func _bind_ui_signals() -> void:
	if enter_m4_button == null:
		return
	var cb: Callable = Callable(self, "_on_enter_m4_button_pressed")
	if not enter_m4_button.is_connected("pressed", cb):
		enter_m4_button.connect("pressed", cb)


func _on_enter_m4_button_pressed() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_scene_change_requested", "res://scenes/battle/battlefield_m4.tscn")


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


func _get_data_manager() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("DataManager")
