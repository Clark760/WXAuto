extends Node
class_name CombatManager

# ===========================
# 战斗管理器
# 负责逻辑帧驱动、寻路/占格、攻击结算与战斗生命周期管理。
signal battle_started(ally_count: int, enemy_count: int)
signal battle_ended(winner_team: int, summary: Dictionary)
signal battle_ended_detail(winner_team: int, summary: Dictionary)
signal damage_resolved(event: Dictionary)
signal unit_died(unit: Node, killer: Node, team_id: int)
signal unit_cell_changed(unit: Node, from_cell: Vector2i, to_cell: Vector2i)
signal unit_spawned(unit: Node, team_id: int)
signal unit_spawned_mid_battle(unit: Node, team_id: int)
signal terrain_changed(changed_cells: Array, reason: String)
signal team_alive_count_changed(team_id: int, alive_count: int)
signal attack_failed(attacker: Node, target: Node, reason: String, event: Dictionary)
signal shield_broken(target: Node, source: Node, event: Dictionary)
signal damage_received_detail(target: Node, source: Node, event: Dictionary)
signal heal_received(source: Node, target: Node, amount: float, heal_type: String)
signal thorns_triggered(source: Node, target: Node, event: Dictionary)
signal unit_move_success(unit: Node, from_cell: Vector2i, to_cell: Vector2i, steps: int)
signal unit_move_failed(unit: Node, reason: String, context: Dictionary)
signal terrain_created(terrain: Dictionary, reason: String)
signal terrain_phase_tick(event: Dictionary)

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2
const CELL_OCCUPANCY_SCRIPT: Script = preload("res://scripts/combat/cell_occupancy.gd")
const COMBAT_PATHFINDING_SCRIPT: Script = preload("res://scripts/combat/combat_pathfinding.gd")
const COMBAT_TARGETING_SCRIPT: Script = preload("res://scripts/combat/combat_targeting.gd")
const COMBAT_METRICS_SCRIPT: Script = preload("res://scripts/combat/combat_metrics.gd")
const SPATIAL_HASH_SCRIPT: Script = preload("res://scripts/board/spatial_hash.gd")
const FLOW_FIELD_SCRIPT: Script = preload("res://scripts/combat/flow_field.gd")
const COMBAT_RUNTIME_SERVICE_SCRIPT: Script = preload("res://scripts/combat/combat_runtime_service.gd")
const COMBAT_UNIT_REGISTRY_SCRIPT: Script = preload("res://scripts/combat/combat_unit_registry.gd")
const COMBAT_MOVEMENT_SERVICE_SCRIPT: Script = preload("res://scripts/combat/combat_movement_service.gd")
const COMBAT_ATTACK_SERVICE_SCRIPT: Script = preload("res://scripts/combat/combat_attack_service.gd")
const COMBAT_TERRAIN_SERVICE_SCRIPT: Script = preload("res://scripts/combat/combat_terrain_service.gd")
const COMBAT_EVENT_BRIDGE_SCRIPT: Script = preload("res://scripts/combat/combat_event_bridge.gd")
const TERRAIN_MANAGER_SCRIPT: Script = preload("res://scripts/combat/terrain_manager.gd")
const PROBE_SCOPE_COMBAT_MANAGER_PROCESS: String = "combat_manager_process"

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
@export var teammate_flow_weight_penalty: int = 3
@export var allow_equal_cost_side_step: bool = true
@export var allow_uphill_escape_step: bool = true
@export var prioritize_targets_in_attack_range: bool = true
@export var target_rescan_interval_frames: int = 6
@export var loop_animation_reduce_unit_threshold: int = 180

var _hex_grid: Node = null
var _vfx_factory: Node = null
var _services: ServiceRegistry = null
var _runtime_probe = null

var _spatial_hash = SPATIAL_HASH_SCRIPT.new(64.0)
var _flow_to_enemy = FLOW_FIELD_SCRIPT.new()
var _flow_to_ally = FLOW_FIELD_SCRIPT.new()

var _rng := RandomNumberGenerator.new()

