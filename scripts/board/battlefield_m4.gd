extends "res://scripts/board/battlefield_m3.gd"

# ===========================
# M4 经济与综合商店验证场景
# ===========================
# 说明：
# 1. 继承 M3，复用已稳定的战斗/拖放/详情/仓库基础功能。
# 2. 接入 EconomyManager + ShopManager，补齐银两、等级经验、商店刷新/锁定/购买。
# 3. 右侧仓库改为“已拥有物品”视图，购买秘籍/装备后可拖放到角色槽位并消耗库存。

const SHOP_TAB_RECRUIT: String = "recruit"
const SHOP_TAB_GONGFA: String = "gongfa"
const SHOP_TAB_EQUIPMENT: String = "equipment"

const SHOP_LAYER_INDEX: int = 12
const SHOP_PANEL_MIN_WIDTH: float = 760.0
const SHOP_PANEL_MAX_WIDTH: float = 980.0
const SHOP_PANEL_HEIGHT: float = 320.0
const BATTLE_STATS_PANEL_WIDTH: float = 860.0
const BATTLE_STATS_PANEL_HEIGHT: float = 520.0
const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2

const QUALITY_SELL_PRICE: Dictionary = {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 5,
	"orange": 8,
	"red": 15
}

const HEALER_ROLE_KEY: String = "healer"
const HEALER_FALLBACK_GONGFA_BY_QUALITY: Dictionary = {
	# 低品质补“保底治疗”功法，保证医者最基础治疗职责可用。
	"white": ["gf_baicao_jiushi", "gongfa_taiji_neigong"],
	"green": ["gf_yangchun_huixin", "gongfa_taiji_neigong"],
	"blue": ["gongfa_taiji_neigong", "gf_wudang_heal"],
	"purple": ["gf_emei_heal", "gf_wudang_heal", "gongfa_huagong"],
	"orange": ["gf_jiuyang_heal", "gf_huqingniu", "gf_yideng_heal"],
	"red": ["gf_shennong", "gf_yijin", "gf_xisui"]
}

const ECONOMY_MANAGER_SCRIPT: Script = preload("res://scripts/economy/economy_manager.gd")
const SHOP_MANAGER_SCRIPT: Script = preload("res://scripts/economy/shop_manager.gd")
const RECYCLE_DROP_ZONE_SCRIPT: Script = preload("res://scripts/ui/m3_recycle_drop_zone.gd")
const BATTLE_STATISTICS_SCRIPT: Script = preload("res://scripts/battle/battle_statistics.gd")

@onready var _shop_bar: HBoxContainer = $BottomLayer/BottomPanel/RootVBox/ShopBar
@onready var _shop_label: Label = $BottomLayer/BottomPanel/RootVBox/ShopBar/ShopLabel

var _economy_manager: Node = null
var _shop_manager: Node = null

var _shop_layer: CanvasLayer = null
var _shop_panel: PanelContainer = null
var _shop_open_button: Button = null
var _shop_title_label: Label = null
var _shop_status_label: Label = null
var _shop_close_button: Button = null
var _shop_tabs: Dictionary = {}
var _shop_offer_row: HBoxContainer = null
var _shop_silver_label: Label = null
var _shop_level_label: Label = null
var _shop_refresh_button: Button = null
var _shop_upgrade_button: Button = null
var _shop_lock_button: Button = null
var _shop_test_add_silver_button: Button = null
var _shop_test_add_exp_button: Button = null

var _shop_current_tab: String = SHOP_TAB_RECRUIT
var _shop_open_in_preparation: bool = true
var _m4_initialized: bool = false

var _owned_gongfa_stock: Dictionary = {}    # gongfa_id -> count
var _owned_equipment_stock: Dictionary = {} # equip_id -> count
var _recycle_drop_zone: PanelContainer = null

var _battle_statistics: Node = null
var _battle_stats_panel: PanelContainer = null
var _battle_stats_mvp_label: Label = null
var _battle_stats_damage_rank: RichTextLabel = null
var _battle_stats_tank_rank: RichTextLabel = null
var _battle_stats_heal_rank: RichTextLabel = null
var _battle_stats_tab_ally_button: Button = null
var _battle_stats_tab_enemy_button: Button = null
var _battle_stats_current_team_tab: int = TEAM_ALLY


func _ready() -> void:
	# 兜底取消暂停：防止从调试切场景时遗留 pause 状态，导致“进入场景像挂起”。
	get_tree().paused = false
	_bootstrap_m4_systems()
	super._ready()
	_ensure_battle_statistics_created()
	_ensure_recycle_zone_created()
	_ensure_battle_stats_panel_created()
	_ensure_shop_open_button()
	_ensure_shop_panel_created()
	_connect_m4_ui_signals()
	_refresh_shop_for_preparation(true)
	_update_shop_ui()
	_m4_initialized = true
	_refresh_all_ui()
	_apply_stage_ui_state()
	_prepare_linkage_panel_for_m4()
	_sync_linkage_panel_visibility()


func _input(event: InputEvent) -> void:
	# 输入优先级修复：
	# 当鼠标位于商店面板上时，不让战场层 _input 抢先消费，
	# 交给 Button/Tab 等 UI 控件处理，解决“点击无响应”。
	if _shop_panel != null and _shop_panel.visible:
		if event is InputEventMouseButton:
			var mouse_btn: InputEventMouseButton = event as InputEventMouseButton
			if _shop_panel.get_global_rect().has_point(mouse_btn.position):
				return
		elif event is InputEventMouseMotion:
			var mouse_motion: InputEventMouseMotion = event as InputEventMouseMotion
			if _shop_panel.get_global_rect().has_point(mouse_motion.position):
				return

	# 回收区与仓库同属 UI 层，鼠标位于回收区时应阻止战场输入抢占。
	if _dragging_unit == null and _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		if event is InputEventMouseButton:
			var recycle_mouse_btn: InputEventMouseButton = event as InputEventMouseButton
			if _recycle_drop_zone.get_global_rect().has_point(recycle_mouse_btn.position):
				return
		elif event is InputEventMouseMotion:
			var recycle_mouse_motion: InputEventMouseMotion = event as InputEventMouseMotion
			if _recycle_drop_zone.get_global_rect().has_point(recycle_mouse_motion.position):
				return
	super._input(event)


func _handle_key_input(event: InputEventKey) -> void:
	# M4 场景内按 F7 重开 M4，便于反复调试经济与商店逻辑。
	if event.pressed and not event.echo and event.keycode == KEY_F7:
		var event_bus: Node = _get_root_node("EventBus")
		if event_bus != null:
			event_bus.call("emit_scene_change_requested", "res://scenes/battle/battlefield_m4.tscn")
		return
	super._handle_key_input(event)


func _unhandled_input(event: InputEvent) -> void:
	super._unhandled_input(event)
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ESCAPE and _shop_panel != null and _shop_panel.visible:
		# ESC 在详情面板关闭后，可继续关闭商店面板。
		_set_shop_panel_visible(false)
		get_viewport().set_input_as_handled()


func _set_stage(next_stage: int) -> void:
	var previous_stage: int = _stage
	super._set_stage(next_stage)
	if next_stage == Stage.PREPARATION and previous_stage != Stage.PREPARATION:
		_shop_open_in_preparation = true
		_refresh_shop_for_preparation(false)
		_hide_battle_stats_panel()
	_update_shop_ui()


func _apply_stage_ui_state() -> void:
	super._apply_stage_ui_state()
	if _shop_panel != null and is_instance_valid(_shop_panel):
		if _stage == Stage.PREPARATION:
			_set_shop_panel_visible(_shop_open_in_preparation)
		else:
			_set_shop_panel_visible(false)
	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		var recycle_visible: bool = _stage == Stage.PREPARATION
		_recycle_drop_zone.visible = recycle_visible
		if _recycle_drop_zone.has_method("set_drop_enabled"):
			_recycle_drop_zone.call("set_drop_enabled", recycle_visible)
		if not recycle_visible and _recycle_drop_zone.has_method("clear_external_preview"):
			_recycle_drop_zone.call("clear_external_preview")
	if _stage != Stage.RESULT:
		_hide_battle_stats_panel()
	_sync_linkage_panel_visibility()
	_update_shop_ui()


func _on_viewport_size_changed() -> void:
	super._on_viewport_size_changed()
	_layout_shop_panel()
	_layout_bench_recycle_wrap()
	_layout_battle_stats_panel()


func _set_bottom_expanded(expanded: bool, animate: bool) -> void:
	# M4 底栏在展开/收起时，回收区与备战席的可见区域会发生变化，
	# 这里在父类布局结束后立刻重排，避免“回收区被挤出屏幕”。
	super._set_bottom_expanded(expanded, animate)
	_layout_bench_recycle_wrap()


