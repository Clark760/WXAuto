extends "res://scripts/board/battlefield_m2.gd"

# ===========================
# M3 战斗测试场景脚本
# ===========================
# 设计目标：
# 1. 复用 M2 已验证的“战场/视角/拖拽/战斗流程”基础能力，避免重复造轮子。
# 2. 按新版 M2 场景显示逻辑补齐 M3 所需的 UI：富信息 Tooltip + 角色详情面板。
# 3. 接入功法槽位轮换测试入口，便于快速验证 M3 功法/联动系统。

const SLOT_ORDER: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa", "qishu"]
const EQUIP_ORDER: Array[String] = ["weapon", "armor", "accessory"]
const CLICK_DRAG_THRESHOLD: float = 8.0

@onready var tooltip_header_name: Label = $HUDLayer/UnitTooltip/TooltipVBox/HeaderRow/HeaderName
@onready var tooltip_faction_icon: ColorRect = $HUDLayer/UnitTooltip/TooltipVBox/HeaderRow/FactionIcon
@onready var tooltip_quality_badge: ColorRect = $HUDLayer/UnitTooltip/TooltipVBox/HeaderRow/QualityBadge
@onready var tooltip_hp_rich: ProgressBar = $HUDLayer/UnitTooltip/TooltipVBox/HPRow/HPBarRich
@onready var tooltip_hp_text: Label = $HUDLayer/UnitTooltip/TooltipVBox/HPRow/HPText
@onready var tooltip_mp_rich: ProgressBar = $HUDLayer/UnitTooltip/TooltipVBox/MPRow/MPBarRich
@onready var tooltip_mp_text: Label = $HUDLayer/UnitTooltip/TooltipVBox/MPRow/MPText
@onready var tooltip_atk_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/AtkLabel
@onready var tooltip_def_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/DefLabel
@onready var tooltip_iat_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/IatLabel
@onready var tooltip_idr_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/IdrLabel
@onready var tooltip_spd_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/SpdLabel
@onready var tooltip_rng_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatsGrid/RngLabel
@onready var tooltip_gongfa_list: VBoxContainer = $HUDLayer/UnitTooltip/TooltipVBox/GongfaList
@onready var tooltip_buff_list: HBoxContainer = $HUDLayer/UnitTooltip/TooltipVBox/BuffList
@onready var tooltip_status_label: Label = $HUDLayer/UnitTooltip/TooltipVBox/StatusLabel
@onready var tooltip_layer: CanvasLayer = $TooltipLayer

@onready var unit_detail_mask: ColorRect = $DetailLayer/UnitDetailMask
@onready var unit_detail_panel: PanelContainer = $DetailLayer/UnitDetailPanel
@onready var detail_close_button: Button = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/HeaderRow/DetailCloseButton
@onready var detail_title: Label = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/HeaderRow/DetailTitle
@onready var detail_portrait_color: ColorRect = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/PortraitSection/PortraitColor
@onready var detail_name_label: Label = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/PortraitSection/DetailNameLabel
@onready var detail_faction_label: Label = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/PortraitSection/DetailFactionLabel
@onready var detail_stats_value_label: Label = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/StatsSection/StatsValueLabel
@onready var detail_bonus_value_label: Label = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/StatsSection/BonusValueLabel
@onready var detail_slot_list: VBoxContainer = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/GongfaSection/SlotList
@onready var detail_equip_slot_list: VBoxContainer = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/GongfaSection/EquipSlotList
@onready var detail_linkage_list: VBoxContainer = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/ContentRow/GongfaSection/LinkagePreviewList
@onready var item_tooltip: PanelContainer = $DetailLayer/ItemTooltip
@onready var item_tooltip_name: Label = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/ItemName
@onready var item_tooltip_type: Label = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/ItemType
@onready var item_tooltip_desc: RichTextLabel = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/DescLabel
@onready var item_tooltip_effects: VBoxContainer = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/EffectsList
@onready var item_tooltip_skill_section: VBoxContainer = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/SkillSection
@onready var item_tooltip_skill_trigger: Label = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/SkillSection/SkillTrigger
@onready var item_tooltip_skill_effects: VBoxContainer = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/SkillSection/SkillEffects
@onready var item_tooltip_linkage_tags: Label = $DetailLayer/ItemTooltip/TooltipMargin/TooltipRoot/LinkageTags

var _detail_unit: Node = null
var _detail_refresh_accum: float = 0.0
var _left_click_pending: bool = false
var _left_press_pos: Vector2 = Vector2.ZERO
var _bench_press_slot: int = -1
var _bench_press_pos: Vector2 = Vector2.ZERO
var _world_press_unit: Node = null
var _world_press_pos: Vector2 = Vector2.ZERO
var _world_press_cell: Vector2i = Vector2i(-999, -999)
var _gongfa_by_type: Dictionary = {}
var _equip_data_map: Dictionary = {}
var _buff_data_map: Dictionary = {}
var _item_hover_source: Control = null
var _item_hover_data: Dictionary = {}
var _item_hover_timer: float = 0.0
var _item_fade_timer: float = 0.0


func _ready() -> void:
	super._ready()
	_reparent_tooltips_to_high_layer()
	_hide_legacy_tooltip_nodes()
	_connect_m3_ui_signals()
	_build_gongfa_type_cache()
	_reload_external_item_data()
	_layout_detail_panel()
	_close_detail_panel(false)
	item_tooltip.visible = false


func _reparent_tooltips_to_high_layer() -> void:
	# 根据修复方案，UnitTooltip / ItemTooltip 统一迁移到高层 CanvasLayer，
	# 彻底避免被 BottomLayer 遮挡。
	if tooltip_layer == null:
		return
	if unit_tooltip != null and unit_tooltip.get_parent() != tooltip_layer:
		unit_tooltip.reparent(tooltip_layer)
	if item_tooltip != null and item_tooltip.get_parent() != tooltip_layer:
		item_tooltip.reparent(tooltip_layer)
	if item_tooltip != null:
		tooltip_layer.move_child(item_tooltip, tooltip_layer.get_child_count() - 1)


