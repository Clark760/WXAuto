extends "res://scripts/ui/battlefield_ui.gd"

# ===========================
# 正式战斗场景
# ===========================
# 说明：
# 1. 在基础战场交互之上接入经济、商店、回收出售与战斗统计结算。
# 2. 本脚本负责正式战斗场景编排，不再承担历史阶段测试职责。
# 3. 与基础战斗层、UI 层、统计层按职责协作。

const SHOP_TAB_RECRUIT: String = "recruit"
const SHOP_TAB_GONGFA: String = "gongfa"
const SHOP_TAB_EQUIPMENT: String = "equipment"

const QUALITY_SELL_PRICE: Dictionary = {
	"white": 1,
	"green": 2,
	"blue": 3,
	"purple": 5,
	"orange": 8,
	"red": 15
}

const ECONOMY_MANAGER_SCRIPT: Script = preload("res://scripts/economy/economy_manager.gd")
const SHOP_MANAGER_SCRIPT: Script = preload("res://scripts/economy/shop_manager.gd")
const RECYCLE_DROP_ZONE_SCRIPT: Script = preload("res://scripts/ui/recycle_drop_zone.gd")
const BATTLE_FLOW_SCRIPT: Script = preload("res://scripts/combat/battle_flow.gd")
const STAGE_MANAGER_SCRIPT: Script = preload("res://scripts/stage/stage_manager.gd")
const SHOP_CONTROLLER_SCRIPT: Script = preload("res://scripts/board/shop_controller.gd")
const STAGE_BRIDGE_SCRIPT: Script = preload("res://scripts/board/stage_bridge.gd")
const INVENTORY_CONTROLLER_SCRIPT: Script = preload("res://scripts/board/inventory_controller.gd")
const RECYCLE_CONTROLLER_SCRIPT: Script = preload("res://scripts/board/recycle_controller.gd")

const DEFAULT_DEPLOY_ZONE: Dictionary = {
	"x_min": 0,
	"x_max": 15,
	"y_min": 0,
	"y_max": 15
}

var _economy_manager: Node = null
var _shop_manager: Node = null
var _stage_manager: Node = null

@onready var _shop_panel: PanelContainer = $ShopPanelLayer/ShopPanel
@onready var _shop_open_button: Button = $HUDLayer/TopBar/TopBarContent/ShopOpenButton
@onready var _start_battle_button: Button = $HUDLayer/TopBar/TopBarContent/StartBattleButton
@onready var _reset_battle_button: Button = $HUDLayer/TopBar/TopBarContent/ResetBattleButton
@onready var _shop_status_label: Label = $ShopPanelLayer/ShopPanel/ShopRoot/HeaderRow/ShopStatus
@onready var _shop_close_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/HeaderRow/ShopCloseButton
@onready var _shop_tab_recruit_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/TabRow/RecruitTabButton
@onready var _shop_tab_gongfa_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/TabRow/GongfaTabButton
@onready var _shop_tab_equipment_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/TabRow/EquipmentTabButton
var _shop_tabs: Dictionary = {}
@onready var _shop_offer_row: HBoxContainer = $ShopPanelLayer/ShopPanel/ShopRoot/OfferRow
@onready var _shop_silver_label: Label = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row1/ShopSilverLabel
@onready var _shop_level_label: Label = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopLevelLabel
@onready var _shop_refresh_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row1/ShopRefreshButton
@onready var _shop_upgrade_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopUpgradeButton
@onready var _shop_lock_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopLockButton
@onready var _shop_test_add_silver_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row1/ShopTestAddSilverButton
@onready var _shop_test_add_exp_button: Button = $ShopPanelLayer/ShopPanel/ShopRoot/OperationPanel/OperationRoot/Row2/ShopTestAddExpButton

var _shop_current_tab: String = SHOP_TAB_RECRUIT
var _shop_open_in_preparation: bool = true
var _battle_scene_initialized: bool = false
var _scene_reload_requested: bool = false

var _owned_gongfa_stock: Dictionary = {}    # gongfa_id -> count
var _owned_equipment_stock: Dictionary = {} # equip_id -> count
var _recycle_drop_zone: PanelContainer = null

var _battle_flow: Node = null
var _current_stage_config: Dictionary = {}
var _current_deploy_zone: Dictionary = DEFAULT_DEPLOY_ZONE.duplicate(true)
var _stage_enemy_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _stage_forced_hex_size: float = -1.0
var _shop_controller: Node = null
var _stage_bridge: Node = null
var _inventory_controller: Node = null
var _recycle_controller: Node = null


func _bootstrap_board_controllers() -> void:
	# M5：将商店、关卡桥接、库存、回收拆为独立控制器，降低 battlefield 职责耦合。
	if _shop_controller == null:
		_shop_controller = SHOP_CONTROLLER_SCRIPT.new() as Node
		_shop_controller.name = "RuntimeShopController"
		add_child(_shop_controller)
	if _stage_bridge == null:
		_stage_bridge = STAGE_BRIDGE_SCRIPT.new() as Node
		_stage_bridge.name = "RuntimeStageBridge"
		add_child(_stage_bridge)
	if _inventory_controller == null:
		_inventory_controller = INVENTORY_CONTROLLER_SCRIPT.new() as Node
		_inventory_controller.name = "RuntimeInventoryController"
		add_child(_inventory_controller)
	if _recycle_controller == null:
		_recycle_controller = RECYCLE_CONTROLLER_SCRIPT.new() as Node
		_recycle_controller.name = "RuntimeRecycleController"
		add_child(_recycle_controller)


func _ready() -> void:
	# 兜底取消暂停：防止从调试切场景时遗留 pause 状态，导致“进入场景像挂起”。
	get_tree().paused = false
	_bootstrap_board_controllers()
	_stage_enemy_rng.randomize()
	_bootstrap_battle_services()
	super._ready()
	_ensure_recycle_zone_created()
	_ensure_battle_flow_created()
	_shop_tabs = {
		SHOP_TAB_RECRUIT: _shop_tab_recruit_button,
		SHOP_TAB_GONGFA: _shop_tab_gongfa_button,
		SHOP_TAB_EQUIPMENT: _shop_tab_equipment_button
	}
	_connect_battle_ui_signals()
	_initialize_stage_progression()
	_refresh_shop_for_preparation(true)
	_update_shop_ui()
	_battle_scene_initialized = true
	_refresh_all_ui()
	_apply_stage_ui_state()


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
	# 战斗场景内按 F7 直接重开正式战场，便于反复调试完整局内循环。
	if event.pressed and not event.echo and event.keycode == KEY_F7:
		_request_battlefield_reload()
		return
	if event.pressed and not event.echo and event.keycode == KEY_B and _stage == Stage.PREPARATION:
		_shop_open_in_preparation = not (_shop_panel != null and _shop_panel.visible)
		_set_shop_panel_visible(_shop_open_in_preparation)
		_update_shop_ui()
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
	# M5-FIX: 从结算阶段离开时，立即停止胜利动作并重置为待机。
	if previous_stage == Stage.RESULT and next_stage != Stage.RESULT:
		reset_all_units_to_idle()
	if next_stage == Stage.PREPARATION and previous_stage != Stage.PREPARATION:
		_shop_open_in_preparation = true
		_refresh_shop_for_preparation(false)
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
	if _battle_flow != null and is_instance_valid(_battle_flow):
		_battle_flow.call("sync_stage", _stage, Stage.RESULT)
	_update_shop_ui()


