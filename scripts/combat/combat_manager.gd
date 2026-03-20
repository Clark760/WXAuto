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

@export var logic_fps: float = 10.0
@export var logic_max_substeps: int = 6
@export var spatial_cell_size: float = 64.0
@export var target_query_radius: float = 420.0
@export var flow_refresh_interval_frames: int = 5
@export var flow_step_distance: float = 28.0

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


func _ready() -> void:
	_logic_step = 1.0 / maxf(logic_fps, 1.0)
	_spatial_hash = SpatialHash.new(spatial_cell_size)


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


func is_battle_running() -> bool:
	return _battle_running


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

	for unit in _all_units:
		if not _is_live_unit(unit):
			continue
		_cleanup_unit_after_battle(unit, winner_team)

	battle_ended.emit(winner_team, summary)


func get_alive_count(team_id: int) -> int:
	return int(_alive_by_team.get(team_id, 0))


func _logic_tick(delta: float) -> void:
	_logic_frame += 1
	_logic_time += delta

	_pre_tick_scan()
	if _all_units.is_empty():
		_finalize_if_needed()
		return

	_update_group_ai_focus()
	var effective_flow_refresh_interval: int = _get_effective_flow_refresh_interval()
	if effective_flow_refresh_interval <= 1 or (_logic_frame % effective_flow_refresh_interval == 0):
		_rebuild_flow_fields()

	for unit in _all_units:
		if not _battle_running:
			break
		_run_unit_logic(unit, delta)

	_finalize_if_needed()


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

	if _hex_grid == null:
		return
	var cell: Vector2i = _hex_grid.call("world_to_axial", unit.position)
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


func _update_group_ai_focus() -> void:
	_group_focus_target_id.clear()
	_group_center.clear()

	_update_team_focus(TEAM_ALLY, TEAM_ENEMY)
	_update_team_focus(TEAM_ENEMY, TEAM_ALLY)


func _update_team_focus(self_team: int, enemy_team: int) -> void:
	var own_alive: Array = _team_alive_cache.get(self_team, [])
	var enemy_alive: Array = _team_alive_cache.get(enemy_team, [])
	if own_alive.is_empty() or enemy_alive.is_empty():
		return

	var center: Vector2 = Vector2.ZERO
	for unit in own_alive:
		center += (unit as Node2D).position
	center /= float(maxi(own_alive.size(), 1))
	_group_center[self_team] = center

	var best_enemy: Node = null
	var best_dist_sq: float = INF
	for enemy in enemy_alive:
		var enemy_node: Node2D = enemy as Node2D
		var d2: float = center.distance_squared_to(enemy_node.position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_enemy = enemy

	if best_enemy != null:
		_group_focus_target_id[self_team] = best_enemy.get_instance_id()


func _rebuild_flow_fields() -> void:
	if _hex_grid == null:
		return

	var ally_targets: Array[Vector2i] = []
	var enemy_targets: Array[Vector2i] = []
	for cell in _team_cells_cache.get(TEAM_ENEMY, []):
		ally_targets.append(cell)
	for cell in _team_cells_cache.get(TEAM_ALLY, []):
		enemy_targets.append(cell)

	_flow_to_enemy.build(_hex_grid, ally_targets, {})
	_flow_to_ally.build(_hex_grid, enemy_targets, {})


func _run_unit_logic(unit: Node, delta: float) -> void:
	if not _battle_running:
		return
	if not _is_live_unit(unit):
		return
	if not _is_unit_alive(unit):
		return

	var combat: Node = _get_combat(unit)
	if combat == null:
		return

	combat.call("tick_logic", delta)
	var target: Node = _pick_target_for_unit(unit)

	if _try_execute_attack(unit, combat, target):
		return

	var movement: Node = _get_movement(unit)
	if movement == null:
		return

	var direction: Vector2 = _sample_flow_direction(unit)
	if direction.is_zero_approx() and target != null:
		direction = (target.position - unit.position).normalized()

	if direction.is_zero_approx():
		movement.call("clear_target")
		unit.call("play_anim_state", 0, {}) # IDLE
		return

	movement.call("set_flow_direction", direction, flow_step_distance)
	unit.call("play_anim_state", 1, {}) # MOVE


func _pick_target_for_unit(unit: Node) -> Node:
	var self_team: int = int(unit.get("team_id"))
	var enemy_team: int = TEAM_ENEMY if self_team == TEAM_ALLY else TEAM_ALLY

	# 分组 AI：优先尝试共享焦点目标，减少每单位筛选开销。
	var focus_id: int = int(_group_focus_target_id.get(self_team, -1))
	if focus_id > 0 and _unit_by_instance_id.has(focus_id):
		var focus_target: Node = _unit_by_instance_id[focus_id]
		if _is_live_unit(focus_target) and _is_unit_alive(focus_target):
			if int(focus_target.get("team_id")) == enemy_team:
				return focus_target

	var search_ids: Array[int] = _spatial_hash.query_radius(unit.position, target_query_radius)
	var best_target: Node = null
	var best_dist_sq: float = INF
	for candidate_id in search_ids:
		if not _unit_by_instance_id.has(candidate_id):
			continue
		var candidate: Node = _unit_by_instance_id[candidate_id]
		if not _is_live_unit(candidate):
			continue
		if not _is_unit_alive(candidate):
			continue
		if int(candidate.get("team_id")) != enemy_team:
			continue

		var d2: float = unit.position.distance_squared_to(candidate.position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_target = candidate

	if best_target != null:
		return best_target

	# 兜底：若空间查询为空，使用敌方存活列表中最近目标。
	for enemy in _team_alive_cache.get(enemy_team, []):
		var d2: float = unit.position.distance_squared_to((enemy as Node2D).position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_target = enemy
	return best_target


func _is_target_in_attack_range(attacker: Node, target: Node) -> bool:
	var combat: Node = _get_combat(attacker)
	if combat == null:
		return false

	var hex_size: float = 26.0
	if _hex_grid != null:
		hex_size = float(_hex_grid.get("hex_size"))

	var world_range: float = float(combat.call("get_attack_range_world", hex_size))
	var dist_sq: float = attacker.position.distance_squared_to(target.position)
	return dist_sq <= world_range * world_range


func _sample_flow_direction(unit: Node) -> Vector2:
	if _hex_grid == null:
		return Vector2.ZERO

	var cell: Vector2i = _hex_grid.call("world_to_axial", unit.position)
	var team_id: int = int(unit.get("team_id"))
	if team_id == TEAM_ALLY:
		return _flow_to_enemy.sample_direction(cell)
	if team_id == TEAM_ENEMY:
		return _flow_to_ally.sample_direction(cell)
	return Vector2.ZERO


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
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


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
		"logic_frame": _logic_frame
	}