func _refresh_dynamic_ui() -> void:
	super._refresh_dynamic_ui()
	if _economy_manager == null:
		return
	var assets: Dictionary = _economy_manager.get_assets_snapshot()
	var level: int = int(assets.get("level", 1))
	var exp_value: int = int(assets.get("exp", 0))
	var max_exp: int = int(assets.get("max_exp", 0))
	var silver: int = int(assets.get("silver", 0))
	var bench_count: int = bench_ui.get_unit_count() if bench_ui != null else 0
	var bench_slots: int = bench_ui.get_slot_count() if bench_ui != null else 0
	var deploy_limit: int = _economy_manager.get_max_deploy_limit()
	resource_label.text = "门派LV%d (%d/%d) | 银两%d | 上场上限%d | 备战席 %d/%d" % [
		level,
		exp_value,
		max_exp,
		silver,
		deploy_limit,
		bench_count,
		bench_slots
	]
	_refresh_linkage_info_for_deployed_only()
	_update_shop_operation_labels()


func _refresh_all_ui() -> void:
	super._refresh_all_ui()
	_update_shop_ui()
	_rebuild_battle_stats_panel_content()


func _on_battle_ended(winner_team: int, summary: Dictionary) -> void:
	super._on_battle_ended(winner_team, summary)
	if _economy_manager != null:
		_economy_manager.record_battle_result_by_team(winner_team, 1)
		var income_detail: Dictionary = _economy_manager.apply_round_income()
		_append_battle_log(
			"经济结算：基础%d + 利息%d + 连胜/败%d = +%d 银两" % [
				int(income_detail.get("base", 0)),
				int(income_detail.get("interest", 0)),
				int(income_detail.get("streak", 0)),
				int(income_detail.get("total", 0))
			],
			"system"
		)
		_update_shop_ui()
	_show_battle_stats_panel()


func _on_bench_changed() -> void:
	super._on_bench_changed()
	_update_shop_operation_labels()


func _on_damage_resolved(event_dict: Dictionary) -> void:
	super._on_damage_resolved(event_dict)
	if _battle_statistics == null:
		return
	var damage_value: int = int(round(float(event_dict.get("damage", 0.0))))
	if damage_value <= 0:
		return
	var source_unit: Node = _find_unit_node_by_instance_id(int(event_dict.get("source_id", -1)))
	var target_unit: Node = _find_unit_node_by_instance_id(int(event_dict.get("target_id", -1)))
	_battle_statistics.call("record_damage", source_unit, target_unit, damage_value)


func _on_skill_effect_damage_for_log(event_dict: Dictionary) -> void:
	super._on_skill_effect_damage_for_log(event_dict)
	if _battle_statistics == null:
		return
	var damage_value: int = int(round(float(event_dict.get("damage", 0.0))))
	if damage_value <= 0:
		return
	var source_unit: Node = event_dict.get("source", null)
	var target_unit: Node = event_dict.get("target", null)
	_battle_statistics.call("record_damage", source_unit, target_unit, damage_value)


func _on_skill_effect_heal_for_stats(event_dict: Dictionary) -> void:
	if _battle_statistics == null:
		return
	if _stage != Stage.COMBAT:
		return
	var heal_value: int = int(round(float(event_dict.get("heal", 0.0))))
	if heal_value <= 0:
		return
	var source_unit: Node = event_dict.get("source", null)
	var target_unit: Node = event_dict.get("target", null)
	_battle_statistics.call("record_healing", source_unit, target_unit, heal_value)


func _on_unit_died(dead_unit: Node, killer: Node, team_id: int) -> void:
	super._on_unit_died(dead_unit, killer, team_id)
	if _battle_statistics == null:
		return
	_battle_statistics.call("record_kill", killer, dead_unit)


func _get_drop_target(screen_mouse: Vector2) -> Dictionary:
	# M4 新增：优先识别“回收区”落点，再回退到 M2/M3 的棋盘/备战席判定。
	if _is_point_in_recycle_zone(screen_mouse):
		return {"type": "recycle"}
	return super._get_drop_target(screen_mouse)


func _update_drag_target(screen_pos: Vector2) -> void:
	# 为“备战角色拖到回收区”提供实时预估售价提示。
	var target: Dictionary = _get_drop_target(screen_pos)
	var target_type: String = str(target.get("type", "invalid"))
	if target_type == "battlefield":
		_drag_target_cell = target.get("cell", Vector2i(-999, -999))
		_drag_target_valid = _can_deploy_ally_to_cell(_dragging_unit, _drag_target_cell)
	else:
		_drag_target_cell = Vector2i(-999, -999)
		_drag_target_valid = false

	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		if target_type == "recycle" and _dragging_unit != null and _is_valid_unit(_dragging_unit):
			var can_sell_unit: bool = _drag_origin_kind == "bench"
			var payload: Dictionary = {
				"type": "unit",
				"id": str(_dragging_unit.get("unit_id")),
				"unit_node": _dragging_unit,
				"cost": int(_safe_node_prop(_dragging_unit, "cost", 0))
			}
			if _recycle_drop_zone.has_method("set_external_preview"):
				_recycle_drop_zone.call("set_external_preview", payload, can_sell_unit)
		elif _recycle_drop_zone.has_method("clear_external_preview"):
			_recycle_drop_zone.call("clear_external_preview")

	queue_redraw()


func _try_end_drag(screen_pos: Vector2) -> void:
	if _dragging_unit == null:
		return
	var dropped: bool = false
	var target: Dictionary = _get_drop_target(screen_pos)
	var target_type: String = str(target.get("type", "invalid"))
	if target_type == "battlefield":
		var cell: Vector2i = target.get("cell", Vector2i(-999, -999))
		if _can_deploy_ally_to_cell(_dragging_unit, cell):
			_deploy_ally_unit_to_cell(_dragging_unit, cell)
			dropped = true
	elif target_type == "bench":
		var slot_index: int = int(target.get("slot", -1))
		dropped = _drop_to_bench_slot(_dragging_unit, slot_index)
	elif target_type == "recycle":
		dropped = _try_sell_dragging_unit()
	if not dropped:
		_restore_drag_origin()
	_finish_drag()


func _finish_drag() -> void:
	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		if _recycle_drop_zone.has_method("clear_external_preview"):
			_recycle_drop_zone.call("clear_external_preview")
	super._finish_drag()


func _on_data_reloaded(is_full_reload: bool, summary: Dictionary) -> void:
	super._on_data_reloaded(is_full_reload, summary)
	_rebuild_m4_data_caches()
	_refresh_shop_for_preparation(true)


func _on_gongfa_data_reloaded(summary: Dictionary) -> void:
	super._on_gongfa_data_reloaded(summary)
	_rebuild_m4_data_caches()
	_refresh_shop_for_preparation(true)


func _can_deploy_ally_to_cell(unit: Node, cell: Vector2i) -> bool:
	if not super._can_deploy_ally_to_cell(unit, cell):
		return false
	if _economy_manager == null:
		return true
	var limit: int = _economy_manager.get_max_deploy_limit()
	# 仅限制“新增上场单位”。战场单位重新拖拽换位不应被阻断。
	if _ally_deployed.size() >= limit and not _ally_deployed.has(_cell_key(cell)):
		return false
	return true


func _start_combat() -> void:
	# 开战前按门派等级动态收紧自动上场上限。
	_hide_battle_stats_panel()
	if _economy_manager != null:
		max_auto_deploy = _economy_manager.get_max_deploy_limit()
	super._start_combat()
	if bool(combat_manager.call("is_battle_running")):
		_start_battle_statistics_capture()


func _rebuild_inventory_items() -> void:
	# M4 仓库改为“拥有库存”视图：
	# - 仅展示已购买或已装备中的条目；
	# - 支持显示库存与已装备数量；
	# - 拖放装备会消耗库存，卸下会返还库存。
	if _inventory_grid == null or gongfa_manager == null:
		return

	for child in _inventory_grid.get_children():
		child.queue_free()

	var item_mode: String = _inventory_mode
	var stock_map: Dictionary = _owned_gongfa_stock if item_mode == "gongfa" else _owned_equipment_stock
	var id_set: Dictionary = {}

	for key in stock_map.keys():
		var item_id: String = str(key).strip_edges()
		if item_id.is_empty():
			continue
		if int(stock_map.get(item_id, 0)) > 0:
			id_set[item_id] = true

	for unit in _collect_player_units():
		if unit == null or not _is_valid_unit(unit):
			continue
		if item_mode == "gongfa":
			var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
			for slot in SLOT_ORDER:
				var gid: String = str(slots.get(slot, "")).strip_edges()
				if not gid.is_empty():
					id_set[gid] = true
		else:
			var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(unit))
			for equip_slot in EQUIP_ORDER:
				var eid: String = str(equip_slots.get(equip_slot, "")).strip_edges()
				if not eid.is_empty():
					id_set[eid] = true

	var items: Array[Dictionary] = []
	for id_key in id_set.keys():
		var lookup_id: String = str(id_key)
		var data: Dictionary = {}
		if item_mode == "gongfa":
			data = gongfa_manager.call("get_gongfa_data", lookup_id)
		else:
			data = gongfa_manager.call("get_equipment_data", lookup_id)
		if data.is_empty():
			continue
		var packed: Dictionary = data.duplicate(true)
		packed["_owned_count"] = int(stock_map.get(lookup_id, 0))
		packed["_equipped_count"] = _count_equipped_instances(item_mode, lookup_id)
		items.append(packed)

	items.sort_custom(Callable(self, "_sort_inventory_item"))

	var search_text: String = _inventory_search.text.strip_edges().to_lower() if _inventory_search != null else ""
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

	var total_owned: int = 0
	var total_equipped: int = 0
	for item_data in filtered:
		total_owned += int(item_data.get("_owned_count", 0))
		total_equipped += int(item_data.get("_equipped_count", 0))
		var card: PanelContainer = _create_inventory_card(item_data)
		_inventory_grid.add_child(card)

	_inventory_summary.text = "库存 %d 件 | 已装备 %d 件 | 条目 %d" % [total_owned, total_equipped, filtered.size()]


