extends RefCounted

# HUD 运行时视图
# 说明：
# 1. 只承接顶栏、阶段样式和战斗日志的投影。
# 2. 这里不处理 inventory、detail 和 tooltip 具体内容。
# 运行时视图节奏：
# 1. 顶栏数值每帧可以轻量刷新，但日志文本按固定间隔批量落盘。
# 2. 阶段样式与阶段显隐拆成两个函数，避免颜色和交互混在一起。
# 3. 结果期只保留统计与日志，不再允许 detail / inventory 抢焦点。
# 日志口径：
# 1. battle log entries 先写入 state，再由 RichText 批量同步。
# 2. rebuild 与 append 分成两条路径，避免日志裁剪后滚动状态错乱。
# 3. 非交锋期追加日志时允许立即 flush，方便调试和过场观察。
# 可读性约束：
# 1. 这里优先解释刷新节奏和阶段显隐原因，而不是重复控件名称。

const STAGE_PREPARATION: int = 0 # 备战期 HUD 允许商店和仓库交互。
const STAGE_COMBAT: int = 1 # 交锋期 HUD 强调战斗信息。
const STAGE_RESULT: int = 2 # 结算期 HUD 让位给结果统计。

const BATTLE_LOG_MAX_LINES: int = 50 # 日志缓存上限。
const BATTLE_LOG_FLUSH_INTERVAL: float = 0.12 # 日志批量刷新的节奏。

var _owner = null # HUD facade。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _support = null # HUD 共享支撑。