var _battle_running: bool = false
var _logic_step: float = 0.1
var _logic_accumulator: float = 0.0
var _logic_frame: int = 0
var _logic_time: float = 0.0
var _next_attack_phase: bool = true

var _all_units: Array[Node] = []
var _unit_by_instance_id: Dictionary = {} # instance_id -> 单位节点
var _dead_registry: Dictionary = {} # instance_id -> 是否已处理死亡
var _unit_position_cache: Dictionary = {} # instance_id -> 上一帧位置缓存

var _alive_by_team: Dictionary = {
	TEAM_ALLY: 0,
	TEAM_ENEMY: 0
}
var _group_focus_target_id: Dictionary = {} # team_id -> 当前集火目标 instance_id
var _group_center: Dictionary = {} # team_id -> 队伍中心点

# 预扫描缓存：每个逻辑帧只做一次全量遍历，后续步骤复用。
var _team_alive_cache: Dictionary = {
	TEAM_ALLY: [],
	TEAM_ENEMY: []
}
var _team_cells_cache: Dictionary = {
	TEAM_ALLY: [],
	TEAM_ENEMY: []
}

# 组件缓存：减少热路径中重复 get_node_or_null 的开销。
var _combat_cache: Dictionary = {} # instance_id -> UnitCombat 组件
var _movement_cache: Dictionary = {} # instance_id -> UnitMovement 组件
var _target_memory: Dictionary = {} # attacker_iid -> retained target_iid
var _target_refresh_frame: Dictionary = {} # attacker_iid -> last reselection logic_frame
var _attack_range_target_memory: Dictionary = {} # attacker_iid -> same-frame in-range target iid or 0
var _attack_range_target_frame: Dictionary = {} # attacker_iid -> logic_frame of in-range query result
var _follow_anchor_by_unit_id: Dictionary = {} # unit_iid -> cached follow-anchor ally iid
var _last_move_from_cell: Dictionary = {} # unit_iid -> previous occupied cell for side-step inertia
var _move_replan_cooldown_frame: Dictionary = {} # unit_iid -> logic_frame until which move replanning is skipped
var _side_step_cooldown_frame: Dictionary = {} # unit_iid -> logic_frame until which equal-cost side-step is disabled
var _target_query_ids_scratch: Array[int] = []
var _loop_animation_reduced: bool = false
var _skip_runtime_cache_refresh_once: bool = false

# 压测指标：用于定位高密度战斗下的瓶颈与卡格热点。
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

# 六角格占用表：
# - _cell_occupancy: 格子 -> 单位
var _cell_occupancy: Dictionary = {} # int(cell_key) -> int(unit_instance_id)
var _unit_cell: Dictionary = {} # int(unit_instance_id) -> Vector2i
var _neighbor_cells_cache: Dictionary = {} # int(cell_key) -> Array[Vector2i]
var _static_blocked_cells: Dictionary = {} # int(cell_key) -> true（关卡静态阻挡）
var _terrain_blocked_cells: Dictionary = {} # int(cell_key) -> true（临时地形阻挡）
var _flow_force_rebuild: bool = false
var _terrain_manager = TERRAIN_MANAGER_SCRIPT.new()
var _terrain_registry_loaded: bool = false
var _last_terrain_cells: Dictionary = {} # int(cell_key) -> true

# 拆分子模块（M5）：
# - 占格系统
# - 路径与流场
# - 目标选择
# - 指标统计
var _occupancy = CELL_OCCUPANCY_SCRIPT.new()
var _pathfinding = COMBAT_PATHFINDING_SCRIPT.new()
var _targeting = COMBAT_TARGETING_SCRIPT.new()
var _metrics = COMBAT_METRICS_SCRIPT.new()
var _runtime_service = COMBAT_RUNTIME_SERVICE_SCRIPT.new()
var _unit_registry_service = COMBAT_UNIT_REGISTRY_SCRIPT.new()
var _movement_service = COMBAT_MOVEMENT_SERVICE_SCRIPT.new()
var _attack_service = COMBAT_ATTACK_SERVICE_SCRIPT.new()
var _terrain_service = COMBAT_TERRAIN_SERVICE_SCRIPT.new()
var _event_bridge_service = COMBAT_EVENT_BRIDGE_SCRIPT.new()