func _input(event: InputEvent) -> void:
	# M3 交互规则：
	# 1. 备战席“短按”打开详情。
	# 2. 备战席“移动超过阈值”才开始拖拽，避免点击和拖放冲突。
	# 3. 战场单位仍保持 M2 拖拽逻辑，点击可打开详情。
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton

		if _handle_world_view_input(event):
			get_viewport().set_input_as_handled()
			return

		if mouse_button.button_index != MOUSE_BUTTON_LEFT:
			return

		if mouse_button.pressed:
			_left_click_pending = true
			_left_press_pos = mouse_button.position
			_bench_press_slot = -1
			_world_press_unit = null
			_world_press_cell = Vector2i(-999, -999)

			if _stage == Stage.PREPARATION:
				if bench_ui != null and bench_ui.is_screen_point_inside(mouse_button.position):
					var slot: int = bench_ui.get_slot_index_at_screen_pos(mouse_button.position)
					if slot >= 0 and bench_ui.get_unit_at_slot(slot) != null:
						_bench_press_slot = slot
						_bench_press_pos = mouse_button.position
						get_viewport().set_input_as_handled()
						return

				var world_pos_press: Vector2 = _screen_to_world(mouse_button.position)
				var world_unit: Node = _pick_deployed_ally_unit_at(world_pos_press)
				if world_unit != null:
					_world_press_unit = world_unit
					_world_press_pos = mouse_button.position
					_world_press_cell = world_unit.get("deployed_cell")
					get_viewport().set_input_as_handled()
					return
			return

		# 左键释放
		if _stage == Stage.PREPARATION and _dragging_unit != null:
			_try_end_drag(mouse_button.position)
			_bench_press_slot = -1
			_world_press_unit = null
			_left_click_pending = false
			get_viewport().set_input_as_handled()
			return

		if _stage == Stage.PREPARATION and _bench_press_slot >= 0 and _dragging_unit == null:
			var slot_index: int = _bench_press_slot
			var click_like_bench: bool = mouse_button.position.distance_to(_bench_press_pos) <= CLICK_DRAG_THRESHOLD
			_bench_press_slot = -1
			_left_click_pending = false
			if click_like_bench:
				_open_detail_for_bench_slot(slot_index)
				get_viewport().set_input_as_handled()
			return

		if _stage == Stage.PREPARATION and _world_press_unit != null and _dragging_unit == null:
			var clicked_unit: Node = _world_press_unit
			var click_like_world: bool = mouse_button.position.distance_to(_world_press_pos) <= CLICK_DRAG_THRESHOLD
			_world_press_unit = null
			_world_press_cell = Vector2i(-999, -999)
			_left_click_pending = false
			if click_like_world and _is_valid_unit(clicked_unit):
				_open_detail_panel(clicked_unit)
				get_viewport().set_input_as_handled()
			return

		var click_like: bool = _left_click_pending and mouse_button.position.distance_to(_left_press_pos) <= CLICK_DRAG_THRESHOLD
		_left_click_pending = false
		if click_like and _dragging_unit == null:
			_try_open_detail_from_click(mouse_button.position)
		return

	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion

		if _handle_world_view_input(event):
			get_viewport().set_input_as_handled()
			return

		if _left_click_pending and motion.position.distance_to(_left_press_pos) > CLICK_DRAG_THRESHOLD:
			_left_click_pending = false

		if _bench_press_slot >= 0 and _stage == Stage.PREPARATION and _dragging_unit == null:
			if motion.position.distance_to(_bench_press_pos) > CLICK_DRAG_THRESHOLD:
				var bench_unit: Node = bench_ui.remove_unit_at(_bench_press_slot)
				var origin_slot: int = _bench_press_slot
				_bench_press_slot = -1
				if bench_unit != null:
					_begin_drag(bench_unit, "bench", origin_slot, Vector2i(-999, -999), motion.position)
					get_viewport().set_input_as_handled()
			return

		if _world_press_unit != null and _stage == Stage.PREPARATION and _dragging_unit == null:
			if motion.position.distance_to(_world_press_pos) > CLICK_DRAG_THRESHOLD:
				var pressed_unit: Node = _world_press_unit
				var origin_cell: Vector2i = _world_press_cell
				_world_press_unit = null
				_world_press_cell = Vector2i(-999, -999)
				if _is_valid_unit(pressed_unit):
					_remove_ally_mapping(pressed_unit)
					_begin_drag(pressed_unit, "battlefield", -1, origin_cell, motion.position)
					get_viewport().set_input_as_handled()
			return

		if _stage == Stage.PREPARATION and _dragging_unit != null:
			_update_drag_preview(motion.position)
			_update_drag_target(motion.position)
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	super._process(delta)
	_update_item_tooltip_hover(delta)
	if not unit_detail_panel.visible:
		return
	if _detail_unit == null or not _is_valid_unit(_detail_unit):
		_close_detail_panel(true)
		return
	_detail_refresh_accum += delta
	if _detail_refresh_accum >= 0.2:
		_detail_refresh_accum = 0.0
		_update_detail_panel(_detail_unit)


func _update_tooltip(delta: float) -> void:
	# 修复方案要求：当详情面板打开时，暂停 UnitTooltip 的悬浮检测，
	# 避免其消失计时影响其它 Tooltip 交互。
	if unit_detail_panel != null and unit_detail_panel.visible:
		if unit_tooltip != null:
			unit_tooltip.visible = false
		_hover_candidate_unit = null
		_hover_hold_time = 0.0
		_tooltip_hide_delay = 0.0
		return
	super._update_tooltip(delta)


func _unhandled_input(event: InputEvent) -> void:
	super._unhandled_input(event)
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ESCAPE and unit_detail_panel.visible:
		_close_detail_panel(true)
		get_viewport().set_input_as_handled()


func _handle_key_input(event: InputEventKey) -> void:
	# M3 场景中 F7 固定重开自身，便于反复验证功法改动。
	if event.pressed and not event.echo and event.keycode == KEY_F7:
		var event_bus: Node = _get_root_node("EventBus")
		if event_bus != null:
			event_bus.call("emit_scene_change_requested", "res://scenes/battle/battlefield_m3.tscn")
		return
	super._handle_key_input(event)