# 绑定 runtime view 所需的 facade、引用表、状态和共享 support。
func initialize(owner, scene_root, refs, state, support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = support


# 新入口初始化时统一收拢 HUD 默认显隐和按钮状态。
# 这些默认态只在 scene 装配时写一次，避免后续阶段切换互相覆盖。
func initialize_view_defaults() -> void:
	if _refs.unit_tooltip != null:
		_refs.unit_tooltip.visible = false
	if _refs.item_tooltip != null:
		_refs.item_tooltip.visible = false
	if _refs.drag_preview != null:
		_refs.drag_preview.visible = false
	if _refs.unit_detail_panel != null:
		_refs.unit_detail_panel.visible = false
	if _refs.unit_detail_mask != null:
		_refs.unit_detail_mask.visible = false
		_refs.unit_detail_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _refs.inventory_tab_gongfa_button != null:
		_refs.inventory_tab_gongfa_button.button_pressed = _state.inventory_mode == "gongfa"
	if _refs.inventory_tab_equip_button != null:
		_refs.inventory_tab_equip_button.button_pressed = _state.inventory_mode == "equipment"
	sync_world_debug_status({})


# 刷新顶栏回合、计时和战力条，保证世界变化后 HUD 立即同步。
# 战力条按存活人数实时计算，不缓存旧值，避免战斗开始后读到准备期数据。
func refresh_top_runtime_hud() -> void:
	if _refs.round_label != null:
		_refs.round_label.text = "第 %d 回合" % maxi(_state.round_index, 1)
	var render_fps: int = int(Engine.get_frames_per_second())
	if _refs.timer_label != null:
		if int(_state.stage) == STAGE_COMBAT:
			_refs.timer_label.text = "%.1fs | %d fps" % [_state.combat_elapsed, render_fps]
		else:
			_refs.timer_label.text = "-- | %d fps" % render_fps
	if _refs.power_bar != null:
		var ally_alive: int = _support.get_alive_count(_support.TEAM_ALLY)
		var enemy_alive: int = _support.get_alive_count(_support.TEAM_ENEMY)
		var total_alive: int = maxi(ally_alive + enemy_alive, 1)
		_refs.power_bar.value = float(ally_alive) / float(total_alive) * 100.0
		_refs.power_bar.tooltip_text = "己方 %d / 敌方 %d" % [ally_alive, enemy_alive]


# 顶栏快捷按钮只根据当前阶段和战斗运行态切换可用性。
# 按钮文案和 tooltip 也在这里统一，防止不同刷新入口写出不同提示。
func refresh_top_quick_action_buttons() -> void:
	var editable_stage: bool = int(_state.stage) == STAGE_PREPARATION
	var battle_running: bool = false
	if _refs.combat_manager != null and _refs.combat_manager.has_method("is_battle_running"):
		battle_running = bool(_refs.combat_manager.call("is_battle_running"))
	if _refs.shop_open_button != null:
		_refs.shop_open_button.text = "商店(B)"
		_refs.shop_open_button.disabled = not editable_stage
		_refs.shop_open_button.button_pressed = _state.shop_visible and editable_stage
		_refs.shop_open_button.tooltip_text = "快捷键：B"
	if _refs.start_battle_button != null:
		_refs.start_battle_button.text = "开始战斗(F6)"
		_refs.start_battle_button.disabled = (not editable_stage) or battle_running
		_refs.start_battle_button.tooltip_text = "快捷键：F6"
	if _refs.reset_battle_button != null:
		_refs.reset_battle_button.text = "重置战场(F7)"
		_refs.reset_battle_button.disabled = false
		_refs.reset_battle_button.tooltip_text = "快捷键：F7"


# 根据阶段切换顶栏阶段标签的文案与主色。
# 样式函数只改视觉，不改任何 session state，便于后续单独复用。
func apply_stage_hud_style() -> void:
	if _refs.phase_label == null:
		return
	match int(_state.stage):
		STAGE_PREPARATION:
			_refs.phase_label.text = "布阵期"
			_refs.phase_label.modulate = Color(0.67, 0.84, 1.0, 1.0)
		STAGE_COMBAT:
			_refs.phase_label.text = "交锋期"
			_refs.phase_label.modulate = Color(1.0, 0.60, 0.55, 1.0)
		STAGE_RESULT:
			_refs.phase_label.text = "结算期"
			_refs.phase_label.modulate = Color(1.0, 0.86, 0.50, 1.0)


# 阶段切换时只收敛 HUD 显隐与交互性，不承接业务编排。
# 结果期强制收起 detail 和 hover，是为了让统计面板成为唯一焦点层。
func apply_stage_ui_state() -> void:
	_state.inventory_visible = int(_state.stage) != STAGE_RESULT
	_state.inventory_drag_enabled = int(_state.stage) == STAGE_PREPARATION
	if _refs.inventory_panel != null:
		_refs.inventory_panel.visible = _state.inventory_visible
		if int(_state.stage) == STAGE_PREPARATION:
			_refs.inventory_panel.modulate = Color(1, 1, 1, 1)
		else:
			_refs.inventory_panel.modulate = Color(1, 1, 1, 0.4)
	if _refs.battle_log_panel != null:
		_refs.battle_log_panel.visible = (
			int(_state.stage) == STAGE_COMBAT or int(_state.stage) == STAGE_RESULT
		)
	if int(_state.stage) == STAGE_PREPARATION:
		_owner.set_shop_panel_visible(_state.shop_open_in_preparation, false)
	else:
		_owner.set_shop_panel_visible(false, false)
	if int(_state.stage) != STAGE_RESULT:
		return
	_owner.force_close_detail_panel(false)
	_owner.clear_hovered_unit()
	if _refs.item_tooltip != null:
		_refs.item_tooltip.visible = false


# 返回阶段切换提示词，供过场文案统一使用。
# 过场文本不直接散落在 coordinator，避免后续国际化时到处查字符串。
func phase_transition_text_for_stage(stage_id: int) -> String:
	match stage_id:
		STAGE_PREPARATION:
			return "布阵开始"
		STAGE_COMBAT:
			return "交锋开始"
		STAGE_RESULT:
			return "战斗结束"
		_:
			return ""


# 用统一淡入淡出效果展示阶段过场文字。
# 动画 tween 由 facade 创建，确保和其他 HUD tween 共用同一生命周期。
func play_phase_transition(text: String) -> void:
	if text.is_empty():
		return
	if _refs.phase_transition == null or _refs.phase_transition_text == null:
		return
	_refs.phase_transition_text.text = text
	_refs.phase_transition.visible = true
	_refs.phase_transition.modulate = Color(1, 1, 1, 0)
	var tween: Tween = _owner.create_tween()
	tween.tween_property(_refs.phase_transition, "modulate:a", 1.0, 0.16)
	tween.tween_interval(0.18)
	tween.tween_property(_refs.phase_transition, "modulate:a", 0.0, 0.24)
	tween.finished.connect(func() -> void:
		if _refs.phase_transition != null:
			_refs.phase_transition.visible = false
	)


# 写入一条战斗日志，并保持日志缓存长度受控。
# 先写缓存再决定是否立刻 flush，这样任何入口都不会绕过统一裁剪逻辑。
func append_battle_log(line: String, event_type: String = "info") -> void:
	if line.strip_edges().is_empty():
		return
	_state.battle_log_entries.append(
		"[color=%s]%s[/color]" % [_support.battle_log_color_hex(event_type), line]
	)
	while _state.battle_log_entries.size() > BATTLE_LOG_MAX_LINES:
		_state.battle_log_entries.remove_at(0)
		_state.battle_log_requires_rebuild = true
	_state.battle_log_dirty = true
	if int(_state.stage) != STAGE_COMBAT:
		flush_battle_log(true)


# 以固定间隔把 battle log 缓存刷入 RichText，减少逐条 append 抖动。
# combat 中频繁事件很多，所以这里宁可批量刷新，也不每次都碰 UI 树。
func update_battle_log_view(delta: float) -> void:
	if not _state.battle_log_dirty:
		return
	_state.battle_log_flush_accum += delta
	if _state.battle_log_flush_accum < BATTLE_LOG_FLUSH_INTERVAL:
		return
	flush_battle_log(true)


# 把 battle log 缓存同步到 RichText，并在需要时滚到末尾。
# rebuild 分支专门处理裁剪或回退场景，append 分支只补新增内容。
func flush_battle_log(scroll_to_bottom: bool) -> void:
	if _refs.battle_log_text == null:
		return
	if _state.battle_log_requires_rebuild:
		_refs.battle_log_text.clear()
		if not _state.battle_log_entries.is_empty():
			_refs.battle_log_text.append_text("\n".join(_state.battle_log_entries))
		_state.battle_log_last_flushed_count = _state.battle_log_entries.size()
		_state.battle_log_requires_rebuild = false
	elif _state.battle_log_last_flushed_count > _state.battle_log_entries.size():
		_refs.battle_log_text.clear()
		if not _state.battle_log_entries.is_empty():
			_refs.battle_log_text.append_text("\n".join(_state.battle_log_entries))
		_state.battle_log_last_flushed_count = _state.battle_log_entries.size()
	else:
		for index in range(
			_state.battle_log_last_flushed_count,
			_state.battle_log_entries.size()
		):
			_refs.battle_log_text.append_text("%s\n" % _state.battle_log_entries[index])
		_state.battle_log_last_flushed_count = _state.battle_log_entries.size()
	if scroll_to_bottom and _refs.battle_log_panel != null and _refs.battle_log_panel.visible:
		_refs.battle_log_text.scroll_to_line(_refs.battle_log_text.get_line_count())
	_state.battle_log_dirty = false
	_state.battle_log_flush_accum = 0.0


# 清空日志缓存和面板内容，供切入战斗或重开场景时复位。
# 重置时连 last_flushed_count 一起归零，避免下次 flush 错过首批消息。
func clear_battle_log() -> void:
	_state.battle_log_entries.clear()
	_state.battle_log_last_flushed_count = 0
	_state.battle_log_requires_rebuild = true
	_state.battle_log_dirty = false
	_state.battle_log_flush_accum = 0.0
	if _refs.battle_log_text != null:
		_refs.battle_log_text.clear()


# 世界拖拽显隐只通过 runtime view 写 DragPreview 节点，避免 world 层继续碰 UI。
func set_drag_preview_visible(visible: bool) -> void:
	if _refs.drag_preview != null:
		_refs.drag_preview.visible = visible


# 拖拽预览位置统一由 runtime view 维护视觉偏移。
func update_drag_preview_position(screen_pos: Vector2) -> void:
	if _refs.drag_preview != null:
		_refs.drag_preview.position = screen_pos + Vector2(14.0, 14.0)


# 拖拽中的单位快照在 HUD 侧完成颜色和文案投影。
func set_drag_preview_unit(unit: Node) -> void:
	if unit == null:
		return
	if _refs.drag_preview_name != null:
		_refs.drag_preview_name.text = str(unit.get("unit_name"))
	if _refs.drag_preview_star != null:
		var star: int = int(unit.get("star_level"))
		_refs.drag_preview_star.text = "★".repeat(clampi(star, 1, 3))
		_refs.drag_preview_star.modulate = _drag_preview_star_color(star)
	if _refs.drag_preview_icon != null:
		_refs.drag_preview_icon.color = _support.quality_color(str(unit.get("quality")))


# 世界调试文案仍保留在 HUD/debug 层，但数据来源改成 world snapshot。
func sync_world_debug_status(snapshot: Dictionary) -> void:
	if _refs.debug_label == null:
		return
	if snapshot.is_empty():
		_refs.debug_label.text = ""
		return
	_refs.debug_label.text = "阶段:%s  备战:%d  己方:%d  敌方:%d" % [
		str(snapshot.get("stage_name", "PREPARATION")),
		int(snapshot.get("bench_count", 0)),
		int(snapshot.get("ally_count", 0)),
		int(snapshot.get("enemy_count", 0))
	]


# 星级颜色只服务拖拽预览，不把这组表现规则散回 world controller。
func _drag_preview_star_color(star: int) -> Color:
	match star:
		1:
			return Color(0.94, 0.94, 0.94, 1.0)
		2:
			return Color(1.0, 0.86, 0.35, 1.0)
		3:
			return Color(1.0, 0.42, 0.2, 1.0)
		_:
			return Color(1, 1, 1, 1)

