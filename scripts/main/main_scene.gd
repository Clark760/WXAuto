extends Node2D

const STAGE_DATA_SCRIPT: Script = preload("res://scripts/domain/stage/stage_data.gd")
const BATTLEFIELD_SCENE_PATH: String = "res://scenes/battle/battlefield_scene.tscn"
const INK_THEME_BUILDER = preload("res://scripts/ui/ink_theme_builder.gd")
const STAGE_SEQUENCE_BUTTON_SCENE: PackedScene = preload(
	"res://scenes/ui/stage_sequence_button.tscn"
)
const EMPTY_STATE_LABEL_SCENE: PackedScene = preload(
	"res://scenes/ui/empty_state_label.tscn"
)

@onready var info_label: Label = $CanvasLayer/InfoLabel
@onready var tip_label: Label = $CanvasLayer/TipLabel
@onready var stage_list_vbox: VBoxContainer = $CanvasLayer/StageListPanel/StageListRoot/StageListScroll/StageListVBox

var _stage_data: RefCounted = STAGE_DATA_SCRIPT.new()
var _selected_sequence_id: String = ""
var _services: ServiceRegistry = null

# 绑定 bind app services
func bind_app_services(services: ServiceRegistry) -> void:
	_services = services

# 处理 ready
func _ready() -> void:
	_apply_ink_theme()
	_connect_event_bus()
	_refresh_ui()

# 处理 unhandled input
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return

	var key_event: InputEventKey = event
	if not key_event.pressed or key_event.echo:
		return

	if key_event.keycode == KEY_F5:
		var scene_navigator: SceneNavigator = _get_scene_navigator()
		if scene_navigator != null:
			scene_navigator.reload_runtime_data()
		_refresh_ui()
	elif key_event.keycode == KEY_F6 or key_event.keycode == KEY_ENTER:
		_enter_selected_sequence()

# 连接 connect event bus
func _connect_event_bus() -> void:
	var event_bus: Node = _get_event_bus()
	if event_bus == null:
		return

	var on_data_reloaded: Callable = Callable(self, "_on_data_reloaded")
	var on_mod_load_completed: Callable = Callable(self, "_on_mod_load_completed")
	var on_phase_changed: Callable = Callable(self, "_on_phase_changed")

	if event_bus.has_signal("data_reloaded") and not event_bus.is_connected("data_reloaded", on_data_reloaded):
		event_bus.connect("data_reloaded", on_data_reloaded)
	if event_bus.has_signal("mod_load_completed") \
	and not event_bus.is_connected("mod_load_completed", on_mod_load_completed):
		event_bus.connect("mod_load_completed", on_mod_load_completed)
	if event_bus.has_signal("phase_changed") and not event_bus.is_connected("phase_changed", on_phase_changed):
		event_bus.connect("phase_changed", on_phase_changed)

# 响应 on data reloaded
func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	_refresh_ui()

# 响应 on mod load completed
func _on_mod_load_completed(_summary: Dictionary) -> void:
	_refresh_ui()

# 响应 on phase changed
func _on_phase_changed(_previous_phase: int, _next_phase: int) -> void:
	_refresh_ui()

# 处理 refresh ui
func _refresh_ui() -> void:
	var app_session: AppSessionState = _get_app_session()
	var data_manager: Node = _get_data_manager()

	var phase_name: String = "UNKNOWN"
	var scene_path: String = "未设置"
	if app_session != null:
		phase_name = app_session.get_phase_name()
		scene_path = app_session.current_scene_path

	var summary_text: String = "DataManager 未就绪"
	if data_manager != null:
		summary_text = str(data_manager.get_summary_text())

	var lines: Array[String] = []
	lines.append("正式战斗测试入口")
	lines.append("当前阶段: %s" % phase_name)
	lines.append("当前场景: %s" % scene_path)
	lines.append("")
	lines.append(summary_text)

	info_label.text = "\n".join(lines)
	tip_label.text = "点击章节序列按钮直接进入 | F6/Enter 进入当前选中序列 | F5 重载 JSON + Mod 数据 | 战场内悬停棋格可查看地形"
	_refresh_stage_buttons(data_manager)