func _create_inventory_card(item_data: Dictionary) -> PanelContainer:
	var card := _inventory_card_script.new() as PanelContainer
	if card == null:
		card = PanelContainer.new()
	card.custom_minimum_size = Vector2(160, 122)
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
	var owned_count: int = int(item_data.get("_owned_count", 0))
	var equipped_count: int = int(item_data.get("_equipped_count", 0))
	var status_label := Label.new()
	status_label.text = "库存 x%d | 已装备 x%d" % [owned_count, equipped_count]
	if owned_count <= 0 and equipped_count > 0:
		status_label.text = "库存 x0 | 已装备 x%d" % equipped_count
	elif owned_count <= 0 and equipped_count <= 0:
		status_label.text = "无库存"
	vbox.add_child(status_label)

	var tooltip_payload: Dictionary = _build_gongfa_item_tooltip_data(item_id) if _inventory_mode == "gongfa" else _build_equip_item_tooltip_data(item_id)
	var drag_payload: Dictionary = {
		"type": _inventory_mode,
		"id": item_id,
		"item_data": item_data.duplicate(true),
		"slot_type": item_type
	}

	var can_drag: bool = owned_count > 0 and _inventory_drag_enabled
	if card.has_method("setup_card"):
		card.call("setup_card", item_id, item_data, drag_payload, can_drag)
		var click_cb: Callable = Callable(self, "_on_inventory_card_clicked")
		if card.has_signal("card_clicked") and not card.is_connected("card_clicked", click_cb):
			card.connect("card_clicked", click_cb)

	if not can_drag:
		card.modulate = Color(0.75, 0.75, 0.75, 0.92)

	card.set_meta("item_id", item_id)
	card.set_meta("item_data", item_data.duplicate(true))
	card.set_meta("tooltip_data", tooltip_payload)
	card.mouse_entered.connect(Callable(self, "_on_item_source_hover_entered").bind(card, tooltip_payload))
	card.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(card))
	return card


func _on_slot_item_dropped(slot_category: String, slot_key: String, item_id: String) -> void:
	# M4 槽位拖放与 M3 的核心差异：
	# 1) 槽位装备成功后会扣减仓库库存；
	# 2) 被替换下来的旧条目会返还到仓库库存。
	if _detail_unit == null or not _is_valid_unit(_detail_unit):
		return
	if _stage != Stage.PREPARATION:
		return
	if gongfa_manager == null:
		return

	var stock_category: String = "gongfa" if slot_category == "gongfa" else "equipment"
	if _get_owned_item_count(stock_category, item_id) <= 0:
		debug_label.text = "库存不足：无法装备 %s" % item_id
		return

	var replaced_item_id: String = ""
	var ok: bool = false
	if slot_category == "gongfa":
		var slots: Dictionary = _normalize_unit_slots(_detail_unit.get("gongfa_slots"))
		replaced_item_id = str(slots.get(slot_key, "")).strip_edges()
		if replaced_item_id == item_id:
			return
		ok = bool(gongfa_manager.call("equip_gongfa", _detail_unit, slot_key, item_id))
	else:
		var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(_detail_unit))
		replaced_item_id = str(equip_slots.get(slot_key, "")).strip_edges()
		if replaced_item_id == item_id:
			return
		ok = bool(gongfa_manager.call("equip_equipment", _detail_unit, slot_key, item_id))

	if not ok:
		debug_label.text = "拖放失败：槽位不匹配或数据无效。"
		return

	_consume_owned_item(stock_category, item_id, 1)
	if not replaced_item_id.is_empty():
		_add_owned_item(stock_category, replaced_item_id, 1)

	_update_detail_panel(_detail_unit)
	_refresh_all_ui()


func _on_slot_unequip_pressed(slot_category: String, slot: String) -> void:
	if _detail_unit == null or not _is_valid_unit(_detail_unit):
		return
	if _stage != Stage.PREPARATION:
		return
	if gongfa_manager == null:
		return

	var removed_item_id: String = ""
	if slot_category == "gongfa":
		var slots: Dictionary = _normalize_unit_slots(_detail_unit.get("gongfa_slots"))
		removed_item_id = str(slots.get(slot, "")).strip_edges()
		if removed_item_id.is_empty():
			return
		gongfa_manager.call("unequip_gongfa", _detail_unit, slot)
		_add_owned_item("gongfa", removed_item_id, 1)
	else:
		var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(_detail_unit))
		removed_item_id = str(equip_slots.get(slot, "")).strip_edges()
		if removed_item_id.is_empty():
			return
		gongfa_manager.call("unequip_equipment", _detail_unit, slot)
		_add_owned_item("equipment", removed_item_id, 1)

	_update_detail_panel(_detail_unit)
	_refresh_all_ui()


func _bootstrap_m4_systems() -> void:
	if _economy_manager == null:
		_economy_manager = ECONOMY_MANAGER_SCRIPT.new() as Node
		_economy_manager.name = "RuntimeEconomyManager"
		add_child(_economy_manager)
	if _shop_manager == null:
		_shop_manager = SHOP_MANAGER_SCRIPT.new() as Node
		_shop_manager.name = "RuntimeShopManager"
		add_child(_shop_manager)
	_rebuild_m4_data_caches()

	if _economy_manager != null:
		var data_manager: Node = _get_root_node("DataManager")
		_economy_manager.setup_from_data_manager(data_manager)


func _rebuild_m4_data_caches() -> void:
	if _shop_manager == null:
		return
	_shop_manager.reload_pools(unit_factory, gongfa_manager)


func _connect_m4_ui_signals() -> void:
	if _economy_manager != null:
		var assets_cb: Callable = Callable(self, "_on_assets_changed")
		if not _economy_manager.is_connected("assets_changed", assets_cb):
			_economy_manager.connect("assets_changed", assets_cb)
		var lock_cb: Callable = Callable(self, "_on_shop_locked_changed")
		if not _economy_manager.is_connected("shop_lock_changed", lock_cb):
			_economy_manager.connect("shop_lock_changed", lock_cb)

	if _shop_manager != null:
		var refresh_cb: Callable = Callable(self, "_on_shop_snapshot_refreshed")
		if not _shop_manager.is_connected("shop_refreshed", refresh_cb):
			_shop_manager.connect("shop_refreshed", refresh_cb)

	if gongfa_manager != null and gongfa_manager.has_signal("skill_effect_heal"):
		var heal_cb: Callable = Callable(self, "_on_skill_effect_heal_for_stats")
		if not gongfa_manager.is_connected("skill_effect_heal", heal_cb):
			gongfa_manager.connect("skill_effect_heal", heal_cb)

	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		var sell_cb: Callable = Callable(self, "_on_recycle_sell_requested")
		if _recycle_drop_zone.has_signal("sell_requested") and not _recycle_drop_zone.is_connected("sell_requested", sell_cb):
			_recycle_drop_zone.connect("sell_requested", sell_cb)

	var refresh_cb_btn: Callable = Callable(self, "_on_bottom_refresh_pressed")
	if refresh_button != null and not refresh_button.is_connected("pressed", refresh_cb_btn):
		refresh_button.connect("pressed", refresh_cb_btn)
	var lock_cb_btn: Callable = Callable(self, "_on_bottom_lock_pressed")
	if lock_button != null and not lock_button.is_connected("pressed", lock_cb_btn):
		lock_button.connect("pressed", lock_cb_btn)
	var upgrade_cb_btn: Callable = Callable(self, "_on_bottom_upgrade_pressed")
	if upgrade_button != null and not upgrade_button.is_connected("pressed", upgrade_cb_btn):
		upgrade_button.connect("pressed", upgrade_cb_btn)


func _ensure_battle_statistics_created() -> void:
	if _battle_statistics != null and is_instance_valid(_battle_statistics):
		return
	_battle_statistics = BATTLE_STATISTICS_SCRIPT.new() as Node
	_battle_statistics.name = "RuntimeBattleStatistics"
	add_child(_battle_statistics)