# 绑定运行时服务后，允许地形注册表从 DataManager 拉取配置。
func bind_runtime_services(services: ServiceRegistry) -> void:
	_services = services
	_runtime_probe = services.runtime_probe if services != null else null
	if is_inside_tree():
		reload_terrain_registry()

# 初始化逻辑步长、空间索引和地形 registry 缓存。
func _ready() -> void:
	_logic_step = 1.0 / maxf(logic_fps, 1.0)
	_spatial_hash = SPATIAL_HASH_SCRIPT.new(spatial_cell_size)
	reload_terrain_registry()
	_metric_tick_duration_us = int(_metric_tick_duration_us)
	_metric_total_tick_duration_us = int(_metric_total_tick_duration_us)
	_metric_last_tick = (_metric_last_tick as Dictionary)

# 主循环仅委托给运行时服务推进战斗帧。
func _process(delta: float) -> void:
	var process_begin_us: int = 0
	if _runtime_probe != null and _runtime_probe.has_method("begin_timing"):
		process_begin_us = int(_runtime_probe.begin_timing())
	_runtime_service.process(self, delta)
	if _runtime_probe != null and _runtime_probe.has_method("commit_timing"):
		_runtime_probe.commit_timing(PROBE_SCOPE_COMBAT_MANAGER_PROCESS, process_begin_us)

# 注入 HexGrid 和 VFX 依赖，并强制刷新一次地形表现。
func configure_dependencies(hex_grid: Node, vfx_factory: Node) -> void:
	_hex_grid = hex_grid
	_vfx_factory = vfx_factory
	_neighbor_cells_cache.clear()
	_flow_force_rebuild = true
	_apply_terrain_visuals()

# 重新从 DataManager 读取地形配置并同步到 terrain service。
func reload_terrain_registry(data_manager: Node = null) -> void:
	_terrain_service.reload_terrain_registry(self, data_manager)

# Combat 侧只从显式注入的 ServiceRegistry 获取 DataManager。
func _get_data_manager_node() -> Node:
	if _services == null:
		return null
	return _services.data_repository

# 写入关卡静态阻挡格，并标记流场需要重建。
func set_static_blocked_cells(cells: Array[Vector2i]) -> void:
	_static_blocked_cells.clear()
	for cell in cells:
		var key: int = _cell_key_int(cell)
		_static_blocked_cells[key] = true
	_flow_force_rebuild = true

# 清空静态阻挡缓存。
func clear_static_blocked_cells() -> void:
	_static_blocked_cells.clear()
	_flow_force_rebuild = true

# 写入临时地形阻挡格，并标记流场需要重建。
func set_terrain_blocked_cells(cells: Array[Vector2i]) -> void:
	_terrain_blocked_cells.clear()
	for cell in cells:
		_terrain_blocked_cells[_cell_key_int(cell)] = true
	_flow_force_rebuild = true

# 清空临时地形阻挡缓存。
func clear_terrain_blocked_cells() -> void:
	_terrain_blocked_cells.clear()
	_flow_force_rebuild = true

# 对外暴露当前战斗是否处于运行态。
func is_battle_running() -> bool:
	return _battle_running

# 返回逻辑战斗时钟的累计秒数。
func get_logic_time() -> float:
	return _logic_time

# 按 instance_id 查询当前注册的单位节点。
func get_unit_by_instance_id(iid: int) -> Node:
	if _unit_by_instance_id.has(iid):
		return _unit_by_instance_id[iid]
	return null

# 外部显式请求流场下个逻辑帧重建。
func request_flow_rebuild() -> void:
	_flow_force_rebuild = true

# 返回存活单位列表；team_id=0 时汇总双方。
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

# 暴露单位占格查询，供地形与外部系统复用。
func get_unit_cell_of(unit: Node) -> Vector2i:
	return _get_unit_cell(unit)


