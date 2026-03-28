extends RefCounted
# 本文件专门负责详情面板、单位悬停提示、物品悬停提示的展示投影与交互桥接。
# 详情状态、悬停状态、拖拽状态都由本协作者集中维护，避免状态散落到别的视图脚本。
# 物品提示必须严格经过来源区域、桥接区域、提示面板三段悬停判定，不能跳步。
# 详情刷新要按阶段节流处理，结算阶段必须禁止重新打开详情面板，避免遮挡结果面板。
# 任何经济结算、存档写入、战斗结果推进都不允许落进本文件，只能由外部协调器处理。
# 详情拖拽只允许改变面板位置，不允许顺手触发仓库刷新、装备刷新、属性重算之类副作用。
# 槽位子场景统一优先从引用表场景库解析，本地资源回退只在资源真正缺失时才允许生效。
# 悬停判定完全依赖全局矩形与全局坐标，调整节点层级、锚点或父节点后都必须复测坐标系。
# 详情目标一旦失效就必须立刻关闭面板并清空状态，避免旧节点引用继续停留在会话状态表。

const STAGE_PREPARATION: int = 0 # 备战期允许详情拖拽和装备调整。
const STAGE_COMBAT: int = 1 # 交锋期详情只读。
const STAGE_RESULT: int = 2 # 结算期优先让位给结果统计。

const DETAIL_REFRESH_INTERVAL_PREP: float = 0.20 # 备战期详情刷新节奏。
const DETAIL_REFRESH_INTERVAL_COMBAT: float = 0.05 # 战斗期详情刷新节奏。
const DETAIL_ROW_SUPPORT_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_hud_detail_row_support.gd"
)

var _owner = null # HUD facade，用于 tween 和对外回调。
var _scene_root = null # 根场景入口。
var _refs = null # 场景引用表。
var _state = null # 会话状态表。
var _support = null # 共享 tooltip/格式化支撑。
var _shop_inventory_view = null # 仓库协作者，用于槽位交互回接。
var _row_support = null # 详情行节点与 tooltip 行缓存支撑。


# 绑定 detail 协作者依赖。
func initialize(owner, scene_root, refs, state, support) -> void:
	# 这里统一写入根上下文，避免遗漏单项引用。
	_owner = owner; _scene_root = scene_root; _refs = refs; _state = state
	_support = support # 记录共享支撑。
	_row_support = DETAIL_ROW_SUPPORT_SCRIPT.new()
	_row_support.initialize(_refs, _state, _support, self)


# 释放 detail 协作者持有的运行时引用和行缓存。
func shutdown() -> void:
	if _row_support != null:
		_row_support.shutdown()
	_owner = null
	_scene_root = null
	_refs = null
	_state = null
	_support = null
	_shop_inventory_view = null
	_row_support = null


# 绑定 shop/inventory 协作者。
func bind_shop_inventory_view(shop_inventory_view) -> void:
	_shop_inventory_view = shop_inventory_view
	if _row_support != null:
		_row_support.bind_shop_inventory_view(shop_inventory_view)


# 强制关闭详情与物品 tooltip。
func force_close_detail_panel(animate: bool) -> void:
	if _refs.unit_detail_panel == null:
		return
	if not _refs.unit_detail_panel.visible:
		_state.detail_visible = false
		_state.detail_unit = null
		if _refs.item_tooltip != null:
			_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	if animate:
		var tween: Tween = _owner.create_tween()
		tween.tween_property(_refs.unit_detail_panel, "modulate:a", 0.0, 0.08)
		tween.finished.connect(func() -> void:
			_refs.unit_detail_panel.visible = false
			_refs.unit_detail_panel.modulate = Color(1, 1, 1, 1)
		)
	else:
		_refs.unit_detail_panel.visible = false
	if _refs.unit_detail_mask != null:
		_refs.unit_detail_mask.visible = false
	if _refs.item_tooltip != null:
		_refs.item_tooltip.visible = false
	_state.detail_visible = false
	_state.detail_unit = null
	_state.is_dragging_detail_panel = false
	_support.clear_item_hover_state()


# 处理备战席单位点击。
func handle_bench_unit_click(_slot_index: int, unit: Node) -> void:
	toggle_or_open_detail(unit)