func _start_battle_statistics_capture() -> void:
	if _battle_statistics == null:
		return
	var combat_units: Array[Node] = []
	for unit in _ally_deployed.values():
		if _is_valid_unit(unit):
			combat_units.append(unit)
	for unit in _enemy_deployed.values():
		if _is_valid_unit(unit):
			combat_units.append(unit)
	_battle_statistics.call("start_battle", combat_units)
	_rebuild_battle_stats_panel_content()


func _ensure_recycle_zone_created() -> void:
	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		return
	if bottom_panel == null or bench_ui == null:
		return
	var root_vbox: VBoxContainer = bottom_panel.get_node_or_null("RootVBox") as VBoxContainer
	var bench_control: Control = bench_ui as Control
	if root_vbox == null or bench_control == null:
		return

	# 用 MarginContainer 给“备战+回收行”预留右侧空间，避免被右栏仓库遮挡。
	var bench_wrap: MarginContainer = root_vbox.get_node_or_null("BenchRecycleWrap") as MarginContainer
	if bench_wrap == null:
		bench_wrap = MarginContainer.new()
		bench_wrap.name = "BenchRecycleWrap"
		bench_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bench_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
		bench_wrap.custom_minimum_size = Vector2(0.0, 154.0)
		var bench_index: int = root_vbox.get_children().find(bench_control)
		root_vbox.add_child(bench_wrap)
		root_vbox.move_child(bench_wrap, maxi(bench_index, 0))

	var bench_row: HBoxContainer = bench_wrap.get_node_or_null("BenchRecycleRow") as HBoxContainer
	if bench_row == null:
		bench_row = HBoxContainer.new()
		bench_row.name = "BenchRecycleRow"
		bench_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bench_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		bench_row.add_theme_constant_override("separation", 8)
		bench_wrap.add_child(bench_row)
	bench_row.alignment = BoxContainer.ALIGNMENT_BEGIN

	if bench_control.get_parent() != bench_row:
		var old_parent: Node = bench_control.get_parent()
		if old_parent != null:
			old_parent.remove_child(bench_control)
		bench_row.add_child(bench_control)
	bench_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bench_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# ★ 关键修复：清零 minimum_size.x 防止 GridContainer 撑爆 HBox。
	# TSCN 中 horizontal_scroll_mode=0 (DISABLED) 会让 ScrollContainer 把子控件宽度
	# 作为自身最小宽度向上传播，导致 BenchRecycleRow 溢出屏幕。
	# 改为 SCROLL_MODE_SHOW_NEVER(=3) 即可让 ScrollContainer 不传播子控件宽度。
	bench_control.custom_minimum_size.x = 0.0
	if bench_control is ScrollContainer:
		(bench_control as ScrollContainer).horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER

	_recycle_drop_zone = RECYCLE_DROP_ZONE_SCRIPT.new() as PanelContainer
	if _recycle_drop_zone == null:
		return
	_recycle_drop_zone.name = "RecycleDropZone"
	_recycle_drop_zone.custom_minimum_size = Vector2(148, 118)
	_recycle_drop_zone.size_flags_horizontal = Control.SIZE_SHRINK_END
	_recycle_drop_zone.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bench_row.add_child(_recycle_drop_zone)
	bench_row.move_child(bench_control, 0)
	bench_row.move_child(_recycle_drop_zone, 1)
	_layout_bench_recycle_wrap()


func _is_point_in_recycle_zone(screen_pos: Vector2) -> bool:
	if _recycle_drop_zone == null or not is_instance_valid(_recycle_drop_zone):
		return false
	if not _recycle_drop_zone.visible:
		return false
	return _recycle_drop_zone.get_global_rect().has_point(screen_pos)


func _try_sell_dragging_unit() -> bool:
	if _dragging_unit == null or not _is_valid_unit(_dragging_unit):
		return false
	# 规则：仅允许出售备战区角色，已上场角色必须先拖回备战区。
	if _drag_origin_kind != "bench":
		debug_label.text = "已上场角色不可直接出售，请先拖回备战区。"
		return false
	return _sell_unit_node(_dragging_unit)


func _on_recycle_sell_requested(payload: Dictionary, price: int) -> void:
	if _stage != Stage.PREPARATION:
		return
	if _economy_manager == null:
		return
	var item_type: String = str(payload.get("type", "")).strip_edges()
	if item_type == "unit":
		var unit_node: Node = payload.get("unit_node", null)
		if unit_node == null or not _is_valid_unit(unit_node):
			return
		if _sell_unit_node(unit_node):
			return
		debug_label.text = "出售失败：该角色不在备战区。"
		return
	if item_type == "gongfa" or item_type == "equipment":
		var item_id: String = str(payload.get("id", "")).strip_edges()
		if item_id.is_empty():
			return
		if not _consume_owned_item(item_type, item_id, 1):
			debug_label.text = "出售失败：库存不足。"
			return
		var item_data: Dictionary = {}
		var raw_item_data: Variant = payload.get("item_data", {})
		if raw_item_data is Dictionary:
			item_data = (raw_item_data as Dictionary).duplicate(true)
		# 价格以服务端（场景逻辑）重算为准，避免 UI 侧 payload 被误改后价格异常。
		var final_price: int = _get_sell_price_item(item_data)
		if final_price <= 0:
			final_price = maxi(price, 0)
		_economy_manager.add_silver(final_price)
		_append_battle_log(
			"出售%s：%s（+%d 银两）" % [
				"功法" if item_type == "gongfa" else "装备",
				_resolve_sell_item_name(item_type, item_id),
				final_price
			],
			"system"
		)
		_refresh_all_ui()


func _sell_unit_node(unit_node: Node) -> bool:
	if unit_node == null or not _is_valid_unit(unit_node):
		return false
	if _economy_manager == null:
		return false
	var unit_name: String = str(_safe_node_prop(unit_node, "unit_name", "未知角色"))
	var in_bench: bool = bool(unit_node.get("is_on_bench"))
	# 若单位仍在备战席，先从槽位移除，再交给对象池回收。
	if bench_ui != null and bench_ui.has_method("find_slot_of_unit"):
		var slot: int = int(bench_ui.call("find_slot_of_unit", unit_node))
		if slot >= 0:
			in_bench = true
			bench_ui.call("remove_unit_at", slot)
	if not in_bench:
		return false
	var price: int = _get_sell_price_unit(unit_node)
	if _detail_unit == unit_node:
		_close_detail_panel(false)
	unit_factory.call("release_unit", unit_node)
	_economy_manager.add_silver(price)
	_append_battle_log(
		"出售角色：%s（+%d 银两）" % [
			unit_name,
			price
		],
		"system"
	)
	_refresh_all_ui()
	return true


func _get_sell_price_unit(unit: Node) -> int:
	if unit == null or not _is_valid_unit(unit):
		return 0
	return maxi(int(_safe_node_prop(unit, "cost", 0)), 0)


func _get_sell_price_item(item_data: Dictionary) -> int:
	var quality_key: String = str(item_data.get("quality", item_data.get("rarity", "white"))).strip_edges().to_lower()
	return int(QUALITY_SELL_PRICE.get(quality_key, 1))


func _resolve_sell_item_name(item_type: String, item_id: String) -> String:
	if gongfa_manager == null:
		return item_id
	var data: Dictionary = {}
	if item_type == "gongfa":
		data = gongfa_manager.call("get_gongfa_data", item_id)
	else:
		data = gongfa_manager.call("get_equipment_data", item_id)
	return str(data.get("name", item_id))


func _ensure_battle_stats_panel_created() -> void:
	if _battle_stats_panel != null and is_instance_valid(_battle_stats_panel):
		return
	var detail_layer: CanvasLayer = get_node_or_null("DetailLayer") as CanvasLayer
	if detail_layer == null:
		return

	_battle_stats_panel = PanelContainer.new()
	_battle_stats_panel.name = "BattleStatsPanel"
	_battle_stats_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_battle_stats_panel.visible = false
	detail_layer.add_child(_battle_stats_panel)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 10)
	_battle_stats_panel.add_child(root)

	var title := Label.new()
	title.text = "战斗统计"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	root.add_child(title)

	_battle_stats_mvp_label = Label.new()
	_battle_stats_mvp_label.text = "🏆 MVP：无"
	_battle_stats_mvp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_battle_stats_mvp_label.add_theme_font_size_override("font_size", 20)
	root.add_child(_battle_stats_mvp_label)

	var tab_row := HBoxContainer.new()
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	tab_row.add_theme_constant_override("separation", 8)
	root.add_child(tab_row)

	_battle_stats_tab_ally_button = Button.new()
	_battle_stats_tab_ally_button.text = "己方统计"
	_battle_stats_tab_ally_button.toggle_mode = true
	_battle_stats_tab_ally_button.button_pressed = true
	_battle_stats_tab_ally_button.pressed.connect(Callable(self, "_on_battle_stats_tab_pressed").bind(TEAM_ALLY))
	tab_row.add_child(_battle_stats_tab_ally_button)

	_battle_stats_tab_enemy_button = Button.new()
	_battle_stats_tab_enemy_button.text = "敌方统计"
	_battle_stats_tab_enemy_button.toggle_mode = true
	_battle_stats_tab_enemy_button.button_pressed = false
	_battle_stats_tab_enemy_button.pressed.connect(Callable(self, "_on_battle_stats_tab_pressed").bind(TEAM_ENEMY))
	tab_row.add_child(_battle_stats_tab_enemy_button)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)
	root.add_child(row)

	_battle_stats_damage_rank = _create_rank_text_panel(row, "伤害排行")
	_battle_stats_tank_rank = _create_rank_text_panel(row, "承伤排行")
	_battle_stats_heal_rank = _create_rank_text_panel(row, "治疗排行")

	var close_row := HBoxContainer.new()
	close_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(close_row)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(spacer)

	var close_button := Button.new()
	close_button.text = "继续"
	close_button.pressed.connect(Callable(self, "_hide_battle_stats_panel"))
	close_row.add_child(close_button)

	_layout_battle_stats_panel()