func _on_viewport_size_changed() -> void:
	super._on_viewport_size_changed()
	_layout_bench_recycle_wrap()
	if _battle_flow != null and is_instance_valid(_battle_flow):
		_battle_flow.call("refresh_layout")


func _set_bottom_expanded(expanded: bool, animate: bool) -> void:
	# 底栏在展开/收起时，回收区与备战席的可见区域会发生变化，
	# 这里在父类布局结束后立刻重排，避免“回收区被挤出屏幕”。
	super._set_bottom_expanded(expanded, animate)
	_layout_bench_recycle_wrap()


func _refresh_dynamic_ui() -> void:
	super._refresh_dynamic_ui()
	if _economy_manager == null:
		return
	_update_shop_operation_labels()


func _refresh_all_ui() -> void:
	super._refresh_all_ui()
	_update_shop_ui()
	if _battle_flow != null and is_instance_valid(_battle_flow):
		_battle_flow.call("refresh_panel")


func _on_battle_ended(winner_team: int, summary: Dictionary) -> void:
	super._on_battle_ended(winner_team, summary)
	if _stage_manager != null and is_instance_valid(_stage_manager):
		_stage_manager.call("on_battle_ended", winner_team, summary)
	_update_shop_ui()


func reset_all_units_to_idle() -> void:
	# 离开 RESULT 阶段前，统一把仍存活单位恢复到待机状态，避免胜利动作残留。
	var units: Array[Node] = []
	units.append_array(_collect_units_from_map(_ally_deployed))
	units.append_array(_collect_units_from_map(_enemy_deployed))
	for unit in units:
		if not _is_valid_unit(unit):
			continue
		# M5-FIX：死亡单位不做待机重置，保持死亡表现，避免出现“假复活”观感。
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat != null and not bool(combat.get("is_alive")):
			continue
		if unit.has_method("reset_visual_transform"):
			unit.call("reset_visual_transform")
		unit.call("play_anim_state", 0, {})

func _on_bench_changed() -> void:
	super._on_bench_changed()
	_update_shop_operation_labels()


func _get_drop_target(screen_mouse: Vector2) -> Dictionary:
	# 优先识别“回收区”落点，再回退到棋盘/备战席判定。
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
			var can_sell_unit: bool = _get_drag_origin_kind() == "bench"
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


func _restore_drag_origin() -> void:
	# 本地兜底：避免继承链调整时找不到 Runtime 层同名方法。
	var drag_controller: Node = get("_drag_controller") as Node
	if drag_controller != null and is_instance_valid(drag_controller):
		drag_controller.call("restore_drag_origin")


func _get_drag_origin_kind() -> String:
	# 本地兜底：由 RuntimeDragController 返回拖拽来源。
	var drag_controller: Node = get("_drag_controller") as Node
	if drag_controller != null and is_instance_valid(drag_controller):
		return str(drag_controller.call("get_drag_origin_kind"))
	return ""


func _on_data_reloaded(is_full_reload: bool, summary: Dictionary) -> void:
	super._on_data_reloaded(is_full_reload, summary)
	_rebuild_battle_data_caches()
	if _stage_manager != null and is_instance_valid(_stage_manager):
		var data_manager: Node = _get_root_node("DataManager")
		_stage_manager.call("load_stage_sequence", data_manager)
		var current_stage_id: String = str(_stage_manager.call("get_current_stage_id"))
		if current_stage_id.is_empty() or not bool(_stage_manager.call("start_stage", current_stage_id)):
			_stage_manager.call("start_first_stage")
	_refresh_shop_for_preparation(true)


func _on_gongfa_data_reloaded(summary: Dictionary) -> void:
	super._on_gongfa_data_reloaded(summary)
	_rebuild_battle_data_caches()
	if _stage_manager != null and is_instance_valid(_stage_manager):
		var data_manager: Node = _get_root_node("DataManager")
		_stage_manager.call("load_stage_sequence", data_manager)
		var current_stage_id: String = str(_stage_manager.call("get_current_stage_id"))
		if not current_stage_id.is_empty():
			_stage_manager.call("start_stage", current_stage_id)
	_refresh_shop_for_preparation(true)


func _is_ally_deploy_zone(cell: Vector2i) -> bool:
	if not bool(hex_grid.is_inside_grid(cell)):
		return false
	var x_min: int = int(_current_deploy_zone.get("x_min", 0))
	var x_max: int = int(_current_deploy_zone.get("x_max", 15))
	var y_min: int = int(_current_deploy_zone.get("y_min", 0))
	var y_max: int = int(_current_deploy_zone.get("y_max", int(hex_grid.grid_height) - 1))
	return cell.x >= x_min and cell.x <= x_max and cell.y >= y_min and cell.y <= y_max


func _collect_ally_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var width: int = int(hex_grid.grid_width)
	var height: int = int(hex_grid.grid_height)
	for y in range(height):
		for x in range(width):
			var cell: Vector2i = Vector2i(x, y)
			if _is_ally_deploy_zone(cell) and not _is_stage_cell_blocked(cell):
				cells.append(cell)
	return cells


func _collect_enemy_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var width: int = int(hex_grid.grid_width)
	var height: int = int(hex_grid.grid_height)
	for y in range(height):
		for x in range(width):
			var cell: Vector2i = Vector2i(x, y)
			if _is_ally_deploy_zone(cell):
				continue
			if _is_stage_cell_blocked(cell):
				continue
			cells.append(cell)
	return cells


func _is_stage_cell_blocked(cell: Vector2i) -> bool:
	if combat_manager == null or not is_instance_valid(combat_manager):
		return false
	if not combat_manager.has_method("is_cell_blocked"):
		return false
	return bool(combat_manager.call("is_cell_blocked", cell))


func _can_deploy_ally_to_cell(unit: Node, cell: Vector2i) -> bool:
	if not super._can_deploy_ally_to_cell(unit, cell):
		return false
	if _is_stage_cell_blocked(cell):
		return false
	if _economy_manager == null:
		return true
	var limit: int = _economy_manager.get_max_deploy_limit()
	# 仅限制“新增上场单位”。战场单位重新拖拽换位不应被阻断。
	if _ally_deployed.size() >= limit and not _ally_deployed.has(_cell_key(cell)):
		return false
	return true


func _spawn_enemy_wave(count: int) -> void:
	if _spawn_enemies_from_stage_config():
		return
	super._spawn_enemy_wave(count)


func _spawn_enemies_from_stage_config() -> bool:
	if _stage_bridge != null:
		return bool(_stage_bridge.call("spawn_enemies_from_stage_config", self))
	return false

func _resolve_stage_enemy_cells(enemy_cfg: Dictionary, wanted_count: int, occupied: Dictionary) -> Array[Vector2i]:
	var zone: String = str(enemy_cfg.get("deploy_zone", "random")).strip_edges().to_lower()
	var candidates: Array[Vector2i] = []
	if zone == "fixed":
		var fixed_cells_value: Variant = enemy_cfg.get("fixed_cells", [])
		if fixed_cells_value is Array:
			for cell_value in fixed_cells_value:
				if not (cell_value is Vector2i):
					continue
				var fixed_cell: Vector2i = cell_value as Vector2i
				if not bool(hex_grid.is_inside_grid(fixed_cell)):
					continue
				if _is_ally_deploy_zone(fixed_cell):
					continue
				if _is_stage_cell_blocked(fixed_cell):
					continue
				if _ally_deployed.has(_cell_key(fixed_cell)) or _enemy_deployed.has(_cell_key(fixed_cell)):
					continue
				if occupied.has(_cell_key(fixed_cell)):
					continue
				candidates.append(fixed_cell)
		return _pick_stage_enemy_cells(candidates, wanted_count, occupied)

	var zone_cells: Array[Vector2i] = _collect_enemy_cells_by_zone(zone)
	return _pick_stage_enemy_cells(zone_cells, wanted_count, occupied)


