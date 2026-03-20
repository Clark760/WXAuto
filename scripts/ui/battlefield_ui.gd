extends "res://scripts/battle/battlefield_runtime.gd"

# ===========================
# 战场 UI 层
# ===========================
# 设计目标：
# 1. 承接战场展示、Tooltip、详情面板、库存面板与战斗日志。
# 2. 与基础战斗运行层分离，避免把大量 UI 逻辑塞回战场核心。
# 3. 保持输入交互与显示刷新集中在一层维护。

const SLOT_ORDER: Array[String] = ["neigong", "waigong", "qinggong", "zhenfa", "qishu"]
const EQUIP_ORDER: Array[String] = ["weapon", "armor", "accessory"]
const CLICK_DRAG_THRESHOLD: float = 8.0
const INVENTORY_PANEL_WIDTH: float = 260.0
const LEFT_PANEL_WIDTH: float = 180.0
const TOP_BAR_HEIGHT: float = 56.0
const DETAIL_DEFAULT_WIDTH: float = 720.0
const DETAIL_DEFAULT_HEIGHT: float = 520.0
const BATTLE_LOG_MAX_LINES: int = 50
const BATTLE_LOG_FLUSH_INTERVAL: float = 0.12

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
@onready var detail_drag_handle: HBoxContainer = $DetailLayer/UnitDetailPanel/DetailMargin/DetailRoot/HeaderRow
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

var _inventory_card_script: Script = load("res://scripts/ui/battle_inventory_item_card.gd")
var _slot_drop_target_script: Script = load("res://scripts/ui/battle_slot_drop_target.gd")

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
var _buff_data_map: Dictionary = {}
var _item_hover_source: Control = null
var _item_hover_data: Dictionary = {}
var _item_hover_timer: float = 0.0
var _item_fade_timer: float = 0.0
var _gongfa_slot_rows: Array[PanelContainer] = []
var _gongfa_slot_name_buttons: Array[LinkButton] = []
var _gongfa_slot_swap_buttons: Array[Button] = []
var _equip_slot_rows: Array[PanelContainer] = []
var _equip_slot_name_buttons: Array[LinkButton] = []
var _equip_slot_swap_buttons: Array[Button] = []
var _tooltip_gongfa_rows: Array[PanelContainer] = []
var _tooltip_gongfa_links: Array[LinkButton] = []
var _inventory_panel: PanelContainer = null
var _inventory_title: Label = null
var _inventory_filter_row: HBoxContainer = null
var _inventory_search: LineEdit = null
var _inventory_grid: VBoxContainer = null
var _inventory_summary: Label = null
var _inventory_tab_gongfa_btn: Button = null
var _inventory_tab_equip_btn: Button = null
var _inventory_mode: String = ""
var _inventory_filter_type: String = "all"
var _inventory_drag_enabled: bool = true

var _battle_log_panel: PanelContainer = null
var _battle_log_text: RichTextLabel = null
var _battle_log_entries: Array[String] = []
var _battle_log_dirty: bool = false
var _battle_log_flush_accum: float = 0.0
var _battle_log_last_flushed_count: int = 0
var _battle_log_requires_rebuild: bool = false

var _is_dragging_detail_panel: bool = false
var _detail_drag_offset: Vector2 = Vector2.ZERO


func _ready() -> void:
	super._ready()
	if gongfa_button != null:
		gongfa_button.visible = false
		gongfa_button.disabled = true
	if equip_button != null:
		equip_button.visible = false
		equip_button.disabled = true
	_reparent_tooltips_to_high_layer()
	_hide_legacy_tooltip_nodes()
	_connect_ui_signals()
	_prune_verbose_battle_log_signals()
	_build_gongfa_type_cache()
	_reload_external_item_data()
	_ensure_battle_log_panel()
	_layout_detail_panel()
	_ensure_inventory_panel_created()
	_layout_left_side_panels()
	_layout_inventory_panel()
	_apply_stage_ui_state()
	if unit_detail_mask != null:
		unit_detail_mask.visible = false
		unit_detail_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	# UI 交互规则：
	# 1. 备战席“短按”打开详情。
	# 2. 备战席“移动超过阈值”才开始拖拽，避免点击和拖放冲突。
	# 3. 战场单位保持拖拽与点击打开详情并存。
	# 4. 右侧常驻仓库优先处理鼠标，不应透传到战场。
	if _inventory_panel != null and _inventory_panel.visible:
		if event is InputEventMouseButton:
			var inv_btn: InputEventMouseButton = event as InputEventMouseButton
			if _inventory_panel.get_global_rect().has_point(inv_btn.position):
				return
		elif event is InputEventMouseMotion:
			var inv_motion: InputEventMouseMotion = event as InputEventMouseMotion
			if _inventory_panel.get_global_rect().has_point(inv_motion.position):
				return

	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		# 备战区滚轮优先：在备战区内滚动时，先驱动列表滚动，避免触发地图缩放。
		if _consume_bench_wheel_input(mouse_button):
			get_viewport().set_input_as_handled()
			return
		if mouse_button.button_index == MOUSE_BUTTON_LEFT and not mouse_button.pressed:
			_is_dragging_detail_panel = false

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
	_update_battle_log_view(delta)
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
	# UI 层复用统一重开入口，方便反复验证拖拽、详情和日志。
	if event.pressed and not event.echo and event.keycode == KEY_F7:
		var event_bus: Node = _get_root_node("EventBus")
		if event_bus != null:
			event_bus.call("emit_scene_change_requested", "res://scenes/battle/battlefield.tscn")
		return
	super._handle_key_input(event)


func _on_viewport_size_changed() -> void:
	super._on_viewport_size_changed()
	_layout_left_side_panels()
	_layout_detail_panel()
	_layout_inventory_panel()


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


func _connect_ui_signals() -> void:
	var close_cb: Callable = Callable(self, "_on_detail_close_pressed")
	if not detail_close_button.is_connected("pressed", close_cb):
		detail_close_button.connect("pressed", close_cb)

	var drag_cb: Callable = Callable(self, "_on_detail_drag_handle_gui_input")
	if detail_drag_handle != null and not detail_drag_handle.is_connected("gui_input", drag_cb):
		detail_drag_handle.connect("gui_input", drag_cb)

	if gongfa_manager == null:
		return
	var reload_cb: Callable = Callable(self, "_on_gongfa_data_reloaded")
	if gongfa_manager.has_signal("gongfa_data_reloaded") and not gongfa_manager.is_connected("gongfa_data_reloaded", reload_cb):
		gongfa_manager.connect("gongfa_data_reloaded", reload_cb)
	var skill_cb: Callable = Callable(self, "_on_skill_triggered_for_log")
	if gongfa_manager.has_signal("skill_triggered") and not gongfa_manager.is_connected("skill_triggered", skill_cb):
		gongfa_manager.connect("skill_triggered", skill_cb)
	var skill_damage_cb: Callable = Callable(self, "_on_skill_effect_damage_for_log")
	if gongfa_manager.has_signal("skill_effect_damage") and not gongfa_manager.is_connected("skill_effect_damage", skill_damage_cb):
		gongfa_manager.connect("skill_effect_damage", skill_damage_cb)
	var buff_event_cb: Callable = Callable(self, "_on_buff_event_for_log")
	if gongfa_manager.has_signal("buff_event") and not gongfa_manager.is_connected("buff_event", buff_event_cb):
		gongfa_manager.connect("buff_event", buff_event_cb)

	var event_bus: Node = _get_root_node("EventBus")
	if event_bus != null:
		var data_reload_cb: Callable = Callable(self, "_on_data_reloaded")
		if event_bus.has_signal("data_reloaded") and not event_bus.is_connected("data_reloaded", data_reload_cb):
			event_bus.connect("data_reloaded", data_reload_cb)


