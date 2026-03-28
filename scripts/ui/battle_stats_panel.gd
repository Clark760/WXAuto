extends PanelContainer

# 战斗统计面板
# 说明：
# 1. 负责面板展示、页签切换和统计文本刷新。
# 2. 不直接监听战斗事件，统计数据由外部注入。
signal panel_closed

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2
const PANEL_WIDTH: float = 860.0
const PANEL_HEIGHT: float = 520.0

var _statistics = null
var _current_team_tab: int = TEAM_ALLY
var _view_model: Dictionary = {}
var _actions: Dictionary = {}

var _mvp_label: Label = null
var _damage_rank: RichTextLabel = null
var _tank_rank: RichTextLabel = null
var _heal_rank: RichTextLabel = null
var _tab_ally_button: Button = null
var _tab_enemy_button: Button = null
var _close_button: Button = null


# 节点就绪后绑定子节点并连接按钮事件。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_bind_nodes()
	_bind_internal_signals()
	_apply_view_model()


# scene-first 统一入口：写入统计面板 view_model。
func setup(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	else:
		_view_model = {}
	refresh(_view_model)


# scene-first 统一入口：刷新面板标题类文案。
func refresh(view_model: Variant) -> void:
	if view_model is Dictionary:
		_view_model = (view_model as Dictionary).duplicate(true)
	_apply_view_model()


# scene-first 统一入口：预留动作绑定参数。
func bind(actions: Variant) -> void:
	if actions is Dictionary:
		_actions = (actions as Dictionary).duplicate(true)
	else:
		_actions = {}


# 绑定统计数据来源并立即刷新内容。
func bind_statistics(statistics: Node) -> void:
	_statistics = statistics
	refresh_content()


# 依据视口尺寸重排面板位置与大小。
func relayout(viewport_size: Vector2) -> void:
	var width: float = minf(PANEL_WIDTH, viewport_size.x - 40.0)
	var height: float = minf(PANEL_HEIGHT, viewport_size.y - 70.0)
	position = Vector2((viewport_size.x - width) * 0.5, (viewport_size.y - height) * 0.5)
	size = Vector2(width, height)


# 显示统计面板并切到指定阵营页签。
func show_panel(default_team: int = TEAM_ALLY) -> void:
	_set_team_tab(default_team)
	refresh_content()
	visible = true


# 隐藏统计面板。
func hide_panel() -> void:
	visible = false


# 刷新 MVP 与三列排行文本。
func refresh_content() -> void:
	if _statistics == null or not is_instance_valid(_statistics):
		return
	if _mvp_label == null:
		return
	var team_name: String = "己方" if _current_team_tab == TEAM_ALLY else "敌方"
	var mvp: Dictionary = _statistics.get_mvp(_current_team_tab)
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
			_statistics.get_ranked_stats("damage_dealt", 8, 0, _current_team_tab),
			"damage_dealt"
		)
	if _tank_rank != null:
		_tank_rank.text = _format_rank_text(
			_statistics.get_ranked_stats("damage_taken_total", 8, 0, _current_team_tab),
			"damage_taken_total"
		)
	if _heal_rank != null:
		_heal_rank.text = _format_rank_text(
			_statistics.get_ranked_stats("healing_done", 8, 0, _current_team_tab),
			"healing_done"
		)


# 绑定场景内核心子节点。
func _bind_nodes() -> void:
	_mvp_label = get_node_or_null("RootVBox/MvpLabel") as Label
	_tab_ally_button = get_node_or_null("RootVBox/TabRow/AllyTabButton") as Button
	_tab_enemy_button = get_node_or_null("RootVBox/TabRow/EnemyTabButton") as Button
	_damage_rank = get_node_or_null("RootVBox/RankRow/DamagePanel/PanelVBox/RankText") as RichTextLabel
	_tank_rank = get_node_or_null("RootVBox/RankRow/TankPanel/PanelVBox/RankText") as RichTextLabel
	_heal_rank = get_node_or_null("RootVBox/RankRow/HealPanel/PanelVBox/RankText") as RichTextLabel
	_close_button = get_node_or_null("RootVBox/CloseRow/CloseButton") as Button


# 只连接一次内部按钮信号。
func _bind_internal_signals() -> void:
	var ally_tab_cb: Callable = Callable(self, "_on_tab_pressed").bind(TEAM_ALLY)
	if _tab_ally_button != null and not _tab_ally_button.is_connected("pressed", ally_tab_cb):
		_tab_ally_button.connect("pressed", ally_tab_cb)
	var enemy_tab_cb: Callable = Callable(self, "_on_tab_pressed").bind(TEAM_ENEMY)
	if _tab_enemy_button != null and not _tab_enemy_button.is_connected("pressed", enemy_tab_cb):
		_tab_enemy_button.connect("pressed", enemy_tab_cb)
	var close_cb: Callable = Callable(self, "_on_close_pressed")
	if _close_button != null and not _close_button.is_connected("pressed", close_cb):
		_close_button.connect("pressed", close_cb)


# 将 view_model 的标题文案投影到场景节点。
func _apply_view_model() -> void:
	if _view_model.is_empty():
		return
	var title_label: Label = get_node_or_null("RootVBox/TitleLabel") as Label
	if title_label != null:
		var title_text: String = str(_view_model.get("title", "")).strip_edges()
		if not title_text.is_empty():
			title_label.text = title_text
	if _close_button != null:
		var close_text: String = str(_view_model.get("close_text", "")).strip_edges()
		if not close_text.is_empty():
			_close_button.text = close_text


# 处理统计页签点击。
func _on_tab_pressed(team_id: int) -> void:
	_set_team_tab(team_id)
	refresh_content()


# 应用当前页签状态到两个 tab 按钮。
func _set_team_tab(team_id: int) -> void:
	_current_team_tab = TEAM_ALLY if team_id == TEAM_ALLY else TEAM_ENEMY
	if _tab_ally_button != null:
		_tab_ally_button.button_pressed = _current_team_tab == TEAM_ALLY
	if _tab_enemy_button != null:
		_tab_enemy_button.button_pressed = _current_team_tab == TEAM_ENEMY


# 把排行列表格式化为 RichText 文本。
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


# 关闭统计面板并通知外层。
func _on_close_pressed() -> void:
	hide_panel()
	panel_closed.emit()