func _collect_enemy_cells_by_zone(zone: String) -> Array[Vector2i]:
	var all_enemy_cells: Array[Vector2i] = _collect_enemy_spawn_cells()
	if all_enemy_cells.is_empty():
		return []
	var width: int = int(hex_grid.grid_width)
	var _x_min: int = int(_current_deploy_zone.get("x_min", 0))
	var x_max: int = int(_current_deploy_zone.get("x_max", 15))
	var y_min: int = int(_current_deploy_zone.get("y_min", 0))
	var y_max: int = int(_current_deploy_zone.get("y_max", int(hex_grid.grid_height) - 1))
	var enemy_x_start: int = clampi(x_max + 1, 0, width - 1)
	var enemy_x_end: int = width - 1
	var enemy_span: int = maxi(enemy_x_end - enemy_x_start + 1, 1)
	var third: int = maxi(int(round(float(enemy_span) / 3.0)), 1)

	var front_cells: Array[Vector2i] = []
	var back_cells: Array[Vector2i] = []
	var center_cells: Array[Vector2i] = []
	var center_x_min: int = clampi(enemy_x_start + enemy_span / 3, enemy_x_start, enemy_x_end)
	var center_x_max: int = clampi(enemy_x_end - enemy_span / 3, enemy_x_start, enemy_x_end)
	var center_y_min: int = y_min + maxi((y_max - y_min) / 4, 0)
	var center_y_max: int = y_max - maxi((y_max - y_min) / 4, 0)

	for cell in all_enemy_cells:
		if cell.x <= enemy_x_start + third - 1:
			front_cells.append(cell)
		if cell.x >= enemy_x_end - third + 1:
			back_cells.append(cell)
		if cell.x >= center_x_min and cell.x <= center_x_max and cell.y >= center_y_min and cell.y <= center_y_max:
			center_cells.append(cell)

	match zone:
		"front":
			return front_cells if not front_cells.is_empty() else all_enemy_cells
		"back":
			return back_cells if not back_cells.is_empty() else all_enemy_cells
		"center":
			return center_cells if not center_cells.is_empty() else all_enemy_cells
		_:
			return all_enemy_cells