func _on_viewport_size_changed() -> void:
	super._on_viewport_size_changed()
	_layout_detail_panel()


func _show_tooltip_for_unit(unit: Node, screen_pos: Vector2) -> void:
	# Tooltip 数据严格走“实时读取单位状态”，确保战斗中 HP/Buff 能实时更新。
	if unit == null or not _is_valid_unit(unit):
		unit_tooltip.visible = false
		return

	var unit_name: String = str(unit.get("unit_name"))
	var star: int = clampi(int(unit.get("star_level")), 1, 3)
	tooltip_header_name.text = "%s %s" % [unit_name, "★".repeat(star)]
	tooltip_faction_icon.color = _faction_color(str(unit.get("faction")))
	tooltip_quality_badge.color = _quality_color(str(unit.get("quality")))

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
	tooltip_hp_rich.value = clampf(current_hp / max_hp * 100.0, 0.0, 100.0)
	tooltip_mp_rich.value = clampf(current_mp / max_mp * 100.0, 0.0, 100.0)
	tooltip_hp_text.text = "%d/%d" % [int(round(current_hp)), int(round(max_hp))]
	tooltip_mp_text.text = "%d/%d" % [int(round(current_mp)), int(round(max_mp))]

	var base_stats: Dictionary = unit.get("base_stats")
	var runtime_stats: Dictionary = unit.get("runtime_stats")
	tooltip_atk_label.text = _format_stat_pair("外功", runtime_stats, base_stats, "atk")
	tooltip_def_label.text = _format_stat_pair("外防", runtime_stats, base_stats, "def")
	tooltip_iat_label.text = _format_stat_pair("内功", runtime_stats, base_stats, "iat")
	tooltip_idr_label.text = _format_stat_pair("内防", runtime_stats, base_stats, "idr")
	tooltip_spd_label.text = _format_stat_pair("速度", runtime_stats, base_stats, "spd")
	tooltip_rng_label.text = _format_stat_pair("射程", runtime_stats, base_stats, "rng")

	_refresh_tooltip_gongfa_list(unit)
	_refresh_tooltip_buff_list(unit)
	tooltip_status_label.text = "状态: %s" % _resolve_unit_status(unit)

	_position_tooltip(screen_pos)


func _connect_m3_ui_signals() -> void:
	var close_cb: Callable = Callable(self, "_on_detail_close_pressed")
	if not detail_close_button.is_connected("pressed", close_cb):
		detail_close_button.connect("pressed", close_cb)

	if gongfa_manager == null:
		return
	var reload_cb: Callable = Callable(self, "_on_gongfa_data_reloaded")
	if gongfa_manager.has_signal("gongfa_data_reloaded") and not gongfa_manager.is_connected("gongfa_data_reloaded", reload_cb):
		gongfa_manager.connect("gongfa_data_reloaded", reload_cb)

	var event_bus: Node = _get_root_node("EventBus")
	if event_bus != null:
		var data_reload_cb: Callable = Callable(self, "_on_data_reloaded")
		if event_bus.has_signal("data_reloaded") and not event_bus.is_connected("data_reloaded", data_reload_cb):
			event_bus.connect("data_reloaded", data_reload_cb)


func _on_gongfa_data_reloaded(_summary: Dictionary) -> void:
	_build_gongfa_type_cache()
	_reload_external_item_data()
	if unit_detail_panel.visible and _detail_unit != null and _is_valid_unit(_detail_unit):
		_update_detail_panel(_detail_unit)


func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	_reload_external_item_data()


func _hide_legacy_tooltip_nodes() -> void:
	# 父类为了兼容仍会绑定旧节点，这里仅隐藏旧显示节点，避免与新版 Tooltip 叠加。
	if tooltip_name != null:
		tooltip_name.visible = false
	if tooltip_hp != null:
		tooltip_hp.visible = false
	if tooltip_mp != null:
		tooltip_mp.visible = false
	if tooltip_gongfa != null:
		tooltip_gongfa.visible = false


func _build_gongfa_type_cache() -> void:
	_gongfa_by_type.clear()
	for slot in SLOT_ORDER:
		_gongfa_by_type[slot] = []
	if gongfa_manager == null:
		return
	var all_data: Variant = gongfa_manager.call("get_all_gongfa")
	if not (all_data is Array):
		return
	for item in all_data:
		if not (item is Dictionary):
			continue
		var data: Dictionary = item as Dictionary
		var gid: String = str(data.get("id", "")).strip_edges()
		var gtype: String = str(data.get("type", "")).strip_edges()
		if gid.is_empty() or gtype.is_empty():
			continue
		if not _gongfa_by_type.has(gtype):
			_gongfa_by_type[gtype] = []
		var ids: Array = _gongfa_by_type[gtype]
		ids.append(gid)
		_gongfa_by_type[gtype] = ids


func _try_open_detail_from_click(screen_pos: Vector2) -> void:
	if _stage == Stage.COMBAT:
		return
	if unit_detail_panel.visible:
		if unit_detail_panel.get_global_rect().has_point(screen_pos):
			# 点击详情面板内部交给按钮等控件处理，不触发“透传选中战场单位”。
			return
		_close_detail_panel(true)
		return
	var world_pos: Vector2 = _screen_to_world(screen_pos)
	var clicked_unit: Node = _pick_visible_unit_at_world(world_pos)
	if clicked_unit == null:
		return
	_open_detail_panel(clicked_unit)
	get_viewport().set_input_as_handled()


func _open_detail_for_bench_slot(slot_index: int) -> void:
	if bench_ui == null:
		return
	var bench_unit: Node = bench_ui.get_unit_at_slot(slot_index)
	if bench_unit == null or not _is_valid_unit(bench_unit):
		return
	_open_detail_panel(bench_unit)


func _open_detail_panel(unit: Node) -> void:
	if unit == null or not _is_valid_unit(unit):
		return
	_detail_unit = unit
	_detail_refresh_accum = 0.0
	_update_detail_panel(unit)
	_layout_detail_panel()
	if unit_detail_panel.visible:
		unit_detail_mask.visible = true
		return

	unit_detail_mask.visible = true
	unit_detail_panel.visible = true
	var target_pos: Vector2 = unit_detail_panel.position
	unit_detail_panel.position = Vector2(target_pos.x, get_viewport().get_visible_rect().size.y + 24.0)
	var tween: Tween = create_tween()
	tween.tween_property(unit_detail_panel, "position", target_pos, 0.25).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)