# 处理世界单位点击。
func handle_world_unit_click(unit: Node, _screen_pos: Vector2) -> void:
	toggle_or_open_detail(unit)


# 更新世界 hover 单位并驱动 tooltip。
func update_hovered_unit(unit: Node, screen_pos: Vector2) -> void:
	if not _support.is_valid_unit(unit):
		clear_hovered_unit()
		return
	if _refs.unit_detail_panel != null and _refs.unit_detail_panel.visible:
		clear_hovered_unit()
		return
	_state.tooltip_visible = true
	_state.hover_candidate_unit = unit
	show_tooltip_for_unit(unit, screen_pos)


# 清理单位 hover tooltip。
func clear_hovered_unit() -> void:
	_state.tooltip_visible = false
	if _refs.unit_tooltip != null:
		_refs.unit_tooltip.visible = false


# 同单位切换开合，不同单位直接切换详情。
func toggle_or_open_detail(unit: Node) -> void:
	if not _support.is_valid_unit(unit):
		return
	if _state.detail_visible and _state.detail_unit == unit:
		force_close_detail_panel(false)
		return
	open_detail_panel(unit)


# 打开详情面板并刷新目标单位。
func open_detail_panel(unit: Node) -> void:
	if int(_state.stage) == STAGE_RESULT:
		return
	if not _support.is_valid_unit(unit):
		return
	_state.detail_unit = unit
	_state.detail_visible = true
	_state.detail_refresh_accum = 0.0
	update_detail_panel(unit)
	if _refs.unit_detail_panel != null:
		_refs.unit_detail_panel.visible = true
	if _refs.unit_detail_mask != null:
		_refs.unit_detail_mask.visible = true


# 按阶段节流刷新已打开详情。
func refresh_open_detail_panel(delta: float) -> void:
	if not _state.detail_visible:
		_state.detail_refresh_accum = 0.0
		return
	if _refs.unit_detail_panel == null or not _refs.unit_detail_panel.visible:
		_state.detail_refresh_accum = 0.0
		return
	if not _support.is_valid_unit(_state.detail_unit):
		force_close_detail_panel(false)
		return
	_state.detail_refresh_accum += delta
	var refresh_interval: float = DETAIL_REFRESH_INTERVAL_PREP
	if int(_state.stage) == STAGE_COMBAT:
		refresh_interval = DETAIL_REFRESH_INTERVAL_COMBAT
	if _state.detail_refresh_accum < refresh_interval:
		return
	_state.detail_refresh_accum = 0.0
	update_detail_panel(_state.detail_unit)


# 详情目标失效时关闭面板。
func clear_detail_if_invalid() -> void:
	if _state.detail_visible and not _support.is_valid_unit(_state.detail_unit):
		force_close_detail_panel(false)


# 重建详情头部、属性与槽位投影。
func update_detail_panel(unit: Node) -> void:
	if not _support.is_valid_unit(unit):
		return
	var unit_name: String = str(unit.get("unit_name"))
	var star: int = clampi(int(unit.get("star_level")), 1, 3)
	var quality: String = str(unit.get("quality"))
	if _refs.detail_title != null:
		_refs.detail_title.text = "角色详情 - %s" % unit_name
	if _refs.detail_name_label != null:
		_refs.detail_name_label.text = "%s %s" % [unit_name, "★".repeat(star)]
	if _refs.detail_quality_label != null:
		_refs.detail_quality_label.text = "品质：%s" % _support.quality_to_cn(quality)
	if _refs.detail_portrait_color != null:
		_refs.detail_portrait_color.color = _support.quality_color(quality)
	var base_stats: Dictionary = unit.get("base_stats")
	var runtime_stats: Dictionary = unit.get("runtime_stats")
	if _refs.detail_stats_value_label != null:
		_refs.detail_stats_value_label.text = "\n".join([
			_support.format_stat_pair("生命", runtime_stats, base_stats, "hp"),
			_support.format_stat_pair("内力", runtime_stats, base_stats, "mp"),
			_support.format_stat_pair("外功", runtime_stats, base_stats, "atk"),
			_support.format_stat_pair("外防", runtime_stats, base_stats, "def"),
			_support.format_stat_pair("内功", runtime_stats, base_stats, "iat"),
			_support.format_stat_pair("内防", runtime_stats, base_stats, "idr"),
			_support.format_stat_pair("速度", runtime_stats, base_stats, "spd"),
			_support.format_stat_pair("射程", runtime_stats, base_stats, "rng")
		])
	if _refs.detail_bonus_value_label != null:
		var bonus_lines: Array[String] = _support.build_gongfa_bonus_lines(unit)
		_refs.detail_bonus_value_label.text = "无" if bonus_lines.is_empty() else "\n".join(bonus_lines)
	_row_support.rebuild_detail_slot_rows(unit)
	_row_support.rebuild_equip_slot_rows(unit)