# 按扫描格收集当前仍存活的单位，供局部机制避免回退到整场单位遍历。
# 输出数组由调用方复用，接口内部只负责清空并回填结果。
func collect_alive_units_in_cells(cells: Array[Vector2i], output: Array[Node]) -> void:
	output.clear()
	if cells.is_empty():
		return

	var seen_units: Dictionary = {}
	for cell in cells:
		var cell_key: int = _cell_key_int(cell)
		if not _cell_occupancy.has(cell_key):
			continue
		var unit_iid: int = int(_cell_occupancy[cell_key])
		if unit_iid <= 0 or seen_units.has(unit_iid):
			continue
		if not _unit_by_instance_id.has(unit_iid):
			continue
		var unit: Node = _unit_by_instance_id[unit_iid]
		if not _is_live_unit(unit) or not _is_unit_alive(unit):
			continue
		seen_units[unit_iid] = true
		output.append(unit)

# 临时地形入口继续由 terrain service 承接。
func add_temporary_terrain(config: Dictionary, source: Node = null) -> bool:
	return _terrain_service.add_temporary_terrain(self, config, source)

# 清空全部临时地形实例。
func clear_temporary_terrains() -> void:
	_terrain_service.clear_temporary_terrains(self)

# 添加静态地形时复用 terrain service 的关卡入口。
func add_static_terrain(terrain_id: String, cells: Array, extra_config: Dictionary = {}) -> bool:
	return _terrain_service.add_static_terrain(self, terrain_id, cells, extra_config)

# 清空静态地形实例与对应障碍。
func clear_static_terrains() -> void:
	_terrain_service.clear_static_terrains(self)

# 对外提供统一的阻挡格布尔查询。
func is_cell_blocked(cell: Vector2i) -> bool:
	return _is_cell_blocked(cell)

# 查询指定格子的 terrain tag 列表。
func get_terrain_tags_at_cell(cell: Vector2i, scope: String = "all") -> Array[String]:
	return _terrain_service.get_terrain_tags_at_cell(self, cell, scope)

# 查询指定格子是否包含目标 terrain tag。
func cell_has_terrain_tag(cell: Vector2i, tag: String, scope: String = "all") -> bool:
	return _terrain_service.cell_has_terrain_tag(self, cell, tag, scope)

# 把当前 visual cache 投影回 HexGrid。
func _apply_terrain_visuals() -> void:
	_terrain_service.apply_terrain_visuals(self)

# 统一广播 terrain_changed 信号。
func _emit_terrain_changed(reason: String) -> void:
	_terrain_service.emit_terrain_changed(self, reason)

# 从压缩过的 int key 还原六角格坐标。
func _cell_from_key_int(key: int) -> Vector2i:
	var x: int = (key >> 16) & 0xFFFF
	var y: int = key & 0xFFFF
	if x > 32767:
		x -= 65536
	if y > 32767:
		y -= 65536
	return Vector2i(x, y)

# 强制把单位挪到指定格，用于技能位移与修正。
func force_move_unit_to_cell(unit: Node, target_cell: Vector2i) -> bool:
	return _movement_service.force_move_unit_to_cell(self, unit, target_cell)

# 按锚点方向推进指定步数。
func move_unit_steps_towards(unit: Node, anchor_cell: Vector2i, max_steps: int) -> bool:
	return _movement_service.move_unit_steps_towards(self, unit, anchor_cell, max_steps)

# 按威胁源反方向推进指定步数。
func move_unit_steps_away(unit: Node, threat_cell: Vector2i, max_steps: int) -> bool:
	return _movement_service.move_unit_steps_away(self, unit, threat_cell, max_steps)

# 交换两个单位的占格与位置。
func swap_unit_cells(unit_a: Node, unit_b: Node) -> bool:
	return _movement_service.swap_unit_cells(self, unit_a, unit_b)

# 把新单位接入正在运行的战斗。
func add_unit_mid_battle(unit: Node) -> bool:
	return _unit_registry_service.add_unit_mid_battle(self, unit)

# 开战入口委托运行时服务完成注册与启动。
func start_battle(ally_units: Array[Node], enemy_units: Array[Node], battle_seed: int = 0) -> bool:
	return _runtime_service.start_battle(
		self,
		ally_units,
		enemy_units,
		battle_seed
	)