func _close_detail_panel(animate: bool) -> void:
	if not unit_detail_panel.visible and not unit_detail_mask.visible:
		_detail_unit = null
		item_tooltip.visible = false
		_clear_item_hover_state()
		return
	var finish_close := func() -> void:
		unit_detail_panel.visible = false
		unit_detail_mask.visible = false
		item_tooltip.visible = false
		_detail_unit = null
		_clear_item_hover_state()
	if not animate:
		finish_close.call()
		return
	var target_y: float = get_viewport().get_visible_rect().size.y + 24.0
	var tween: Tween = create_tween()
	tween.tween_property(unit_detail_panel, "position:y", target_y, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.finished.connect(finish_close)


func _on_detail_close_pressed() -> void:
	_close_detail_panel(true)


func _layout_detail_panel() -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var width: float = minf(viewport_size.x * 0.65, 840.0)
	var height: float = minf(viewport_size.y * 0.75, 620.0)
	var left: float = (viewport_size.x - width) * 0.5
	var top: float = (viewport_size.y - height) * 0.5
	unit_detail_panel.position = Vector2(left, top)
	unit_detail_panel.size = Vector2(width, height)


func _update_detail_panel(unit: Node) -> void:
	if unit == null or not _is_valid_unit(unit):
		return

	var name_text: String = str(unit.get("unit_name"))
	var star: int = clampi(int(unit.get("star_level")), 1, 3)
	var faction: String = str(unit.get("faction"))
	var quality: String = str(unit.get("quality"))

	detail_title.text = "角色详情 - %s" % name_text
	detail_name_label.text = "%s %s" % [name_text, "★".repeat(star)]
	detail_faction_label.text = "%s · %s" % [_faction_to_cn(faction), _quality_to_cn(quality)]
	detail_portrait_color.color = _quality_color(quality)

	var base_stats: Dictionary = unit.get("base_stats")
	var runtime_stats: Dictionary = unit.get("runtime_stats")
	var stats_lines: Array[String] = []
	stats_lines.append(_format_stat_pair("生命", runtime_stats, base_stats, "hp"))
	stats_lines.append(_format_stat_pair("内力", runtime_stats, base_stats, "mp"))
	stats_lines.append(_format_stat_pair("外功", runtime_stats, base_stats, "atk"))
	stats_lines.append(_format_stat_pair("外防", runtime_stats, base_stats, "def"))
	stats_lines.append(_format_stat_pair("内功", runtime_stats, base_stats, "iat"))
	stats_lines.append(_format_stat_pair("内防", runtime_stats, base_stats, "idr"))
	stats_lines.append(_format_stat_pair("速度", runtime_stats, base_stats, "spd"))
	stats_lines.append(_format_stat_pair("射程", runtime_stats, base_stats, "rng"))
	detail_stats_value_label.text = "\n".join(stats_lines)

	var bonus_lines: Array[String] = _build_gongfa_bonus_lines(unit)
	detail_bonus_value_label.text = "无" if bonus_lines.is_empty() else "\n".join(bonus_lines)

	_rebuild_detail_slot_rows(unit)
	_rebuild_equip_slot_rows(unit)
	_rebuild_linkage_preview()


func _build_gongfa_bonus_lines(unit: Node) -> Array[String]:
	var lines: Array[String] = []
	if gongfa_manager == null:
		return lines
	var equipped_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	for gid_value in equipped_ids:
		var gid: String = str(gid_value)
		var data: Dictionary = gongfa_manager.call("get_gongfa_data", gid)
		if data.is_empty():
			continue
		var gname: String = str(data.get("name", gid))
		var passive: Variant = data.get("passive_effects", [])
		if not (passive is Array):
			continue
		for fx in passive:
			if not (fx is Dictionary):
				continue
			var effect: Dictionary = fx as Dictionary
			var op: String = str(effect.get("op", ""))
			match op:
				"stat_add":
					lines.append("%s: %s +%s" % [gname, _stat_key_to_cn(str(effect.get("stat", ""))), str(effect.get("value", 0))])
				"stat_percent":
					var percent: float = float(effect.get("value", 0.0)) * 100.0
					lines.append("%s: %s %+d%%" % [gname, _stat_key_to_cn(str(effect.get("stat", ""))), int(round(percent))])
				"mp_regen_add":
					lines.append("%s: 内力回复 +%s" % [gname, str(effect.get("value", 0))])
				_:
					lines.append("%s: %s" % [gname, op])
	return lines


func _rebuild_detail_slot_rows(unit: Node) -> void:
	for child in detail_slot_list.get_children():
		child.queue_free()
	var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
	for slot in SLOT_ORDER:
		var row_panel := PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 30)
		row_panel.mouse_filter = Control.MOUSE_FILTER_PASS

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)

		var gid: String = str(slots.get(slot, "")).strip_edges()
		var icon_label := Label.new()
		icon_label.text = _slot_icon(slot)

		var name_button := LinkButton.new()
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.text = "%s: %s" % [_slot_to_cn(slot), _gongfa_name_or_empty(gid)]
		name_button.disabled = gid.is_empty()
		if not gid.is_empty():
			var item_data: Dictionary = _build_gongfa_item_tooltip_data(gid)
			row_panel.mouse_entered.connect(Callable(self, "_on_item_source_hover_entered").bind(row_panel, item_data))
			row_panel.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))

		var swap_button := Button.new()
		swap_button.text = "更换" if _stage == Stage.PREPARATION else "锁定"
		swap_button.disabled = _stage != Stage.PREPARATION
		swap_button.pressed.connect(Callable(self, "_on_slot_swap_pressed").bind(slot))

		row.add_child(icon_label)
		row.add_child(name_button)
		row.add_child(swap_button)
		row_panel.add_child(row)
		detail_slot_list.add_child(row_panel)