# 渲染单位 tooltip 头部、属性、技能与 Buff。
func show_tooltip_for_unit(unit: Node, screen_pos: Vector2) -> void:
	if _refs.unit_tooltip == null:
		return
	if not _support.is_valid_unit(unit):
		return
	var unit_name: String = str(unit.get("unit_name"))
	var star: int = clampi(int(unit.get("star_level")), 1, 3)
	if _refs.tooltip_header_name != null:
		_refs.tooltip_header_name.text = "%s %s" % [unit_name, "★".repeat(star)]
	if _refs.tooltip_quality_badge != null:
		_refs.tooltip_quality_badge.color = _support.quality_color(str(unit.get("quality")))
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	var current_hp: float = 0.0
	var max_hp: float = 1.0
	var current_mp: float = 0.0
	var max_mp: float = 1.0
	if combat != null:
		current_hp = float(combat.get("current_hp"))
		max_hp = maxf(float(combat.get("max_hp")), 1.0)
		current_mp = float(combat.get("current_mp"))
		max_mp = maxf(float(combat.get("max_mp")), 1.0)
	if _refs.tooltip_hp_bar != null:
		_refs.tooltip_hp_bar.value = clampf(current_hp / max_hp * 100.0, 0.0, 100.0)
	if _refs.tooltip_mp_bar != null:
		_refs.tooltip_mp_bar.value = clampf(current_mp / max_mp * 100.0, 0.0, 100.0)
	if _refs.tooltip_hp_text != null:
		_refs.tooltip_hp_text.text = "%d/%d" % [int(round(current_hp)), int(round(max_hp))]
	if _refs.tooltip_mp_text != null:
		_refs.tooltip_mp_text.text = "%d/%d" % [int(round(current_mp)), int(round(max_mp))]
	var base_stats: Dictionary = unit.get("base_stats")
	var runtime_stats: Dictionary = unit.get("runtime_stats")
	if _refs.tooltip_atk_label != null:
		_refs.tooltip_atk_label.text = _support.format_stat_pair(
			"外功",
			runtime_stats,
			base_stats,
			"atk"
		)
	if _refs.tooltip_def_label != null:
		_refs.tooltip_def_label.text = _support.format_stat_pair(
			"外防",
			runtime_stats,
			base_stats,
			"def"
		)
	if _refs.tooltip_iat_label != null:
		_refs.tooltip_iat_label.text = _support.format_stat_pair(
			"内功",
			runtime_stats,
			base_stats,
			"iat"
		)
	if _refs.tooltip_idr_label != null:
		_refs.tooltip_idr_label.text = _support.format_stat_pair(
			"内防",
			runtime_stats,
			base_stats,
			"idr"
		)
	if _refs.tooltip_spd_label != null:
		_refs.tooltip_spd_label.text = _support.format_stat_pair(
			"速度",
			runtime_stats,
			base_stats,
			"spd"
		)
	if _refs.tooltip_rng_label != null:
		_refs.tooltip_rng_label.text = _support.format_stat_pair(
			"射程",
			runtime_stats,
			base_stats,
			"rng"
		)
	if _refs.tooltip_status_label != null:
		_refs.tooltip_status_label.text = "状态: %s" % _support.resolve_unit_status(unit)
	_row_support.refresh_tooltip_gongfa_list(unit)
	refresh_tooltip_buff_list(unit)
	position_unit_tooltip(screen_pos)