func _create_rank_text_panel(parent: Control, title_text: String) -> RichTextLabel:
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


func _layout_battle_stats_panel() -> void:
	if _battle_stats_panel == null or not is_instance_valid(_battle_stats_panel):
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var width: float = minf(BATTLE_STATS_PANEL_WIDTH, viewport_size.x - 40.0)
	var height: float = minf(BATTLE_STATS_PANEL_HEIGHT, viewport_size.y - 70.0)
	var x: float = (viewport_size.x - width) * 0.5
	var y: float = (viewport_size.y - height) * 0.5
	_battle_stats_panel.position = Vector2(x, y)
	_battle_stats_panel.size = Vector2(width, height)


func _show_battle_stats_panel() -> void:
	if _battle_stats_panel == null or not is_instance_valid(_battle_stats_panel):
		return
	# 每次打开默认展示“己方统计”，便于快速查看本局阵容表现。
	_set_battle_stats_tab(TEAM_ALLY)
	_rebuild_battle_stats_panel_content()
	_layout_battle_stats_panel()
	_battle_stats_panel.visible = true


func _hide_battle_stats_panel() -> void:
	if _battle_stats_panel == null or not is_instance_valid(_battle_stats_panel):
		return
	_battle_stats_panel.visible = false


func _rebuild_battle_stats_panel_content() -> void:
	if _battle_statistics == null:
		return
	if _battle_stats_mvp_label == null:
		return
	var mvp: Dictionary = _battle_statistics.call("get_mvp", _battle_stats_current_team_tab)
	var team_name: String = "己方" if _battle_stats_current_team_tab == TEAM_ALLY else "敌方"
	if mvp.is_empty():
		_battle_stats_mvp_label.text = "🏆 %s MVP：无" % team_name
	else:
		_battle_stats_mvp_label.text = "🏆 %s MVP：%s（伤害 %d，击杀 %d）" % [
			team_name,
			str(mvp.get("unit_name", "未知")),
			int(mvp.get("damage_dealt", 0)),
			int(mvp.get("kills", 0))
		]
	if _battle_stats_damage_rank != null:
		_battle_stats_damage_rank.text = _format_rank_rich_text(_battle_statistics.call("get_ranked_stats", "damage_dealt", 8, 0, _battle_stats_current_team_tab), "damage_dealt")
	if _battle_stats_tank_rank != null:
		_battle_stats_tank_rank.text = _format_rank_rich_text(_battle_statistics.call("get_ranked_stats", "damage_taken", 8, 0, _battle_stats_current_team_tab), "damage_taken")
	if _battle_stats_heal_rank != null:
		_battle_stats_heal_rank.text = _format_rank_rich_text(_battle_statistics.call("get_ranked_stats", "healing_done", 8, 0, _battle_stats_current_team_tab), "healing_done")


func _on_battle_stats_tab_pressed(team_id: int) -> void:
	_set_battle_stats_tab(team_id)
	_rebuild_battle_stats_panel_content()


func _set_battle_stats_tab(team_id: int) -> void:
	_battle_stats_current_team_tab = TEAM_ALLY if team_id == TEAM_ALLY else TEAM_ENEMY
	if _battle_stats_tab_ally_button != null:
		_battle_stats_tab_ally_button.button_pressed = _battle_stats_current_team_tab == TEAM_ALLY
	if _battle_stats_tab_enemy_button != null:
		_battle_stats_tab_enemy_button.button_pressed = _battle_stats_current_team_tab == TEAM_ENEMY


func _format_rank_rich_text(rows: Array, stat_key: String) -> String:
	if rows.is_empty():
		return "[color=#A8A8A8]暂无数据[/color]"
	var lines: Array[String] = []
	for i in range(rows.size()):
		var row: Dictionary = rows[i]
		var rank: int = i + 1
		var unit_name: String = str(row.get("unit_name", "未知"))
		var value: int = int(row.get(stat_key, row.get("value", 0)))
		lines.append("%d. %s  %d" % [rank, unit_name, value])
	return "\n".join(lines)


func _find_unit_node_by_instance_id(instance_id: int) -> Node:
	if instance_id <= 0:
		return null
	for unit in _collect_player_units():
		if _is_valid_unit(unit) and unit.get_instance_id() == instance_id:
			return unit
	for enemy in _enemy_deployed.values():
		if _is_valid_unit(enemy) and enemy.get_instance_id() == instance_id:
			return enemy
	return null


func _ensure_shop_open_button() -> void:
	if _shop_bar == null:
		return
	if _shop_label != null:
		_shop_label.text = "综合商店"
	if _shop_open_button != null and is_instance_valid(_shop_open_button):
		return
	_shop_open_button = Button.new()
	_shop_open_button.text = "商店"
	_shop_open_button.toggle_mode = true
	_shop_open_button.button_pressed = true
	_shop_open_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_shop_open_button.pressed.connect(Callable(self, "_on_shop_open_button_pressed"))
	_shop_bar.add_child(_shop_open_button)
	_shop_bar.move_child(_shop_open_button, 1)


func _ensure_shop_panel_created() -> void:
	if _shop_panel != null and is_instance_valid(_shop_panel):
		return

	_shop_layer = CanvasLayer.new()
	_shop_layer.name = "ShopPanelLayer"
	_shop_layer.layer = SHOP_LAYER_INDEX
	add_child(_shop_layer)

	_shop_panel = PanelContainer.new()
	_shop_panel.name = "ShopPanel"
	_shop_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_shop_layer.add_child(_shop_panel)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 8)
	_shop_panel.add_child(root)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(header)

	_shop_title_label = Label.new()
	_shop_title_label.text = "综合商店"
	_shop_title_label.add_theme_font_size_override("font_size", 20)
	header.add_child(_shop_title_label)

	_shop_status_label = Label.new()
	_shop_status_label.text = "布阵期可购买"
	_shop_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_shop_status_label)

	_shop_close_button = Button.new()
	_shop_close_button.text = "关闭"
	_shop_close_button.pressed.connect(Callable(self, "_on_shop_close_pressed"))
	header.add_child(_shop_close_button)

	var tab_row := HBoxContainer.new()
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.add_theme_constant_override("separation", 8)
	root.add_child(tab_row)

	_shop_tabs.clear()
	for tab_info in [
		{"id": SHOP_TAB_RECRUIT, "name": "招募侠客"},
		{"id": SHOP_TAB_GONGFA, "name": "秘籍阁"},
		{"id": SHOP_TAB_EQUIPMENT, "name": "神兵铺"}
	]:
		var tab_id: String = str(tab_info.get("id", ""))
		var tab_btn := Button.new()
		tab_btn.text = str(tab_info.get("name", tab_id))
		tab_btn.toggle_mode = true
		tab_btn.button_pressed = tab_id == _shop_current_tab
		tab_btn.pressed.connect(Callable(self, "_on_shop_tab_pressed").bind(tab_id))
		tab_row.add_child(tab_btn)
		_shop_tabs[tab_id] = tab_btn

	_shop_offer_row = HBoxContainer.new()
	_shop_offer_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_offer_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shop_offer_row.add_theme_constant_override("separation", 10)
	root.add_child(_shop_offer_row)

	var op_panel := PanelContainer.new()
	op_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(op_panel)

	var op_root := VBoxContainer.new()
	op_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	op_root.add_theme_constant_override("separation", 4)
	op_panel.add_child(op_root)

	var row1 := HBoxContainer.new()
	row1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	op_root.add_child(row1)

	_shop_silver_label = Label.new()
	_shop_silver_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_silver_label.text = "银两: 0"
	row1.add_child(_shop_silver_label)

	_shop_refresh_button = Button.new()
	_shop_refresh_button.text = "刷新(2)"
	_shop_refresh_button.pressed.connect(Callable(self, "_on_bottom_refresh_pressed"))
	row1.add_child(_shop_refresh_button)

	_shop_test_add_silver_button = Button.new()
	_shop_test_add_silver_button.text = "测试+10银两"
	_shop_test_add_silver_button.pressed.connect(Callable(self, "_on_test_add_silver_pressed"))
	row1.add_child(_shop_test_add_silver_button)

	var row2 := HBoxContainer.new()
	row2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	op_root.add_child(row2)

	_shop_level_label = Label.new()
	_shop_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shop_level_label.text = "门派LV1 (0/2)"
	row2.add_child(_shop_level_label)

	_shop_upgrade_button = Button.new()
	_shop_upgrade_button.text = "升级(4)"
	_shop_upgrade_button.pressed.connect(Callable(self, "_on_bottom_upgrade_pressed"))
	row2.add_child(_shop_upgrade_button)

	_shop_test_add_exp_button = Button.new()
	_shop_test_add_exp_button.text = "测试+5经验"
	_shop_test_add_exp_button.pressed.connect(Callable(self, "_on_test_add_exp_pressed"))
	row2.add_child(_shop_test_add_exp_button)

	_shop_lock_button = Button.new()
	_shop_lock_button.text = "锁定"
	_shop_lock_button.pressed.connect(Callable(self, "_on_bottom_lock_pressed"))
	row2.add_child(_shop_lock_button)

	_layout_shop_panel()
	_set_shop_panel_visible(true)