func _on_slot_swap_pressed(slot: String) -> void:
	if _detail_unit == null or not _is_valid_unit(_detail_unit):
		return
	if _stage != Stage.PREPARATION:
		return
	if gongfa_manager == null:
		return

	var slots: Dictionary = _normalize_unit_slots(_detail_unit.get("gongfa_slots"))
	var current_id: String = str(slots.get(slot, "")).strip_edges()
	var candidates: Array = _gongfa_by_type.get(slot, []).duplicate()
	var cycle: Array[String] = [""]
	for gid_value in candidates:
		cycle.append(str(gid_value))
	var current_index: int = cycle.find(current_id)
	if current_index < 0:
		current_index = 0
	var next_id: String = cycle[(current_index + 1) % cycle.size()]

	var ok: bool = true
	if next_id.is_empty():
		gongfa_manager.call("unequip_gongfa", _detail_unit, slot)
	else:
		ok = bool(gongfa_manager.call("equip_gongfa", _detail_unit, slot, next_id))

	if not ok:
		debug_label.text = "更换功法失败：槽位 %s 不满足上限或数据无效。" % _slot_to_cn(slot)
		return

	_update_detail_panel(_detail_unit)
	_refresh_all_ui()


func _rebuild_equip_slot_rows(unit: Node) -> void:
	# M3 阶段装备系统未实现，此处先提供“可查看详情 + 不可更换”的占位槽位。
	for child in detail_equip_slot_list.get_children():
		child.queue_free()
	var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(unit))
	for equip_type in EQUIP_ORDER:
		var row_panel := PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 30)
		row_panel.mouse_filter = Control.MOUSE_FILTER_PASS

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)

		var icon_label := Label.new()
		icon_label.text = _equip_icon(equip_type)

		var equip_id: String = str(equip_slots.get(equip_type, "")).strip_edges()
		var name_button := LinkButton.new()
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.text = "%s: %s" % [_equip_type_to_cn(equip_type), _equip_name_or_empty(equip_id)]
		name_button.disabled = equip_id.is_empty()
		name_button.modulate = Color(0.82, 0.82, 0.82, 1.0)
		if not equip_id.is_empty():
			var item_data: Dictionary = _build_equip_item_tooltip_data(equip_id)
			row_panel.mouse_entered.connect(Callable(self, "_on_item_source_hover_entered").bind(row_panel, item_data))
			row_panel.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))

		var swap_button := Button.new()
		swap_button.text = "锁定"
		swap_button.disabled = true

		row.add_child(icon_label)
		row.add_child(name_button)
		row.add_child(swap_button)
		row_panel.add_child(row)
		detail_equip_slot_list.add_child(row_panel)


func _rebuild_linkage_preview() -> void:
	for child in detail_linkage_list.get_children():
		child.queue_free()
	if gongfa_manager == null:
		var empty_label := Label.new()
		empty_label.text = "未连接 GongfaManager"
		detail_linkage_list.add_child(empty_label)
		return
	var names: Array = gongfa_manager.call("get_active_linkage_names")
	if names.is_empty():
		var none_label := Label.new()
		none_label.text = "暂无已激活联动"
		detail_linkage_list.add_child(none_label)
		return
	for item in names:
		var row := Label.new()
		row.text = "✅ %s" % str(item)
		detail_linkage_list.add_child(row)


func _refresh_tooltip_gongfa_list(unit: Node) -> void:
	for child in tooltip_gongfa_list.get_children():
		child.queue_free()
	var runtime_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	if runtime_ids.is_empty():
		var empty_label := Label.new()
		empty_label.text = "功法: 无"
		tooltip_gongfa_list.add_child(empty_label)
		return
	for gid_value in runtime_ids:
		var gid: String = str(gid_value)
		var data: Dictionary = {}
		if gongfa_manager != null:
			data = gongfa_manager.call("get_gongfa_data", gid)
		var row_panel := PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 24)
		row_panel.mouse_filter = Control.MOUSE_FILTER_PASS

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 4)
		var prefix := Label.new()
		prefix.text = "•"
		var link := LinkButton.new()
		link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if data.is_empty():
			link.text = gid
		else:
			link.text = "%s（%s/%s）" % [
				str(data.get("name", gid)),
				_slot_to_cn(str(data.get("type", ""))),
				_element_to_cn(str(data.get("element", "none")))
			]
		var item_data: Dictionary = _build_gongfa_item_tooltip_data(gid)
		row_panel.mouse_entered.connect(Callable(self, "_on_item_source_hover_entered").bind(row_panel, item_data))
		row_panel.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))
		row.add_child(prefix)
		row.add_child(link)
		row_panel.add_child(row)
		tooltip_gongfa_list.add_child(row_panel)


func _refresh_tooltip_buff_list(unit: Node) -> void:
	for child in tooltip_buff_list.get_children():
		child.queue_free()
	var buff_ids: Array = []
	if gongfa_manager != null and gongfa_manager.has_method("get_unit_buff_ids"):
		var buff_value: Variant = gongfa_manager.call("get_unit_buff_ids", unit)
		if buff_value is Array:
			buff_ids = buff_value
	if buff_ids.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Buff: 无"
		tooltip_buff_list.add_child(empty_label)
		return
	for buff_id_value in buff_ids:
		var tag := Label.new()
		tag.text = "[%s]" % str(buff_id_value)
		tooltip_buff_list.add_child(tag)


func _reload_external_item_data() -> void:
	# 从 DataManager 读取装备/Buff 数据，供 ItemTooltip 展示。
	_equip_data_map.clear()
	_buff_data_map.clear()
	var data_manager: Node = _get_root_node("DataManager")
	if data_manager == null:
		return
	var equip_records: Variant = data_manager.call("get_all_records", "equipment")
	if equip_records is Array:
		for record_value in equip_records:
			if not (record_value is Dictionary):
				continue
			var record: Dictionary = record_value
			var record_id: String = str(record.get("id", "")).strip_edges()
			if not record_id.is_empty():
				_equip_data_map[record_id] = record.duplicate(true)
	var buff_records: Variant = data_manager.call("get_all_records", "buffs")
	if buff_records is Array:
		for buff_value in buff_records:
			if not (buff_value is Dictionary):
				continue
			var buff_data: Dictionary = buff_value
			var buff_id: String = str(buff_data.get("id", "")).strip_edges()
			if not buff_id.is_empty():
				_buff_data_map[buff_id] = buff_data.duplicate(true)