func _prune_verbose_battle_log_signals() -> void:
	if combat_manager != null:
		var damage_cb: Callable = Callable(self, "_on_damage_resolved")
		if combat_manager.has_signal("damage_resolved") and combat_manager.is_connected("damage_resolved", damage_cb):
			combat_manager.disconnect("damage_resolved", damage_cb)
	if gongfa_manager != null:
		var skill_damage_cb: Callable = Callable(self, "_on_skill_effect_damage_for_log")
		if gongfa_manager.has_signal("skill_effect_damage") and gongfa_manager.is_connected("skill_effect_damage", skill_damage_cb):
			gongfa_manager.disconnect("skill_effect_damage", skill_damage_cb)
		var buff_event_cb: Callable = Callable(self, "_on_buff_event_for_log")
		if gongfa_manager.has_signal("buff_event") and gongfa_manager.is_connected("buff_event", buff_event_cb):
			gongfa_manager.disconnect("buff_event", buff_event_cb)


func _on_gongfa_data_reloaded(_summary: Dictionary) -> void:
	_build_gongfa_type_cache()
	_reload_external_item_data()
	if _inventory_panel != null and _inventory_panel.visible:
		_rebuild_inventory_items()
	if unit_detail_panel.visible and _detail_unit != null and _is_valid_unit(_detail_unit):
		_update_detail_panel(_detail_unit)


func _on_data_reloaded(_is_full_reload: bool, _summary: Dictionary) -> void:
	_reload_external_item_data()
	if _inventory_panel != null and _inventory_panel.visible:
		_rebuild_inventory_items()


func _refresh_all_ui() -> void:
	super._refresh_all_ui()
	if _inventory_panel != null and _inventory_panel.visible:
		_rebuild_inventory_items()
	_layout_left_side_panels()
	_layout_inventory_panel()


func _set_stage(next_stage: int) -> void:
	var previous_stage: int = _stage
	super._set_stage(next_stage)
	if previous_stage != Stage.COMBAT and next_stage == Stage.COMBAT:
		_clear_battle_log()
	elif next_stage == Stage.RESULT:
		_flush_battle_log(true)
	_apply_stage_ui_state()


func _apply_stage_ui_state() -> void:
	# 按正式战场 UI 规则控制各区域显隐与交互能力。
	if _inventory_panel != null and is_instance_valid(_inventory_panel):
		match _stage:
			Stage.PREPARATION:
				_inventory_panel.visible = true
				_inventory_panel.modulate = Color(1, 1, 1, 1)
				_inventory_drag_enabled = true
			Stage.COMBAT:
				_inventory_panel.visible = true
				_inventory_panel.modulate = Color(1, 1, 1, 0.4)
				_inventory_drag_enabled = false
			_:
				_inventory_panel.visible = false
				_inventory_drag_enabled = false
		if _inventory_panel.visible:
			_rebuild_inventory_items()
	if _battle_log_panel != null and is_instance_valid(_battle_log_panel):
		_battle_log_panel.visible = _stage == Stage.COMBAT or _stage == Stage.RESULT
	if linkage_info != null:
		var linkage_parent: Control = linkage_info.get_parent().get_parent() as Control
		if linkage_parent != null:
			linkage_parent.visible = _stage != Stage.RESULT
	if _stage != Stage.PREPARATION:
		_close_detail_panel(false)
	if _stage == Stage.RESULT:
		if unit_tooltip != null:
			unit_tooltip.visible = false
		if item_tooltip != null:
			item_tooltip.visible = false


func _append_battle_log(line: String, event_type: String = "info") -> void:
	if line.strip_edges().is_empty():
		return
	var color_hex: String = _battle_log_color_hex(event_type)
	_battle_log_entries.append("[color=%s]%s[/color]" % [color_hex, line])
	while _battle_log_entries.size() > BATTLE_LOG_MAX_LINES:
		_battle_log_entries.remove_at(0)
		_battle_log_requires_rebuild = true
	_battle_log_dirty = true
	if _stage != Stage.COMBAT:
		_flush_battle_log(true)


func _update_battle_log_view(delta: float) -> void:
	if not _battle_log_dirty:
		return
	_battle_log_flush_accum += delta
	if _battle_log_flush_accum < BATTLE_LOG_FLUSH_INTERVAL:
		return
	_flush_battle_log(true)


func _flush_battle_log(scroll_to_bottom: bool) -> void:
	if _battle_log_text == null or not is_instance_valid(_battle_log_text):
		return
	if _battle_log_requires_rebuild or _battle_log_last_flushed_count > _battle_log_entries.size():
		_battle_log_text.clear()
		if not _battle_log_entries.is_empty():
			_battle_log_text.append_text("\n".join(_battle_log_entries))
		_battle_log_last_flushed_count = _battle_log_entries.size()
		_battle_log_requires_rebuild = false
	else:
		for i in range(_battle_log_last_flushed_count, _battle_log_entries.size()):
			_battle_log_text.append_text("%s\n" % _battle_log_entries[i])
		_battle_log_last_flushed_count = _battle_log_entries.size()
	if scroll_to_bottom and _battle_log_panel != null and _battle_log_panel.visible:
		_battle_log_text.scroll_to_line(_battle_log_text.get_line_count())
	_battle_log_dirty = false
	_battle_log_flush_accum = 0.0


func _clear_battle_log() -> void:
	_battle_log_entries.clear()
	_battle_log_last_flushed_count = 0
	_battle_log_requires_rebuild = true
	_battle_log_dirty = false
	if _battle_log_text != null and is_instance_valid(_battle_log_text):
		_battle_log_text.clear()
	_battle_log_flush_accum = 0.0


func _on_damage_resolved(_event_dict: Dictionary) -> void:
	super._on_damage_resolved(_event_dict)
	return


func _on_unit_died(dead_unit: Node, killer: Node, team_id: int) -> void:
	super._on_unit_died(dead_unit, killer, team_id)
	var dead_name: String = str(_safe_node_prop(dead_unit, "unit_name", "未知")) if dead_unit != null else "未知"
	var killer_name: String = str(_safe_node_prop(killer, "unit_name", "未知")) if killer != null else "未知"
	_append_battle_log("%s 被 %s 击败" % [dead_name, killer_name], "death")