func _pick_stage_enemy_cells(candidates: Array[Vector2i], wanted_count: int, occupied: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if candidates.is_empty() or wanted_count <= 0:
		return result
	var pool: Array[Vector2i] = candidates.duplicate()
	_shuffle_cells(pool, _stage_enemy_rng)
	for cell in pool:
		if result.size() >= wanted_count:
			break
		var key: String = _cell_key(cell)
		if occupied.has(key):
			continue
		if _ally_deployed.has(key) or _enemy_deployed.has(key):
			continue
		occupied[key] = true
		result.append(cell)
	return result


func _apply_stage_enemy_overrides(unit_node: Node, enemy_cfg: Dictionary) -> void:
	if unit_node == null or not _is_valid_unit(unit_node):
		return
	var base_stats: Dictionary = (unit_node.get("base_stats") as Dictionary).duplicate(true)
	var stats_changed: bool = false
	var stat_scale: float = maxf(float(enemy_cfg.get("stat_scale", 1.0)), 0.01)
	if not is_equal_approx(stat_scale, 1.0):
		# 关卡倍率只放大核心战斗数值，不改写 RNG/SPD/WIS。
		var scalable_keys: Array[String] = ["hp", "mp", "atk", "iat", "def", "idr"]
		for stat_key in scalable_keys:
			var current_value: Variant = base_stats.get(stat_key, 0.0)
			if current_value is int or current_value is float:
				base_stats[stat_key] = float(current_value) * stat_scale
		stats_changed = true
	# summon_units 的 clone 模式可按 hp/atk 比例局部缩放，避免只能整表缩放。
	var hp_ratio: float = maxf(float(enemy_cfg.get("hp_ratio", 1.0)), 0.01)
	if not is_equal_approx(hp_ratio, 1.0):
		base_stats["hp"] = float(base_stats.get("hp", 1.0)) * hp_ratio
		stats_changed = true
	var atk_ratio: float = maxf(float(enemy_cfg.get("atk_ratio", 1.0)), 0.01)
	if not is_equal_approx(atk_ratio, 1.0):
		base_stats["atk"] = float(base_stats.get("atk", 1.0)) * atk_ratio
		base_stats["iat"] = float(base_stats.get("iat", 1.0)) * atk_ratio
		stats_changed = true
	if stats_changed:
		unit_node.set("base_stats", base_stats)
		unit_node.call("_apply_runtime_stats")

	if gongfa_manager != null:
		gongfa_manager.call("apply_gongfa", unit_node)


func spawn_mechanic_enemy_wave(wave_units_value: Variant) -> int:
	if not (wave_units_value is Array):
		return 0
	var wave_units: Array = wave_units_value
	if wave_units.is_empty():
		return 0

	var occupied: Dictionary = {}
	for key in _ally_deployed.keys():
		occupied[str(key)] = true
	for key in _enemy_deployed.keys():
		occupied[str(key)] = true

	var spawned_total: int = 0
	for row_value in wave_units:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = (row_value as Dictionary).duplicate(true)
		var unit_id: String = str(row.get("unit_id", "")).strip_edges()
		var count: int = maxi(int(row.get("count", 1)), 0)
		var star: int = clampi(int(row.get("star", 1)), 1, 3)
		if unit_id.is_empty() or count <= 0:
			continue
		if not row.has("deploy_zone"):
			row["deploy_zone"] = "back"
		var spawn_cells: Array[Vector2i] = _resolve_stage_enemy_cells(row, count, occupied)
		for cell in spawn_cells:
			var unit_node: Node = unit_factory.call("acquire_unit", unit_id, star, unit_layer)
			if unit_node == null:
				continue
			_apply_stage_enemy_overrides(unit_node, row)
			_deploy_enemy_unit_to_cell(unit_node, cell)
			if combat_manager != null \
			and combat_manager.has_method("is_battle_running") \
			and bool(combat_manager.call("is_battle_running")) \
			and combat_manager.has_method("add_unit_mid_battle"):
				combat_manager.call("add_unit_mid_battle", unit_node)
			spawned_total += 1

	if spawned_total > 0:
		_refresh_multimesh()
		_refresh_all_ui()
	return spawned_total


func _is_enemy_unit_alive(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _is_non_combat_stage(config: Dictionary) -> bool:
	if _stage_bridge != null:
		return bool(_stage_bridge.call("is_non_combat_stage", config))
	if config.is_empty():
		return false
	var stage_type: String = str(config.get("type", "normal")).strip_edges().to_lower()
	return stage_type == "rest" or stage_type == "event"

func _start_combat() -> void:
	# 开战前按门派等级动态收紧自动上场上限。
	if _battle_flow != null and is_instance_valid(_battle_flow):
		_battle_flow.call("prepare_for_battle_start")
	if _economy_manager != null:
		max_auto_deploy = _economy_manager.get_max_deploy_limit()
	# 休息/事件关不进入战斗，按一次“开始战斗”直接结算关卡奖励并推进。
	if _is_non_combat_stage(_current_stage_config):
		if _stage_manager != null and is_instance_valid(_stage_manager):
			if bool(_stage_manager.call("complete_current_stage_without_battle")):
				return
	super._start_combat()
	if bool(combat_manager.call("is_battle_running")):
		if _stage_manager != null and is_instance_valid(_stage_manager):
			_stage_manager.call("notify_stage_combat_started")
		if _battle_flow != null and is_instance_valid(_battle_flow):
			_battle_flow.call(
				"start_battle_capture",
				_collect_units_from_map(_ally_deployed),
				_collect_units_from_map(_enemy_deployed)
			)


func _rebuild_inventory_items() -> void:
	if _inventory_controller != null:
		_inventory_controller.call("rebuild_inventory_items", self)
		return
	_rebuild_inventory_items_impl()


func _rebuild_inventory_items_impl() -> void:
	# 正式仓库使用“拥有库存”视图：
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
	card.custom_minimum_size = Vector2(0, 122)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text = str(item_data.get("name", str(item_data.get("id", "未知"))))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(name_label)

	var type_line := Label.new()
	type_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	# 正式场景的槽位拖放规则：
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


func _bootstrap_battle_services() -> void:
	var data_manager: Node = _get_root_node("DataManager")
	if _economy_manager == null:
		_economy_manager = ECONOMY_MANAGER_SCRIPT.new() as Node
		_economy_manager.name = "RuntimeEconomyManager"
		add_child(_economy_manager)
	if _shop_manager == null:
		_shop_manager = SHOP_MANAGER_SCRIPT.new() as Node
		_shop_manager.name = "RuntimeShopManager"
		add_child(_shop_manager)
	if _stage_manager == null:
		_stage_manager = STAGE_MANAGER_SCRIPT.new() as Node
		_stage_manager.name = "RuntimeStageManager"
		add_child(_stage_manager)
	_rebuild_battle_data_caches()

	if _economy_manager != null:
		_economy_manager.setup_from_data_manager(data_manager)
	if _stage_manager != null:
		_stage_manager.call(
			"configure_runtime_context",
			_economy_manager,
			bench_ui,
			self,
			unit_factory,
			TEAM_ALLY
		)
		_stage_manager.call("load_stage_sequence", data_manager)
	# M5 合并后 Boss 机制改由 GongfaManager 统一执行，这里不再挂载旧 runner。


func _rebuild_battle_data_caches() -> void:
	if _shop_manager != null:
		_shop_manager.reload_pools(unit_factory, gongfa_manager)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("reload_terrain_registry"):
		var data_manager: Node = _get_root_node("DataManager")
		combat_manager.call("reload_terrain_registry", data_manager)


func _connect_battle_ui_signals() -> void:
	_connect_shop_ui_signals()

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
	if _stage_manager != null:
		var stage_loaded_cb: Callable = Callable(self, "_on_stage_loaded")
		if _stage_manager.has_signal("stage_loaded") and not _stage_manager.is_connected("stage_loaded", stage_loaded_cb):
			_stage_manager.connect("stage_loaded", stage_loaded_cb)
		var stage_combat_cb: Callable = Callable(self, "_on_stage_combat_started")
		if _stage_manager.has_signal("stage_combat_started") and not _stage_manager.is_connected("stage_combat_started", stage_combat_cb):
			_stage_manager.connect("stage_combat_started", stage_combat_cb)
		var stage_completed_cb: Callable = Callable(self, "_on_stage_completed")
		if _stage_manager.has_signal("stage_completed") and not _stage_manager.is_connected("stage_completed", stage_completed_cb):
			_stage_manager.connect("stage_completed", stage_completed_cb)
		var stage_failed_cb: Callable = Callable(self, "_on_stage_failed")
		if _stage_manager.has_signal("stage_failed") and not _stage_manager.is_connected("stage_failed", stage_failed_cb):
			_stage_manager.connect("stage_failed", stage_failed_cb)
		var all_cleared_cb: Callable = Callable(self, "_on_all_stages_cleared")
		if _stage_manager.has_signal("all_stages_cleared") and not _stage_manager.is_connected("all_stages_cleared", all_cleared_cb):
			_stage_manager.connect("all_stages_cleared", all_cleared_cb)

	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		var sell_cb: Callable = Callable(self, "_on_recycle_sell_requested")
		if _recycle_drop_zone.has_signal("sell_requested") and not _recycle_drop_zone.is_connected("sell_requested", sell_cb):
			_recycle_drop_zone.connect("sell_requested", sell_cb)


func _connect_shop_ui_signals() -> void:
	if _shop_open_button != null:
		_shop_open_button.text = "商店(B)"
		_shop_open_button.toggle_mode = true
		var shop_open_cb: Callable = Callable(self, "_on_shop_open_button_pressed")
		if not _shop_open_button.is_connected("pressed", shop_open_cb):
			_shop_open_button.connect("pressed", shop_open_cb)

	if _start_battle_button != null:
		_start_battle_button.text = "开始战斗(F6)"
		var start_cb: Callable = Callable(self, "_on_start_battle_button_pressed")
		if not _start_battle_button.is_connected("pressed", start_cb):
			_start_battle_button.connect("pressed", start_cb)

	if _reset_battle_button != null:
		_reset_battle_button.text = "重置战场(F7)"
		var reset_cb: Callable = Callable(self, "_on_reset_battle_button_pressed")
		if not _reset_battle_button.is_connected("pressed", reset_cb):
			_reset_battle_button.connect("pressed", reset_cb)

	if _shop_close_button != null:
		var close_cb: Callable = Callable(self, "_on_shop_close_pressed")
		if not _shop_close_button.is_connected("pressed", close_cb):
			_shop_close_button.connect("pressed", close_cb)

	if _shop_tab_recruit_button != null:
		_shop_tab_recruit_button.toggle_mode = true
		var recruit_tab_cb: Callable = Callable(self, "_on_shop_tab_pressed").bind(SHOP_TAB_RECRUIT)
		if not _shop_tab_recruit_button.is_connected("pressed", recruit_tab_cb):
			_shop_tab_recruit_button.connect("pressed", recruit_tab_cb)
	if _shop_tab_gongfa_button != null:
		_shop_tab_gongfa_button.toggle_mode = true
		var gongfa_tab_cb: Callable = Callable(self, "_on_shop_tab_pressed").bind(SHOP_TAB_GONGFA)
		if not _shop_tab_gongfa_button.is_connected("pressed", gongfa_tab_cb):
			_shop_tab_gongfa_button.connect("pressed", gongfa_tab_cb)
	if _shop_tab_equipment_button != null:
		_shop_tab_equipment_button.toggle_mode = true
		var equip_tab_cb: Callable = Callable(self, "_on_shop_tab_pressed").bind(SHOP_TAB_EQUIPMENT)
		if not _shop_tab_equipment_button.is_connected("pressed", equip_tab_cb):
			_shop_tab_equipment_button.connect("pressed", equip_tab_cb)

	if _shop_refresh_button != null:
		var refresh_cb: Callable = Callable(self, "_on_bottom_refresh_pressed")
		if not _shop_refresh_button.is_connected("pressed", refresh_cb):
			_shop_refresh_button.connect("pressed", refresh_cb)
	if _shop_upgrade_button != null:
		var upgrade_cb: Callable = Callable(self, "_on_bottom_upgrade_pressed")
		if not _shop_upgrade_button.is_connected("pressed", upgrade_cb):
			_shop_upgrade_button.connect("pressed", upgrade_cb)
	if _shop_lock_button != null:
		var lock_cb: Callable = Callable(self, "_on_bottom_lock_pressed")
		if not _shop_lock_button.is_connected("pressed", lock_cb):
			_shop_lock_button.connect("pressed", lock_cb)
	if _shop_test_add_silver_button != null:
		var test_silver_cb: Callable = Callable(self, "_on_test_add_silver_pressed")
		if not _shop_test_add_silver_button.is_connected("pressed", test_silver_cb):
			_shop_test_add_silver_button.connect("pressed", test_silver_cb)
	if _shop_test_add_exp_button != null:
		var test_exp_cb: Callable = Callable(self, "_on_test_add_exp_pressed")
		if not _shop_test_add_exp_button.is_connected("pressed", test_exp_cb):
			_shop_test_add_exp_button.connect("pressed", test_exp_cb)

	for key in _shop_tabs.keys():
		var tab_btn: Button = _shop_tabs[key] as Button
		if tab_btn != null:
			tab_btn.button_pressed = str(key) == _shop_current_tab

	_refresh_top_quick_action_buttons()


func _initialize_stage_progression() -> void:
	if _stage_manager == null or not is_instance_valid(_stage_manager):
		return
	var data_manager: Node = _get_root_node("DataManager")
	var requested_sequence_id: String = _consume_requested_stage_sequence_id()
	if requested_sequence_id.is_empty():
		_stage_manager.call("load_stage_sequence", data_manager)
	else:
		_stage_manager.call("load_stage_sequence", data_manager, requested_sequence_id)
	var started: bool = bool(_stage_manager.call("start_first_stage"))
	if not started and not requested_sequence_id.is_empty():
		_stage_manager.call("load_stage_sequence", data_manager)
		started = bool(_stage_manager.call("start_first_stage"))
		if started:
			_append_battle_log("指定章节序列不可用：%s，已回退默认序列。" % requested_sequence_id, "system")
	if not started:
		debug_label.text = "M5 提示：未检测到关卡配置，沿用旧战场模式。"


func _consume_requested_stage_sequence_id() -> String:
	var game_manager: Node = _get_root_node("GameManager")
	if game_manager == null or not is_instance_valid(game_manager):
		return ""
	if game_manager.has_method("consume_requested_stage_sequence_id"):
		return str(game_manager.call("consume_requested_stage_sequence_id")).strip_edges()
	if game_manager.has_method("consume_requested_stage_id"):
		return str(game_manager.call("consume_requested_stage_id")).strip_edges()
	return ""


func _on_stage_loaded(config: Dictionary) -> void:
	_current_stage_config = config.duplicate(true)
	_round_index = maxi(int(_current_stage_config.get("index", _round_index)), 1)
	_apply_stage_runtime_config(_current_stage_config)
	# 切回布阵期，准备下一关。
	_set_stage(Stage.PREPARATION)
	_refresh_shop_for_preparation(false)
	_update_shop_ui()
	var stage_name: String = str(_current_stage_config.get("name", str(_current_stage_config.get("id", "未知关卡"))))
	var stage_type: String = str(_current_stage_config.get("type", "normal"))
	_append_battle_log("进入关卡：%s（%s）" % [stage_name, stage_type], "system")
	debug_label.text = "当前关卡：%s（布阵阶段）" % stage_name


func _on_stage_combat_started(config: Dictionary) -> void:
	var stage_name: String = str(config.get("name", str(config.get("id", "未知关卡"))))
	_append_battle_log("关卡开战：%s" % stage_name, "system")


func _on_stage_completed(config: Dictionary, rewards: Dictionary) -> void:
	var stage_name: String = str(config.get("name", str(config.get("id", "未知关卡"))))
	var silver: int = int(rewards.get("silver", 0))
	var exp_value: int = int(rewards.get("exp", 0))
	var granted_units: int = (rewards.get("granted_units", []) as Array).size() if rewards.get("granted_units", []) is Array else 0
	var drops_count: int = (rewards.get("drops", []) as Array).size() if rewards.get("drops", []) is Array else 0
	_append_battle_log(
		"关卡胜利：%s，奖励 银两+%d 经验+%d 掉落%d 侠客%d" % [stage_name, silver, exp_value, drops_count, granted_units],
		"system"
	)
	var advanced: bool = false
	if _stage_manager != null and is_instance_valid(_stage_manager):
		advanced = bool(_stage_manager.call("advance_to_next_stage"))
	if not advanced:
		return
	return


func _on_stage_failed(config: Dictionary) -> void:
	var stage_name: String = str(config.get("name", str(config.get("id", "未知关卡"))))
	_append_battle_log("关卡失败：%s（按 F7 重置，或调试后重开）" % stage_name, "death")


func _on_all_stages_cleared() -> void:
	_append_battle_log("全部关卡已完成，恭喜通关。", "system")
	debug_label.text = "全部关卡已完成。按 F7 可重开。"


func _apply_stage_runtime_config(config: Dictionary) -> void:
	_apply_stage_grid_config(config.get("grid", {}))
	_apply_stage_terrains(config.get("terrains", []), config.get("obstacles", []))
	_clear_enemy_wave()
	# 若仍残留战斗状态，强制停战并重置计时。
	if combat_manager != null and combat_manager.has_method("is_battle_running") and bool(combat_manager.call("is_battle_running")):
		if combat_manager.has_method("stop_battle"):
			combat_manager.call("stop_battle", "stage_switched", 0)
	_combat_elapsed = 0.0
	_refresh_deployed_positions()
	_apply_visual_to_all_units()
	_refresh_all_ui()


func _apply_stage_grid_config(grid_value: Variant) -> void:
	var grid_cfg: Dictionary = {}
	if grid_value is Dictionary:
		grid_cfg = (grid_value as Dictionary).duplicate(true)
	var width: int = maxi(int(grid_cfg.get("width", int(hex_grid.grid_width))), 4)
	var height: int = maxi(int(grid_cfg.get("height", int(hex_grid.grid_height))), 4)
	hex_grid.grid_width = width
	hex_grid.grid_height = height
	_stage_forced_hex_size = -1.0
	if grid_cfg.has("hex_size"):
		_stage_forced_hex_size = maxf(float(grid_cfg.get("hex_size", -1.0)), 8.0)
		hex_grid.hex_size = _stage_forced_hex_size
	if grid_cfg.get("deploy_zone", null) is Dictionary:
		_current_deploy_zone = (grid_cfg.get("deploy_zone", {}) as Dictionary).duplicate(true)
	else:
		_current_deploy_zone = DEFAULT_DEPLOY_ZONE.duplicate(true)
	_current_deploy_zone["x_min"] = clampi(int(_current_deploy_zone.get("x_min", 0)), 0, width - 1)
	_current_deploy_zone["x_max"] = clampi(int(_current_deploy_zone.get("x_max", 15)), 0, width - 1)
	_current_deploy_zone["y_min"] = clampi(int(_current_deploy_zone.get("y_min", 0)), 0, height - 1)
	_current_deploy_zone["y_max"] = clampi(int(_current_deploy_zone.get("y_max", height - 1)), 0, height - 1)
	if int(_current_deploy_zone["x_min"]) > int(_current_deploy_zone["x_max"]):
		var swap_x: int = int(_current_deploy_zone["x_min"])
		_current_deploy_zone["x_min"] = int(_current_deploy_zone["x_max"])
		_current_deploy_zone["x_max"] = swap_x
	if int(_current_deploy_zone["y_min"]) > int(_current_deploy_zone["y_max"]):
		var swap_y: int = int(_current_deploy_zone["y_min"])
		_current_deploy_zone["y_min"] = int(_current_deploy_zone["y_max"])
		_current_deploy_zone["y_max"] = swap_y
	if deploy_overlay != null and deploy_overlay.has_method("set_deploy_zone_rect"):
		deploy_overlay.call(
			"set_deploy_zone_rect",
			int(_current_deploy_zone.get("x_min", 0)),
			int(_current_deploy_zone.get("x_max", 15)),
			int(_current_deploy_zone.get("y_min", 0)),
			int(_current_deploy_zone.get("y_max", height - 1))
		)
	_refit_hex_grid()


func _calculate_fit_hex_size(available_w: float, available_h: float) -> float:
	if _stage_forced_hex_size > 0.0:
		# M5 支持关卡自定义 hex_size：优先使用关卡配置，并保留一个最小可视下限。
		return maxf(_stage_forced_hex_size, 8.0)
	return super._calculate_fit_hex_size(available_w, available_h)


func _apply_stage_terrains(terrains_value: Variant, obstacles_value: Variant) -> void:
	if combat_manager == null or not is_instance_valid(combat_manager):
		return
	if combat_manager.has_method("clear_static_terrains"):
		combat_manager.call("clear_static_terrains")

	var terrain_rows: Array[Dictionary] = _normalize_stage_terrains(terrains_value, obstacles_value)
	if terrain_rows.is_empty():
		return
	if not combat_manager.has_method("add_static_terrain"):
		return
	for row in terrain_rows:
		var terrain_id: String = str(row.get("terrain_id", "")).strip_edges().to_lower()
		if terrain_id.is_empty():
			continue
		var cells_value: Variant = row.get("cells", [])
		if not (cells_value is Array):
			continue
		var normalized_cells: Array[Vector2i] = []
		for cell_value in (cells_value as Array):
			if cell_value is Vector2i:
				normalized_cells.append(cell_value as Vector2i)
			elif cell_value is Array:
				var arr: Array = cell_value as Array
				if arr.size() >= 2:
					normalized_cells.append(Vector2i(int(arr[0]), int(arr[1])))
			elif cell_value is Dictionary:
				var cell_dict: Dictionary = cell_value as Dictionary
				normalized_cells.append(Vector2i(int(cell_dict.get("x", -1)), int(cell_dict.get("y", -1))))
		if normalized_cells.is_empty():
			continue
		var extra: Dictionary = {}
		for key in row.keys():
			if key == "terrain_id" or key == "cells":
				continue
			extra[key] = row[key]
		combat_manager.call("add_static_terrain", terrain_id, normalized_cells, extra)


func _normalize_stage_terrains(terrains_value: Variant, obstacles_value: Variant) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if terrains_value is Array:
		for item in terrains_value:
			if not (item is Dictionary):
				continue
			var row: Dictionary = (item as Dictionary).duplicate(true)
			var terrain_id: String = str(row.get("terrain_id", "")).strip_edges().to_lower()
			if terrain_id.is_empty():
				continue
			var cells_value: Variant = row.get("cells", [])
			if not (cells_value is Array) or (cells_value as Array).is_empty():
				continue
			rows.append(row)
	if rows.is_empty() and obstacles_value is Array:
		for obstacle_value in obstacles_value:
			if not (obstacle_value is Dictionary):
				continue
			var obstacle: Dictionary = obstacle_value as Dictionary
			var obstacle_type: String = str(obstacle.get("type", "rock")).strip_edges().to_lower()
			if obstacle_type.is_empty():
				continue
			var cells_value: Variant = obstacle.get("cells", [])
			if not (cells_value is Array) or (cells_value as Array).is_empty():
				continue
			rows.append({
				"terrain_id": "terrain_%s" % obstacle_type,
				"cells": (cells_value as Array).duplicate(true)
			})
	return rows


func _ensure_battle_flow_created() -> void:
	if _battle_flow != null and is_instance_valid(_battle_flow):
		return
	var detail_layer: CanvasLayer = get_node_or_null("DetailLayer") as CanvasLayer
	if detail_layer == null:
		return
	_battle_flow = BATTLE_FLOW_SCRIPT.new() as Node
	if _battle_flow == null:
		return
	_battle_flow.name = "BattleFlow"
	add_child(_battle_flow)
	_battle_flow.call("setup", self, combat_manager, gongfa_manager, detail_layer)


func _ensure_recycle_zone_created() -> void:
	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		return
	if bottom_panel == null or bench_ui == null:
		return
	var root_vbox: VBoxContainer = bottom_panel.get_node_or_null("RootVBox") as VBoxContainer
	var bench_control: Control = bench_ui as Control
	if root_vbox == null or bench_control == null:
		return
	var wrap_node_new: Node = root_vbox.get_node_or_null("BenchRecycleWrapRuntime")
	if wrap_node_new != null and _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		_layout_bench_recycle_wrap()
		return
	if wrap_node_new == null:
		var bench_wrap_new := Control.new()
		bench_wrap_new.name = "BenchRecycleWrapRuntime"
		bench_wrap_new.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bench_wrap_new.size_flags_vertical = Control.SIZE_EXPAND_FILL
		bench_wrap_new.custom_minimum_size = Vector2(0.0, 154.0)
		bench_wrap_new.clip_contents = true
		bench_wrap_new.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bench_index_new: int = root_vbox.get_children().find(bench_control)
		root_vbox.add_child(bench_wrap_new)
		root_vbox.move_child(bench_wrap_new, maxi(bench_index_new, 0))
		var resize_cb_new: Callable = Callable(self, "_layout_bench_recycle_wrap")
		if not bench_wrap_new.is_connected("resized", resize_cb_new):
			bench_wrap_new.connect("resized", resize_cb_new)
		if bench_control.get_parent() != bench_wrap_new:
			var old_parent_new: Node = bench_control.get_parent()
			if old_parent_new != null:
				old_parent_new.remove_child(bench_control)
			bench_wrap_new.add_child(bench_control)
		bench_control.size_flags_horizontal = 0
		bench_control.size_flags_vertical = 0
		bench_control.custom_minimum_size.x = 0.0
		bench_control.anchor_left = 0.0
		bench_control.anchor_top = 0.0
		bench_control.anchor_right = 0.0
		bench_control.anchor_bottom = 0.0
		bench_control.position = Vector2.ZERO
		if bench_control is ScrollContainer:
			var bench_scroll_new: ScrollContainer = bench_control as ScrollContainer
			bench_scroll_new.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
			bench_scroll_new.clip_contents = true
		_recycle_drop_zone = RECYCLE_DROP_ZONE_SCRIPT.new() as PanelContainer
		if _recycle_drop_zone == null:
			return
		_recycle_drop_zone.name = "RecycleDropZone"
		_recycle_drop_zone.custom_minimum_size = Vector2(148, 118)
		_recycle_drop_zone.size_flags_horizontal = 0
		_recycle_drop_zone.size_flags_vertical = 0
		_recycle_drop_zone.anchor_left = 0.0
		_recycle_drop_zone.anchor_top = 0.0
		_recycle_drop_zone.anchor_right = 0.0
		_recycle_drop_zone.anchor_bottom = 0.0
		bench_wrap_new.add_child(_recycle_drop_zone)
		_layout_bench_recycle_wrap()
		return

	# 用 MarginContainer 给“备战+回收行”预留右侧空间，避免被右栏仓库遮挡。
	var bench_wrap: Control = root_vbox.get_node_or_null("BenchRecycleWrap") as Control
	if bench_wrap != null and bench_wrap is Container:
		bench_wrap.queue_free()
		bench_wrap = null
	if bench_wrap == null:
		bench_wrap = Control.new()
		bench_wrap.name = "BenchRecycleWrap"
		bench_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bench_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
		bench_wrap.custom_minimum_size = Vector2(0.0, 154.0)
		bench_wrap.clip_contents = true
		bench_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	if _recycle_controller != null:
		return bool(_recycle_controller.call("try_sell_dragging_unit", self))
	return false

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


func _set_shop_panel_visible(panel_visible: bool) -> void:
	if _shop_panel == null or not is_instance_valid(_shop_panel):
		return
	_shop_panel.visible = panel_visible
	if _shop_open_button != null and is_instance_valid(_shop_open_button):
		_shop_open_button.button_pressed = panel_visible
	_refresh_top_quick_action_buttons()


func _on_shop_open_button_pressed() -> void:
	if _stage != Stage.PREPARATION:
		return
	_shop_open_in_preparation = not (_shop_panel != null and _shop_panel.visible)
	_set_shop_panel_visible(_shop_open_in_preparation)
	_update_shop_ui()


func _on_start_battle_button_pressed() -> void:
	# 顶部按钮与 F6 行为保持一致，统一走战斗启动入口。
	if _stage != Stage.PREPARATION:
		return
	_start_combat()
	_refresh_top_quick_action_buttons()


func _on_reset_battle_button_pressed() -> void:
	# 顶部“重置”与 F7 统一走同一安全入口。
	_request_battlefield_reload()


func _request_battlefield_reload() -> void:
	# 防抖：避免连点按钮/按键导致多次切场景并发。
	if _scene_reload_requested:
		return
	_scene_reload_requested = true
	# 战斗中先停逻辑，再延迟一帧切场景，规避释放顺序导致的崩溃。
	if combat_manager != null and combat_manager.has_method("is_battle_running") and bool(combat_manager.call("is_battle_running")):
		if combat_manager.has_method("stop_battle"):
			combat_manager.call("stop_battle", "manual_reload", 0)
	call_deferred("_emit_battlefield_reload_requested")


func _emit_battlefield_reload_requested() -> void:
	var event_bus: Node = _get_root_node("EventBus")
	if event_bus != null:
		event_bus.call("emit_scene_change_requested", "res://scenes/battle/battlefield.tscn")
	else:
		_scene_reload_requested = false


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
	if _shop_controller != null:
		_shop_controller.call("refresh_shop_for_preparation", self, force_refresh)
		return
	if _economy_manager == null or _shop_manager == null:
		return
	var locked: bool = _economy_manager.is_shop_locked()
	_shop_manager.refresh_shop(_economy_manager.get_shop_probabilities(), locked, force_refresh)
	_update_shop_ui()

func _update_shop_ui() -> void:
	if _shop_controller != null:
		_shop_controller.call("update_shop_ui", self)
		return
	_update_shop_operation_labels()
	_rebuild_shop_cards()

func _refresh_top_quick_action_buttons() -> void:
	var editable_stage: bool = _stage == Stage.PREPARATION
	if _shop_open_button != null and is_instance_valid(_shop_open_button):
		_shop_open_button.text = "商店(B)"
		_shop_open_button.disabled = not editable_stage
		_shop_open_button.tooltip_text = "快捷键：B"
	if _start_battle_button != null and is_instance_valid(_start_battle_button):
		_start_battle_button.text = "开始战斗(F6)"
		var battle_running: bool = false
		if combat_manager != null and combat_manager.has_method("is_battle_running"):
			battle_running = bool(combat_manager.call("is_battle_running"))
		_start_battle_button.disabled = (not editable_stage) or battle_running
		_start_battle_button.tooltip_text = "快捷键：F6"
	if _reset_battle_button != null and is_instance_valid(_reset_battle_button):
		_reset_battle_button.text = "重置战场(F7)"
		_reset_battle_button.disabled = false
		_reset_battle_button.tooltip_text = "快捷键：F7"


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
	if _shop_open_button != null and is_instance_valid(_shop_open_button):
		_shop_open_button.disabled = _stage != Stage.PREPARATION
	_refresh_top_quick_action_buttons()


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
		type_label.text = "[%s] 侠客" % _quality_to_cn(quality)
	else:
		type_label.text = "[%s] %s" % [_quality_to_cn(quality), _slot_or_equip_cn(tab_id, slot_type)]

	price_label.text = "💰 %d" % price if price > 0 else ""
	buy_button.text = "已售罄" if sold else "购买"
	var can_afford: bool = _economy_manager != null and _economy_manager.get_silver() >= price
	buy_button.disabled = sold or _stage != Stage.PREPARATION or not can_afford
	buy_button.pressed.connect(Callable(self, "_on_shop_buy_pressed").bind(tab_id, index))

	# 复用统一 Tooltip：秘籍和装备卡悬停时仍走详情面板。
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
	if not bench_ui.add_unit(unit_node):
		unit_factory.call("release_unit", unit_node)
		debug_label.text = "备战区已满，无法招募。"
		return false
	_apply_visual_to_all_units()
	return true


func _spawn_random_units_to_bench(count: int) -> void:
	super._spawn_random_units_to_bench(count)


func grant_stage_reward_item(item_type: String, item_id: String, count: int = 1) -> bool:
	var normalized_type: String = item_type.strip_edges().to_lower()
	var amount: int = maxi(count, 1)
	if item_id.strip_edges().is_empty():
		return false
	match normalized_type:
		"gongfa":
			_add_owned_item("gongfa", item_id, amount)
			_refresh_all_ui()
			return true
		"equipment":
			_add_owned_item("equipment", item_id, amount)
			_refresh_all_ui()
			return true
		_:
			return false


func grant_stage_reward_unit(unit_id: String, star: int = 1) -> Dictionary:
	var result: Dictionary = {
		"type": "unit",
		"id": unit_id,
		"star": clampi(star, 1, 3),
		"granted": false,
		"placement": "discarded"
	}
	if unit_id.strip_edges().is_empty():
		return result
	var unit_node: Node = unit_factory.call("acquire_unit", unit_id, clampi(star, 1, 3), unit_layer)
	if unit_node == null:
		return result
	unit_node.call("set_team", TEAM_ALLY)
	unit_node.call("set_on_bench_state", true, -1)
	unit_node.set("is_in_combat", false)

	# 优先放备战席；满员时退化为“棋盘部署区随机空格”。
	if bench_ui != null and bench_ui.has_method("add_unit") and bool(bench_ui.call("add_unit", unit_node)):
		result["granted"] = true
		result["placement"] = "bench"
		_apply_visual_to_all_units()
		_refresh_all_ui()
		return result

	var board_cell: Vector2i = _find_reward_unit_board_cell(unit_node)
	if board_cell.x >= 0:
		_deploy_ally_unit_to_cell(unit_node, board_cell)
		result["granted"] = true
		result["placement"] = "board"
		result["cell"] = board_cell
		_apply_visual_to_all_units()
		_refresh_all_ui()
		return result

	unit_factory.call("release_unit", unit_node)
	return result


func _find_reward_unit_board_cell(unit_node: Node = null) -> Vector2i:
	var candidates: Array[Vector2i] = _collect_ally_spawn_cells()
	if candidates.is_empty():
		return Vector2i(-1, -1)
	_shuffle_cells(candidates, _stage_enemy_rng)
	for cell in candidates:
		var cell_key: String = _cell_key(cell)
		if _ally_deployed.has(cell_key):
			continue
		if _is_stage_cell_blocked(cell):
			continue
		if unit_node != null and not _can_deploy_ally_to_cell(unit_node, cell):
			continue
		return cell
	return Vector2i(-1, -1)


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


func _layout_bench_recycle_wrap() -> void:
	if bottom_panel == null:
		return
	var root_vbox: VBoxContainer = bottom_panel.get_node_or_null("RootVBox") as VBoxContainer
	if root_vbox == null:
		return
	var wrap_runtime: Control = root_vbox.get_node_or_null("BenchRecycleWrapRuntime") as Control
	if wrap_runtime != null:
		var bench_control_runtime: Control = bench_ui as Control
		if bench_control_runtime == null or wrap_runtime.size.x <= 1.0 or wrap_runtime.size.y <= 1.0:
			return
		var gap: float = 8.0
		var wrap_size: Vector2 = wrap_runtime.size
		var row_height: float = maxf(wrap_size.y, 154.0)
		var base_recycle_width: float = 148.0
		if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
			base_recycle_width = maxf(_recycle_drop_zone.custom_minimum_size.x, 120.0)
		var slot_width: float = 112.0
		var slot_size_value: Variant = bench_ui.get("slot_size") if bench_ui != null else null
		if slot_size_value is Vector2:
			slot_width = maxf((slot_size_value as Vector2).x, 96.0)
		var recycle_min_width: float = 96.0
		var runtime_recycle_width: float = clampf(base_recycle_width, recycle_min_width, maxf(wrap_size.x - gap - slot_width, recycle_min_width))
		var bench_width: float = maxf(wrap_size.x - runtime_recycle_width - gap, 0.0)
		if bench_width < slot_width:
			runtime_recycle_width = maxf(wrap_size.x - slot_width - gap, recycle_min_width)
			bench_width = maxf(wrap_size.x - runtime_recycle_width - gap, 0.0)
		bench_control_runtime.clip_contents = true
		bench_control_runtime.custom_minimum_size = Vector2(0.0, row_height)
		bench_control_runtime.anchor_left = 0.0
		bench_control_runtime.anchor_top = 0.0
		bench_control_runtime.anchor_right = 0.0
		bench_control_runtime.anchor_bottom = 0.0
		bench_control_runtime.position = Vector2.ZERO
		bench_control_runtime.size = Vector2(bench_width, row_height)
		if bench_ui.has_method("set_layout_width"):
			bench_ui.call("set_layout_width", bench_width)
		if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
			_recycle_drop_zone.anchor_left = 0.0
			_recycle_drop_zone.anchor_top = 0.0
			_recycle_drop_zone.anchor_right = 0.0
			_recycle_drop_zone.anchor_bottom = 0.0
			_recycle_drop_zone.position = Vector2(wrap_size.x - runtime_recycle_width, 0.0)
			_recycle_drop_zone.size = Vector2(runtime_recycle_width, row_height)
			_recycle_drop_zone.custom_minimum_size = Vector2(runtime_recycle_width, row_height)
			_recycle_drop_zone.visible = _stage == Stage.PREPARATION
		wrap_runtime.custom_minimum_size = Vector2(0.0, row_height)
		if bench_ui.has_method("refresh_adaptive_layout"):
			bench_ui.call_deferred("refresh_adaptive_layout")
		return
	var wrap_container: MarginContainer = root_vbox.get_node_or_null("BenchRecycleWrap") as MarginContainer
	if wrap_container == null:
		return

	# ── 1. 计算右边距（避开仓库面板） ──
	var right_margin: int = 0
	wrap_container.add_theme_constant_override("margin_right", right_margin)
	wrap_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var row: HBoxContainer = wrap_container.get_node_or_null("BenchRecycleRow") as HBoxContainer
	if row == null:
		return
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if wrap_container.size.x <= 1.0:
		return

	# ── 2. 计算行总可用宽度 ──
	# bottom_panel.size.x 已经被 _set_bottom_expanded 限制为视口宽度 - 24px。
	# 行可用 = 面板内容宽 - 右边距 - 一些内边距
	var total_row_width: float = maxf(wrap_container.size.x - float(right_margin), 0.0)

	# ── 3. 回收区固定宽度 ──
	var recycle_width: float = 160.0
	if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
		recycle_width = maxf(_recycle_drop_zone.custom_minimum_size.x, 148.0)
	var row_gap: float = maxf(float(row.get_theme_constant("separation")), 8.0)
	var min_bench_width: float = 112.0
	var bench_slot_size: Variant = bench_ui.get("slot_size") if bench_ui != null else null
	if bench_slot_size is Vector2:
		min_bench_width = maxf((bench_slot_size as Vector2).x, 96.0)
	var max_recycle_width: float = maxf(total_row_width - row_gap - min_bench_width, 96.0)
	recycle_width = clampf(recycle_width, 96.0, max_recycle_width)

	# ── 4. 备战区可用宽度 ──
	var bench_max_width: float = maxf(total_row_width - recycle_width - row_gap, min_bench_width)

	# ── 5. 强制设置行容器宽度（截断溢出） ──
	row.clip_contents = true
	row.custom_minimum_size.x = total_row_width

	# ── 6. 强制限制备战区 ScrollContainer 宽度 ──
	var bench_control: Control = bench_ui as Control
	if bench_control != null:
		bench_control.clip_contents = true
		bench_control.custom_minimum_size.x = bench_max_width
		bench_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bench_control.size_flags_stretch_ratio = 1.0

		var row_min_h: float = maxf(bench_control.custom_minimum_size.y, 154.0)
		wrap_container.custom_minimum_size = Vector2(0.0, row_min_h)

		# 通知备战席基于新宽度重算列数
		if bench_ui.has_method("refresh_adaptive_layout"):
			bench_ui.call_deferred("refresh_adaptive_layout")

		if _recycle_drop_zone != null and is_instance_valid(_recycle_drop_zone):
			_recycle_drop_zone.custom_minimum_size = Vector2(recycle_width, row_min_h)
			_recycle_drop_zone.size_flags_horizontal = Control.SIZE_SHRINK_END
			_recycle_drop_zone.size_flags_stretch_ratio = 0.0
			_recycle_drop_zone.visible = _stage == Stage.PREPARATION


func _slot_or_equip_cn(tab_id: String, slot_type: String) -> String:
	if tab_id == SHOP_TAB_GONGFA:
		return _slot_to_cn(slot_type)
	return _equip_type_to_cn(slot_type)


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
