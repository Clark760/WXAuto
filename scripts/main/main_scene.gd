extends Node2D

# ===========================
# 主测试场景
# ===========================
# 作用：
# 1. 展示当前数据加载摘要与游戏阶段。
# 2. 提供进入正式战斗场景的单一入口。
# 3. 提供数据热重载入口，便于反复测试完整战斗回路。

@onready var info_label: Label = $CanvasLayer/InfoLabel
@onready var tip_label: Label = $CanvasLayer/TipLabel
@onready var enter_battle_button: Button = $CanvasLayer/EnterBattleButton


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

	if key_event.keycode == KEY_F5:
		var game_manager: Node = _get_game_manager()
		if game_manager != null:
			game_manager.call("reload_game_data")
		_refresh_ui()
	elif key_event.keycode == KEY_F6 or key_event.keycode == KEY_ENTER:
		_enter_battle_scene()


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
	lines.append("正式战斗测试入口")
	lines.append("当前阶段: %s" % phase_name)
	lines.append("当前场景: %s" % scene_path)
	lines.append("")
	lines.append(summary_text)

	info_label.text = "\n".join(lines)
	tip_label.text = "快捷键：F6/Enter 进入战斗 | F5 重载 JSON + Mod 数据"


func _bind_ui_signals() -> void:
	if enter_battle_button == null:
		return
	var cb: Callable = Callable(self, "_on_enter_battle_button_pressed")
	if not enter_battle_button.is_connected("pressed", cb):
		enter_battle_button.connect("pressed", cb)


func _on_enter_battle_button_pressed() -> void:
	_enter_battle_scene()


func _enter_battle_scene() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus != null:
		event_bus.call("emit_scene_change_requested", "res://scenes/battle/battlefield.tscn")


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