func _on_battle_ended(winner_team: int, summary: Dictionary) -> void:
	super._on_battle_ended(winner_team, summary)


func _on_skill_triggered_for_log(unit: Node, gongfa_id: String, trigger: String) -> void:
	if _stage != Stage.COMBAT:
		return
	var team_id: int = int(_safe_node_prop(unit, "team_id", 0)) if unit != null and is_instance_valid(unit) else 0
	var unit_name: String = str(_safe_node_prop(unit, "unit_name", "未知")) if unit != null else "未知"
	var gongfa_name: String = _resolve_gongfa_name(gongfa_id)
	_append_battle_log(
		"%s 触发「%s」(%s)" % [
			_format_name_with_team(unit_name, team_id),
			gongfa_name,
			_trigger_to_cn(trigger)
		],
		"skill"
	)


func _on_skill_effect_damage_for_log(_event_dict: Dictionary) -> void:
	return


func _on_buff_event_for_log(_event_dict: Dictionary) -> void:
	return


func _battle_log_color_hex(event_type: String) -> String:
	# 日志颜色规范：
	# - damage: 普通伤害事件（暖色）
	# - skill: 技能/触发事件（青色）
	# - buff: Buff 施加/触发（青绿色）
	# - death: 击杀与死亡事件（红色）
	# - system/info: 系统提示（浅灰）
	match event_type:
		"damage":
			return "#FFC38A"
		"skill":
			return "#87D7FF"
		"buff":
			return "#7DE3C0"
		"death":
			return "#FF8A8A"
		"system":
			return "#B0F0B0"
		_:
			return "#D6D6D6"


func _ensure_battle_log_panel() -> void:
	if _battle_log_panel != null and is_instance_valid(_battle_log_panel):
		return
	_battle_log_panel = PanelContainer.new()
	_battle_log_panel.name = "BattleLogPanel"
	$HUDLayer.add_child(_battle_log_panel)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_battle_log_panel.add_child(root)
	var title := Label.new()
	title.text = "战斗日志"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_battle_log_text = RichTextLabel.new()
	_battle_log_text.bbcode_enabled = true
	_battle_log_text.fit_content = false
	_battle_log_text.scroll_active = true
	_battle_log_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_battle_log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(_battle_log_text)