# 停战入口委托运行时服务完成收尾。
func stop_battle(reason: String = "manual", winner_team: int = 0) -> void:
	_runtime_service.stop_battle(self, reason, winner_team)

# 兼容旧接口，实际复用 team_alive_count 查询。
func get_alive_count(team_id: int) -> int:
	return get_team_alive_count(team_id)

# 统计指定阵营的存活人数，并支持排除一个单位。
func get_team_alive_count(team_id: int, exclude_unit: Node = null) -> int:
	var count: int = 0
	if team_id == TEAM_ALLY or team_id == TEAM_ENEMY:
		count = int(_alive_by_team.get(team_id, 0))
	else:
		count = int(_alive_by_team.get(TEAM_ALLY, 0)) + int(_alive_by_team.get(TEAM_ENEMY, 0))
	if exclude_unit == null or not is_instance_valid(exclude_unit):
		return maxi(count, 0)
	if not _is_unit_alive(exclude_unit):
		return maxi(count, 0)
	var exclude_team: int = int(exclude_unit.get("team_id"))
	if team_id == TEAM_ALLY or team_id == TEAM_ENEMY:
		if exclude_team == team_id:
			count -= 1
	else:
		if exclude_team == TEAM_ALLY or exclude_team == TEAM_ENEMY:
			count -= 1
	return maxi(count, 0)

# 广播 team_alive_count_changed 信号。
func _emit_team_alive_count_changed(team_id: int) -> void:
	_event_bridge_service.emit_team_alive_count_changed(self, team_id)

# 输出当前战斗期内的指标快照。
func get_runtime_metrics_snapshot() -> Dictionary:
	return _metrics.build_runtime_snapshot(self)

# 单步推进逻辑战斗帧。
func _logic_tick(delta: float) -> void:
	_runtime_service.logic_tick(self, delta)

# 执行完整预扫描并刷新队伍缓存。
func _pre_tick_scan() -> void:
	_unit_registry_service.pre_tick_scan(self)

# 按有效 id 集修剪组件缓存。
func _trim_component_caches(valid_ids: Dictionary) -> void:
	_unit_registry_service.trim_component_caches(self, valid_ids)

# 在世界坐标附近拾取一个可交互单位。
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

# 执行增量预扫描，减少高密度战斗的全量遍历成本。
func _pre_tick_scan_incremental() -> void:
	_unit_registry_service.pre_tick_scan_incremental(self)

# 把单个存活单位写入增量缓存。
func _cache_alive_unit_incremental(unit: Node, ally_seen_cells: Dictionary, enemy_seen_cells: Dictionary) -> void:
	_unit_registry_service.cache_alive_unit_incremental(
		self,
		unit,
		ally_seen_cells,
		enemy_seen_cells
	)

# 修剪战斗运行态缓存，移除失效单位。
func _trim_runtime_caches(valid_ids: Dictionary) -> void:
	_unit_registry_service.trim_runtime_caches(self, valid_ids)

# 删除单个单位对应的运行态缓存。
func _remove_unit_runtime_entry(unit: Node) -> void:
	_unit_registry_service.remove_unit_runtime_entry(self, unit)

# 直接按 instance_id 删除运行态缓存。
func _remove_runtime_entry_by_id(iid: int) -> void:
	_unit_registry_service.remove_runtime_entry_by_id(self, iid)

# 根据当前存活规模动态放宽流场刷新间隔。
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


func _get_effective_target_rescan_interval() -> int:
	var interval: int = maxi(target_rescan_interval_frames, 1)
	var alive_total: int = int(_alive_by_team.get(TEAM_ALLY, 0))
	alive_total += int(_alive_by_team.get(TEAM_ENEMY, 0))
	if alive_total >= 320:
		return interval * 3
	if alive_total >= 220:
		return interval * 2
	return interval


