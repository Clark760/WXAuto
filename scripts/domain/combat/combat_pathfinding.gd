extends RefCounted
class_name CombatPathfindingRules

# 寻路规则
# 说明：
# 1. 这里只承接 blocked map 构造、流场目标生成和邻格决策。
# 2. runtime_port 只提供存活判定、格子查询和射程判定能力。
# 3. 规则层不再通过 owner.get/call 读取 facade 私有状态。


# 流场重建只关心双方目标格集合与阻挡快照，不负责触发时机和缓存装配。
func rebuild_flow_fields(
	runtime_port: Node,
	flow_to_enemy,
	flow_to_ally,
	team_cells_cache: Dictionary,
	blocked_for_ally: Dictionary,
	blocked_for_enemy: Dictionary
) -> void:
	var ally_targets: Array[Vector2i] = []
	var enemy_targets: Array[Vector2i] = []
	# 目标格同时包含敌方脚下与相邻可接敌格，能减少近战贴脸绕圈。
	for cell in team_cells_cache.get(2, []):
		ally_targets.append(cell)
		for neighbor in runtime_port._neighbors_of(cell):
			if runtime_port._is_cell_free(neighbor):
				ally_targets.append(neighbor)
	for cell in team_cells_cache.get(1, []):
		enemy_targets.append(cell)
		for neighbor in runtime_port._neighbors_of(cell):
			if runtime_port._is_cell_free(neighbor):
				enemy_targets.append(neighbor)

	var hex_grid: Node = runtime_port.get("_hex_grid")
	if hex_grid == null or not is_instance_valid(hex_grid):
		return
	flow_to_enemy.build(hex_grid, ally_targets, blocked_for_ally)
	flow_to_ally.build(hex_grid, enemy_targets, blocked_for_enemy)


# “友军也视为阻挡”的快照构造统一收在这里，避免 manager 自己再写一份遍历。
func build_blocked_cells_for_team(
	runtime_port: Node,
	blocked_cells_snapshot: Dictionary,
	cell_occupancy: Dictionary,
	unit_by_id: Dictionary,
	self_team: int
) -> Dictionary:
	var blocked: Dictionary = blocked_cells_snapshot.duplicate(true)
	# blocked snapshot 先拷一份基础阻挡，再叠加“本队友军也算阻挡”的部分。
	for raw_key in cell_occupancy.keys():
		var cell_key: int = int(raw_key)
		var iid: int = int(cell_occupancy[cell_key])
		if not unit_by_id.has(iid):
			continue
		var unit: Node = unit_by_id[iid]
		if not runtime_port._is_live_unit(unit):
			continue
		if not runtime_port._is_unit_alive(unit):
			continue
		if int(unit.get("team_id")) == self_team:
			blocked[cell_key] = true
	return blocked


# 邻格决策只负责选下一步，不直接提交移动或改写占格。
func pick_best_adjacent_cell(
	runtime_port: Node,
	unit: Node,
	current_cell: Vector2i,
	flow_to_enemy,
	flow_to_ally,
	allow_equal_cost_side_step: bool,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary,
	team_alive_cache: Dictionary
) -> Vector2i:
	var team_id: int = int(unit.get("team_id"))
	var enemy_team: int = 2 if team_id == 1 else 1
	if runtime_port._pick_target_in_attack_range(unit, enemy_team) != null:
		return current_cell

	var flow_field = flow_to_enemy if team_id == 1 else flow_to_ally
	var current_cost: int = flow_field.sample_cost(current_cell)
	var best_cell: Vector2i = current_cell
	var best_cost: float = INF if current_cost < 0 else float(current_cost)
	var best_focus_dist: int = 1 << 30
	var side_step_cell: Vector2i = current_cell
	var side_step_found: bool = false
	var side_step_focus_dist: int = 1 << 30
	# side_step 只在没有更优降代价路径时参与，避免贴脸时横向抖动。

	var has_focus_cell: bool = false
	var focus_cell: Vector2i = Vector2i.ZERO
	var focus_target_id: int = int(group_focus_target_id.get(team_id, -1))
	if focus_target_id > 0 and unit_by_id.has(focus_target_id):
		var focus_target: Node = unit_by_id[focus_target_id]
		if runtime_port._is_live_unit(focus_target) and runtime_port._is_unit_alive(focus_target):
			var resolved_focus_cell: Vector2i = runtime_port._get_unit_cell(focus_target)
			if resolved_focus_cell.x >= 0:
				has_focus_cell = true
				focus_cell = resolved_focus_cell

	for neighbor in runtime_port._neighbors_of(current_cell):
		if not runtime_port._is_cell_free(neighbor):
			continue
		# 流场里没有代价的邻格视为不可达，不参与平手比较。
		var neighbor_cost: int = flow_field.sample_cost(neighbor)
		if neighbor_cost < 0:
			continue

		var neighbor_focus_dist: int = 0
		if has_focus_cell:
			neighbor_focus_dist = runtime_port._hex_distance(neighbor, focus_cell)

		if current_cost < 0:
			if _is_better_candidate(float(neighbor_cost), neighbor_focus_dist, best_cost, best_focus_dist):
				best_cost = float(neighbor_cost)
				best_focus_dist = neighbor_focus_dist
				best_cell = neighbor
			continue

		if neighbor_cost < current_cost:
			if _is_better_candidate(float(neighbor_cost), neighbor_focus_dist, best_cost, best_focus_dist):
				best_cost = float(neighbor_cost)
				best_focus_dist = neighbor_focus_dist
				best_cell = neighbor
			continue

		if allow_equal_cost_side_step and neighbor_cost == current_cost:
			if current_cost <= 2:
				continue
			if not side_step_found or neighbor_focus_dist < side_step_focus_dist:
				side_step_found = true
				side_step_focus_dist = neighbor_focus_dist
				side_step_cell = neighbor

	if best_cell != current_cell:
		return best_cell
	# 没有明确主路径时，才允许退回“同代价但更靠近焦点”的横移方案。
	if allow_equal_cost_side_step and side_step_found and current_cost > 2:
		return side_step_cell
	var follow_ally_cell: Vector2i = _pick_follow_ally_cell(
		runtime_port,
		unit,
		current_cell,
		flow_field,
		team_alive_cache,
		team_id,
		focus_cell,
		has_focus_cell
	)
	if follow_ally_cell != current_cell:
		return follow_ally_cell
	return best_cell