func _ensure_inventory_panel_created() -> void:
	# 右侧常驻功法/装备区。
	if _inventory_panel != null and is_instance_valid(_inventory_panel):
		return

	# 修复拖放跨层失效：
	# 1. 仓库与详情槽位必须位于同一 CanvasLayer，Godot 原生拖放才会生效。
	# 2. 优先挂到场景已有的 DetailLayer；仅在缺失时创建容错层（layer=20）。
	var detail_layer_node: Node = get_node_or_null("DetailLayer")
	if detail_layer_node == null:
		var fallback_layer: Node = get_node_or_null("RightPanelLayer")
		if fallback_layer == null:
			var created_layer := CanvasLayer.new()
			created_layer.layer = 20
			created_layer.name = "RightPanelLayer"
			add_child(created_layer)
			detail_layer_node = created_layer
		else:
			detail_layer_node = fallback_layer

	_inventory_panel = PanelContainer.new()
	_inventory_panel.name = "InventoryPanel"
	_inventory_panel.visible = true
	_inventory_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# 仓库面板渲染在详情面板下方，避免遮挡详情交互区域。
	_inventory_panel.z_index = -1
	detail_layer_node.add_child(_inventory_panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_theme_constant_override("separation", 8)
	_inventory_panel.add_child(root_vbox)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", 8)
	root_vbox.add_child(header)

	_inventory_tab_gongfa_btn = Button.new()
	_inventory_tab_gongfa_btn.text = "功法"
	_inventory_tab_gongfa_btn.toggle_mode = true
	_inventory_tab_gongfa_btn.button_pressed = true
	_inventory_tab_gongfa_btn.pressed.connect(Callable(self, "_on_inventory_tab_pressed").bind("gongfa"))
	header.add_child(_inventory_tab_gongfa_btn)

	_inventory_tab_equip_btn = Button.new()
	_inventory_tab_equip_btn.text = "装备"
	_inventory_tab_equip_btn.toggle_mode = true
	_inventory_tab_equip_btn.button_pressed = false
	_inventory_tab_equip_btn.pressed.connect(Callable(self, "_on_inventory_tab_pressed").bind("equipment"))
	header.add_child(_inventory_tab_equip_btn)

	_inventory_title = Label.new()
	_inventory_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inventory_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_inventory_title.text = "功法装备区"
	header.add_child(_inventory_title)

	_inventory_filter_row = HBoxContainer.new()
	_inventory_filter_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inventory_filter_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(_inventory_filter_row)

	_inventory_search = LineEdit.new()
	_inventory_search.placeholder_text = "搜索名称..."
	_inventory_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inventory_search.text_changed.connect(Callable(self, "_on_inventory_search_changed"))
	root_vbox.add_child(_inventory_search)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.clip_contents = true
	root_vbox.add_child(scroll)

	# 仓库改为单列纵向列表，避免窄宽度下的多列裁切与滚动遮挡。
	_inventory_grid = VBoxContainer.new()
	_inventory_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inventory_grid.add_theme_constant_override("separation", 8)
	scroll.add_child(_inventory_grid)

	var footer := HBoxContainer.new()
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(footer)

	_inventory_summary = Label.new()
	_inventory_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inventory_summary.text = "共 0 件 | 已装备 0 件"
	footer.add_child(_inventory_summary)

	_inventory_mode = "gongfa"
	_inventory_filter_type = "all"
	_rebuild_inventory_filters()
	_rebuild_inventory_items()
	_layout_inventory_panel()


func _layout_inventory_panel() -> void:
	if _inventory_panel == null or not is_instance_valid(_inventory_panel):
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var bottom_top: float = bottom_panel.position.y if bottom_panel != null else viewport_size.y - 230.0
	var width: float = INVENTORY_PANEL_WIDTH
	var top: float = TOP_BAR_HEIGHT + 8.0
	var height: float = maxf(bottom_top - top - 8.0, 180.0)
	var left: float = viewport_size.x - width - 12.0
	_inventory_panel.position = Vector2(left, top)
	_inventory_panel.size = Vector2(width, height)


func _layout_left_side_panels() -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var top: float = TOP_BAR_HEIGHT + 8.0
	var x: float = 12.0
	var minimap_h: float = 170.0
	if minimap_info != null:
		var minimap: Control = minimap_info.get_parent() as Control
		if minimap != null:
			minimap.position = Vector2(x, top)
			minimap.size = Vector2(LEFT_PANEL_WIDTH, minimap_h)
	if _battle_log_panel != null and is_instance_valid(_battle_log_panel):
		var bottom_top: float = bottom_panel.position.y if bottom_panel != null else viewport_size.y - 230.0
		var log_top: float = top + minimap_h + 10.0
		var linkage_height: float = 96.0
		_battle_log_panel.position = Vector2(x, log_top)
		_battle_log_panel.size = Vector2(LEFT_PANEL_WIDTH, maxf(bottom_top - log_top - linkage_height - 12.0, 120.0))
		var linkage_panel: Control = null
		if linkage_info != null:
			linkage_panel = linkage_info.get_parent().get_parent() as Control
		if linkage_panel != null:
			linkage_panel.position = Vector2(x, bottom_top - linkage_height - 8.0)
			linkage_panel.size = Vector2(LEFT_PANEL_WIDTH, linkage_height)


func _refit_hex_grid() -> void:
	# 重新定义棋盘可用区域：扣除左侧信息区和右侧仓库区，避免 UI 与棋盘重叠。
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return
	var bottom_reserved: float = bottom_reserved_preparation if _bottom_expanded else bottom_reserved_collapsed
	var left_reserved: float = LEFT_PANEL_WIDTH + 28.0
	var right_reserved: float = INVENTORY_PANEL_WIDTH + 20.0
	var available_w: float = maxf(viewport_size.x - left_reserved - right_reserved - board_margin, 280.0)
	var available_h: float = maxf(viewport_size.y - top_reserved_height - bottom_reserved - board_margin, 180.0)
	var fit_hex: float = _calculate_fit_hex_size(available_w, available_h)
	hex_grid.hex_size = fit_hex
	var board_size: Vector2 = _calculate_board_pixel_size(fit_hex)
	hex_grid.origin_offset = Vector2(
		left_reserved + (available_w - board_size.x) * 0.5 + fit_hex * 0.8660254,
		top_reserved_height + (available_h - board_size.y) * 0.5 + fit_hex
	)
	hex_grid.queue_redraw()
	deploy_overlay.queue_redraw()
	_unit_scale_factor = clampf((fit_hex * 1.52) / 32.0, 0.42, 1.10)
	_apply_visual_to_all_units()


func _on_inventory_tab_pressed(mode: String) -> void:
	if gongfa_manager == null:
		return
	_inventory_mode = mode
	_inventory_filter_type = "all"
	if _inventory_search != null:
		_inventory_search.text = ""
	if _inventory_tab_gongfa_btn != null:
		_inventory_tab_gongfa_btn.button_pressed = mode == "gongfa"
	if _inventory_tab_equip_btn != null:
		_inventory_tab_equip_btn.button_pressed = mode == "equipment"
	if _inventory_title != null:
		_inventory_title.text = "功法装备区·功法" if mode == "gongfa" else "功法装备区·装备"
	_rebuild_inventory_filters()
	_rebuild_inventory_items()


func _rebuild_inventory_filters() -> void:
	if _inventory_filter_row == null:
		return
	for child in _inventory_filter_row.get_children():
		child.queue_free()

	var filters: Array[Dictionary] = []
	if _inventory_mode == "gongfa":
		filters = [
			{"id": "all", "name": "全部"},
			{"id": "neigong", "name": "内功"},
			{"id": "waigong", "name": "外功"},
			{"id": "qinggong", "name": "轻功"},
			{"id": "zhenfa", "name": "阵法"},
			{"id": "qishu", "name": "奇术"}
		]
	else:
		filters = [
			{"id": "all", "name": "全部"},
			{"id": "weapon", "name": "兵器"},
			{"id": "armor", "name": "护甲"},
			{"id": "accessory", "name": "饰品"}
		]

	for filter_data in filters:
		var filter_id: String = str(filter_data.get("id", "all"))
		var btn := Button.new()
		btn.text = str(filter_data.get("name", filter_id))
		btn.toggle_mode = true
		btn.button_pressed = filter_id == _inventory_filter_type
		btn.pressed.connect(Callable(self, "_on_inventory_filter_pressed").bind(filter_id))
		_inventory_filter_row.add_child(btn)


func _on_inventory_filter_pressed(filter_id: String) -> void:
	_inventory_filter_type = filter_id
	_rebuild_inventory_filters()
	_rebuild_inventory_items()


func _on_inventory_search_changed(_new_text: String) -> void:
	_rebuild_inventory_items()


func _rebuild_inventory_items() -> void:
	if _inventory_grid == null or gongfa_manager == null:
		return

	for child in _inventory_grid.get_children():
		child.queue_free()

	var source_items: Variant = []
	if _inventory_mode == "gongfa":
		source_items = gongfa_manager.call("get_all_gongfa")
	else:
		source_items = gongfa_manager.call("get_all_equipment")
	if not (source_items is Array):
		_inventory_summary.text = "共 0 件 | 已装备 0 件"
		return

	var items: Array[Dictionary] = []
	for value in source_items:
		if value is Dictionary:
			items.append((value as Dictionary).duplicate(true))
	items.sort_custom(Callable(self, "_sort_inventory_item"))

	var search_text: String = _inventory_search.text.strip_edges().to_lower()
	var filtered: Array[Dictionary] = []
	for item_data in items:
		var item_type: String = str(item_data.get("type", "")).strip_edges()
		if _inventory_filter_type != "all" and item_type != _inventory_filter_type:
			continue
		if not search_text.is_empty():
			var item_name: String = str(item_data.get("name", "")).to_lower()
			if not item_name.contains(search_text):
				continue
		filtered.append(item_data)

	var equipped_count: int = 0
	for item_data in filtered:
		var card: PanelContainer = _create_inventory_card(item_data)
		_inventory_grid.add_child(card)
		var equipped_info: Dictionary = _find_equipped_info(str(item_data.get("id", "")))
		if not equipped_info.is_empty():
			equipped_count += 1

	_inventory_summary.text = "共 %d 件 | 已装备 %d 件" % [filtered.size(), equipped_count]


func _sort_inventory_item(a: Dictionary, b: Dictionary) -> bool:
	var rarity_a: String = str(a.get("rarity", a.get("quality", "white")))
	var rarity_b: String = str(b.get("rarity", b.get("quality", "white")))
	var rank_a: int = _quality_rank(rarity_a)
	var rank_b: int = _quality_rank(rarity_b)
	if rank_a != rank_b:
		return rank_a > rank_b
	return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0


func _quality_rank(quality: String) -> int:
	match quality:
		"red":
			return 6
		"orange":
			return 5
		"purple":
			return 4
		"blue":
			return 3
		"green":
			return 2
		_:
			return 1


func _create_inventory_card(item_data: Dictionary) -> PanelContainer:
	var card := _inventory_card_script.new() as PanelContainer
	if card == null:
		card = PanelContainer.new()
	card.custom_minimum_size = Vector2(160, 112)
	card.mouse_filter = Control.MOUSE_FILTER_STOP

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)

	var icon_label := Label.new()
	var item_type: String = str(item_data.get("type", ""))
	icon_label.text = _slot_icon(item_type) if _inventory_mode == "gongfa" else _equip_icon(item_type)
	vbox.add_child(icon_label)

	var name_label := Label.new()
	name_label.text = str(item_data.get("name", str(item_data.get("id", "未知"))))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(name_label)

	var type_line := Label.new()
	if _inventory_mode == "gongfa":
		type_line.text = "[%s] %s · %s" % [
			_quality_to_cn(str(item_data.get("quality", "white"))),
			_slot_to_cn(item_type),
			_element_to_cn(str(item_data.get("element", "none")))
		]
	else:
		type_line.text = "[%s] %s · %s" % [
			_quality_to_cn(str(item_data.get("rarity", "white"))),
			_equip_type_to_cn(item_type),
			_element_to_cn(str(item_data.get("element", "none")))
		]
	vbox.add_child(type_line)

	var item_id: String = str(item_data.get("id", "")).strip_edges()
	var equipped_info: Dictionary = _find_equipped_info(item_id)
	var status_label := Label.new()
	status_label.text = "空闲"
	if not equipped_info.is_empty():
		status_label.text = "已装备: %s" % str(equipped_info.get("unit_name", "未知"))
	vbox.add_child(status_label)

	var tooltip_payload: Dictionary = _build_gongfa_item_tooltip_data(item_id) if _inventory_mode == "gongfa" else _build_equip_item_tooltip_data(item_id)
	var drag_payload: Dictionary = {
		"type": _inventory_mode,
		"id": item_id,
		"item_data": item_data.duplicate(true),
		"slot_type": item_type
	}

	if card.has_method("setup_card"):
		card.call("setup_card", item_id, item_data, drag_payload, _inventory_drag_enabled)
		var click_cb: Callable = Callable(self, "_on_inventory_card_clicked")
		if card.has_signal("card_clicked") and not card.is_connected("card_clicked", click_cb):
			card.connect("card_clicked", click_cb)

	card.set_meta("item_id", item_id)
	card.set_meta("item_data", item_data.duplicate(true))
	card.set_meta("tooltip_data", tooltip_payload)
	card.mouse_entered.connect(Callable(self, "_on_item_source_hover_entered").bind(card, tooltip_payload))
	card.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(card))
	return card


