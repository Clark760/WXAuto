extends Node
class_name CombatManager

# ===========================
# 战斗管理器
# ===========================
# 核心职责：
# 1. 固定逻辑帧驱动战斗决策，与渲染帧解耦。
# 2. 使用 SpatialHash 做近邻寻敌，避免 O(n^2) 全量遍历。
# 3. 以“队伍焦点 + 流场方向”实现分组 AI。
# 4. 当前实现重点优化：预扫描合并、组件缓存、减少重复遍历。

signal battle_started(ally_count: int, enemy_count: int)
signal battle_ended(winner_team: int, summary: Dictionary)
signal damage_resolved(event: Dictionary)
signal unit_died(unit: Node, killer: Node, team_id: int)

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2
const CELL_OCCUPANCY_SCRIPT: Script = preload("res://scripts/combat/cell_occupancy.gd")
const COMBAT_PATHFINDING_SCRIPT: Script = preload("res://scripts/combat/combat_pathfinding.gd")
const COMBAT_TARGETING_SCRIPT: Script = preload("res://scripts/combat/combat_targeting.gd")
const COMBAT_METRICS_SCRIPT: Script = preload("res://scripts/combat/combat_metrics.gd")
const TERRAIN_MANAGER_SCRIPT: Script = preload("res://scripts/board/terrain_manager.gd")

@export var logic_fps: float = 10.0
@export var logic_max_substeps: int = 6
@export var spatial_cell_size: float = 64.0
@export var target_query_radius: float = 420.0
@export var flow_refresh_interval_frames: int = 5
@export var flow_step_distance: float = 28.0
@export var split_attack_move_phase: bool = true
@export var strict_cell_snap_in_combat: bool = true
@export var strict_snap_visual_step_enabled: bool = true
@export var strict_snap_visual_step_duration_ratio: float = 0.75
@export var shuffle_unit_order_each_tick: bool = true
@export var block_teammate_cells_in_flow: bool = true
@export var allow_equal_cost_side_step: bool = true
@export var allow_uphill_escape_step: bool = true
@export var prioritize_targets_in_attack_range: bool = true

var _hex_grid: Node = null
var _vfx_factory: Node = null

var _spatial_hash: SpatialHash = SpatialHash.new(64.0)
var _flow_to_enemy: FlowField = FlowField.new()
var _flow_to_ally: FlowField = FlowField.new()

var _rng := RandomNumberGenerator.new()

var _battle_running: bool = false
var _logic_step: float = 0.1
var _logic_accumulator: float = 0.0
var _logic_frame: int = 0
var _logic_time: float = 0.0
var _next_attack_phase: bool = true

var _all_units: Array[Node] = []
var _unit_by_instance_id: Dictionary = {}  # instance_id -> Node
var _dead_registry: Dictionary = {}         # instance_id -> true
var _unit_position_cache: Dictionary = {}   # instance_id -> Vector2

var _alive_by_team: Dictionary = {
	TEAM_ALLY: 0,
	TEAM_ENEMY: 0
}
var _group_focus_target_id: Dictionary = {} # team_id -> target_instance_id
var _group_center: Dictionary = {}          # team_id -> Vector2

# 预扫描缓存：每逻辑帧只做一次全量遍历，后续步骤复用结果。
var _team_alive_cache: Dictionary = {
	TEAM_ALLY: [],
	TEAM_ENEMY: []
}
var _team_cells_cache: Dictionary = {
	TEAM_ALLY: [],
	TEAM_ENEMY: []
}

# 组件缓存：避免热路径 get_node_or_null("Components/... ")。
var _combat_cache: Dictionary = {}   # instance_id -> Node
var _movement_cache: Dictionary = {} # instance_id -> Node

# 压测指标：用于定位高密度战斗下的拥堵/卡格热点。
var _metric_tick_units: int = 0
var _metric_tick_attack_checks: int = 0
var _metric_tick_attacks_performed: int = 0
var _metric_tick_move_checks: int = 0
var _metric_tick_move_started: int = 0
var _metric_tick_move_blocked: int = 0
var _metric_tick_move_conflicts: int = 0
var _metric_tick_idle_no_cell: int = 0
var _metric_tick_flow_unreachable: int = 0
var _metric_tick_duration_us: int = 0

var _metric_total_units: int = 0
var _metric_total_attack_checks: int = 0
var _metric_total_attacks_performed: int = 0
var _metric_total_move_checks: int = 0
var _metric_total_move_started: int = 0
var _metric_total_move_blocked: int = 0
var _metric_total_move_conflicts: int = 0
var _metric_total_idle_no_cell: int = 0
var _metric_total_flow_unreachable: int = 0
var _metric_total_tick_duration_us: int = 0

var _metric_last_tick: Dictionary = {}

# 严格六角格占用表：
# - _cell_occupancy：格子 -> 单位
# - _unit_cell：单位 -> 当前逻辑格子
var _cell_occupancy: Dictionary = {} # int(cell_key) -> int(unit_instance_id)
var _unit_cell: Dictionary = {}      # int(unit_instance_id) -> Vector2i
var _static_blocked_cells: Dictionary = {} # int(cell_key) -> true（关卡固定阻挡）
var _terrain_blocked_cells: Dictionary = {} # int(cell_key) -> true（临时 barrier 阻挡）
var _flow_force_rebuild: bool = false
var _terrain_manager = TERRAIN_MANAGER_SCRIPT.new()

# 拆分模块（M5 大文件精简）：
# - 占格系统
# - 流场/寻路
# - 目标选择
# - 指标统计
var _occupancy = CELL_OCCUPANCY_SCRIPT.new()
var _pathfinding = COMBAT_PATHFINDING_SCRIPT.new()
var _targeting = COMBAT_TARGETING_SCRIPT.new()
var _metrics = COMBAT_METRICS_SCRIPT.new()


func _ready() -> void:
	_logic_step = 1.0 / maxf(logic_fps, 1.0)
	_spatial_hash = SpatialHash.new(spatial_cell_size)
	# M5 拆分后这3个字段主要由 CombatMetrics 通过 owner.set/get 访问；
	# 这里显式读写一次，避免编辑器提示“声明但未使用”。
	_metric_tick_duration_us = int(_metric_tick_duration_us)
	_metric_total_tick_duration_us = int(_metric_total_tick_duration_us)
	_metric_last_tick = (_metric_last_tick as Dictionary)