func _layout_shop_panel() -> void:
	if _shop_panel == null or not is_instance_valid(_shop_panel):
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var left_limit: float = LEFT_PANEL_WIDTH + 18.0
	var right_limit: float = viewport_size.x - INVENTORY_PANEL_WIDTH - 16.0
	if right_limit - left_limit < 420.0:
		left_limit = 12.0
		right_limit = viewport_size.x - 12.0
	var available_width: float = maxf(right_limit - left_limit, 360.0)
	var panel_width: float = clampf(available_width, SHOP_PANEL_MIN_WIDTH, SHOP_PANEL_MAX_WIDTH)
	panel_width = minf(panel_width, available_width)

	var bottom_top: float = bottom_panel.position.y if bottom_panel != null else viewport_size.y - 230.0
	var panel_height: float = minf(SHOP_PANEL_HEIGHT, maxf(bottom_top - TOP_BAR_HEIGHT - 24.0, 220.0))
	var panel_x: float = left_limit + (available_width - panel_width) * 0.5
	var panel_y: float = clampf(bottom_top - panel_height - 10.0, TOP_BAR_HEIGHT + 10.0, viewport_size.y - panel_height - 8.0)
	_shop_panel.position = Vector2(panel_x, panel_y)
	_shop_panel.size = Vector2(panel_width, panel_height)


func _set_shop_panel_visible(panel_visible: bool) -> void:
	if _shop_panel == null or not is_instance_valid(_shop_panel):
		return
	_shop_panel.visible = panel_visible
	if _shop_open_button != null and is_instance_valid(_shop_open_button):
		_shop_open_button.button_pressed = panel_visible
	_sync_linkage_panel_visibility()


func _on_shop_open_button_pressed() -> void:
	if _stage != Stage.PREPARATION:
		return
	_shop_open_in_preparation = not (_shop_panel != null and _shop_panel.visible)
	_set_shop_panel_visible(_shop_open_in_preparation)
	_update_shop_ui()


func _on_shop_close_pressed() -> void:
	_shop_open_in_preparation = false
	_set_shop_panel_visible(false)
	_update_shop_ui()


func _on_shop_tab_pressed(tab_id: String) -> void:
	_shop_current_tab = tab_id
	for key in _shop_tabs.keys():
		var btn: Button = _shop_tabs[key] as Button
		if btn != null:
			btn.button_pressed = str(key) == _shop_current_tab
	_rebuild_shop_cards()


func _on_bottom_refresh_pressed() -> void:
	if _stage != Stage.PREPARATION or _economy_manager == null or _shop_manager == null:
		return
	var cost: int = _economy_manager.get_refresh_cost()
	if not _economy_manager.spend_silver(cost):
		debug_label.text = "银两不足：刷新需要 %d 银两" % cost
		return
	_economy_manager.set_shop_locked(false)
	_shop_manager.refresh_shop(_economy_manager.get_shop_probabilities(), false, true)
	_append_battle_log("商店刷新：消耗 %d 银两" % cost, "system")
	_update_shop_ui()


func _on_bottom_lock_pressed() -> void:
	if _stage != Stage.PREPARATION or _economy_manager == null:
		return
	var next_locked: bool = not _economy_manager.is_shop_locked()
	_economy_manager.set_shop_locked(next_locked)
	debug_label.text = "商店已锁定，下回合将保留当前商品。" if next_locked else "商店已解锁，下回合会自动刷新。"
	_update_shop_ui()


func _on_bottom_upgrade_pressed() -> void:
	if _stage != Stage.PREPARATION or _economy_manager == null:
		return
	if not _economy_manager.buy_exp_with_silver():
		debug_label.text = "银两不足：升级需要 %d 银两" % _economy_manager.get_upgrade_cost()
		return
	_append_battle_log(
		"门派修炼：消耗 %d 银两，获得 %d 经验" % [
			_economy_manager.get_upgrade_cost(),
			_economy_manager.get_upgrade_exp_gain()
		],
		"system"
	)
	_update_shop_ui()


func _refresh_shop_for_preparation(force_refresh: bool) -> void:
	if _economy_manager == null or _shop_manager == null:
		return
	var locked: bool = _economy_manager.is_shop_locked()
	_shop_manager.refresh_shop(_economy_manager.get_shop_probabilities(), locked, force_refresh)
	_update_shop_ui()


func _update_shop_ui() -> void:
	_update_shop_operation_labels()
	_rebuild_shop_cards()


func _update_shop_operation_labels() -> void:
	if _economy_manager == null:
		return
	var assets: Dictionary = _economy_manager.get_assets_snapshot()
	var silver: int = int(assets.get("silver", 0))
	var level: int = int(assets.get("level", 1))
	var exp_value: int = int(assets.get("exp", 0))
	var max_exp: int = int(assets.get("max_exp", 0))
	var locked: bool = bool(assets.get("locked_shop", false))
	var stage_editable: bool = _stage == Stage.PREPARATION

	if _shop_silver_label != null:
		_shop_silver_label.text = "当前银两: %d" % silver
	if _shop_level_label != null:
		_shop_level_label.text = "门派LV%d (%d/%d) 上场上限:%d" % [level, exp_value, max_exp, _economy_manager.get_max_deploy_limit()]
	if _shop_refresh_button != null:
		_shop_refresh_button.text = "刷新(💰%d)" % _economy_manager.get_refresh_cost()
		_shop_refresh_button.disabled = not stage_editable
	if _shop_upgrade_button != null:
		_shop_upgrade_button.text = "升级(💰%d)" % _economy_manager.get_upgrade_cost()
		_shop_upgrade_button.disabled = not stage_editable or max_exp <= 0
	if _shop_lock_button != null:
		_shop_lock_button.text = "🔓 解锁" if locked else "🔒 锁定当前"
		_shop_lock_button.disabled = not stage_editable
	if _shop_status_label != null:
		if _stage != Stage.PREPARATION:
			_shop_status_label.text = "交锋期/结算期关闭商店"
		else:
			_shop_status_label.text = "商店已锁定，下回合保留商品" if locked else "布阵期可购买"

	if refresh_button != null:
		refresh_button.text = "刷新(%d)" % _economy_manager.get_refresh_cost()
	if upgrade_button != null:
		upgrade_button.text = "升级(%d)" % _economy_manager.get_upgrade_cost()
	if lock_button != null:
		lock_button.text = "解锁" if locked else "锁定"
	if _shop_open_button != null and is_instance_valid(_shop_open_button):
		_shop_open_button.disabled = _stage != Stage.PREPARATION


func _rebuild_shop_cards() -> void:
	if _shop_offer_row == null or _shop_manager == null:
		return
	for child in _shop_offer_row.get_children():
		child.queue_free()

	var offers: Array[Dictionary] = _shop_manager.get_offers(_shop_current_tab)
	var slot_count: int = 5
	for idx in range(slot_count):
		var offer: Dictionary = offers[idx] if idx < offers.size() else {}
		var card: PanelContainer = _create_shop_offer_card(offer, idx, _shop_current_tab)
		_shop_offer_row.add_child(card)