func _on_inventory_card_clicked(item_id: String, _item_data: Dictionary) -> void:
	# 新交互以“拖放装备”为主，点击仅用于快速定位当前已装备单位。
	if item_id.is_empty():
		return
	var equipped_info: Dictionary = _find_equipped_info(item_id)
	if equipped_info.is_empty():
		return
	var unit: Node = equipped_info.get("unit", null)
	if unit != null and _is_valid_unit(unit):
		_open_detail_panel(unit)


func _equip_item_to_unit(unit: Node, item_id: String) -> bool:
	if unit == null or not _is_valid_unit(unit):
		return false
	if _inventory_mode == "gongfa":
		var gongfa_data: Dictionary = gongfa_manager.call("get_gongfa_data", item_id)
		if gongfa_data.is_empty():
			return false
		var slot: String = str(gongfa_data.get("type", "")).strip_edges()
		if slot.is_empty():
			return false
		return bool(gongfa_manager.call("equip_gongfa", unit, slot, item_id))
	var equip_data: Dictionary = gongfa_manager.call("get_equipment_data", item_id)
	if equip_data.is_empty():
		return false
	var equip_slot: String = str(equip_data.get("type", "")).strip_edges()
	if equip_slot.is_empty():
		return false
	return bool(gongfa_manager.call("equip_equipment", unit, equip_slot, item_id))


func _find_equipped_info(item_id: String) -> Dictionary:
	if item_id.is_empty():
		return {}
	for unit in _collect_player_units():
		if unit == null or not _is_valid_unit(unit):
			continue
		if _inventory_mode == "gongfa":
			var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
			for slot in SLOT_ORDER:
				if str(slots.get(slot, "")).strip_edges() == item_id:
					return {
						"unit": unit,
						"unit_name": str(unit.get("unit_name")),
						"slot": slot
					}
		else:
			var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(unit))
			for equip_slot in EQUIP_ORDER:
				if str(equip_slots.get(equip_slot, "")).strip_edges() == item_id:
					return {
						"unit": unit,
						"unit_name": str(unit.get("unit_name")),
						"slot": equip_slot
					}
	return {}


func _collect_player_units() -> Array[Node]:
	var out: Array[Node] = []
	var seen: Dictionary = {}
	if bench_ui != null:
		for unit in bench_ui.get_all_units():
			if _is_valid_unit(unit):
				var iid: int = unit.get_instance_id()
				if seen.has(iid):
					continue
				seen[iid] = true
				out.append(unit)
	for unit in _ally_deployed.values():
		if _is_valid_unit(unit):
			var iid2: int = unit.get_instance_id()
			if seen.has(iid2):
				continue
			seen[iid2] = true
			out.append(unit)
	return out


func _find_unit_name_by_instance_id(instance_id: int) -> String:
	if instance_id <= 0:
		return "未知"
	for unit in _collect_player_units():
		if unit != null and _is_valid_unit(unit) and unit.get_instance_id() == instance_id:
			return str(_safe_node_prop(unit, "unit_name", "未知"))
	for enemy in _enemy_deployed.values():
		if enemy != null and _is_valid_unit(enemy) and enemy.get_instance_id() == instance_id:
			return str(_safe_node_prop(enemy, "unit_name", "未知"))
	return "未知"


func _safe_node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value


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
	if _stage != Stage.PREPARATION:
		return
	var world_pos: Vector2 = _screen_to_world(screen_pos)
	var clicked_unit: Node = _pick_visible_unit_at_world(world_pos)
	if unit_detail_panel.visible:
		if unit_detail_panel.get_global_rect().has_point(screen_pos):
			return
		if clicked_unit != null and _is_valid_unit(clicked_unit):
			if clicked_unit == _detail_unit:
				_close_detail_panel(false)
			else:
				_open_detail_panel(clicked_unit)
		else:
			_close_detail_panel(false)
		return
	if clicked_unit != null and _is_valid_unit(clicked_unit):
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
	if _stage != Stage.PREPARATION:
		return
	if unit == null or not _is_valid_unit(unit):
		return
	_detail_unit = unit
	_detail_refresh_accum = 0.0
	_update_detail_panel(unit)
	if not unit_detail_panel.visible:
		unit_detail_panel.visible = true
		unit_detail_panel.position = _default_detail_position()
	_layout_detail_panel()


func _close_detail_panel(animate: bool) -> void:
	if not unit_detail_panel.visible:
		_detail_unit = null
		item_tooltip.visible = false
		_clear_item_hover_state()
		return
	if animate:
		var tween: Tween = create_tween()
		tween.tween_property(unit_detail_panel, "modulate:a", 0.0, 0.08)
		tween.finished.connect(func() -> void:
			unit_detail_panel.visible = false
			unit_detail_panel.modulate = Color(1, 1, 1, 1)
		)
	else:
		unit_detail_panel.visible = false
	item_tooltip.visible = false
	_detail_unit = null
	_clear_item_hover_state()
	_is_dragging_detail_panel = false


func _on_detail_close_pressed() -> void:
	_close_detail_panel(true)