func _process(delta: float) -> void:
	if not _battle_running:
		return

	_logic_accumulator += delta
	var substeps: int = 0
	while _logic_accumulator >= _logic_step and substeps < logic_max_substeps:
		_logic_tick(_logic_step)
		_logic_accumulator -= _logic_step
		substeps += 1

	# 防止极端卡顿造成“死亡螺旋”，超过上限后丢弃积压逻辑帧。
	if substeps >= logic_max_substeps and _logic_accumulator >= _logic_step:
		_logic_accumulator = 0.0


func configure_dependencies(hex_grid: Node, vfx_factory: Node) -> void:
	_hex_grid = hex_grid
	_vfx_factory = vfx_factory
	_flow_force_rebuild = true


func set_static_blocked_cells(cells: Array[Vector2i]) -> void:
	_static_blocked_cells.clear()
	for cell in cells:
		var key: int = _cell_key_int(cell)
		_static_blocked_cells[key] = true
	_flow_force_rebuild = true


func clear_static_blocked_cells() -> void:
	_static_blocked_cells.clear()
	_flow_force_rebuild = true


func set_terrain_blocked_cells(cells: Array[Vector2i]) -> void:
	_terrain_blocked_cells.clear()
	for cell in cells:
		_terrain_blocked_cells[_cell_key_int(cell)] = true
	_flow_force_rebuild = true


func clear_terrain_blocked_cells() -> void:
	_terrain_blocked_cells.clear()
	_flow_force_rebuild = true


func is_battle_running() -> bool:
	return _battle_running


func get_logic_time() -> float:
	return _logic_time


func get_unit_by_instance_id(iid: int) -> Node:
	if _unit_by_instance_id.has(iid):
		return _unit_by_instance_id[iid]
	return null


func request_flow_rebuild() -> void:
	_flow_force_rebuild = true


func get_alive_units(team_id: int = 0) -> Array[Node]:
	var output: Array[Node] = []
	if team_id == TEAM_ALLY or team_id == TEAM_ENEMY:
		var cached_team: Array = _team_alive_cache.get(team_id, [])
		for unit in cached_team:
			if _is_live_unit(unit) and _is_unit_alive(unit):
				output.append(unit)
		return output
	for unit in _all_units:
		if _is_live_unit(unit) and _is_unit_alive(unit):
			output.append(unit)
	return output


func get_unit_cell_of(unit: Node) -> Vector2i:
	return _get_unit_cell(unit)


func add_temporary_terrain(config: Dictionary, source: Node = null) -> bool:
	if _terrain_manager == null:
		return false
	var result: Dictionary = _terrain_manager.call("add_terrain", config, source, {
		"hex_grid": _hex_grid
	})
	if bool(result.get("barrier_changed", false)):
		var barrier_cells: Array[Vector2i] = _terrain_manager.call("get_barrier_cells")
		set_terrain_blocked_cells(barrier_cells)
	if bool(result.get("visual_changed", false)) and _hex_grid != null and _hex_grid.has_method("set_terrain_cells"):
		var visual_cells: Dictionary = _terrain_manager.call("get_visual_cells", _hex_grid)
		_hex_grid.call("set_terrain_cells", visual_cells)
	return bool(result.get("added", false))


func clear_temporary_terrains() -> void:
	if _terrain_manager != null:
		_terrain_manager.call("clear_all")
	clear_terrain_blocked_cells()
	if _hex_grid != null and _hex_grid.has_method("clear_terrain_cells"):
		_hex_grid.call("clear_terrain_cells")


func force_move_unit_to_cell(unit: Node, target_cell: Vector2i) -> bool:
	if not _battle_running:
		return false
	if not _is_live_unit(unit) or not _is_unit_alive(unit):
		return false
	if _hex_grid == null:
		return false
	if not bool(_hex_grid.call("is_inside_grid", target_cell)):
		return false
	var current_cell: Vector2i = _get_unit_cell(unit)
	if current_cell == target_cell:
		return true
	if not _is_cell_free(target_cell):
		return false
	if not _occupy_cell(target_cell, unit):
		return false
	var movement: Node = _get_movement(unit)
	if movement != null:
		movement.call("clear_target")
	var unit_node: Node2D = unit as Node2D
	if unit_node != null:
		unit_node.position = _hex_grid.call("axial_to_world", target_cell)
	_flow_force_rebuild = true
	return true


func move_unit_steps_towards(unit: Node, anchor_cell: Vector2i, max_steps: int) -> bool:
	if not _battle_running or max_steps <= 0:
		return false
	var current: Vector2i = _get_unit_cell(unit)
	if current.x < 0:
		return false
	var moved: bool = false
	var steps: int = maxi(max_steps, 0)
	while steps > 0:
		steps -= 1
		var next_cell: Vector2i = _pick_step_towards(current, anchor_cell)
		if next_cell == current:
			break
		if not force_move_unit_to_cell(unit, next_cell):
			break
		current = next_cell
		moved = true
	return moved


func move_unit_steps_away(unit: Node, threat_cell: Vector2i, max_steps: int) -> bool:
	if not _battle_running or max_steps <= 0:
		return false
	var current: Vector2i = _get_unit_cell(unit)
	if current.x < 0:
		return false
	var moved: bool = false
	var steps: int = maxi(max_steps, 0)
	while steps > 0:
		steps -= 1
		var next_cell: Vector2i = _pick_step_away(current, threat_cell)
		if next_cell == current:
			break
		if not force_move_unit_to_cell(unit, next_cell):
			break
		current = next_cell
		moved = true
	return moved