func _clear_item_hover_state() -> void:
	_item_hover_source = null
	_item_hover_data = {}
	_item_hover_timer = 0.0
	_item_fade_timer = 0.0


func _on_item_source_hover_entered(source: Control, payload: Dictionary) -> void:
	_item_hover_source = source
	_item_hover_data = payload.duplicate(true)
	_item_hover_timer = 0.0
	_item_fade_timer = 0.0


func _on_item_source_hover_exited(source: Control) -> void:
	# 不立即清空 source，给“源控件 -> Tooltip 面板”的鼠标移动留出缓冲窗口。
	if _item_hover_source != source:
		return
	_item_hover_timer = 0.0
	_item_fade_timer = 0.0


func _update_item_tooltip_hover(delta: float) -> void:
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var source_valid: bool = _item_hover_source != null and is_instance_valid(_item_hover_source)
	var in_source: bool = source_valid and _item_hover_source.get_global_rect().has_point(mouse)
	var in_tooltip: bool = item_tooltip.visible and item_tooltip.get_global_rect().has_point(mouse)
	var in_bridge: bool = false
	if source_valid and item_tooltip.visible:
		in_bridge = _calc_bridge_rect(_item_hover_source, item_tooltip, 8.0).has_point(mouse)

	if source_valid and in_source:
		_item_hover_timer += delta
		if _item_hover_timer >= 0.2:
			_show_item_tooltip(_item_hover_data, _item_hover_source)
		_item_fade_timer = 0.0
		return

	if in_tooltip or in_bridge:
		_item_fade_timer = 0.0
		return

	if source_valid and item_tooltip.visible:
		# 允许从 source 移向 tooltip 的短暂空窗期，避免“一闪即关”。
		_item_fade_timer += delta
		if _item_fade_timer >= 0.2:
			item_tooltip.visible = false
			_clear_item_hover_state()
		return

	if source_valid and not item_tooltip.visible:
		_item_fade_timer += delta
		if _item_fade_timer >= 0.2:
			_clear_item_hover_state()
		return

	if not item_tooltip.visible:
		return
	_item_fade_timer += delta
	if _item_fade_timer >= 0.2:
		item_tooltip.visible = false
		_clear_item_hover_state()


func _calc_bridge_rect(source: Control, tooltip: Control, padding: float) -> Rect2:
	if source == null or tooltip == null:
		return Rect2()
	if not is_instance_valid(source) or not is_instance_valid(tooltip):
		return Rect2()
	return source.get_global_rect().merge(tooltip.get_global_rect()).grow(padding)


func _show_item_tooltip(payload: Dictionary, source: Control) -> void:
	if payload.is_empty():
		item_tooltip.visible = false
		return
	item_tooltip_name.text = str(payload.get("name", "未知条目"))
	item_tooltip_type.text = str(payload.get("type_line", ""))
	item_tooltip_desc.text = str(payload.get("desc", ""))
	item_tooltip_linkage_tags.text = str(payload.get("linkage_tags", "联动标签：无"))

	for child in item_tooltip_effects.get_children():
		child.queue_free()
	var effect_lines: Array = payload.get("effects", [])
	if effect_lines.is_empty():
		var empty_effect := Label.new()
		empty_effect.text = "· 无"
		item_tooltip_effects.add_child(empty_effect)
	else:
		for line_value in effect_lines:
			var line := Label.new()
			line.text = "· %s" % str(line_value)
			item_tooltip_effects.add_child(line)

	for child in item_tooltip_skill_effects.get_children():
		child.queue_free()
	var has_skill: bool = bool(payload.get("has_skill", false))
	item_tooltip_skill_section.visible = has_skill
	if has_skill:
		item_tooltip_skill_trigger.text = str(payload.get("skill_trigger", "触发：-"))
		var skill_lines: Array = payload.get("skill_effects", [])
		for line_value in skill_lines:
			var line := Label.new()
			line.text = "· %s" % str(line_value)
			item_tooltip_skill_effects.add_child(line)

	item_tooltip.reset_size()
	_position_item_tooltip(source)
	item_tooltip.visible = true


func _position_item_tooltip(source: Control) -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var source_rect: Rect2 = source.get_global_rect()
	var desired: Vector2 = source_rect.position + Vector2(source_rect.size.x + 10.0, 0.0)
	var size: Vector2 = item_tooltip.size
	if desired.x + size.x > viewport_size.x - 8.0:
		desired.x = source_rect.position.x - size.x - 10.0
	if desired.y + size.y > viewport_size.y - 8.0:
		desired.y = viewport_size.y - size.y - 8.0
	desired.x = clampf(desired.x, 8.0, viewport_size.x - size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - size.y - 8.0)
	item_tooltip.position = desired