func _on_detail_drag_handle_gui_input(event: InputEvent) -> void:
	if _detail_unit == null or not unit_detail_panel.visible:
		return
	if event is InputEventMouseButton:
		var mouse_btn: InputEventMouseButton = event as InputEventMouseButton
		if mouse_btn.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse_btn.pressed:
			var mouse_screen: Vector2 = get_viewport().get_mouse_position()
			if detail_close_button != null and detail_close_button.get_global_rect().has_point(mouse_screen):
				return
			_is_dragging_detail_panel = true
			_detail_drag_offset = mouse_screen - unit_detail_panel.position
		else:
			_is_dragging_detail_panel = false
	elif event is InputEventMouseMotion and _is_dragging_detail_panel:
		var next_pos: Vector2 = get_viewport().get_mouse_position() - _detail_drag_offset
		unit_detail_panel.position = _clamp_detail_panel_position(next_pos)


func _layout_detail_panel() -> void:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var width: float = minf(DETAIL_DEFAULT_WIDTH, viewport_size.x - INVENTORY_PANEL_WIDTH - LEFT_PANEL_WIDTH - 48.0)
	var height: float = minf(DETAIL_DEFAULT_HEIGHT, viewport_size.y - TOP_BAR_HEIGHT - 26.0)
	width = maxf(width, 520.0)
	height = maxf(height, 380.0)
	unit_detail_panel.size = Vector2(width, height)
	if not unit_detail_panel.visible:
		unit_detail_panel.position = _default_detail_position()
		return
	unit_detail_panel.position = _clamp_detail_panel_position(unit_detail_panel.position)


func _default_detail_position() -> Vector2:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var left_limit: float = LEFT_PANEL_WIDTH + 24.0
	var right_limit: float = viewport_size.x - INVENTORY_PANEL_WIDTH - 20.0
	var x: float = (left_limit + right_limit - unit_detail_panel.size.x) * 0.5
	var y: float = (viewport_size.y - unit_detail_panel.size.y) * 0.45
	return _clamp_detail_panel_position(Vector2(x, y))


func _clamp_detail_panel_position(pos: Vector2) -> Vector2:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var min_x: float = LEFT_PANEL_WIDTH + 12.0
	var max_x: float = viewport_size.x - INVENTORY_PANEL_WIDTH - unit_detail_panel.size.x - 12.0
	var min_y: float = TOP_BAR_HEIGHT + 8.0
	var max_y: float = viewport_size.y - unit_detail_panel.size.y - 8.0
	return Vector2(clampf(pos.x, min_x, maxf(min_x, max_x)), clampf(pos.y, min_y, maxf(min_y, max_y)))


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

	# 装备被动同样纳入“加成明细”，便于验证叠加顺序与数值来源。
	var equipped_equip_ids: Array = unit.get("runtime_equipped_equip_ids")
	for equip_id_value in equipped_equip_ids:
		var equip_id: String = str(equip_id_value)
		var equip_data: Dictionary = gongfa_manager.call("get_equipment_data", equip_id)
		if equip_data.is_empty():
			continue
		var equip_name: String = str(equip_data.get("name", equip_id))
		var equip_passive: Variant = equip_data.get("passive_effects", [])
		if not (equip_passive is Array):
			continue
		for fx in equip_passive:
			if not (fx is Dictionary):
				continue
			var effect: Dictionary = fx as Dictionary
			var op: String = str(effect.get("op", ""))
			match op:
				"stat_add":
					lines.append("%s: %s +%s" % [equip_name, _stat_key_to_cn(str(effect.get("stat", ""))), str(effect.get("value", 0))])
				"stat_percent":
					var percent2: float = float(effect.get("value", 0.0)) * 100.0
					lines.append("%s: %s %+d%%" % [equip_name, _stat_key_to_cn(str(effect.get("stat", ""))), int(round(percent2))])
				"mp_regen_add":
					lines.append("%s: 内力回复 +%s" % [equip_name, str(effect.get("value", 0))])
				_:
					lines.append("%s: %s" % [equip_name, op])
	return lines


func _ensure_detail_slot_rows_created() -> void:
	# 只创建一次行节点，后续刷新只更新内容，避免 queue_free 导致 hover source 失效。
	if not _gongfa_slot_rows.is_empty():
		return
	for slot in SLOT_ORDER:
		var row_panel := _slot_drop_target_script.new() as PanelContainer
		if row_panel == null:
			row_panel = PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 30)
		row_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		if row_panel.has_method("setup_slot"):
			row_panel.call("setup_slot", "gongfa", slot)
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", _stage == Stage.PREPARATION)
		if row_panel.has_signal("item_dropped"):
			row_panel.connect("item_dropped", Callable(self, "_on_slot_item_dropped"))

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)

		var icon_label := Label.new()
		icon_label.text = _slot_icon(slot)
		icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var name_button := LinkButton.new()
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var unequip_button := Button.new()
		unequip_button.mouse_filter = Control.MOUSE_FILTER_PASS
		unequip_button.pressed.connect(Callable(self, "_on_slot_unequip_pressed").bind("gongfa", slot))

		row.add_child(icon_label)
		row.add_child(name_button)
		row.add_child(unequip_button)
		row_panel.add_child(row)
		detail_slot_list.add_child(row_panel)

		row_panel.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		row_panel.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))
		# 子控件（文字/按钮）会吃掉 hover，必须同步绑定到同一行热区。
		name_button.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		name_button.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))
		unequip_button.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		unequip_button.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))

		_gongfa_slot_rows.append(row_panel)
		_gongfa_slot_name_buttons.append(name_button)
		_gongfa_slot_swap_buttons.append(unequip_button)


func _rebuild_detail_slot_rows(unit: Node) -> void:
	_ensure_detail_slot_rows_created()
	var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
	for i in range(SLOT_ORDER.size()):
		var slot: String = SLOT_ORDER[i]
		var gid: String = str(slots.get(slot, "")).strip_edges()
		var row_panel: PanelContainer = _gongfa_slot_rows[i]
		var name_button: LinkButton = _gongfa_slot_name_buttons[i]
		var unequip_button: Button = _gongfa_slot_swap_buttons[i]

		name_button.text = "%s: %s" % [_slot_to_cn(slot), _gongfa_name_or_empty(gid)]
		name_button.disabled = gid.is_empty()
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", _stage == Stage.PREPARATION)
		if gid.is_empty():
			row_panel.set_meta("item_data", {})
			row_panel.set_meta("gongfa_id", "")
		else:
			row_panel.set_meta("gongfa_id", gid)
			row_panel.set_meta("item_data", _build_gongfa_item_tooltip_data(gid))
		if _item_hover_source == row_panel:
			var refreshed_payload: Variant = row_panel.get_meta("item_data", {})
			if refreshed_payload is Dictionary:
				_item_hover_data = (refreshed_payload as Dictionary).duplicate(true)

		unequip_button.text = "卸下" if not gid.is_empty() else "—"
		unequip_button.disabled = gid.is_empty() or _stage != Stage.PREPARATION


