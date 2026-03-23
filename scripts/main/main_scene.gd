extends Node2D

# ===========================
# 主测试场景
# ===========================
# 作用：
# 1. 展示当前数据加载摘要与游戏阶段。
# 2. 提供章节序列列表入口，可直接选择并进入对应序列首关。
# 3. 提供数据热重载入口，便于反复测试完整战斗回路。

const STAGE_DATA_SCRIPT: Script = preload("res://scripts/stage/stage_data.gd")

@onready var info_label: Label = $CanvasLayer/InfoLabel
@onready var tip_label: Label = $CanvasLayer/TipLabel
@onready var stage_list_vbox: VBoxContainer = $CanvasLayer/StageListPanel/StageListRoot/StageListScroll/StageListVBox

var _stage_data: StageData = STAGE_DATA_SCRIPT.new() as StageData
var _selected_sequence_id: String = ""


func _ready() -> void:
	_connect_event_bus()
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
		_enter_selected_sequence()


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
	tip_label.text = "点击章节序列按钮直接进入 | F6/Enter 进入当前选中序列 | F5 重载 JSON + Mod 数据"
	_refresh_stage_buttons(data_manager)


func _refresh_stage_buttons(data_manager: Node) -> void:
	if stage_list_vbox == null:
		return
	for child in stage_list_vbox.get_children():
		child.queue_free()

	var entries: Array[Dictionary] = _collect_sequence_entries(data_manager)
	if entries.is_empty():
		var empty_label := Label.new()
		empty_label.text = "未检测到可用章节序列（需包含 chapters）"
		stage_list_vbox.add_child(empty_label)
		_selected_sequence_id = ""
		return

	_ensure_selected_sequence(entries)
	for entry in entries:
		var sequence_id: String = str(entry.get("id", "")).strip_edges()
		if sequence_id.is_empty():
			continue
		var btn := Button.new()
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 38)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.text = _build_sequence_button_text(entry)
		btn.tooltip_text = "点击进入序列 %s" % sequence_id
		btn.pressed.connect(Callable(self, "_on_sequence_button_pressed").bind(sequence_id))
		if sequence_id == _selected_sequence_id:
			btn.text = "▶ " + btn.text
		stage_list_vbox.add_child(btn)


func _collect_sequence_entries(data_manager: Node) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if data_manager == null or not is_instance_valid(data_manager) or not data_manager.has_method("get_all_records"):
		return entries

	var all_rows: Variant = data_manager.call("get_all_records", "stages")
	if not (all_rows is Array):
		return entries
	for row_value in all_rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		if not row.has("chapters"):
			continue
		var seq_cfg: Dictionary = _stage_data.normalize_stage_sequence_record(row)
		var seq_id: String = str(seq_cfg.get("id", "")).strip_edges()
		if seq_id.is_empty():
			continue
		var stage_ids: Array[String] = _stage_data.flatten_sequence_stage_ids(seq_cfg)
		if stage_ids.is_empty():
			continue
		var chapter_count: int = 0
		var chapters_value: Variant = seq_cfg.get("chapters", [])
		if chapters_value is Array:
			chapter_count = (chapters_value as Array).size()
		entries.append({
			"id": seq_id,
			"name": seq_id,
			"chapters": chapter_count,
			"stages": stage_ids.size()
		})
	entries.sort_custom(Callable(self, "_sort_sequence_entry"))
	return entries


func _build_sequence_button_text(entry: Dictionary) -> String:
	var seq_id: String = str(entry.get("id", ""))
	var chapter_count: int = int(entry.get("chapters", 0))
	var stage_count: int = int(entry.get("stages", 0))
	return "%s（章节%d，关卡%d）" % [seq_id, chapter_count, stage_count]


func _sort_sequence_entry(a: Dictionary, b: Dictionary) -> bool:
	return str(a.get("id", "")) < str(b.get("id", ""))


func _ensure_selected_sequence(entries: Array[Dictionary]) -> void:
	if entries.is_empty():
		_selected_sequence_id = ""
		return
	if _selected_sequence_id.is_empty():
		_selected_sequence_id = str(entries[0].get("id", "")).strip_edges()
		return
	for entry in entries:
		if str(entry.get("id", "")).strip_edges() == _selected_sequence_id:
			return
	_selected_sequence_id = str(entries[0].get("id", "")).strip_edges()


func _on_sequence_button_pressed(sequence_id: String) -> void:
	_selected_sequence_id = sequence_id.strip_edges()
	_enter_battle_scene(_selected_sequence_id)


func _enter_selected_sequence() -> void:
	if _selected_sequence_id.is_empty():
		var data_manager: Node = _get_data_manager()
		var entries: Array[Dictionary] = _collect_sequence_entries(data_manager)
		if not entries.is_empty():
			_selected_sequence_id = str(entries[0].get("id", "")).strip_edges()
	_enter_battle_scene(_selected_sequence_id)


func _enter_battle_scene(sequence_id: String = "") -> void:
	var game_manager: Node = _get_game_manager()
	if game_manager != null and is_instance_valid(game_manager):
		if game_manager.has_method("set_requested_stage_sequence_id"):
			game_manager.call("set_requested_stage_sequence_id", sequence_id)
		elif game_manager.has_method("set_requested_stage_id"):
			game_manager.call("set_requested_stage_id", sequence_id)
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