# 刷新单位 tooltip 的 Buff 标签列表。
func refresh_tooltip_buff_list(unit: Node) -> void:
	if _refs.tooltip_buff_list == null:
		return
	for child in _refs.tooltip_buff_list.get_children():
		child.queue_free()
	var buff_ids: Array[String] = []
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager != null:
		buff_ids = unit_augment_manager.get_unit_buff_ids(unit)
	if buff_ids.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Buff: 无"
		_refs.tooltip_buff_list.add_child(empty_label)
		return
	for buff_id in buff_ids:
		var tag := Label.new()
		tag.text = "[%s]" % _support.buff_name_from_id(buff_id)
		_refs.tooltip_buff_list.add_child(tag)


# 计算并限制单位 tooltip 的落点位置。
func position_unit_tooltip(screen_pos: Vector2) -> void:
	if _refs.unit_tooltip == null:
		return
	_refs.unit_tooltip.reset_size()
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	var desired: Vector2 = screen_pos + Vector2(16.0, 16.0)
	var tooltip_size: Vector2 = _refs.unit_tooltip.size
	if desired.x + tooltip_size.x > viewport_size.x - 8.0:
		desired.x = screen_pos.x - tooltip_size.x - 16.0
	if desired.y + tooltip_size.y > viewport_size.y - 8.0:
		desired.y = screen_pos.y - tooltip_size.y - 16.0
	desired.x = clampf(desired.x, 8.0, viewport_size.x - tooltip_size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - tooltip_size.y - 8.0)
	_refs.unit_tooltip.position = desired
	_refs.unit_tooltip.visible = true

# 行 hover 入口：读取行 meta 并开始物品悬停。
func on_item_row_hover_entered(row_panel: Control) -> void:
	if _scene_root.get_viewport().gui_is_dragging():
		if _refs.item_tooltip != null:
			_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	if row_panel == null or not is_instance_valid(row_panel):
		return
	var payload: Variant = row_panel.get_meta("item_data", {})
	if not (payload is Dictionary):
		return
	if (payload as Dictionary).is_empty():
		return
	on_item_source_hover_entered(row_panel, payload as Dictionary)

# 记录物品悬停来源与 payload。
func on_item_source_hover_entered(source: Control, payload: Dictionary) -> void:
	if _scene_root.get_viewport().gui_is_dragging():
		if _refs.item_tooltip != null:
			_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	_state.item_hover_source = source
	_state.item_hover_data = payload.duplicate(true)
	_state.item_hover_timer = 0.0
	_state.item_fade_timer = 0.0

# 来源离开时重置 hover/fade 计时。
func on_item_source_hover_exited(source: Control) -> void:
	if _state.item_hover_source != source:
		return
	_state.item_hover_timer = 0.0
	_state.item_fade_timer = 0.0

# 管理物品 tooltip 的延迟显示与淡出。
func update_item_tooltip_hover(delta: float) -> void:
	if _refs.item_tooltip == null:
		return
	if _scene_root.get_viewport().gui_is_dragging():
		_refs.item_tooltip.visible = false
		_support.clear_item_hover_state()
		return
	var source_valid: bool = (
		_state.item_hover_source != null and is_instance_valid(_state.item_hover_source)
	)
	if not source_valid:
		return
	var mouse: Vector2 = _scene_root.get_viewport().get_mouse_position()
	var in_source: bool = _state.item_hover_source.get_global_rect().has_point(mouse)
	var in_tooltip: bool = false
	if _refs.item_tooltip.visible:
		in_tooltip = _refs.item_tooltip.get_global_rect().has_point(mouse)
	var in_bridge: bool = false
	if _refs.item_tooltip.visible:
		in_bridge = calc_bridge_rect(_state.item_hover_source, _refs.item_tooltip, 8.0).has_point(mouse)
	if in_source:
		_state.item_hover_timer += delta
		if _state.item_hover_timer >= 0.2:
			show_item_tooltip(_state.item_hover_data, _state.item_hover_source)
		_state.item_fade_timer = 0.0
		return
	if in_tooltip or in_bridge:
		_state.item_fade_timer = 0.0
		return
	_state.item_fade_timer += delta
	if _state.item_fade_timer < 0.2:
		return
	_refs.item_tooltip.visible = false
	_support.clear_item_hover_state()