func _get_effective_move_replan_cooldown_frames() -> int:
	var alive_total: int = int(_alive_by_team.get(TEAM_ALLY, 0))
	alive_total += int(_alive_by_team.get(TEAM_ENEMY, 0))
	var split_phase_factor: int = 2 if split_attack_move_phase else 1
	if alive_total >= 320:
		return 2 * split_phase_factor
	if alive_total >= 220:
		return split_phase_factor
	return 0


func _get_effective_side_step_cooldown_frames() -> int:
	return 2 if split_attack_move_phase else 1

# 注册一批单位并写入阵营与占格缓存。
func _register_units(units: Array[Node], team_id: int) -> void:
	_unit_registry_service.register_units(self, units, team_id)

# 刷新双方队伍的集火目标与中心点。
func _update_group_ai_focus() -> void:
	_targeting.update_group_ai_focus(self)

# 更新单个队伍的目标选择焦点。
func _update_team_focus(self_team: int, enemy_team: int) -> void:
	_targeting.update_team_focus(self, self_team, enemy_team)

# 按当前阻挡和队伍位置重建流场。
func _rebuild_flow_fields() -> void:
	_pathfinding.rebuild_flow_fields(self)

# 推进地形 phase，并同步 barrier 与 visual。
func _tick_terrain(delta: float) -> void:
	_terrain_service.tick_terrain(self, delta)

# Combat 侧只从显式注入的 ServiceRegistry 获取 UnitAugmentManager。
func _get_unit_augment_manager() -> Node:
	if _services == null:
		return null
	return _services.unit_augment_manager

# 执行单个单位的攻击与移动逻辑。
func _run_unit_logic(unit: Node, delta: float, allow_attack: bool = true, allow_move: bool = true) -> void:
	_movement_service.run_unit_logic(self, unit, delta, allow_attack, allow_move)

# 为单位选择一个当前帧目标。
func _pick_target_for_unit(unit: Node, allow_refresh_target: bool = true) -> Node:
	return _targeting.pick_target_for_unit(self, unit, allow_refresh_target)

# 在攻击范围内优先挑选目标。
func _pick_target_in_attack_range(unit: Node, enemy_team: int) -> Node:
	return _targeting.pick_target_in_attack_range(self, unit, enemy_team)

# 读取目标格上的占用单位。
func _get_occupant_unit_at_cell(cell: Vector2i) -> Node:
	return _targeting.get_occupant_unit_at_cell(self, cell)

# 查询攻击者当前是否已覆盖目标攻击范围。
func _is_target_in_attack_range(attacker: Node, target: Node) -> bool:
	return _targeting.is_target_in_attack_range(self, attacker, target)

# 战斗结束条件满足时触发结算收尾。
func _finalize_if_needed() -> void:
	_runtime_service.finalize_if_needed(self)

# 缓存单位身上的战斗与移动组件。
func _cache_components_for_unit(unit: Node) -> void:
	_unit_registry_service.cache_components_for_unit(self, unit)

# 绑定战斗组件对 CombatManager 的事件回调。
func _bind_combat_component_signals(unit: Node) -> void:
	_unit_registry_service.bind_combat_component_signals(self, unit)

# 解绑单位离场后的战斗组件事件。
func _unbind_combat_component_signals(unit: Node) -> void:
	_unit_registry_service.unbind_combat_component_signals(self, unit)

# 读取并缓存 UnitCombat 组件。
func _get_combat(unit: Node) -> Node:
	if not _is_live_unit(unit):
		return null
	var iid: int = unit.get_instance_id()
	if not _combat_cache.has(iid) or not is_instance_valid(_combat_cache[iid]):
		_combat_cache[iid] = unit.get_node_or_null("Components/UnitCombat")
	return _combat_cache[iid] as Node

# 读取并缓存 UnitMovement 组件。
func _get_movement(unit: Node) -> Node:
	if not _is_live_unit(unit):
		return null
	var iid: int = unit.get_instance_id()
	if not _movement_cache.has(iid) or not is_instance_valid(_movement_cache[iid]):
		_movement_cache[iid] = unit.get_node_or_null("Components/UnitMovement")
	return _movement_cache[iid] as Node