func _on_slot_unequip_pressed(slot_category: String, slot: String) -> void:
	if _detail_unit == null or not _is_valid_unit(_detail_unit):
		return
	if _stage != Stage.PREPARATION:
		return
	if gongfa_manager == null:
		return
	if slot_category == "gongfa":
		gongfa_manager.call("unequip_gongfa", _detail_unit, slot)
	else:
		gongfa_manager.call("unequip_equipment", _detail_unit, slot)
	_update_detail_panel(_detail_unit)
	_refresh_all_ui()


func _ensure_detail_equip_rows_created() -> void:
	# 装备槽同样固定创建，避免 hover 时节点被销毁。
	if not _equip_slot_rows.is_empty():
		return
	for equip_type in EQUIP_ORDER:
		var row_panel := _slot_drop_target_script.new() as PanelContainer
		if row_panel == null:
			row_panel = PanelContainer.new()
		row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_panel.custom_minimum_size = Vector2(0, 30)
		row_panel.mouse_filter = Control.MOUSE_FILTER_STOP
		if row_panel.has_method("setup_slot"):
			row_panel.call("setup_slot", "equipment", equip_type)
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", _stage == Stage.PREPARATION)
		if row_panel.has_signal("item_dropped"):
			row_panel.connect("item_dropped", Callable(self, "_on_slot_item_dropped"))

		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)

		var icon_label := Label.new()
		icon_label.text = _equip_icon(equip_type)
		icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var name_button := LinkButton.new()
		name_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_button.modulate = Color(0.82, 0.82, 0.82, 1.0)
		name_button.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var unequip_button := Button.new()
		unequip_button.mouse_filter = Control.MOUSE_FILTER_PASS
		unequip_button.pressed.connect(Callable(self, "_on_slot_unequip_pressed").bind("equipment", equip_type))

		row.add_child(icon_label)
		row.add_child(name_button)
		row.add_child(unequip_button)
		row_panel.add_child(row)
		detail_equip_slot_list.add_child(row_panel)
		row_panel.set_meta("equip_type", equip_type)

		row_panel.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		row_panel.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))
		name_button.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		name_button.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))
		unequip_button.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		unequip_button.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))

		_equip_slot_rows.append(row_panel)
		_equip_slot_name_buttons.append(name_button)
		_equip_slot_swap_buttons.append(unequip_button)


func _rebuild_equip_slot_rows(unit: Node) -> void:
	# 装备槽位与功法槽位一致：布阵期可拖放/卸下，交锋后只读。
	_ensure_detail_equip_rows_created()
	var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(unit))
	for i in range(EQUIP_ORDER.size()):
		var equip_type: String = EQUIP_ORDER[i]
		var equip_id: String = str(equip_slots.get(equip_type, "")).strip_edges()
		var row_panel: PanelContainer = _equip_slot_rows[i]
		var name_button: LinkButton = _equip_slot_name_buttons[i]
		var unequip_button: Button = _equip_slot_swap_buttons[i]

		name_button.text = "%s: %s" % [_equip_type_to_cn(equip_type), _equip_name_or_empty(equip_id)]
		name_button.disabled = equip_id.is_empty()
		if row_panel.has_method("set_drop_enabled"):
			row_panel.call("set_drop_enabled", _stage == Stage.PREPARATION)
		if equip_id.is_empty():
			row_panel.set_meta("item_data", {})
			row_panel.set_meta("equip_id", "")
		else:
			row_panel.set_meta("equip_id", equip_id)
			row_panel.set_meta("item_data", _build_equip_item_tooltip_data(equip_id))
		if _item_hover_source == row_panel:
			var refreshed_equip_payload: Variant = row_panel.get_meta("item_data", {})
			if refreshed_equip_payload is Dictionary:
				_item_hover_data = (refreshed_equip_payload as Dictionary).duplicate(true)

		unequip_button.text = "卸下" if not equip_id.is_empty() else "—"
		unequip_button.disabled = equip_id.is_empty() or _stage != Stage.PREPARATION


func _on_slot_item_dropped(slot_category: String, slot_key: String, item_id: String) -> void:
	if _detail_unit == null or not _is_valid_unit(_detail_unit):
		return
	if _stage != Stage.PREPARATION:
		return
	if gongfa_manager == null:
		return

	var ok: bool = false
	if slot_category == "gongfa":
		ok = bool(gongfa_manager.call("equip_gongfa", _detail_unit, slot_key, item_id))
	else:
		ok = bool(gongfa_manager.call("equip_equipment", _detail_unit, slot_key, item_id))
	if not ok:
		debug_label.text = "拖放失败：槽位不匹配或数据无效。"
		return
	_update_detail_panel(_detail_unit)
	_refresh_all_ui()


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


func _ensure_tooltip_gongfa_rows_created(required_count: int) -> void:
	# UnitTooltip 功法列表也改为增量更新，避免周期刷新时频繁销毁 hover 源。
	var needed: int = maxi(required_count, 1)
	while _tooltip_gongfa_rows.size() < needed:
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
		link.text = "-"

		row.add_child(prefix)
		row.add_child(link)
		row_panel.add_child(row)
		tooltip_gongfa_list.add_child(row_panel)

		row_panel.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		row_panel.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))
		link.mouse_entered.connect(Callable(self, "_on_item_row_hover_entered").bind(row_panel))
		link.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(row_panel))

		_tooltip_gongfa_rows.append(row_panel)
		_tooltip_gongfa_links.append(link)


func _refresh_tooltip_gongfa_list(unit: Node) -> void:
	var runtime_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	var row_count: int = runtime_ids.size()
	_ensure_tooltip_gongfa_rows_created(row_count)
	if row_count == 0:
		var only_row: PanelContainer = _tooltip_gongfa_rows[0]
		var only_link: LinkButton = _tooltip_gongfa_links[0]
		only_link.text = "功法: 无"
		only_link.disabled = true
		only_row.set_meta("item_data", {})
		only_row.visible = true
		for i in range(1, _tooltip_gongfa_rows.size()):
			_tooltip_gongfa_rows[i].visible = false
		return

	for i in range(_tooltip_gongfa_rows.size()):
		_tooltip_gongfa_rows[i].visible = i < row_count
		if i >= row_count:
			continue
		var gid: String = str(runtime_ids[i])
		var data: Dictionary = {}
		if gongfa_manager != null:
			data = gongfa_manager.call("get_gongfa_data", gid)
		var link: LinkButton = _tooltip_gongfa_links[i]
		if data.is_empty():
			link.text = gid
		else:
			link.text = "%s（%s/%s）" % [
				str(data.get("name", gid)),
				_slot_to_cn(str(data.get("type", ""))),
				_element_to_cn(str(data.get("element", "none")))
			]
		link.disabled = false
		_tooltip_gongfa_rows[i].set_meta("item_data", _build_gongfa_item_tooltip_data(gid))
		if _item_hover_source == _tooltip_gongfa_rows[i]:
			var refreshed_tip_payload: Variant = _tooltip_gongfa_rows[i].get_meta("item_data", {})
			if refreshed_tip_payload is Dictionary:
				_item_hover_data = (refreshed_tip_payload as Dictionary).duplicate(true)


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
	# ItemTooltip 的 Buff 名称需要直接读取 buffs 数据。
	# 装备数据改为统一从 GongfaManager.get_equipment_data 读取，避免两套来源不一致。
	_buff_data_map.clear()
	var data_manager: Node = _get_root_node("DataManager")
	if data_manager == null:
		return
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