# 把统一 payload 投影到物品 tooltip。
func show_item_tooltip(payload: Dictionary, source: Control) -> void:
	if _refs.item_tooltip == null:
		return
	if payload.is_empty():
		_refs.item_tooltip.visible = false
		return
	if _refs.item_tooltip_name != null:
		_refs.item_tooltip_name.text = str(payload.get("name", "未知条目"))
	if _refs.item_tooltip_type != null:
		_refs.item_tooltip_type.text = str(payload.get("type_line", ""))
	if _refs.item_tooltip_desc != null:
		_refs.item_tooltip_desc.text = str(payload.get("desc", ""))
	if _refs.item_tooltip_effects != null:
		var effect_lines: Array = payload.get("effects", [])
		_row_support.rebuild_item_tooltip_effect_rows(_refs.item_tooltip_effects, effect_lines, true)
	var has_skill: bool = bool(payload.get("has_skill", false))
	if _refs.item_tooltip_skill_section != null:
		_refs.item_tooltip_skill_section.visible = has_skill
	if has_skill:
		if _refs.item_tooltip_skill_trigger != null:
			_refs.item_tooltip_skill_trigger.text = str(payload.get("skill_trigger", "触发：-"))
		if _refs.item_tooltip_skill_effects != null:
			var skill_lines: Array = payload.get("skill_effects", [])
			_row_support.rebuild_item_tooltip_effect_rows(
				_refs.item_tooltip_skill_effects,
				skill_lines,
				false
			)
	elif _refs.item_tooltip_skill_effects != null:
		for child in _refs.item_tooltip_skill_effects.get_children():
			child.queue_free()
	_refs.item_tooltip.reset_size()
	position_item_tooltip(source)
	_refs.item_tooltip.visible = true

# 计算并限制物品 tooltip 的相对落点。
func position_item_tooltip(source: Control) -> void:
	if _refs.item_tooltip == null:
		return
	if source == null or not is_instance_valid(source):
		return
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	var source_rect: Rect2 = source.get_global_rect()
	var desired: Vector2 = source_rect.position + Vector2(source_rect.size.x + 10.0, 0.0)
	var tooltip_size: Vector2 = _refs.item_tooltip.size
	if desired.x + tooltip_size.x > viewport_size.x - 8.0:
		desired.x = source_rect.position.x - tooltip_size.x - 10.0
	if desired.y + tooltip_size.y > viewport_size.y - 8.0:
		desired.y = viewport_size.y - tooltip_size.y - 8.0
	desired.x = clampf(desired.x, 8.0, viewport_size.x - tooltip_size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - tooltip_size.y - 8.0)
	_refs.item_tooltip.position = desired

# 计算来源与 tooltip 之间的 bridge 区域。
func calc_bridge_rect(source: Control, tooltip: Control, padding: float) -> Rect2:
	if source == null or tooltip == null:
		return Rect2()
	if not is_instance_valid(source) or not is_instance_valid(tooltip):
		return Rect2()
	return source.get_global_rect().merge(tooltip.get_global_rect()).grow(padding)

# 响应详情关闭按钮。
func on_detail_close_pressed() -> void:
	force_close_detail_panel(true)

# 处理详情面板拖拽句柄输入。
func on_detail_drag_handle_gui_input(event: InputEvent) -> void:
	if not _state.detail_visible:
		return
	if not _support.is_valid_unit(_state.detail_unit):
		return
	if _refs.unit_detail_panel == null:
		return
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if mouse_button.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse_button.pressed:
			var mouse_screen: Vector2 = _scene_root.get_viewport().get_mouse_position()
			if _refs.detail_close_button != null:
				if _refs.detail_close_button.get_global_rect().has_point(mouse_screen):
					return
			_state.is_dragging_detail_panel = true
			_state.detail_drag_offset = mouse_screen - _refs.unit_detail_panel.position
			return
		_state.is_dragging_detail_panel = false
		return
	if event is InputEventMouseMotion and _state.is_dragging_detail_panel:
		_refs.unit_detail_panel.position = (
			_scene_root.get_viewport().get_mouse_position() - _state.detail_drag_offset
		)

# 统一读取 UnitAugmentManager，避免 tooltip 明细重复散落服务访问。
func _get_unit_augment_manager():
	if _refs == null:
		return null
	return _refs.unit_augment_manager