# 六角距离优先复用正式棋盘口径；缺失时再回退 axial 公式。
func hex_distance(hex_grid: Node, a: Vector2i, b: Vector2i) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.get_cell_distance(a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2


# 相同代价下仍允许用“更接近焦点”打破平手，避免整队左右摇摆。
func _is_better_candidate(
	candidate_cost: float,
	candidate_focus_dist: int,
	best_cost: float,
	best_focus_dist: int
) -> bool:
	return (
		candidate_cost < best_cost
		or (
			is_equal_approx(candidate_cost, best_cost)
			and candidate_focus_dist < best_focus_dist
		)
	)


# 当正面通路被友军堵住时，允许后排向更靠前的最近友军贴近，维持队形前压。
func _pick_follow_ally_cell(
	runtime_port: Node,
	unit: Node,
	current_cell: Vector2i,
	flow_field,
	team_alive_cache: Dictionary,
	team_id: int,
	focus_cell: Vector2i,
	has_focus_cell: bool
) -> Vector2i:
	var own_alive: Array = team_alive_cache.get(team_id, [])
	if own_alive.is_empty():
		return current_cell

	var best_anchor_cell: Vector2i = Vector2i(-1, -1)
	var best_anchor_dist: int = 1 << 30
	var self_focus_dist: int = 1 << 30
	if has_focus_cell:
		self_focus_dist = runtime_port._hex_distance(current_cell, focus_cell)

	for ally_value in own_alive:
		var ally: Node = ally_value as Node
		if ally == null or ally == unit:
			continue
		if not runtime_port._is_live_unit(ally) or not runtime_port._is_unit_alive(ally):
			continue
		var ally_cell: Vector2i = runtime_port._get_unit_cell(ally)
		if ally_cell.x < 0 or ally_cell == current_cell:
			continue
		if has_focus_cell:
			var ally_focus_dist: int = runtime_port._hex_distance(ally_cell, focus_cell)
			if ally_focus_dist >= self_focus_dist:
				continue
		var anchor_dist: int = runtime_port._hex_distance(current_cell, ally_cell)
		if anchor_dist < best_anchor_dist:
			best_anchor_dist = anchor_dist
			best_anchor_cell = ally_cell

	if best_anchor_cell.x < 0:
		return current_cell

	var current_anchor_dist: int = runtime_port._hex_distance(current_cell, best_anchor_cell)
	var current_focus_dist: int = self_focus_dist
	var best_follow_cell: Vector2i = current_cell
	var best_follow_anchor_dist: int = current_anchor_dist
	var best_follow_focus_dist: int = current_focus_dist
	var best_follow_cost: int = 1 << 30
	for neighbor in runtime_port._neighbors_of(current_cell):
		if not runtime_port._is_cell_free(neighbor):
			continue
		var neighbor_anchor_dist: int = runtime_port._hex_distance(neighbor, best_anchor_cell)
		if neighbor_anchor_dist > current_anchor_dist:
			continue
		var neighbor_focus_dist: int = current_focus_dist
		if has_focus_cell:
			neighbor_focus_dist = runtime_port._hex_distance(neighbor, focus_cell)
			if neighbor_anchor_dist == current_anchor_dist and neighbor_focus_dist > current_focus_dist:
				continue
		var neighbor_cost: int = flow_field.sample_cost(neighbor)
		if neighbor_cost < 0:
			neighbor_cost = 1 << 29
		if neighbor_anchor_dist < best_follow_anchor_dist:
			best_follow_anchor_dist = neighbor_anchor_dist
			best_follow_focus_dist = neighbor_focus_dist
			best_follow_cost = neighbor_cost
			best_follow_cell = neighbor
			continue
		if neighbor_anchor_dist == best_follow_anchor_dist and neighbor_focus_dist < best_follow_focus_dist:
			best_follow_focus_dist = neighbor_focus_dist
			best_follow_cost = neighbor_cost
			best_follow_cell = neighbor
			continue
		if neighbor_anchor_dist == best_follow_anchor_dist \
		and neighbor_focus_dist == best_follow_focus_dist \
		and neighbor_cost < best_follow_cost:
			best_follow_cost = neighbor_cost
			best_follow_cell = neighbor
	return best_follow_cell
