extends PanelContainer

# ===========================
# 战斗统计面板
# ===========================
# 设计目标：
# 1. 只负责“统计面板 UI”的创建、布局、切页与文本刷新。
# 2. 不直接监听战斗事件，避免 UI 与战斗结算逻辑耦合。
# 3. 统计数据统一由外部模块注入，当前面板只做展示层。

signal panel_closed

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2
const PANEL_WIDTH: float = 860.0
const PANEL_HEIGHT: float = 520.0

var _statistics: Node = null
var _current_team_tab: int = TEAM_ALLY

var _mvp_label: Label = null
var _damage_rank: RichTextLabel = null
var _tank_rank: RichTextLabel = null
var _heal_rank: RichTextLabel = null
var _tab_ally_button: Button = null
var _tab_enemy_button: Button = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()


func bind_statistics(statistics: Node) -> void:
	_statistics = statistics
	refresh_content()


func relayout(viewport_size: Vector2) -> void:
	var width: float = minf(PANEL_WIDTH, viewport_size.x - 40.0)
	var height: float = minf(PANEL_HEIGHT, viewport_size.y - 70.0)
	position = Vector2((viewport_size.x - width) * 0.5, (viewport_size.y - height) * 0.5)
	size = Vector2(width, height)


func show_panel(default_team: int = TEAM_ALLY) -> void:
	_set_team_tab(default_team)
	refresh_content()
	visible = true


func hide_panel() -> void:
	visible = false


func refresh_content() -> void:
	if _statistics == null or not is_instance_valid(_statistics):
		return
	if _mvp_label == null:
		return

	var team_name: String = "己方" if _current_team_tab == TEAM_ALLY else "敌方"
	var mvp: Dictionary = _statistics.call("get_mvp", _current_team_tab)
	if mvp.is_empty():
		_mvp_label.text = "🏆 %s MVP：无" % team_name
	else:
		_mvp_label.text = "🏆 %s MVP：%s（伤害 %d，击杀 %d）" % [
			team_name,
			str(mvp.get("unit_name", "未知")),
			int(mvp.get("damage_dealt", 0)),
			int(mvp.get("kills", 0))
		]

	if _damage_rank != null:
		_damage_rank.text = _format_rank_text(
			_statistics.call("get_ranked_stats", "damage_dealt", 8, 0, _current_team_tab),
			"damage_dealt"
		)
	if _tank_rank != null:
		_tank_rank.text = _format_rank_text(
			_statistics.call("get_ranked_stats", "damage_taken", 8, 0, _current_team_tab),
			"damage_taken"
		)
	if _heal_rank != null:
		_heal_rank.text = _format_rank_text(
			_statistics.call("get_ranked_stats", "healing_done", 8, 0, _current_team_tab),
			"healing_done"
		)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := Label.new()
	title.text = "战斗统计"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	root.add_child(title)

	_mvp_label = Label.new()
	_mvp_label.text = "🏆 MVP：无"
	_mvp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mvp_label.add_theme_font_size_override("font_size", 20)
	root.add_child(_mvp_label)

	var tab_row := HBoxContainer.new()
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	tab_row.add_theme_constant_override("separation", 8)
	root.add_child(tab_row)

	_tab_ally_button = Button.new()
	_tab_ally_button.text = "己方统计"
	_tab_ally_button.toggle_mode = true
	_tab_ally_button.button_pressed = true
	_tab_ally_button.pressed.connect(Callable(self, "_on_tab_pressed").bind(TEAM_ALLY))
	tab_row.add_child(_tab_ally_button)

	_tab_enemy_button = Button.new()
	_tab_enemy_button.text = "敌方统计"
	_tab_enemy_button.toggle_mode = true
	_tab_enemy_button.button_pressed = false
	_tab_enemy_button.pressed.connect(Callable(self, "_on_tab_pressed").bind(TEAM_ENEMY))
	tab_row.add_child(_tab_enemy_button)

	var rank_row := HBoxContainer.new()
	rank_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rank_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rank_row.add_theme_constant_override("separation", 10)
	root.add_child(rank_row)

	_damage_rank = _create_rank_panel(rank_row, "伤害排行")
	_tank_rank = _create_rank_panel(rank_row, "承伤排行")
	_heal_rank = _create_rank_panel(rank_row, "治疗排行")

	var close_row := HBoxContainer.new()
	close_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(close_row)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(spacer)

	var close_button := Button.new()
	close_button.text = "继续"
	close_button.pressed.connect(Callable(self, "_on_close_pressed"))
	close_row.add_child(close_button)


func _create_rank_panel(parent: Control, title_text: String) -> RichTextLabel:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(panel)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(box)

	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = false
	text.scroll_active = true
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(text)
	return text


func _on_tab_pressed(team_id: int) -> void:
	_set_team_tab(team_id)
	refresh_content()


func _set_team_tab(team_id: int) -> void:
	_current_team_tab = TEAM_ALLY if team_id == TEAM_ALLY else TEAM_ENEMY
	if _tab_ally_button != null:
		_tab_ally_button.button_pressed = _current_team_tab == TEAM_ALLY
	if _tab_enemy_button != null:
		_tab_enemy_button.button_pressed = _current_team_tab == TEAM_ENEMY


func _format_rank_text(rows: Array, stat_key: String) -> String:
	if rows.is_empty():
		return "[color=#A8A8A8]暂无数据[/color]"
	var lines: Array[String] = []
	for i in range(rows.size()):
		var row: Dictionary = rows[i]
		lines.append("%d. %s  %d" % [
			i + 1,
			str(row.get("unit_name", "未知")),
			int(row.get(stat_key, row.get("value", 0)))
		])
	return "\n".join(lines)


func _on_close_pressed() -> void:
	hide_panel()
	panel_closed.emit()