func _build_gongfa_item_tooltip_data(gongfa_id: String) -> Dictionary:
	var data: Dictionary = {}
	if gongfa_manager != null:
		data = gongfa_manager.call("get_gongfa_data", gongfa_id)
	if data.is_empty():
		return {
			"name": gongfa_id,
			"type_line": "功法",
			"desc": "未找到功法数据",
			"effects": [],
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": [],
			"linkage_tags": "联动标签：无"
		}
	var effects: Array[String] = []
	var passive_effects: Variant = data.get("passive_effects", [])
	if passive_effects is Array:
		for effect_value in passive_effects:
			if effect_value is Dictionary:
				effects.append(_format_effect_op(effect_value as Dictionary))

	var has_skill: bool = false
	var skill_trigger: String = ""
	var skill_effects: Array[String] = []
	var skill_value: Variant = data.get("skill", {})
	if skill_value is Dictionary and not (skill_value as Dictionary).is_empty():
		has_skill = true
		var skill: Dictionary = skill_value
		skill_trigger = "触发：%s" % _trigger_to_cn(str(skill.get("trigger", "")))
		var mp_cost: float = float(skill.get("mp_cost", 0.0))
		skill_effects.append("消耗：%d 内力" % int(round(mp_cost)))
		var skill_effect_list: Variant = skill.get("effects", [])
		if skill_effect_list is Array:
			for effect_value in skill_effect_list:
				if effect_value is Dictionary:
					skill_effects.append(_format_effect_op(effect_value as Dictionary))

	var linkage_tags: String = "联动标签：无"
	var tags_raw: Variant = data.get("linkage_tags", [])
	if tags_raw is Array and not (tags_raw as Array).is_empty():
		var tags_text: Array[String] = []
		for tag in tags_raw:
			tags_text.append(str(tag))
		linkage_tags = "联动标签：%s" % " · ".join(tags_text)

	return {
		"name": "%s [%s]" % [str(data.get("name", gongfa_id)), _quality_to_cn(str(data.get("quality", "white")))],
		"type_line": "%s · %s · %s" % [
			_slot_to_cn(str(data.get("type", ""))),
			_element_to_cn(str(data.get("element", "none"))),
			_faction_to_cn(str(data.get("faction", "jianghu")))
		],
		"desc": str(data.get("description", "无描述")),
		"effects": effects,
		"has_skill": has_skill,
		"skill_trigger": skill_trigger,
		"skill_effects": skill_effects,
		"linkage_tags": linkage_tags
	}


func _build_equip_item_tooltip_data(equip_id: String) -> Dictionary:
	var data: Dictionary = _equip_data_map.get(equip_id, {})
	if data.is_empty():
		return {
			"name": equip_id,
			"type_line": "装备",
			"desc": "未找到装备数据",
			"effects": [],
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": [],
			"linkage_tags": "联动标签：无"
		}
	var effect_lines: Array[String] = []
	var stats: Variant = data.get("stats", {})
	if stats is Dictionary:
		for key in (stats as Dictionary).keys():
			effect_lines.append("%s %+d" % [_stat_key_to_cn(str(key)), int(round(float((stats as Dictionary).get(key, 0.0))))])
	var passive: String = str(data.get("passive", "")).strip_edges()
	if not passive.is_empty():
		effect_lines.append("被动：%s" % passive)
	return {
		"name": "%s [%s]" % [str(data.get("name", equip_id)), _quality_to_cn(str(data.get("rarity", "white")))],
		"type_line": "%s · %s" % [_equip_type_to_cn(str(data.get("type", "weapon"))), _element_to_cn(str(data.get("element", "none")))],
		"desc": str(data.get("description", "江湖器物")),
		"effects": effect_lines,
		"has_skill": false,
		"skill_trigger": "",
		"skill_effects": [],
		"linkage_tags": "联动标签：无"
	}


func _format_effect_op(effect: Dictionary) -> String:
	var op: String = str(effect.get("op", ""))
	match op:
		"stat_add":
			return "%s %+d" % [_stat_key_to_cn(str(effect.get("stat", ""))), int(round(float(effect.get("value", 0.0))))]
		"stat_percent":
			return "%s %+d%%" % [_stat_key_to_cn(str(effect.get("stat", ""))), int(round(float(effect.get("value", 0.0)) * 100.0))]
		"mp_regen_add":
			return "内力回复 +%s/秒" % str(effect.get("value", 0))
		"dodge_bonus":
			return "闪避率 +%d%%" % int(round(float(effect.get("value", 0.0)) * 100.0))
		"crit_bonus":
			return "暴击率 +%d%%" % int(round(float(effect.get("value", 0.0)) * 100.0))
		"crit_damage_bonus":
			return "暴击伤害 +%d%%" % int(round(float(effect.get("value", 0.0)) * 100.0))
		"damage_reduce_percent":
			return "受伤减免 %d%%" % int(round(float(effect.get("value", 0.0)) * 100.0))
		"heal_self_percent":
			return "回复自身 %d%% 最大生命" % int(round(float(effect.get("value", 0.0)) * 100.0))
		"heal_self":
			return "回复生命 %d" % int(round(float(effect.get("value", 0.0))))
		"damage_target":
			return "对目标造成 %d 点%s伤害" % [
				int(round(float(effect.get("value", 0.0)))),
				_damage_type_to_cn(str(effect.get("damage_type", "external")))
			]
		"damage_aoe":
			return "对周围%d格造成%d点%s伤害" % [
				int(effect.get("radius", 0)),
				int(round(float(effect.get("value", 0.0)))),
				_damage_type_to_cn(str(effect.get("damage_type", "external")))
			]
		"buff_self":
			var buff_id: String = str(effect.get("buff_id", ""))
			var buff_name: String = _buff_name_from_id(buff_id)
			return "获得「%s」(%.1f秒)" % [buff_name, float(effect.get("duration", 0.0))]
		"buff_allies_aoe":
			return "为范围友方施加「%s」" % _buff_name_from_id(str(effect.get("buff_id", "")))
		"debuff_target":
			return "施加减益「%s」(%.1f秒)" % [_buff_name_from_id(str(effect.get("buff_id", ""))), float(effect.get("duration", 0.0))]
		"spawn_vfx":
			return "触发特效 %s" % str(effect.get("vfx_id", ""))
		_:
			return "%s %s" % [op, str(effect)]


func _trigger_to_cn(trigger: String) -> String:
	match trigger:
		"auto_mp_full":
			return "内力满时自动释放"
		"auto_hp_below":
			return "生命低于阈值时自动释放"
		"on_attack_hit":
			return "普攻命中时概率触发"
		"on_attacked":
			return "受击时概率触发"
		"on_kill":
			return "击杀时触发"
		"on_ally_death":
			return "友方死亡时触发"
		"on_combat_start":
			return "战斗开始时触发"
		"passive_aura":
			return "持续光环"
		_:
			return trigger


func _damage_type_to_cn(damage_type: String) -> String:
	match damage_type:
		"internal":
			return "内功"
		"external":
			return "外功"
		"reflect":
			return "反伤"
		_:
			return damage_type


func _buff_name_from_id(buff_id: String) -> String:
	if _buff_data_map.has(buff_id):
		return str((_buff_data_map[buff_id] as Dictionary).get("name", buff_id))
	return buff_id