# 通过战斗组件判断单位是否存活。
func _is_unit_alive(unit: Node) -> bool:
	var combat: Node = _get_combat(unit)
	if combat == null:
		return false
	return bool(combat.get("is_alive"))

# 统一判断一个 Variant 是否仍是有效单位节点。
func _is_live_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	var as_node: Node = unit as Node
	return as_node != null

# 把六角格压缩成占格字典使用的 int key。
func _cell_key_int(cell: Vector2i) -> int:
	return _occupancy.cell_key_int(cell)

# 写入单位对目标格的占格记录。
func _occupy_cell(cell: Vector2i, unit: Node) -> bool:
	return _occupancy.occupy_cell(self, cell, unit)

# 释放指定格子的占格记录。
func _vacate_cell(cell: Vector2i) -> void:
	_occupancy.vacate_cell(self, cell)

# 释放某个单位当前持有的占格。
func _vacate_unit(unit: Node) -> void:
	_occupancy.vacate_unit(self, unit)

# 广播单位占格变化事件。
func _notify_unit_cell_changed(unit: Node, from_cell: Vector2i, to_cell: Vector2i) -> void:
	_event_bridge_service.notify_unit_cell_changed(self, unit, from_cell, to_cell)

# 查询格子是否没有被单位占用。
func _is_cell_free(cell: Vector2i) -> bool:
	return _occupancy.is_cell_free(self, cell)

# 查询格子是否被静态或地形阻挡。
func _is_cell_blocked(cell: Vector2i) -> bool:
	var key: int = _cell_key_int(cell)
	return _static_blocked_cells.has(key) or _terrain_blocked_cells.has(key)

# 合并静态与动态阻挡，供寻路模块快照使用。
func _get_blocked_cells_snapshot() -> Dictionary:
	var blocked: Dictionary = _static_blocked_cells.duplicate(true)
	for key in _terrain_blocked_cells.keys():
		blocked[int(key)] = true
	return blocked

# 读取单位当前已登记的格子坐标。
func _get_unit_cell(unit: Node) -> Vector2i:
	return _occupancy.get_unit_cell(self, unit)

# 缺失占格时尝试从世界坐标反查并登记。
func _resolve_and_register_unit_cell(unit: Node) -> Vector2i:
	return _occupancy.resolve_and_register_unit_cell(self, unit)

# 运行占格一致性检查，帮助定位缓存漂移。
func _validate_cell_occupancy() -> void:
	_occupancy.validate_occupancy(self)

# 按阵营构建用于寻路的阻挡快照。
func _build_blocked_cells_for_team(self_team: int) -> Dictionary:
	return _pathfinding.build_blocked_cells_for_team(self, self_team)

# 从邻接格里挑一个当前最优落脚点。
func _pick_best_adjacent_cell(
	unit: Node,
	current_cell: Vector2i,
	attack_range_target: Node = null,
	skip_equal_cost_side_step: bool = false
) -> Vector2i:
	return _pathfinding.pick_best_adjacent_cell(
		self,
		unit,
		current_cell,
		attack_range_target,
		skip_equal_cost_side_step
	)

# 从起点开始寻找最近可用空格。
func _find_nearest_free_cell(start_cell: Vector2i) -> Vector2i:
	return _occupancy.find_nearest_free_cell(self, start_cell)

# 返回某个六角格的邻接格列表。
func _neighbors_of(cell: Vector2i) -> Array[Vector2i]:
	return _occupancy.neighbors_of(self, cell)

# 计算两个六角格之间的距离。
func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	return _pathfinding.hex_distance(self, a, b)

# 清理一局战斗结束后的运行态缓存。
func _reset_battle_runtime_state() -> void:
	_runtime_service.reset_battle_runtime_state(self)

# 根据外部传入 seed 初始化战斗随机源。
func _setup_battle_seed(battle_seed: int) -> void:
	_runtime_service.setup_battle_seed(self, battle_seed)

# 把 CombatManager 切到正式战斗循环状态。
func _begin_battle_loop() -> void:
	_runtime_service.begin_battle_loop(self)

# 构造结算摘要，供战斗结束信号携带。
func _build_battle_summary(reason: String, winner_team: int) -> Dictionary:
	return _runtime_service.build_battle_summary(self, reason, winner_team)