func swap_unit_cells(unit_a: Node, unit_b: Node) -> bool:
	if not _battle_running:
		return false
	if not _is_live_unit(unit_a) or not _is_live_unit(unit_b):
		return false
	if not _is_unit_alive(unit_a) or not _is_unit_alive(unit_b):
		return false
	var cell_a: Vector2i = _get_unit_cell(unit_a)
	var cell_b: Vector2i = _get_unit_cell(unit_b)
	if cell_a.x < 0 or cell_b.x < 0:
		return false
	var id_a: int = unit_a.get_instance_id()
	var id_b: int = unit_b.get_instance_id()
	var key_a: int = _cell_key_int(cell_a)
	var key_b: int = _cell_key_int(cell_b)
	if _is_cell_blocked(cell_a) or _is_cell_blocked(cell_b):
		return false
	_cell_occupancy[key_a] = id_b
	_cell_occupancy[key_b] = id_a
	_unit_cell[id_a] = cell_b
	_unit_cell[id_b] = cell_a
	var n2d_a: Node2D = unit_a as Node2D
	var n2d_b: Node2D = unit_b as Node2D
	if n2d_a != null and _hex_grid != null:
		n2d_a.position = _hex_grid.call("axial_to_world", cell_b)
	if n2d_b != null and _hex_grid != null:
		n2d_b.position = _hex_grid.call("axial_to_world", cell_a)
	var move_a: Node = _get_movement(unit_a)
	if move_a != null:
		move_a.call("clear_target")
	var move_b: Node = _get_movement(unit_b)
	if move_b != null:
		move_b.call("clear_target")
	_flow_force_rebuild = true
	return true


func add_unit_mid_battle(unit: Node) -> bool:
	if not _battle_running:
		return false
	if not _is_live_unit(unit):
		return false
	var iid: int = unit.get_instance_id()
	if _unit_by_instance_id.has(iid):
		return true

	var team_id: int = int(unit.get("team_id"))
	if team_id != TEAM_ALLY and team_id != TEAM_ENEMY:
		team_id = TEAM_ENEMY
		unit.call("set_team", team_id)

	_prepare_unit_for_battle(unit, team_id)
	_cache_components_for_unit(unit)
	var combat: Node = _get_combat(unit)
	if combat == null:
		return false
	combat.call("prepare_for_battle")
	var movement: Node = _get_movement(unit)
	if movement != null:
		movement.call("clear_target")

	_all_units.append(unit)
	_unit_by_instance_id[iid] = unit
	_dead_registry.erase(iid)
	_spatial_hash.update(iid, unit.position)
	_unit_position_cache[iid] = unit.position
	_alive_by_team[team_id] = int(_alive_by_team.get(team_id, 0)) + 1
	var alive_list: Array = _team_alive_cache.get(team_id, [])
	alive_list.append(unit)
	_team_alive_cache[team_id] = alive_list

	if _hex_grid != null:
		_resolve_and_register_unit_cell(unit)
	return true


func apply_environment_damage(
	target: Node,
	damage_amount: float,
	source: Node = null,
	damage_type: String = "internal",
	source_fallback: Dictionary = {}
) -> Dictionary:
	if not _battle_running:
		return {}
	if not _is_live_unit(target):
		return {}
	if not _is_unit_alive(target):
		return {}
	var combat: Node = _get_combat(target)
	if combat == null:
		return {}
	var result_value: Variant = combat.call(
		"receive_damage",
		maxf(damage_amount, 0.0),
		source,
		damage_type,
		true,
		false,
		false
	)
	if not (result_value is Dictionary):
		return {}
	var result: Dictionary = result_value
	var fallback_source_id: int = int(source_fallback.get("source_id", -1))
	var fallback_source_team: int = int(source_fallback.get("source_team", 0))
	var fallback_source_unit_id: String = str(source_fallback.get("source_unit_id", "")).strip_edges()
	var fallback_source_name: String = str(source_fallback.get("source_name", "")).strip_edges()
	var source_id: int = source.get_instance_id() if _is_live_unit(source) else fallback_source_id
	var source_team: int = int(source.get("team_id")) if _is_live_unit(source) else fallback_source_team
	var source_unit_id: String = str(source.get("unit_id")) if _is_live_unit(source) else fallback_source_unit_id
	var source_name: String = str(source.get("unit_name")) if _is_live_unit(source) else fallback_source_name
	var event_dict: Dictionary = {
		"source_id": source_id,
		"target_id": target.get_instance_id(),
		"source_team": source_team,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"target_team": int(target.get("team_id")),
		"target_unit_id": str(target.get("unit_id")),
		"target_name": str(target.get("unit_name")),
		"is_skill": true,
		"is_dodged": false,
		"is_crit": false,
		"damage_type": damage_type,
		"damage": float(result.get("damage", 0.0)),
		"target_hp_after": float(result.get("target_hp_after", 0.0)),
		"target_mp_after": float(result.get("target_mp_after", 0.0)),
		"shield_absorbed": float(result.get("shield_absorbed", 0.0)),
		"immune_absorbed": float(result.get("immune_absorbed", 0.0)),
		"shield_hp_after": float(result.get("shield_hp_after", 0.0)),
		"shield_broken": bool(result.get("shield_broken", false)),
		"logic_frame": _logic_frame,
		"is_environment": true
	}
	damage_resolved.emit(event_dict)
	if bool(result.get("target_died", false)):
		_handle_unit_death(target, source)
	return event_dict


func start_battle(ally_units: Array[Node], enemy_units: Array[Node], battle_seed: int = 0) -> bool:
	stop_battle("restart", 0)
	_reset_battle_runtime_state()
	_register_units(ally_units, TEAM_ALLY)
	_register_units(enemy_units, TEAM_ENEMY)
	if _all_units.is_empty():
		return false

	_setup_battle_seed(battle_seed)
	_begin_battle_loop()
	_pre_tick_scan()
	battle_started.emit(
		int(_alive_by_team.get(TEAM_ALLY, 0)),
		int(_alive_by_team.get(TEAM_ENEMY, 0))
	)
	return true


func stop_battle(reason: String = "manual", winner_team: int = 0) -> void:
	if not _battle_running:
		return

	_battle_running = false
	var summary: Dictionary = _build_battle_summary(reason, winner_team)

	# M5 修复：战斗结束后统一走清理流程，避免残留 tween/倾斜与视觉重叠。
	for unit in _all_units:
		if not _is_live_unit(unit):
			continue
		_cleanup_unit_after_battle(unit, winner_team)
	if _terrain_manager != null:
		_terrain_manager.call("clear_all")
	clear_terrain_blocked_cells()
	if _hex_grid != null and _hex_grid.has_method("clear_terrain_cells"):
		_hex_grid.call("clear_terrain_cells")

	battle_ended.emit(winner_team, summary)