# 处理 refresh stage buttons
func _refresh_stage_buttons(data_manager: Node) -> void:
	if stage_list_vbox == null:
		return
	for child in stage_list_vbox.get_children():
		child.queue_free()

	var entries: Array[Dictionary] = _collect_sequence_entries(data_manager)
	if entries.is_empty():
		var empty_label: Label = EMPTY_STATE_LABEL_SCENE.instantiate() as Label
		empty_label.text = "未检测到可用章节序列（需包含 chapters）"
		stage_list_vbox.add_child(empty_label)
		_selected_sequence_id = ""
		return

	_ensure_selected_sequence(entries)
	for entry in entries:
		var sequence_id: String = str(entry.get("id", "")).strip_edges()
		if sequence_id.is_empty():
			continue
		var btn: Button = STAGE_SEQUENCE_BUTTON_SCENE.instantiate() as Button
		btn.text = _build_sequence_button_text(entry)
		btn.tooltip_text = "点击进入序列 %s" % sequence_id
		btn.pressed.connect(Callable(self, "_on_sequence_button_pressed").bind(sequence_id))
		if sequence_id == _selected_sequence_id:
			btn.text = "▶ " + btn.text
		stage_list_vbox.add_child(btn)

# 收集 collect sequence entries
func _collect_sequence_entries(data_manager: Node) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if data_manager == null or not is_instance_valid(data_manager):
		return entries

	var all_rows: Variant = data_manager.get_all_records("stages")
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

# 构建 build sequence button text
func _build_sequence_button_text(entry: Dictionary) -> String:
	var seq_id: String = str(entry.get("id", ""))
	var chapter_count: int = int(entry.get("chapters", 0))
	var stage_count: int = int(entry.get("stages", 0))
	return "%s（章节 %d，关卡 %d）" % [seq_id, chapter_count, stage_count]

# 比较 sort sequence entry
func _sort_sequence_entry(a: Dictionary, b: Dictionary) -> bool:
	return str(a.get("id", "")) < str(b.get("id", ""))

# 处理 ensure selected sequence
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

# 响应 on sequence button pressed
func _on_sequence_button_pressed(sequence_id: String) -> void:
	_selected_sequence_id = sequence_id.strip_edges()
	_enter_battle_scene(_selected_sequence_id)

# 处理 enter selected sequence
func _enter_selected_sequence() -> void:
	if _selected_sequence_id.is_empty():
		var data_manager: Node = _get_data_manager()
		var entries: Array[Dictionary] = _collect_sequence_entries(data_manager)
		if not entries.is_empty():
			_selected_sequence_id = str(entries[0].get("id", "")).strip_edges()
	_enter_battle_scene(_selected_sequence_id)

# 处理 enter battle scene
func _enter_battle_scene(sequence_id: String = "") -> void:
	var app_session: AppSessionState = _get_app_session()
	if app_session != null:
		app_session.set_requested_stage_sequence_id(sequence_id)

	var scene_navigator: SceneNavigator = _get_scene_navigator()
	if scene_navigator != null:
		scene_navigator.change_scene_to_file(BATTLEFIELD_SCENE_PATH)


# 主菜单沿用战场的水墨主题，保证入口页与局内视觉口径一致。
func _apply_ink_theme() -> void:
	var ink_theme: Theme = INK_THEME_BUILDER.build() as Theme
	if ink_theme == null:
		return
	var canvas_layer: CanvasLayer = $CanvasLayer
	for child in canvas_layer.get_children():
		if child is Control:
			(child as Control).theme = ink_theme

# 获取 get event bus
func _get_event_bus() -> Node:
	if _services == null:
		return null
	return _services.event_bus

# 获取 get app session
func _get_app_session() -> AppSessionState:
	if _services == null:
		return null
	return _services.app_session

# 获取 get data manager
func _get_data_manager() -> Node:
	if _services == null:
		return null
	return _services.data_repository

# 获取 get scene navigator
func _get_scene_navigator() -> SceneNavigator:
	if _services == null:
		return null
	return _services.scene_navigator