func _on_item_row_hover_entered(row_panel: Control) -> void:
	# 拖拽过程中禁止触发悬停详情，避免 tooltip 抢焦点导致闪烁。
	if get_viewport().gui_is_dragging():
		if item_tooltip != null:
			item_tooltip.visible = false
		_clear_item_hover_state()
		return
	if row_panel == null or not is_instance_valid(row_panel):
		return
	var payload: Variant = row_panel.get_meta("item_data", {})
	if not (payload is Dictionary):
		return
	var payload_dict: Dictionary = payload
	if payload_dict.is_empty():
		return
	_on_item_source_hover_entered(row_panel, payload_dict)


func _on_item_source_hover_entered(source: Control, payload: Dictionary) -> void:
	# 拖拽过程中禁止触发悬停详情，避免 tooltip 抢焦点导致闪烁。
	if get_viewport().gui_is_dragging():
		if item_tooltip != null:
			item_tooltip.visible = false
		_clear_item_hover_state()
		return
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
	# 双保险：只要当前处于拖拽状态，立即清理 Tooltip 的显示与计时。
	if get_viewport().gui_is_dragging():
		if item_tooltip != null:
			item_tooltip.visible = false
		_clear_item_hover_state()
		return
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
		var trigger_text: String = "触发：%s" % _trigger_to_cn(str(skill.get("trigger", "")))
		if skill.has("range"):
			var range_cells: float = maxf(float(skill.get("range", 0.0)), 0.0)
			if range_cells <= 0.0:
				trigger_text += " · 无需锁敌"
			else:
				trigger_text += " · 射程 %.1f 格" % range_cells
		skill_trigger = trigger_text
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
	var data: Dictionary = {}
	if gongfa_manager != null:
		data = gongfa_manager.call("get_equipment_data", equip_id)
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
	var passive_effects: Variant = data.get("passive_effects", [])
	if passive_effects is Array:
		for effect_value in passive_effects:
			if effect_value is Dictionary:
				effect_lines.append(_format_effect_op(effect_value as Dictionary))

	var has_trigger: bool = false
	var trigger_line: String = ""
	var trigger_effect_lines: Array[String] = []
	var trigger_value: Variant = data.get("trigger", {})
	if trigger_value is Dictionary and not (trigger_value as Dictionary).is_empty():
		has_trigger = true
		var trigger_data: Dictionary = trigger_value
		var chance_percent: int = int(round(clampf(float(trigger_data.get("chance", 1.0)), 0.0, 1.0) * 100.0))
		var cooldown: float = float(trigger_data.get("cooldown", 0.0))
		trigger_line = "触发：%s（概率 %d%%，冷却 %.1fs）" % [
			_trigger_to_cn(str(trigger_data.get("type", ""))),
			chance_percent,
			cooldown
		]
		var trigger_effects: Variant = trigger_data.get("effects", [])
		if trigger_effects is Array:
			for effect_value in trigger_effects:
				if effect_value is Dictionary:
					trigger_effect_lines.append(_format_effect_op(effect_value as Dictionary))

	var linkage_tags: String = "联动标签：无"
	var tags_raw: Variant = data.get("linkage_tags", [])
	if tags_raw is Array and not (tags_raw as Array).is_empty():
		var tags_text: Array[String] = []
		for tag in tags_raw:
			tags_text.append(str(tag))
		linkage_tags = "联动标签：%s" % " · ".join(tags_text)

	return {
		"name": "%s [%s]" % [str(data.get("name", equip_id)), _quality_to_cn(str(data.get("rarity", "white")))],
		"type_line": "%s · %s" % [_equip_type_to_cn(str(data.get("type", "weapon"))), _element_to_cn(str(data.get("element", "none")))],
		"desc": str(data.get("description", "江湖器物")),
		"effects": effect_lines,
		"has_skill": has_trigger,
		"skill_trigger": trigger_line,
		"skill_effects": trigger_effect_lines,
		"linkage_tags": linkage_tags
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


func _team_to_cn(team_id: int) -> String:
	match team_id:
		1:
			return "己方"
		2:
			return "敌方"
		_:
			return "中立"


func _format_name_with_team(unit_name: String, team_id: int) -> String:
	return "[%s]%s" % [_team_to_cn(team_id), unit_name]


func _resolve_unit_team(unit: Node) -> int:
	if unit == null or not is_instance_valid(unit):
		return 0
	return int(_safe_node_prop(unit, "team_id", 0))


func _resolve_unit_name(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return "未知"
	return str(_safe_node_prop(unit, "unit_name", "未知"))


func _resolve_gongfa_name(gongfa_id: String) -> String:
	var gid: String = gongfa_id.strip_edges()
	if gid.is_empty():
		return "未知功法"
	if gongfa_manager != null and gongfa_manager.has_method("get_gongfa_data"):
		var data: Dictionary = gongfa_manager.call("get_gongfa_data", gid)
		if not data.is_empty():
			return str(data.get("name", gid))
	return gid


func _origin_to_cn(origin: String) -> String:
	match origin:
		"skill":
			return "功法"
		"buff_tick":
			return "Buff周期"
		_:
			return origin


func _buff_name_from_id(buff_id: String) -> String:
	if _buff_data_map.has(buff_id):
		return str((_buff_data_map[buff_id] as Dictionary).get("name", buff_id))
	return buff_id


func _get_unit_equip_slots(unit: Node) -> Dictionary:
	if unit == null or not _is_valid_unit(unit):
		return {"weapon": "", "armor": "", "accessory": ""}
	var raw_slots: Variant = unit.get("equip_slots")
	return _normalize_equip_slots(raw_slots)


func _normalize_equip_slots(raw: Variant) -> Dictionary:
	var slots: Dictionary = {"weapon": "", "armor": "", "accessory": ""}
	if raw is Dictionary:
		for key in slots.keys():
			slots[key] = str((raw as Dictionary).get(key, "")).strip_edges()
	return slots


func _equip_name_or_empty(equip_id: String) -> String:
	if equip_id.is_empty():
		return "空"
	if gongfa_manager != null:
		var equip_data: Dictionary = gongfa_manager.call("get_equipment_data", equip_id)
		if not equip_data.is_empty():
			return str(equip_data.get("name", equip_id))
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
	var bonus_prefix: String = "+" if bonus > 0.0 else ""
	return "%s %d (%s%d)" % [cn_name, int(round(runtime_value)), bonus_prefix, int(round(bonus))]


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