func get_alive_count(team_id: int) -> int:
	return int(_alive_by_team.get(team_id, 0))


func get_runtime_metrics_snapshot() -> Dictionary:
	return _metrics.build_runtime_snapshot(self)


func _logic_tick(delta: float) -> void:
	var tick_begin_us: int = Time.get_ticks_usec()
	_metrics.reset_tick_metrics(self)
	_logic_frame += 1
	_logic_time += delta
	var allow_attack_phase: bool = true
	var allow_move_phase: bool = true
	if split_attack_move_phase:
		allow_attack_phase = _next_attack_phase
		allow_move_phase = not _next_attack_phase
		_next_attack_phase = not _next_attack_phase

	_pre_tick_scan()
	if _all_units.is_empty():
		_tick_terrain(delta)
		_finalize_if_needed()
		_metrics.finalize_tick(self, tick_begin_us, allow_attack_phase, allow_move_phase)
		return

	_tick_terrain(delta)
	_update_group_ai_focus()
	var effective_flow_refresh_interval: int = _get_effective_flow_refresh_interval()
	if _flow_force_rebuild or effective_flow_refresh_interval <= 1 or (_logic_frame % effective_flow_refresh_interval == 0):
		_rebuild_flow_fields()
		_flow_force_rebuild = false

	if shuffle_unit_order_each_tick and _all_units.size() > 1:
		_all_units.shuffle()

	for unit in _all_units:
		if not _battle_running:
			break
		_run_unit_logic(unit, delta, allow_attack_phase, allow_move_phase)

	_finalize_if_needed()
	_metrics.finalize_tick(self, tick_begin_us, allow_attack_phase, allow_move_phase)


func _pre_tick_scan() -> void:
	_pre_tick_scan_incremental()


func _trim_component_caches(valid_ids: Dictionary) -> void:
	# 删除已失效单位对应缓存，避免字典持续膨胀。
	for key in _combat_cache.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			_combat_cache.erase(iid)
	for key in _movement_cache.keys():
		var iid: int = int(key)
		if not valid_ids.has(iid):
			_movement_cache.erase(iid)