func _get_unit_equip_slots(unit: Node) -> Dictionary:
	# 目前装备系统未落地，优先读取运行时 meta；不存在则生成 3 槽默认值。
	if unit != null and unit.has_meta("m3_equip_slots"):
		var raw: Variant = unit.get_meta("m3_equip_slots")
		if raw is Dictionary:
			return raw
	return {"weapon": "", "armor": "", "accessory": ""}


func _normalize_equip_slots(raw: Variant) -> Dictionary:
	var slots: Dictionary = {"weapon": "", "armor": "", "accessory": ""}
	if raw is Dictionary:
		for key in slots.keys():
			slots[key] = str((raw as Dictionary).get(key, "")).strip_edges()
	return slots


func _equip_name_or_empty(equip_id: String) -> String:
	if equip_id.is_empty():
		return "空"
	if _equip_data_map.has(equip_id):
		return str((_equip_data_map[equip_id] as Dictionary).get("name", equip_id))
	return equip_id


func _position_tooltip(screen_pos: Vector2) -> void:
	unit_tooltip.reset_size()
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var desired: Vector2 = screen_pos + Vector2(16.0, 16.0)
	var tooltip_size: Vector2 = unit_tooltip.size
	if desired.x + tooltip_size.x > viewport_size.x - 8.0:
		desired.x = screen_pos.x - tooltip_size.x - 16.0
	if desired.y + tooltip_size.y > viewport_size.y - 8.0:
		desired.y = screen_pos.y - tooltip_size.y - 16.0
	desired.x = clampf(desired.x, 8.0, viewport_size.x - tooltip_size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - tooltip_size.y - 8.0)
	unit_tooltip.position = desired
	unit_tooltip.visible = true


func _resolve_unit_status(unit: Node) -> String:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null and not bool(combat.get("is_alive")):
		return "已阵亡"
	if bool(unit.get("is_in_combat")):
		return "战斗中"
	if bool(unit.get("is_on_bench")):
		return "备战席"
	return "待命"


func _format_stat_pair(cn_name: String, runtime_stats: Dictionary, base_stats: Dictionary, key: String) -> String:
	var runtime_value: float = float(runtime_stats.get(key, 0.0))
	var base_value: float = float(base_stats.get(key, 0.0))
	var bonus: float = runtime_value - base_value
	if absf(bonus) <= 0.001:
		return "%s %d" % [cn_name, int(round(runtime_value))]
	var sign: String = "+" if bonus > 0.0 else ""
	return "%s %d (%s%d)" % [cn_name, int(round(runtime_value)), sign, int(round(bonus))]


func _normalize_unit_slots(raw: Variant) -> Dictionary:
	var slots: Dictionary = {
		"neigong": "",
		"waigong": "",
		"qinggong": "",
		"zhenfa": "",
		"qishu": ""
	}
	if raw is Dictionary:
		for key in slots.keys():
			slots[key] = str((raw as Dictionary).get(key, "")).strip_edges()
	return slots


func _gongfa_name_or_empty(gongfa_id: String) -> String:
	if gongfa_id.is_empty():
		return "空"
	if gongfa_manager == null:
		return gongfa_id
	var data: Dictionary = gongfa_manager.call("get_gongfa_data", gongfa_id)
	return str(data.get("name", gongfa_id))


func _slot_to_cn(slot: String) -> String:
	match slot:
		"neigong":
			return "内功"
		"waigong":
			return "外功"
		"qinggong":
			return "轻功"
		"zhenfa":
			return "阵法"
		"qishu":
			return "奇术"
		_:
			return slot


func _slot_icon(slot: String) -> String:
	match slot:
		"neigong":
			return "📖"
		"waigong":
			return "⚔"
		"qinggong":
			return "🏃"
		"zhenfa":
			return "🔷"
		"qishu":
			return "✨"
		_:
			return "•"


func _equip_type_to_cn(equip_type: String) -> String:
	match equip_type:
		"weapon":
			return "兵器"
		"armor":
			return "护甲"
		"accessory":
			return "饰品"
		_:
			return equip_type


func _equip_icon(equip_type: String) -> String:
	match equip_type:
		"weapon":
			return "🗡"
		"armor":
			return "🛡"
		"accessory":
			return "💎"
		_:
			return "•"


func _element_to_cn(element: String) -> String:
	match element:
		"metal":
			return "金"
		"wood":
			return "木"
		"water":
			return "水"
		"fire":
			return "火"
		"earth":
			return "土"
		_:
			return "无"


func _faction_to_cn(faction: String) -> String:
	match faction:
		"wudang":
			return "武当"
		"shaolin":
			return "少林"
		"emei":
			return "峨眉"
		"gaibang":
			return "丐帮"
		"xiaoyao":
			return "逍遥"
		"mingjiao":
			return "明教"
		"xingxiu":
			return "星宿"
		_:
			return faction


func _quality_to_cn(quality: String) -> String:
	match quality:
		"white":
			return "白"
		"green":
			return "绿"
		"blue":
			return "蓝"
		"purple":
			return "紫"
		"orange":
			return "橙"
		"red":
			return "红"
		_:
			return quality


func _stat_key_to_cn(stat_key: String) -> String:
	match stat_key:
		"hp":
			return "生命"
		"mp":
			return "内力"
		"atk":
			return "外功"
		"def":
			return "外防"
		"iat":
			return "内功"
		"idr":
			return "内防"
		"spd":
			return "速度"
		"rng":
			return "射程"
		_:
			return stat_key


func _faction_color(faction: String) -> Color:
	match faction:
		"wudang":
			return Color(0.46, 0.66, 0.96, 1.0)
		"shaolin":
			return Color(0.88, 0.66, 0.24, 1.0)
		"emei":
			return Color(0.84, 0.58, 0.9, 1.0)
		"gaibang":
			return Color(0.66, 0.84, 0.42, 1.0)
		"xiaoyao":
			return Color(0.52, 0.82, 0.9, 1.0)
		"mingjiao":
			return Color(0.92, 0.44, 0.44, 1.0)
		_:
			return Color(0.65, 0.65, 0.68, 1.0)