# 战斗结束后恢复单位可视、占格和动画状态。
func _cleanup_unit_after_battle(unit: Node, winner_team: int) -> void:
	# 战斗结束先清理移动目标，避免胜负已定后仍继续位移。
	var movement: Node = _get_movement(unit)
	_clear_movement_target(movement)

	# 终止快速格步进 tween，避免战后视觉重叠。
	if unit.has_method("kill_quick_step_tween"):
		unit.call("kill_quick_step_tween")

	# 战后按逻辑占格强制吸附回格心，消除位置偏差。
	var iid: int = unit.get_instance_id()
	if _hex_grid != null and _unit_cell.has(iid):
		var cell: Vector2i = _unit_cell[iid]
		var snap_pos: Vector2 = _hex_axial_to_world(cell)
		var unit_node: Node2D = unit as Node2D
		if unit_node != null:
			unit_node.position = snap_pos

	# 重置可视节点变换，清除 MOVE/VICTORY 残留倾斜和缩放。
	if unit.has_method("reset_visual_transform"):
		unit.call("reset_visual_transform")

	if _is_unit_alive(unit):
		var team_id: int = int(unit.get("team_id"))
		if winner_team != 0 and team_id == winner_team:
			unit.call("play_anim_state", 6, {}) # 胜利动画
		else:
			unit.call("play_anim_state", 0, {}) # 战后待机动画
	unit.set("is_in_combat", false)
	unit.call("leave_combat")

# 清空单帧统计与队伍缓存。
func _reset_tick_caches() -> void:
	_unit_registry_service.reset_tick_caches(self)

# 把单个活着的单位写入当前帧缓存。
func _cache_alive_unit(unit: Node, ally_seen_cells: Dictionary, enemy_seen_cells: Dictionary) -> void:
	_unit_registry_service.cache_alive_unit(
		self,
		unit,
		ally_seen_cells,
		enemy_seen_cells
	)

# 开战前统一给单位写入阵营和动画状态。
func _prepare_unit_for_battle(unit: Node, team_id: int) -> void:
	unit.call("set_team", team_id)
	unit.call("enter_combat")
	unit.call("set_on_bench_state", false, -1)
	unit.call("play_anim_state", 0, {}) # 开战前统一进入待机动画

# 准备 UnitCombat 组件的战斗运行态。
func _prepare_combat_component_for_battle(combat: Node) -> void:
	if combat == null or not is_instance_valid(combat):
		return
	combat.call("prepare_for_battle")

# 清除移动组件尚未完成的目标。
func _clear_movement_target(movement: Node) -> void:
	if movement == null or not is_instance_valid(movement):
		return
	movement.call("clear_target")

# 通过 HexGrid 把轴坐标转换为世界坐标。
func _hex_axial_to_world(cell: Vector2i) -> Vector2:
	if _hex_grid == null or not is_instance_valid(_hex_grid):
		return Vector2.ZERO
	return _hex_grid.call("axial_to_world", cell)

# 通过 HexGrid 把世界坐标转换为轴坐标。
func _hex_world_to_axial(world_pos: Vector2) -> Vector2i:
	if _hex_grid == null or not is_instance_valid(_hex_grid):
		return Vector2i(-1, -1)
	var cell_value: Variant = _hex_grid.call("world_to_axial", world_pos)
	if cell_value is Vector2i:
		return cell_value as Vector2i
	return Vector2i(-1, -1)

# 尝试执行一次攻击结算并返回是否成功。
func _try_execute_attack(unit: Node, combat: Node, target: Node) -> bool:
	return _attack_service.try_execute_attack(self, unit, combat, target)

# 统一补齐 damage 事件的 Combat 侧字段。
func _build_damage_event(source: Node, target: Node, event_dict: Dictionary) -> Dictionary:
	return _attack_service.build_damage_event(self, source, target, event_dict)


func _rebuild_follow_anchor_cache() -> void:
	_follow_anchor_by_unit_id = _pathfinding.rebuild_follow_anchor_cache(self)