func pick_unit_at_world(world_pos: Vector2, radius: float = 20.0) -> Node:
	var best_target: Node = null
	var best_dist_sq: float = INF
	for candidate_id in _spatial_hash.query_radius(world_pos, maxf(radius, 1.0)):
		if not _unit_by_instance_id.has(candidate_id):
			continue
		var candidate: Node = _unit_by_instance_id[candidate_id]
		if not _is_live_unit(candidate):
			continue
		if not _is_unit_alive(candidate):
			continue
		if candidate is CanvasItem and not (candidate as CanvasItem).visible:
			continue
		var d2: float = world_pos.distance_squared_to((candidate as Node2D).position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_target = candidate
	return best_target


func _pre_tick_scan_incremental() -> void:
	_alive_by_team[TEAM_ALLY] = 0
	_alive_by_team[TEAM_ENEMY] = 0
	_team_alive_cache[TEAM_ALLY] = []
	_team_alive_cache[TEAM_ENEMY] = []
	_team_cells_cache[TEAM_ALLY] = []
	_team_cells_cache[TEAM_ENEMY] = []

	var valid_ids: Dictionary = {}
	var ally_seen_cells: Dictionary = {}
	var enemy_seen_cells: Dictionary = {}
	var index: int = 0
	while index < _all_units.size():
		var unit: Node = _all_units[index]
		if not _is_live_unit(unit):
			_all_units.remove_at(index)
			continue
		_cache_components_for_unit(unit)
		var combat: Node = _get_combat(unit)
		if combat == null or not bool(combat.get("is_alive")):
			_remove_unit_runtime_entry(unit)
			_all_units.remove_at(index)
			continue

		var iid: int = unit.get_instance_id()
		valid_ids[iid] = true
		_cache_alive_unit_incremental(unit, ally_seen_cells, enemy_seen_cells)
		index += 1

	_trim_component_caches(valid_ids)
	_trim_runtime_caches(valid_ids)
	_validate_cell_occupancy()


func _cache_alive_unit_incremental(unit: Node, ally_seen_cells: Dictionary, enemy_seen_cells: Dictionary) -> void:
	var iid: int = unit.get_instance_id()
	var team_id: int = int(unit.get("team_id"))
	_alive_by_team[team_id] = int(_alive_by_team.get(team_id, 0)) + 1
	_unit_by_instance_id[iid] = unit
	_spatial_hash.update(iid, unit.position)
	_unit_position_cache[iid] = unit.position

	var alive_list: Array = _team_alive_cache.get(team_id, [])
	alive_list.append(unit)
	_team_alive_cache[team_id] = alive_list

	var cell: Vector2i = _get_unit_cell(unit)
	if cell.x < 0 or cell.y < 0:
		return
	var seen_cells: Dictionary = ally_seen_cells if team_id == TEAM_ALLY else enemy_seen_cells
	var cell_key: int = _cell_key_int(cell)
	if seen_cells.has(cell_key):
		return
	seen_cells[cell_key] = true
	var team_cells: Array = _team_cells_cache.get(team_id, [])
	team_cells.append(cell)
	_team_cells_cache[team_id] = team_cells


func _trim_runtime_caches(valid_ids: Dictionary) -> void:
	for key in _unit_by_instance_id.keys():
		var iid: int = int(key)
		if valid_ids.has(iid):
			continue
		_remove_runtime_entry_by_id(iid)


func _remove_unit_runtime_entry(unit: Node) -> void:
	if not _is_live_unit(unit):
		return
	_remove_runtime_entry_by_id(unit.get_instance_id())


func _remove_runtime_entry_by_id(iid: int) -> void:
	if _unit_cell.has(iid):
		var cell: Vector2i = _unit_cell[iid]
		var cell_key: int = _cell_key_int(cell)
		if _cell_occupancy.has(cell_key) and int(_cell_occupancy[cell_key]) == iid:
			_cell_occupancy.erase(cell_key)
		_unit_cell.erase(iid)
	_unit_by_instance_id.erase(iid)
	_spatial_hash.remove(iid)
	_unit_position_cache.erase(iid)
	_combat_cache.erase(iid)
	_movement_cache.erase(iid)


func _get_effective_flow_refresh_interval() -> int:
	var interval: int = maxi(flow_refresh_interval_frames, 1)
	var alive_total: int = int(_alive_by_team.get(TEAM_ALLY, 0)) + int(_alive_by_team.get(TEAM_ENEMY, 0))
	if alive_total >= 320:
		return interval * 4
	if alive_total >= 220:
		return interval * 3
	if alive_total >= 120:
		return interval * 2
	return interval


func _register_units(units: Array[Node], team_id: int) -> void:
	for unit in units:
		if not _is_live_unit(unit):
			continue

		_prepare_unit_for_battle(unit, team_id)
		_cache_components_for_unit(unit)
		var combat: Node = _get_combat(unit)
		if combat != null:
			combat.call("prepare_for_battle")
		var movement: Node = _get_movement(unit)
		if movement != null:
			movement.call("clear_target")

		var instance_id: int = unit.get_instance_id()
		_all_units.append(unit)
		_unit_by_instance_id[instance_id] = unit

		# 注册时将单位吸附到格心并登记占格，作为后续格子逻辑的唯一真值。
		if _hex_grid != null:
			_resolve_and_register_unit_cell(unit)


func _update_group_ai_focus() -> void:
	_targeting.update_group_ai_focus(self)


func _update_team_focus(self_team: int, enemy_team: int) -> void:
	_targeting.update_team_focus(self, self_team, enemy_team)


func _rebuild_flow_fields() -> void:
	_pathfinding.rebuild_flow_fields(self)


func _tick_terrain(delta: float) -> void:
	if _terrain_manager == null or _hex_grid == null:
		return
	var gongfa_manager: Node = _get_gongfa_manager()
	var tick_result: Dictionary = _terrain_manager.call("tick", delta, {
		"combat_manager": self,
		"hex_grid": _hex_grid,
		"all_units": _all_units,
		"gongfa_manager": gongfa_manager
	})
	if bool(tick_result.get("barrier_changed", false)):
		var barrier_cells: Array[Vector2i] = _terrain_manager.call("get_barrier_cells")
		set_terrain_blocked_cells(barrier_cells)
	if bool(tick_result.get("visual_changed", false)) and _hex_grid.has_method("set_terrain_cells"):
		var visual_cells: Dictionary = _terrain_manager.call("get_visual_cells", _hex_grid)
		_hex_grid.call("set_terrain_cells", visual_cells)


func _get_gongfa_manager() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("GongfaManager")


func _is_unit_stunned(unit: Node) -> bool:
	return _is_control_active(unit, "status_stun_until")


func _is_unit_feared(unit: Node) -> bool:
	return _is_control_active(unit, "status_fear_until")


func _is_control_active(unit: Node, meta_key: String) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var until_time: float = float(unit.get_meta(meta_key, 0.0))
	if until_time > _logic_time:
		return true
	if until_time > 0.0:
		unit.remove_meta(meta_key)
	return false


func _clear_unit_move_and_idle(unit: Node) -> void:
	var movement: Node = _get_movement(unit)
	if movement != null:
		movement.call("clear_target")
	unit.call("play_anim_state", 0, {}) # IDLE


func _run_feared_unit_logic(unit: Node, target: Node, enemy_team: int) -> void:
	var current_cell: Vector2i = _get_unit_cell(unit)
	if current_cell.x < 0:
		_clear_unit_move_and_idle(unit)
		return
	if target == null or not _is_live_unit(target) or not _is_unit_alive(target):
		target = _pick_target_in_attack_range(unit, enemy_team)
		if target == null:
			target = _pick_target_for_unit(unit)
	if target == null:
		_clear_unit_move_and_idle(unit)
		return
	var target_cell: Vector2i = _get_unit_cell(target)
	if target_cell.x < 0:
		_clear_unit_move_and_idle(unit)
		return
	var moved: bool = move_unit_steps_away(unit, target_cell, 1)
	if moved:
		unit.call("play_anim_state", 1, {}) # MOVE
	else:
		_clear_unit_move_and_idle(unit)
	_metric_tick_move_checks += 1
	_metric_total_move_checks += 1
	if moved:
		_metric_tick_move_started += 1
		_metric_total_move_started += 1
	else:
		_metric_tick_move_blocked += 1
		_metric_total_move_blocked += 1


func _pick_step_towards(from_cell: Vector2i, target_cell: Vector2i) -> Vector2i:
	var best: Vector2i = from_cell
	var best_dist: int = _hex_distance(from_cell, target_cell)
	for neighbor in _neighbors_of(from_cell):
		if not _is_cell_free(neighbor):
			continue
		var dist: int = _hex_distance(neighbor, target_cell)
		if dist < best_dist:
			best_dist = dist
			best = neighbor
	return best


func _pick_step_away(from_cell: Vector2i, threat_cell: Vector2i) -> Vector2i:
	var best: Vector2i = from_cell
	var best_dist: int = _hex_distance(from_cell, threat_cell)
	for neighbor in _neighbors_of(from_cell):
		if not _is_cell_free(neighbor):
			continue
		var dist: int = _hex_distance(neighbor, threat_cell)
		if dist > best_dist:
			best_dist = dist
			best = neighbor
	return best


func _run_unit_logic(unit: Node, delta: float, allow_attack: bool = true, allow_move: bool = true) -> void:
	if not _battle_running:
		return
	if not _is_live_unit(unit):
		return
	if not _is_unit_alive(unit):
		return
	_metric_tick_units += 1
	_metric_total_units += 1

	var combat: Node = _get_combat(unit)
	if combat == null:
		return

	combat.call("tick_logic", delta)
	if _is_unit_stunned(unit):
		_clear_unit_move_and_idle(unit)
		return
	var self_team: int = int(unit.get("team_id"))
	var enemy_team: int = TEAM_ENEMY if self_team == TEAM_ALLY else TEAM_ALLY
	var target: Node = _pick_target_for_unit(unit)
	if _is_unit_feared(unit):
		_run_feared_unit_logic(unit, target, enemy_team)
		return

	if allow_attack:
		_metric_tick_attack_checks += 1
		_metric_total_attack_checks += 1
		if _try_execute_attack(unit, combat, target):
			_metric_tick_attacks_performed += 1
			_metric_total_attacks_performed += 1
			return

	if not allow_move:
		return

	# 关键修复（M5）：目标已经在射程内时，不再继续移动。
	# 这条守卫要放在 move 分支最前面，才能覆盖：
	# 1) 攻击帧中因 CD 未好而攻击失败；
	# 2) split_attack_move_phase 下的纯移动帧。
	if target != null and _is_target_in_attack_range(unit, target):
		var idle_movement: Node = _get_movement(unit)
		if idle_movement != null:
			idle_movement.call("clear_target")
		unit.call("play_anim_state", 0, {}) # IDLE
		_metric_tick_move_checks += 1
		_metric_total_move_checks += 1
		_metric_tick_move_blocked += 1
		_metric_total_move_blocked += 1
		return

	_metric_tick_move_checks += 1
	_metric_total_move_checks += 1
	var current_cell: Vector2i = _get_unit_cell(unit)
	if current_cell.x < 0 or current_cell.y < 0:
		var movement_invalid: Node = _get_movement(unit)
		if movement_invalid != null:
			movement_invalid.call("clear_target")
		unit.call("play_anim_state", 0, {}) # IDLE
		_metric_tick_idle_no_cell += 1
		_metric_total_idle_no_cell += 1
		return

	var flow_field: FlowField = _flow_to_enemy if int(unit.get("team_id")) == TEAM_ALLY else _flow_to_ally
	var flow_cost: int = flow_field.sample_cost(current_cell)
	if flow_cost < 0:
		_metric_tick_flow_unreachable += 1
		_metric_total_flow_unreachable += 1
	var best_next: Vector2i = _pick_best_adjacent_cell(unit, current_cell)
	if best_next == current_cell:
		# 被堵住时兜底：优先尝试攻击“射程内任意敌人”，避免双方僵持。
		if allow_attack:
			var alt_target: Node = _pick_target_in_attack_range(unit, enemy_team)
			if alt_target != null and _try_execute_attack(unit, combat, alt_target):
				_metric_tick_attacks_performed += 1
				_metric_total_attacks_performed += 1
				return
		var movement_idle: Node = _get_movement(unit)
		if movement_idle != null:
			movement_idle.call("clear_target")
		unit.call("play_anim_state", 0, {}) # IDLE
		_metric_tick_move_blocked += 1
		_metric_total_move_blocked += 1
		return

	# 提交前再次检查，若目标格已被本帧其他单位占用则直接判定冲突。
	if not _is_cell_free(best_next):
		var conflict_movement: Node = _get_movement(unit)
		if conflict_movement != null:
			conflict_movement.call("clear_target")
		unit.call("play_anim_state", 0, {}) # IDLE
		_metric_tick_move_conflicts += 1
		_metric_total_move_conflicts += 1
		return

	# 关键修复：先占新格，旧格由 _occupy_cell 内部自动释放，避免“先释后占”竞态。
	if not _occupy_cell(best_next, unit):
		var rollback_movement: Node = _get_movement(unit)
		if rollback_movement != null:
			rollback_movement.call("clear_target")
		unit.call("play_anim_state", 0, {}) # IDLE
		_metric_tick_move_conflicts += 1
		_metric_total_move_conflicts += 1
		return
	var movement: Node = _get_movement(unit)
	if movement != null and _hex_grid != null:
		var target_world: Vector2 = _hex_grid.call("axial_to_world", best_next)
		if strict_cell_snap_in_combat:
			# 严格格子模式：逻辑先到位，再用短动画补视觉位移，避免“瞬移感”。
			var did_visual_step: bool = false
			if strict_snap_visual_step_enabled and unit.has_method("play_quick_cell_step"):
				# 动画时长按逻辑步长比例计算，保证低帧逻辑下仍然利落。
				var duration: float = clampf(_logic_step * strict_snap_visual_step_duration_ratio, 0.03, 0.14)
				unit.call("play_quick_cell_step", target_world, duration)
				did_visual_step = true
			if not did_visual_step:
				var snap_node: Node2D = unit as Node2D
				if snap_node != null:
					snap_node.position = target_world
			movement.call("clear_target")
		else:
			movement.call("set_target", target_world)
	else:
		# 兜底：无移动组件时直接瞬移到格心，保证逻辑与画面一致。
		if _hex_grid != null:
			var unit_node: Node2D = unit as Node2D
			if unit_node != null:
				unit_node.position = _hex_grid.call("axial_to_world", best_next)
	unit.call("play_anim_state", 1, {}) # MOVE
	_metric_tick_move_started += 1
	_metric_total_move_started += 1


func _pick_target_for_unit(unit: Node) -> Node:
	return _targeting.pick_target_for_unit(self, unit)


func _pick_target_in_attack_range(unit: Node, enemy_team: int) -> Node:
	return _targeting.pick_target_in_attack_range(self, unit, enemy_team)


func _get_occupant_unit_at_cell(cell: Vector2i) -> Node:
	return _targeting.get_occupant_unit_at_cell(self, cell)


func _is_target_in_attack_range(attacker: Node, target: Node) -> bool:
	return _targeting.is_target_in_attack_range(self, attacker, target)


func _on_attack_resolved(source: Node, target: Node, event_dict: Dictionary) -> void:
	var attack_dir: Vector2 = (target.position - source.position).normalized()
	if attack_dir.is_zero_approx():
		attack_dir = Vector2.RIGHT

	if bool(event_dict.get("is_skill", false)):
		source.call("play_anim_state", 3, {"direction": attack_dir}) # SKILL
	else:
		source.call("play_anim_state", 2, {"direction": attack_dir}) # ATTACK

	if bool(event_dict.get("is_dodged", false)):
		if _vfx_factory != null:
			_vfx_factory.call("spawn_damage_text", target.position, 0.0, false, true)
	else:
		target.call("play_anim_state", 4, {"direction": attack_dir}) # HIT
		if _vfx_factory != null:
			_vfx_factory.call("play_attack_vfx", "vfx_sword_qi", source.position, target.position)
			_vfx_factory.call(
				"spawn_damage_text",
				target.position,
				float(event_dict.get("damage", 0.0)),
				bool(event_dict.get("is_crit", false)),
				false
			)

	damage_resolved.emit(_build_damage_event(source, target, event_dict))

	if bool(event_dict.get("target_died", false)):
		_handle_unit_death(target, source)


func _handle_unit_death(dead_unit: Node, killer: Node) -> void:
	if not _is_live_unit(dead_unit):
		return

	var dead_id: int = dead_unit.get_instance_id()
	if _dead_registry.has(dead_id):
		return
	_dead_registry[dead_id] = true
	_vacate_unit(dead_unit)

	dead_unit.call("play_anim_state", 5, {}) # DEATH
	var movement: Node = _get_movement(dead_unit)
	if movement != null:
		movement.call("clear_target")
	var dead_team: int = int(dead_unit.get("team_id"))
	_alive_by_team[dead_team] = maxi(int(_alive_by_team.get(dead_team, 0)) - 1, 0)
	var alive_list: Array = _team_alive_cache.get(dead_team, [])
	alive_list.erase(dead_unit)
	_team_alive_cache[dead_team] = alive_list
	_remove_unit_runtime_entry(dead_unit)

	unit_died.emit(dead_unit, killer, dead_team)

	# 关键修复：任一方归零后立刻结算，阻断同帧残余行动。
	_finalize_if_needed()


func _finalize_if_needed() -> void:
	var ally_alive: int = int(_alive_by_team.get(TEAM_ALLY, 0))
	var enemy_alive: int = int(_alive_by_team.get(TEAM_ENEMY, 0))

	if ally_alive > 0 and enemy_alive > 0:
		return

	var winner: int = 0
	if ally_alive > enemy_alive:
		winner = TEAM_ALLY
	elif enemy_alive > ally_alive:
		winner = TEAM_ENEMY
	else:
		winner = 0
	stop_battle("annihilation", winner)


func _cache_components_for_unit(unit: Node) -> void:
	if not _is_live_unit(unit):
		return
	var iid: int = unit.get_instance_id()
	if not _combat_cache.has(iid):
		_combat_cache[iid] = unit.get_node_or_null("Components/UnitCombat")
	if not _movement_cache.has(iid):
		_movement_cache[iid] = unit.get_node_or_null("Components/UnitMovement")


func _get_combat(unit: Node) -> Node:
	if not _is_live_unit(unit):
		return null
	var iid: int = unit.get_instance_id()
	if not _combat_cache.has(iid) or not is_instance_valid(_combat_cache[iid]):
		_combat_cache[iid] = unit.get_node_or_null("Components/UnitCombat")
	return _combat_cache[iid] as Node


func _get_movement(unit: Node) -> Node:
	if not _is_live_unit(unit):
		return null
	var iid: int = unit.get_instance_id()
	if not _movement_cache.has(iid) or not is_instance_valid(_movement_cache[iid]):
		_movement_cache[iid] = unit.get_node_or_null("Components/UnitMovement")
	return _movement_cache[iid] as Node


func _is_unit_alive(unit: Node) -> bool:
	var combat: Node = _get_combat(unit)
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _is_live_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	var as_node: Node = unit as Node
	return as_node != null


func _cell_key_int(cell: Vector2i) -> int:
	return _occupancy.cell_key_int(cell)


func _occupy_cell(cell: Vector2i, unit: Node) -> bool:
	return _occupancy.occupy_cell(self, cell, unit)


func _vacate_cell(cell: Vector2i) -> void:
	_occupancy.vacate_cell(self, cell)


func _vacate_unit(unit: Node) -> void:
	_occupancy.vacate_unit(self, unit)


func _is_cell_free(cell: Vector2i) -> bool:
	return _occupancy.is_cell_free(self, cell)


func _is_cell_blocked(cell: Vector2i) -> bool:
	var key: int = _cell_key_int(cell)
	return _static_blocked_cells.has(key) or _terrain_blocked_cells.has(key)


func _get_blocked_cells_snapshot() -> Dictionary:
	var blocked: Dictionary = _static_blocked_cells.duplicate(true)
	for key in _terrain_blocked_cells.keys():
		blocked[int(key)] = true
	return blocked


func _get_unit_cell(unit: Node) -> Vector2i:
	return _occupancy.get_unit_cell(self, unit)


func _resolve_and_register_unit_cell(unit: Node) -> Vector2i:
	return _occupancy.resolve_and_register_unit_cell(self, unit)


func _validate_cell_occupancy() -> void:
	_occupancy.validate_occupancy(self)


func _build_blocked_cells_for_team(self_team: int) -> Dictionary:
	return _pathfinding.build_blocked_cells_for_team(self, self_team)


func _pick_best_adjacent_cell(unit: Node, current_cell: Vector2i) -> Vector2i:
	return _pathfinding.pick_best_adjacent_cell(self, unit, current_cell)


func _find_nearest_free_cell(start_cell: Vector2i) -> Vector2i:
	return _occupancy.find_nearest_free_cell(self, start_cell)


func _neighbors_of(cell: Vector2i) -> Array[Vector2i]:
	return _occupancy.neighbors_of(self, cell)


func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	return _pathfinding.hex_distance(self, a, b)


func _reset_battle_runtime_state() -> void:
	# 只在“整场战斗开始前”清空的运行态数据集中放在这里，
	# 避免 start_battle 中散落大量 reset 代码。
	_all_units.clear()
	_unit_by_instance_id.clear()
	_dead_registry.clear()
	_unit_position_cache.clear()
	_combat_cache.clear()
	_movement_cache.clear()
	_group_focus_target_id.clear()
	_group_center.clear()
	_spatial_hash.clear()
	_alive_by_team[TEAM_ALLY] = 0
	_alive_by_team[TEAM_ENEMY] = 0
	_team_alive_cache[TEAM_ALLY] = []
	_team_alive_cache[TEAM_ENEMY] = []
	_team_cells_cache[TEAM_ALLY] = []
	_team_cells_cache[TEAM_ENEMY] = []
	_cell_occupancy.clear()
	_unit_cell.clear()
	_terrain_blocked_cells.clear()
	_flow_force_rebuild = true
	if _terrain_manager != null:
		_terrain_manager.call("clear_all")
	if _hex_grid != null and _hex_grid.has_method("clear_terrain_cells"):
		_hex_grid.call("clear_terrain_cells")
	_metrics.reset_all_metrics(self)


func _setup_battle_seed(battle_seed: int) -> void:
	var actual_seed: int = battle_seed
	if actual_seed <= 0:
		actual_seed = int(Time.get_ticks_usec() % 2147483647)
	_rng.seed = actual_seed


func _begin_battle_loop() -> void:
	_logic_step = 1.0 / maxf(logic_fps, 1.0)
	_logic_accumulator = 0.0
	_logic_frame = 0
	_logic_time = 0.0
	_next_attack_phase = true
	_flow_force_rebuild = true
	_battle_running = true


func _build_battle_summary(reason: String, winner_team: int) -> Dictionary:
	return {
		"winner_team": winner_team,
		"reason": reason,
		"logic_frames": _logic_frame,
		"logic_time": _logic_time,
		"ally_alive": int(_alive_by_team.get(TEAM_ALLY, 0)),
		"enemy_alive": int(_alive_by_team.get(TEAM_ENEMY, 0))
	}


func _cleanup_unit_after_battle(unit: Node, winner_team: int) -> void:
	# 结算时强制清空移动目标，避免胜负已出仍有残留位移。
	var movement: Node = _get_movement(unit)
	if movement != null:
		movement.call("clear_target")

	# 杀掉严格格子模式的短 Tween，避免战后仍在位移导致视觉重叠。
	if unit.has_method("kill_quick_step_tween"):
		unit.call("kill_quick_step_tween")

	# 战后以逻辑占格为准强制吸附到格心，彻底消除“逻辑不同格但视觉同格”的情况。
	var iid: int = unit.get_instance_id()
	if _hex_grid != null and _unit_cell.has(iid):
		var cell: Vector2i = _unit_cell[iid]
		var snap_pos: Vector2 = _hex_grid.call("axial_to_world", cell)
		var unit_node: Node2D = unit as Node2D
		if unit_node != null:
			unit_node.position = snap_pos

	# 重置可视节点变换，清除 MOVE/VICTORY 残留倾斜与缩放偏移。
	if unit.has_method("reset_visual_transform"):
		unit.call("reset_visual_transform")

	if _is_unit_alive(unit):
		var team_id: int = int(unit.get("team_id"))
		if winner_team != 0 and team_id == winner_team:
			unit.call("play_anim_state", 6, {}) # VICTORY
		else:
			unit.call("play_anim_state", 0, {}) # IDLE
	unit.set("is_in_combat", false)
	unit.call("leave_combat")


func _reset_tick_caches() -> void:
	_alive_by_team[TEAM_ALLY] = 0
	_alive_by_team[TEAM_ENEMY] = 0
	_unit_by_instance_id.clear()
	_spatial_hash.clear()
	_team_alive_cache[TEAM_ALLY] = []
	_team_alive_cache[TEAM_ENEMY] = []
	_team_cells_cache[TEAM_ALLY] = []
	_team_cells_cache[TEAM_ENEMY] = []


func _cache_alive_unit(unit: Node, ally_seen_cells: Dictionary, enemy_seen_cells: Dictionary) -> void:
	var combat: Node = _get_combat(unit)
	if combat == null:
		return
	if not bool(combat.get("is_alive")):
		return

	var iid: int = unit.get_instance_id()
	var team_id: int = int(unit.get("team_id"))
	_alive_by_team[team_id] = int(_alive_by_team.get(team_id, 0)) + 1
	_unit_by_instance_id[iid] = unit
	_spatial_hash.insert(iid, unit.position)

	var alive_list: Array = _team_alive_cache.get(team_id, [])
	alive_list.append(unit)
	_team_alive_cache[team_id] = alive_list

	if _hex_grid == null:
		return
	var cell: Vector2i = _hex_grid.call("world_to_axial", unit.position)
	var seen_cells: Dictionary = ally_seen_cells if team_id == TEAM_ALLY else enemy_seen_cells
	var cache_key: int = TEAM_ALLY if team_id == TEAM_ALLY else TEAM_ENEMY
	var cell_key: int = _cell_key_int(cell)
	if seen_cells.has(cell_key):
		return
	seen_cells[cell_key] = true
	var team_cells: Array = _team_cells_cache.get(cache_key, [])
	team_cells.append(cell)
	_team_cells_cache[cache_key] = team_cells


func _prepare_unit_for_battle(unit: Node, team_id: int) -> void:
	unit.call("set_team", team_id)
	unit.call("enter_combat")
	unit.call("set_on_bench_state", false, -1)
	unit.call("play_anim_state", 0, {}) # IDLE


func _try_execute_attack(unit: Node, combat: Node, target: Node) -> bool:
	if target == null:
		return false
	if not _is_target_in_attack_range(unit, target):
		return false

	var attack_event: Variant = combat.call("try_attack_target", target, _rng)
	if not (attack_event is Dictionary):
		return false
	var event_dict: Dictionary = attack_event
	if not bool(event_dict.get("performed", false)):
		return false

	_on_attack_resolved(unit, target, event_dict)
	var movement_stop: Node = _get_movement(unit)
	if movement_stop != null:
		movement_stop.call("clear_target")
	return true


func _build_damage_event(source: Node, target: Node, event_dict: Dictionary) -> Dictionary:
	return {
		"source_id": source.get_instance_id(),
		"target_id": target.get_instance_id(),
		"source_team": int(source.get("team_id")),
		"target_team": int(target.get("team_id")),
		"is_skill": bool(event_dict.get("is_skill", false)),
		"is_dodged": bool(event_dict.get("is_dodged", false)),
		"is_crit": bool(event_dict.get("is_crit", false)),
		"damage_type": str(event_dict.get("damage_type", "external")),
		"damage": float(event_dict.get("damage", 0.0)),
		"target_hp_after": float(event_dict.get("target_hp_after", 0.0)),
		"target_mp_after": float(event_dict.get("target_mp_after", 0.0)),
		"shield_absorbed": float(event_dict.get("shield_absorbed", 0.0)),
		"immune_absorbed": float(event_dict.get("immune_absorbed", 0.0)),
		"shield_hp_after": float(event_dict.get("shield_hp_after", 0.0)),
		"shield_broken": bool(event_dict.get("shield_broken", false)),
		"logic_frame": _logic_frame
	}
