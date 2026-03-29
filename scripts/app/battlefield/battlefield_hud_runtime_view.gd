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
const TOP_HUD_REFRESH_INTERVAL_PREP: float = 0.20 # 非战斗期顶栏 5Hz 足够可读。
const TOP_HUD_REFRESH_INTERVAL_COMBAT: float = 0.16 # 普通战斗期顶栏刷新节流。
const TOP_HUD_REFRESH_INTERVAL_DENSE_COMBAT: float = 0.32 # 高密度战斗期进一步减少 UI 改写。
const DENSE_COMBAT_UNIT_THRESHOLD: int = 120 # 超过阈值后按高密度战斗节流顶栏。

var _owner = null # HUD facade。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _support = null # HUD 共享支撑。
var _top_hud_refresh_accum: float = 0.0 # 顶栏节流累计时间。


# 绑定 runtime view 所需的 facade、引用表、状态和共享 support。
func initialize(owner, scene_root, refs, state, support) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_support = support
	_top_hud_refresh_accum = 0.0

# 清理 runtime view 的场景引用，等待下次重新装配。
func shutdown() -> void:
	_owner = null
	_scene_root = null
	_refs = null
	_state = null
	_support = null
	_top_hud_refresh_accum = 0.0


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
# 这里显式做节流和“值未变化不写 UI”，避免高密度战斗里每帧触发 Control 树重排。
func refresh_top_runtime_hud(delta: float = 0.0, force: bool = false) -> void:
	if _state == null or _refs == null or _support == null:
		return
	if not force:
		_top_hud_refresh_accum += maxf(delta, 0.0)
		if _top_hud_refresh_accum < _resolve_top_hud_refresh_interval():
			return
	_top_hud_refresh_accum = 0.0

	var round_text: String = "第 %d 回合" % maxi(_state.round_index, 1)
	_set_label_text_if_changed(_refs.round_label, round_text)

	var render_fps: int = int(Engine.get_frames_per_second())
	var timer_text: String = "-- | %d fps" % render_fps
	if int(_state.stage) == STAGE_COMBAT:
		timer_text = "%.1fs | %d fps" % [_state.combat_elapsed, render_fps]
	_set_label_text_if_changed(_refs.timer_label, timer_text)

	if _refs.power_bar == null:
		return
	var ally_alive: int = _support.get_alive_count(_support.TEAM_ALLY)
	var enemy_alive: int = _support.get_alive_count(_support.TEAM_ENEMY)
	var total_alive: int = maxi(ally_alive + enemy_alive, 1)
	var power_value: float = float(ally_alive) / float(total_alive) * 100.0
	var power_tooltip: String = "己方 %d / 敌方 %d" % [ally_alive, enemy_alive]
	_set_progress_value_if_changed(_refs.power_bar, power_value)
	_set_control_tooltip_if_changed(_refs.power_bar, power_tooltip)


# 顶栏快捷按钮只根据当前阶段和战斗运行态切换可用性。
# 按钮文案和 tooltip 也在这里统一，防止不同刷新入口写出不同提示。
func refresh_top_quick_action_buttons() -> void:
	var editable_stage: bool = int(_state.stage) == STAGE_PREPARATION
	var battle_running: bool = false
	var combat_manager = _get_combat_manager()
	if combat_manager != null:
		battle_running = bool(combat_manager.is_battle_running())
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
	if _refs.drag_preview_icon != null:
		_refs.drag_preview_icon.color = _support.quality_color(str(unit.get("quality")))


# 世界调试文案仍保留在 HUD/debug 层，但数据来源改成 world snapshot。
func sync_world_debug_status(snapshot: Dictionary) -> void:
	if _refs.debug_label == null:
		return
	if snapshot.is_empty():
		_set_label_text_if_changed(_refs.debug_label, "")
		return
	_set_label_text_if_changed(_refs.debug_label, "阶段:%s  备战:%d  己方:%d  敌方:%d" % [
		str(snapshot.get("stage_name", "PREPARATION")),
		int(snapshot.get("bench_count", 0)),
		int(snapshot.get("ally_count", 0)),
		int(snapshot.get("enemy_count", 0))
	])


# 统一读取 CombatManager，避免顶栏按钮重复写 refs 判空。
func _get_combat_manager():
	if _refs == null:
		return null
	return _refs.combat_manager


# 顶栏节流跟随战斗密度变化，高密度时优先把预算留给战斗本身。
func _resolve_top_hud_refresh_interval() -> float:
	var stage_id: int = int(_state.stage) if _state != null else STAGE_PREPARATION
	if stage_id != STAGE_COMBAT:
		return TOP_HUD_REFRESH_INTERVAL_PREP
	var total_units: int = 0
	if _state != null:
		total_units = _state.ally_deployed.size() + _state.enemy_deployed.size()
	if total_units >= DENSE_COMBAT_UNIT_THRESHOLD:
		return TOP_HUD_REFRESH_INTERVAL_DENSE_COMBAT
	return TOP_HUD_REFRESH_INTERVAL_COMBAT


# 只有文案真的变化时才写 Label，避免无意义触发 UI 脏标记。
func _set_label_text_if_changed(label: Label, value: String) -> void:
	if label == null or label.text == value:
		return
	label.text = value


# 进度条变化很小时不重复写回，减少 Control 树内部同步成本。
func _set_progress_value_if_changed(bar: ProgressBar, value: float) -> void:
	if bar == null:
		return
	if absf(bar.value - value) <= 0.01:
		return
	bar.value = value


# tooltip 同样走“值变化才写回”的口径，避免每次刷新都碰 UI 属性。
func _set_control_tooltip_if_changed(control: Control, value: String) -> void:
	if control == null or control.tooltip_text == value:
		return
	control.tooltip_text = value