func _create_shop_offer_card(offer: Dictionary, index: int, tab_id: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(136, 170)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 3)
	card.add_child(root)

	var color_bar := ColorRect.new()
	color_bar.custom_minimum_size = Vector2(0, 8)
	color_bar.color = _quality_color(str(offer.get("quality", "white")))
	root.add_child(color_bar)

	var name_label := Label.new()
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.text = "已售罄"
	root.add_child(name_label)

	var type_label := Label.new()
	type_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	type_label.text = "-"
	root.add_child(type_label)

	var price_label := Label.new()
	price_label.text = ""
	root.add_child(price_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var buy_button := Button.new()
	buy_button.text = "购买"
	buy_button.disabled = true
	root.add_child(buy_button)

	if offer.is_empty():
		name_label.text = "空位"
		type_label.text = "暂无商品"
		price_label.text = ""
		buy_button.text = "—"
		buy_button.disabled = true
		return card

	var item_name: String = str(offer.get("name", "未知"))
	var quality: String = str(offer.get("quality", "white"))
	var slot_type: String = str(offer.get("slot_type", ""))
	var price: int = int(offer.get("price", 0))
	var sold: bool = bool(offer.get("sold", false))
	var item_id: String = str(offer.get("item_id", ""))

	name_label.text = item_name
	if tab_id == SHOP_TAB_RECRUIT:
		type_label.text = "[%s] %s" % [_quality_to_cn(quality), _role_to_cn(slot_type)]
	else:
		type_label.text = "[%s] %s" % [_quality_to_cn(quality), _slot_or_equip_cn(tab_id, slot_type)]

	price_label.text = "💰 %d" % price if price > 0 else ""
	buy_button.text = "已售罄" if sold else "购买"
	var can_afford: bool = _economy_manager != null and _economy_manager.get_silver() >= price
	buy_button.disabled = sold or _stage != Stage.PREPARATION or not can_afford
	buy_button.pressed.connect(Callable(self, "_on_shop_buy_pressed").bind(tab_id, index))

	# 复用 M3 Tooltip：秘籍和装备卡悬停时仍走统一详情面板。
	if not sold and not item_id.is_empty() and tab_id != SHOP_TAB_RECRUIT:
		var tooltip_payload: Dictionary = _build_gongfa_item_tooltip_data(item_id) if tab_id == SHOP_TAB_GONGFA else _build_equip_item_tooltip_data(item_id)
		card.set_meta("item_data", tooltip_payload)
		card.mouse_entered.connect(Callable(self, "_on_item_source_hover_entered").bind(card, tooltip_payload))
		card.mouse_exited.connect(Callable(self, "_on_item_source_hover_exited").bind(card))

	return card


func _on_shop_buy_pressed(tab_id: String, index: int) -> void:
	if _economy_manager == null or _shop_manager == null:
		return
	if _stage != Stage.PREPARATION:
		return

	var offer: Dictionary = _shop_manager.get_offer(tab_id, index)
	if offer.is_empty() or bool(offer.get("sold", false)):
		return

	var price: int = maxi(int(offer.get("price", 0)), 0)
	if not _economy_manager.spend_silver(price):
		debug_label.text = "银两不足：购买失败。"
		return

	if not _grant_offer(offer):
		# 发放失败时回滚银两，避免“扣钱但没拿到物品”。
		_economy_manager.add_silver(price)
		return

	_shop_manager.purchase_offer(tab_id, index)
	_append_battle_log("商店购买：%s（- %d 银两）" % [str(offer.get("name", "未知")), price], "system")
	_refresh_all_ui()


func _grant_offer(offer: Dictionary) -> bool:
	var tab_id: String = str(offer.get("tab", ""))
	var item_id: String = str(offer.get("item_id", "")).strip_edges()
	if item_id.is_empty():
		debug_label.text = "商店条目无效：缺少 item_id。"
		return false

	if tab_id == SHOP_TAB_RECRUIT:
		return _grant_recruit_unit(item_id)
	if tab_id == SHOP_TAB_GONGFA:
		_add_owned_item("gongfa", item_id, 1)
		return true
	if tab_id == SHOP_TAB_EQUIPMENT:
		_add_owned_item("equipment", item_id, 1)
		return true

	debug_label.text = "未知商店页签：%s" % tab_id
	return false


func _grant_recruit_unit(unit_id: String) -> bool:
	if bench_ui == null:
		return false
	if bench_ui.get_unit_count() >= bench_ui.get_slot_count():
		debug_label.text = "备战区已满，无法招募。"
		return false
	var unit_node: Node = unit_factory.call("acquire_unit", unit_id, -1, unit_layer)
	if unit_node == null:
		debug_label.text = "招募失败：无法创建角色 %s" % unit_id
		return false
	unit_node.call("set_team", 1)
	unit_node.call("set_on_bench_state", true, -1)
	unit_node.set("is_in_combat", false)
	_ensure_healer_default_skill(unit_node)
	if not bench_ui.add_unit(unit_node):
		unit_factory.call("release_unit", unit_node)
		debug_label.text = "备战区已满，无法招募。"
		return false
	_apply_visual_to_all_units()
	return true


func _spawn_random_units_to_bench(count: int) -> void:
	# M4 扩展：沿用 M2 生成逻辑后，补一轮“医者保底治疗功法”。
	super._spawn_random_units_to_bench(count)
	_apply_default_healer_skills_for_bench()


func _add_owned_item(category: String, item_id: String, amount: int) -> void:
	var target: Dictionary = _owned_gongfa_stock if category == "gongfa" else _owned_equipment_stock
	var count: int = maxi(int(target.get(item_id, 0)) + amount, 0)
	target[item_id] = count
	if count <= 0:
		target.erase(item_id)
	if category == "gongfa":
		_owned_gongfa_stock = target
	else:
		_owned_equipment_stock = target


func _consume_owned_item(category: String, item_id: String, amount: int) -> bool:
	var current: int = _get_owned_item_count(category, item_id)
	if current < amount:
		return false
	_add_owned_item(category, item_id, -amount)
	return true


func _get_owned_item_count(category: String, item_id: String) -> int:
	if category == "gongfa":
		return int(_owned_gongfa_stock.get(item_id, 0))
	return int(_owned_equipment_stock.get(item_id, 0))


func _count_equipped_instances(mode: String, item_id: String) -> int:
	var count: int = 0
	for unit in _collect_player_units():
		if unit == null or not _is_valid_unit(unit):
			continue
		if mode == "gongfa":
			var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
			for slot in SLOT_ORDER:
				if str(slots.get(slot, "")).strip_edges() == item_id:
					count += 1
		else:
			var equip_slots: Dictionary = _normalize_equip_slots(_get_unit_equip_slots(unit))
			for equip_slot in EQUIP_ORDER:
				if str(equip_slots.get(equip_slot, "")).strip_edges() == item_id:
					count += 1
	return count


func _prepare_linkage_panel_for_m4() -> void:
	var linkage_panel: Control = _get_linkage_panel_control()
	if linkage_panel == null:
		return
	# 联动面板作为信息层，不应拦截底下备战区/拖拽的输入。
	linkage_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if linkage_info != null:
		linkage_info.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _sync_linkage_panel_visibility() -> void:
	var linkage_panel: Control = _get_linkage_panel_control()
	if linkage_panel == null:
		return
	var hidden_by_shop: bool = _shop_panel != null and is_instance_valid(_shop_panel) and _shop_panel.visible
	linkage_panel.visible = _stage != Stage.RESULT and not hidden_by_shop


func _refresh_linkage_info_for_deployed_only() -> void:
	if linkage_info == null:
		return
	if gongfa_manager == null:
		linkage_info.text = "当前联动：未连接 GongfaManager"
		return
	var names: Array[String] = _build_deployed_linkage_names()
	if names.is_empty():
		linkage_info.text = "当前联动：无"
		linkage_info.tooltip_text = linkage_info.text
		return
	# 长文本会遮挡下方 UI，这里只展示前几项，完整内容放到 tooltip。
	var preview_names: Array[String] = names
	if names.size() > 6:
		preview_names = names.slice(0, 6)
		linkage_info.text = "当前联动：%s 等%d项" % ["、".join(preview_names), names.size()]
	else:
		linkage_info.text = "当前联动：%s" % "、".join(preview_names)
	linkage_info.tooltip_text = "当前联动（仅统计上场）：%s" % "、".join(names)


func _build_deployed_linkage_names() -> Array[String]:
	# M4 规则：联动面板只统计“当前已上场”的己方角色，过滤备战席与历史战斗残留。
	var names: Array[String] = []
	if gongfa_manager == null or not gongfa_manager.has_method("get_active_linkages"):
		return names
	var deployed_map: Dictionary = _collect_current_deployed_ally_ids()
	if deployed_map.is_empty():
		return names
	var name_seen: Dictionary = {}
	var active_value: Variant = gongfa_manager.call("get_active_linkages")
	if not (active_value is Array):
		return names
	for result_value in active_value:
		if not (result_value is Dictionary):
			continue
		var result: Dictionary = result_value as Dictionary
		if int(result.get("team_id", 0)) != TEAM_ALLY:
			continue
		var participants_value: Variant = result.get("participants", [])
		if not (participants_value is Array):
			continue
		var participants: Array = participants_value as Array
		if participants.is_empty():
			continue
		var all_on_field: bool = true
		for unit_value in participants:
			var unit: Node = unit_value as Node
			if unit == null or not _is_valid_unit(unit):
				all_on_field = false
				break
			if not deployed_map.has(unit.get_instance_id()):
				all_on_field = false
				break
		if not all_on_field:
			continue
		var linkage_data: Dictionary = result.get("linkage_data", {})
		var linkage_name: String = str(linkage_data.get("name", "")).strip_edges()
		if linkage_name.is_empty() or name_seen.has(linkage_name):
			continue
		name_seen[linkage_name] = true
		names.append(linkage_name)
	return names


func _collect_current_deployed_ally_ids() -> Dictionary:
	var out: Dictionary = {}
	for unit in _ally_deployed.values():
		if not _is_valid_unit(unit):
			continue
		out[unit.get_instance_id()] = true
	return out


func _get_linkage_panel_control() -> Control:
	if linkage_info == null:
		return null
	var linkage_vbox: Control = linkage_info.get_parent() as Control
	if linkage_vbox == null:
		return null
	return linkage_vbox.get_parent() as Control


func _layout_bench_recycle_wrap() -> void:
	if bottom_panel == null:
		return
	var root_vbox: VBoxContainer = bottom_panel.get_node_or_null("RootVBox") as VBoxContainer
	if root_vbox == null:
		return
	var wrap: MarginContainer = root_vbox.get_node_or_null("BenchRecycleWrap") as MarginContainer
	if wrap == null:
		return

	# ── 1. 计算右边距（避开仓库面板） ──
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var right_margin: int = int(INVENTORY_PANEL_WIDTH + 14.0)
	if viewport_size.x < 980.0:
		right_margin = int(maxf(INVENTORY_PANEL_WIDTH * 0.55, 132.0))
	wrap.add_theme_constant_override("margin_right", right_margin)

	var row: HBoxContainer = wrap.get_node_or_null("BenchRecycleRow") as HBoxContainer
	if row == null:
		return

	# ── 2. 计算行总可用宽度 ──
	# bottom_panel.size.x 已经被 _set_bottom_expanded 限制为视口宽度 - 24px。
	# 行可用 = 面板内容宽 - 右边距 - 一些内边距
	var panel_content_width: float = maxf(bottom_panel.size.x - 16.0, 300.0)
	var total_row_width: float = maxf(panel_content_width - float(right_margin), 200.0)

	# ── 3. 回收区固定宽度 ──
	var recycle_width: float = 160.0
	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		recycle_width = maxf(_recycle_drop_zone.custom_minimum_size.x, 148.0)
	var row_gap: float = maxf(float(row.get_theme_constant("separation")), 8.0)

	# ── 4. 备战区可用宽度 ──
	var bench_max_width: float = maxf(total_row_width - recycle_width - row_gap, 200.0)

	# ── 5. 强制设置行容器宽度（截断溢出） ──
	row.clip_contents = true
	row.size.x = total_row_width

	# ── 6. 强制限制备战区 ScrollContainer 宽度 ──
	var bench_control: Control = bench_ui as Control
	if bench_control != null:
		bench_control.clip_contents = true
		bench_control.custom_minimum_size.x = 0.0
		bench_control.size.x = bench_max_width
		bench_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bench_control.size_flags_stretch_ratio = 1.0

		var row_min_h: float = maxf(bench_control.custom_minimum_size.y, 154.0)
		wrap.custom_minimum_size = Vector2(0.0, row_min_h)

		# 通知备战席基于新宽度重算列数
		if bench_ui.has_method("refresh_adaptive_layout"):
			bench_ui.call_deferred("refresh_adaptive_layout")

		if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
			_recycle_drop_zone.custom_minimum_size = Vector2(recycle_width, row_min_h)
			_recycle_drop_zone.size_flags_horizontal = Control.SIZE_SHRINK_END
			_recycle_drop_zone.size_flags_stretch_ratio = 0.0
			_recycle_drop_zone.visible = _stage == Stage.PREPARATION


func _apply_default_healer_skills_for_bench() -> void:
	if bench_ui == null or not is_instance_valid(bench_ui):
		return
	if not bench_ui.has_method("get_all_units"):
		return
	var units_value: Variant = bench_ui.call("get_all_units")
	if not (units_value is Array):
		return
	for unit in units_value:
		_ensure_healer_default_skill(unit as Node)


func _ensure_healer_default_skill(unit: Node) -> void:
	if unit == null or not _is_valid_unit(unit):
		return
	if gongfa_manager == null:
		return
	var role: String = str(_safe_node_prop(unit, "role", "")).strip_edges().to_lower()
	if role != HEALER_ROLE_KEY:
		return
	if _unit_has_healing_gongfa(unit):
		return
	var quality: String = str(_safe_node_prop(unit, "quality", "white")).strip_edges().to_lower()
	var fallback_id: String = _pick_healer_fallback_gongfa_id(quality)
	if fallback_id.is_empty():
		return
	var fallback_data: Dictionary = gongfa_manager.call("get_gongfa_data", fallback_id)
	if fallback_data.is_empty():
		return
	var slot: String = str(fallback_data.get("type", "qishu")).strip_edges()
	if slot.is_empty():
		return
	var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
	slots[slot] = fallback_id
	unit.set("gongfa_slots", slots)
	gongfa_manager.call("apply_gongfa", unit)


func _unit_has_healing_gongfa(unit: Node) -> bool:
	if unit == null or not _is_valid_unit(unit):
		return false
	var slots: Dictionary = _normalize_unit_slots(unit.get("gongfa_slots"))
	for slot in SLOT_ORDER:
		var gongfa_id: String = str(slots.get(slot, "")).strip_edges()
		if gongfa_id.is_empty():
			continue
		var data: Dictionary = gongfa_manager.call("get_gongfa_data", gongfa_id)
		if _is_healing_gongfa_data(data):
			return true
	return false


func _pick_healer_fallback_gongfa_id(quality: String) -> String:
	var preferred: Variant = HEALER_FALLBACK_GONGFA_BY_QUALITY.get(quality, [])
	if preferred is Array:
		for id_value in preferred:
			var gongfa_id: String = str(id_value).strip_edges()
			if gongfa_id.is_empty():
				continue
			var data: Dictionary = gongfa_manager.call("get_gongfa_data", gongfa_id)
			if not data.is_empty():
				return gongfa_id
	# 兜底：按全部映射遍历，拿到任意可用治疗功法。
	for key in HEALER_FALLBACK_GONGFA_BY_QUALITY.keys():
		var arr: Variant = HEALER_FALLBACK_GONGFA_BY_QUALITY[key]
		if not (arr is Array):
			continue
		for id_value in arr:
			var gongfa_id: String = str(id_value).strip_edges()
			if gongfa_id.is_empty():
				continue
			var data: Dictionary = gongfa_manager.call("get_gongfa_data", gongfa_id)
			if not data.is_empty():
				return gongfa_id
	return ""


func _is_healing_gongfa_data(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	var tags_value: Variant = data.get("tags", [])
	if tags_value is Array:
		for tag in tags_value:
			var tag_str: String = str(tag).to_lower()
			if tag_str == "heal" or tag_str == "recovery" or tag_str == "support":
				return true
	var skill_value: Variant = data.get("skill", {})
	if not (skill_value is Dictionary):
		return false
	var effects_value: Variant = (skill_value as Dictionary).get("effects", [])
	if not (effects_value is Array):
		return false
	for effect_value in effects_value:
		if not (effect_value is Dictionary):
			continue
		var op: String = str((effect_value as Dictionary).get("op", "")).strip_edges()
		if op == "heal_self" or op == "heal_self_percent" or op == "heal_allies_aoe" or op == "buff_allies_aoe":
			return true
	return false


func _slot_or_equip_cn(tab_id: String, slot_type: String) -> String:
	if tab_id == SHOP_TAB_GONGFA:
		return _slot_to_cn(slot_type)
	return _equip_type_to_cn(slot_type)


func _role_to_cn(role: String) -> String:
	match role:
		"vanguard":
			return "先锋"
		"swordsman":
			return "剑客"
		"assassin":
			return "刺客"
		"archer":
			return "射手"
		"caster":
			return "术师"
		"healer":
			return "医者"
		"commander":
			return "统领"
		_:
			return role


func _on_assets_changed(_snapshot: Dictionary) -> void:
	_update_shop_ui()


func _on_shop_locked_changed(_locked: bool) -> void:
	_update_shop_ui()


func _on_shop_snapshot_refreshed(_snapshot: Dictionary) -> void:
	_rebuild_shop_cards()


func _on_test_add_silver_pressed() -> void:
	if _economy_manager == null:
		return
	_economy_manager.add_silver(10)
	_append_battle_log("测试指令：银两 +10", "system")
	_refresh_all_ui()


func _on_test_add_exp_pressed() -> void:
	if _economy_manager == null:
		return
	_economy_manager.add_exp(5)
	_append_battle_log("测试指令：经验 +5", "system")
	_refresh_all_ui()
