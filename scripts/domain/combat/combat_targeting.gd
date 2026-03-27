extends RefCounted
class_name CombatTargetingRules

# 目标规则
# 说明：
# 1. 这里只承接集火、射程筛选和嘲讽优先级。
# 2. runtime_port 只提供组件查询、存活判定和格子查询能力。
# 3. 规则层不再通过 owner.get/call 读取 facade 私有状态。


# 每帧都先清空旧焦点，再基于当前存活单位重建双方集火目标。
func update_group_ai_focus(
	group_focus_target_id: Dictionary,
	group_center: Dictionary,
	team_alive_cache: Dictionary
) -> void:
	group_focus_target_id.clear()
	group_center.clear()
	update_team_focus(group_focus_target_id, group_center, team_alive_cache, 1, 2)
	update_team_focus(group_focus_target_id, group_center, team_alive_cache, 2, 1)


# 队伍焦点只按己方中心点选最近敌人，不掺入单体射程和技能特判。
func update_team_focus(
	group_focus_target_id: Dictionary,
	group_center: Dictionary,
	team_alive_cache: Dictionary,
	self_team: int,
	enemy_team: int
) -> void:
	var own_alive: Array = team_alive_cache.get(self_team, [])
	var enemy_alive: Array = team_alive_cache.get(enemy_team, [])
	if own_alive.is_empty() or enemy_alive.is_empty():
		return

	var center: Vector2 = Vector2.ZERO
	for unit in own_alive:
		center += (unit as Node2D).position
	center /= float(maxi(own_alive.size(), 1))
	group_center[self_team] = center

	var best_enemy: Node = null
	var best_dist_sq: float = INF
	for enemy in enemy_alive:
		var dist_sq: float = center.distance_squared_to((enemy as Node2D).position)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_enemy = enemy
	if best_enemy != null:
		group_focus_target_id[self_team] = best_enemy.get_instance_id()


# 单位选敌顺序始终保持：嘲讽、射程内目标、队伍焦点、空间索引、整队兜底。
func pick_target_for_unit(
	runtime_port: Node,
	unit: Node,
	prioritize_targets_in_attack_range: bool,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary,
	spatial_hash,
	team_alive_cache: Dictionary,
	target_query_radius: float
) -> Node:
	var self_team: int = int(unit.get("team_id"))
	var enemy_team: int = 2 if self_team == 1 else 1
	# 嘲讽永远比集火和距离优先级更高，先判它可以少走后续分支。
	var taunt_target: Node = _pick_taunt_forced_target(runtime_port, unit, enemy_team, unit_by_id)
	if taunt_target != null:
		return taunt_target

	if prioritize_targets_in_attack_range:
		# 射程内已有可打目标时，优先避免单位为了“最近敌人”多走一步。
		var in_range_target: Node = pick_target_in_attack_range(
			runtime_port,
			unit,
			enemy_team,
			spatial_hash,
			unit_by_id,
			target_query_radius,
			0.0
		)
		if in_range_target != null:
			return in_range_target

	var focus_id: int = int(group_focus_target_id.get(self_team, -1))
	# 队伍焦点只在目标仍然存活且阵营正确时继续沿用。
	if focus_id > 0 and unit_by_id.has(focus_id):
		var focus_target: Node = unit_by_id[focus_id]
		if runtime_port._is_live_unit(focus_target) and runtime_port._is_unit_alive(focus_target):
			if int(focus_target.get("team_id")) == enemy_team:
				return focus_target

	var best_target: Node = null
	var best_dist_sq: float = INF
	for candidate_id in spatial_hash.query_radius(unit.position, target_query_radius):
		if not unit_by_id.has(candidate_id):
			continue
		# 空间索引命中的候选仍要过存活和阵营筛选，避免脏缓存误选。
		var candidate: Node = unit_by_id[candidate_id]
		if not runtime_port._is_live_unit(candidate):
			continue
		if not runtime_port._is_unit_alive(candidate):
			continue
		if int(candidate.get("team_id")) != enemy_team:
			continue
		var dist_sq: float = unit.position.distance_squared_to(candidate.position)
		if dist_sq < best_dist_sq:
			best_dist_sq = dist_sq
			best_target = candidate
	if best_target != null:
		return best_target

	for enemy in team_alive_cache.get(enemy_team, []):
		var fallback_dist_sq: float = unit.position.distance_squared_to((enemy as Node2D).position)
		if fallback_dist_sq < best_dist_sq:
			best_dist_sq = fallback_dist_sq
			best_target = enemy
	return best_target


# 射程内选敌优先走近邻格，其次才用空间索引粗筛再走 hex 距离精筛。
func pick_target_in_attack_range(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	spatial_hash,
	unit_by_id: Dictionary,
	target_query_radius: float,
	hex_size: float
) -> Node:
	var combat: Node = runtime_port._get_combat(unit)
	if combat == null:
		return null
	var self_cell: Vector2i = runtime_port._get_unit_cell(unit)
	if self_cell.x < 0:
		return null

	var range_cells: int = maxi(int(combat.get_attack_range_cells()), 1)
	# 近战先走邻格占用反查，能少一次空间索引查询。
	if range_cells == 1:
		for neighbor in runtime_port._neighbors_of(self_cell):
			var occupant: Node = get_occupant_unit_at_cell(
				runtime_port,
				neighbor,
				runtime_port.get("_cell_occupancy"),
				unit_by_id
			)
			if occupant != null and int(occupant.get("team_id")) == enemy_team:
				return occupant
		return null

	var query_radius: float = target_query_radius
	if hex_size > 0.0:
		# 射程越远，粗筛半径就越大；最终仍由 hex 距离做精筛。
		query_radius = maxf(float(range_cells) * hex_size * 1.35, hex_size * 1.2)

	var best_target: Node = null
	var best_hex_dist: int = 1 << 30
	var best_world_dist_sq: float = INF
	for candidate_id in spatial_hash.query_radius(unit.position, query_radius):
		if not unit_by_id.has(candidate_id):
			continue
		# 世界距离只用于同 hex 距离下的平手裁决，不替代正式射程口径。
		var candidate: Node = unit_by_id[candidate_id]
		if not runtime_port._is_live_unit(candidate):
			continue
		if not runtime_port._is_unit_alive(candidate):
			continue
		if int(candidate.get("team_id")) != enemy_team:
			continue
		var candidate_cell: Vector2i = runtime_port._get_unit_cell(candidate)
		if candidate_cell.x < 0:
			continue
		var cell_dist: int = runtime_port._hex_distance(self_cell, candidate_cell)
		if cell_dist > range_cells:
			continue
		var world_dist_sq: float = unit.position.distance_squared_to(candidate.position)
		if cell_dist < best_hex_dist or (cell_dist == best_hex_dist and world_dist_sq < best_world_dist_sq):
			best_hex_dist = cell_dist
			best_world_dist_sq = world_dist_sq
			best_target = candidate
	return best_target


# 占格表反查单位时，会同步过滤失效节点和死亡单位。
func get_occupant_unit_at_cell(
	runtime_port: Node,
	cell: Vector2i,
	cell_occupancy: Dictionary,
	unit_by_id: Dictionary
) -> Node:
	var cell_key: int = int(runtime_port._cell_key_int(cell))
	# 占格表和 unit registry 同时承认的单位，才算这格的真实占用者。
	if not cell_occupancy.has(cell_key):
		return null
	var iid: int = int(cell_occupancy[cell_key])
	if not unit_by_id.has(iid):
		return null
	var unit: Node = unit_by_id[iid]
	if not runtime_port._is_live_unit(unit):
		return null
	if not runtime_port._is_unit_alive(unit):
		return null
	return unit


# 射程判定统一按逻辑格距离，不受世界坐标 tween 或视觉偏移影响。
func is_target_in_attack_range(runtime_port: Node, attacker: Node, target: Node) -> bool:
	var combat: Node = runtime_port._get_combat(attacker)
	if combat == null:
		return false
	var attacker_cell: Vector2i = runtime_port._get_unit_cell(attacker)
	var target_cell: Vector2i = runtime_port._get_unit_cell(target)
	if attacker_cell.x < 0 or target_cell.x < 0:
		return false
	var range_cells: int = 1
	if combat.has_method("get_max_effective_range_cells"):
		range_cells = maxi(int(combat.get_max_effective_range_cells()), 1)
	else:
		range_cells = maxi(int(combat.get_attack_range_cells()), 1)
	return runtime_port._hex_distance(attacker_cell, target_cell) <= range_cells


# 嘲讽过期时会顺手清掉 meta，避免无效控制状态继续污染选敌。
func _pick_taunt_forced_target(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	unit_by_id: Dictionary
) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var until_time: float = float(unit.get_meta("status_taunt_until", 0.0))
	if until_time <= 0.0:
		return null
	if until_time <= runtime_port.get_logic_time():
		# 嘲讽到期立刻清 meta，避免失效 source 挂在单位身上继续干扰选敌。
		unit.remove_meta("status_taunt_until")
		unit.remove_meta("status_taunt_source_id")
		unit.remove_meta("status_taunt_source_team")
		return null

	var source_id: int = int(unit.get_meta("status_taunt_source_id", -1))
	if source_id <= 0 or not unit_by_id.has(source_id):
		return null
	var forced_target: Node = unit_by_id[source_id]
	if not runtime_port._is_live_unit(forced_target):
		return null
	if not runtime_port._is_unit_alive(forced_target):
		return null
	if int(forced_target.get("team_id")) != enemy_team:
		return null
	return forced_target
