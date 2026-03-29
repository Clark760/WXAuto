extends RefCounted
class_name CombatPathfindingRules

const FOLLOW_ANCHOR_LOCAL_SEARCH_RADIUS: int = 4

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
	var ally_target_seen: Dictionary = {}
	var enemy_target_seen: Dictionary = {}
	# 目标格同时包含敌方脚下与相邻可接敌格，能减少近战贴脸绕圈。
	for cell in team_cells_cache.get(2, []):
		_append_unique_target_cell(ally_targets, ally_target_seen, cell)
		for neighbor in runtime_port._neighbors_of(cell):
			if runtime_port._is_cell_free(neighbor):
				_append_unique_target_cell(ally_targets, ally_target_seen, neighbor)
	for cell in team_cells_cache.get(1, []):
		_append_unique_target_cell(enemy_targets, enemy_target_seen, cell)
		for neighbor in runtime_port._neighbors_of(cell):
			if runtime_port._is_cell_free(neighbor):
				_append_unique_target_cell(enemy_targets, enemy_target_seen, neighbor)

	var hex_grid: Node = runtime_port.get("_hex_grid")
	if hex_grid == null or not is_instance_valid(hex_grid):
		return
	flow_to_enemy.build(hex_grid, ally_targets, blocked_for_ally)
	flow_to_ally.build(hex_grid, enemy_targets, blocked_for_enemy)


func _append_unique_target_cell(output: Array[Vector2i], seen: Dictionary, cell: Vector2i) -> void:
	if seen.has(cell):
		return
	seen[cell] = true
	output.append(cell)


# 跟随友军锚点按“当前单位 -> 更前方的最近友军”预先缓存，避免被卡住时再扫整队。
# 缓存存的是锚点单位 instance_id，而不是静态 cell，这样同一逻辑帧内前排移动后仍能读到新位置。
# 这里只负责构建索引，不参与具体邻格落点决策。
func rebuild_follow_anchor_cache(
	runtime_port: Node,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary,
	team_alive_cache: Dictionary
) -> Dictionary:
	var cache: Dictionary = {}
	_rebuild_team_follow_anchor_cache(
		cache,
		runtime_port,
		group_focus_target_id,
		unit_by_id,
		team_alive_cache,
		1
	)
	_rebuild_team_follow_anchor_cache(
		cache,
		runtime_port,
		group_focus_target_id,
		unit_by_id,
		team_alive_cache,
		2
	)
	return cache


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
	follow_anchor_by_unit_id: Dictionary,
	attack_range_target: Node
) -> Vector2i:
	var team_id: int = int(unit.get("team_id"))
	if attack_range_target != null:
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
		unit_by_id,
		follow_anchor_by_unit_id,
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
	unit_by_id: Dictionary,
	follow_anchor_by_unit_id: Dictionary,
	focus_cell: Vector2i,
	has_focus_cell: bool
) -> Vector2i:
	var best_anchor_cell: Vector2i = _resolve_cached_follow_anchor_cell(
		runtime_port,
		unit,
		current_cell,
		unit_by_id,
		follow_anchor_by_unit_id
	)
	if best_anchor_cell.x < 0:
		return current_cell

	var self_focus_dist: int = 1 << 30
	if has_focus_cell:
		self_focus_dist = runtime_port._hex_distance(current_cell, focus_cell)

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


# 每队单独预构建“当前单位应该跟随的更前方友军”，避免 move 阶段重复扫完整存活列表。
# 焦点存在时，只允许选择比自己更接近焦点的友军；没有焦点时退化成最近友军。
# 这一步只缓存锚点单位 id，不缓存落点，落点仍按当帧邻格空闲状态即时决策。
func _rebuild_team_follow_anchor_cache(
	cache: Dictionary,
	runtime_port: Node,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary,
	team_alive_cache: Dictionary,
	team_id: int
) -> void:
	var own_alive: Array = team_alive_cache.get(team_id, [])
	if own_alive.size() <= 1:
		return

	var focus_cell: Vector2i = _resolve_team_focus_cell(
		runtime_port,
		group_focus_target_id,
		unit_by_id,
		team_id
	)
	var has_focus_cell: bool = focus_cell.x >= 0
	var unit_ids: Array[int] = []
	var cell_by_unit_id: Dictionary = {}
	var focus_distance_by_unit_id: Dictionary = {}
	var team_unit_by_cell: Dictionary = {}

	for unit_value in own_alive:
		var unit: Node = unit_value as Node
		if unit == null or not runtime_port._is_live_unit(unit):
			continue
		if not runtime_port._is_unit_alive(unit):
			continue
		var current_cell: Vector2i = runtime_port._get_unit_cell(unit)
		if current_cell.x < 0:
			continue
		var unit_id: int = unit.get_instance_id()
		var focus_distance: int = (
			_axial_distance(current_cell, focus_cell)
			if has_focus_cell
			else 1 << 30
		)
		unit_ids.append(unit_id)
		cell_by_unit_id[unit_id] = current_cell
		focus_distance_by_unit_id[unit_id] = focus_distance
		team_unit_by_cell[current_cell] = unit_id

	for unit_id in unit_ids:
		var current_cell: Vector2i = cell_by_unit_id.get(unit_id, Vector2i(-1, -1))
		var self_focus_dist: int = int(focus_distance_by_unit_id.get(unit_id, 1 << 30))
		var best_anchor_id: int = _find_local_follow_anchor_id(
			runtime_port,
			unit_id,
			current_cell,
			self_focus_dist,
			has_focus_cell,
			team_unit_by_cell,
			focus_distance_by_unit_id
		)
		if best_anchor_id <= 0:
			best_anchor_id = _find_nearest_follow_anchor_id_full_scan(
				unit_id,
				current_cell,
				self_focus_dist,
				has_focus_cell,
				unit_ids,
				cell_by_unit_id,
				focus_distance_by_unit_id
			)
		if best_anchor_id > 0:
			cache[unit_id] = best_anchor_id


func _find_local_follow_anchor_id(
	runtime_port: Node,
	self_unit_id: int,
	current_cell: Vector2i,
	self_focus_dist: int,
	has_focus_cell: bool,
	team_unit_by_cell: Dictionary,
	focus_distance_by_unit_id: Dictionary
) -> int:
	if current_cell.x < 0:
		return -1

	var frontier: Array[Vector2i] = [current_cell]
	var visited: Dictionary = {current_cell: true}
	for _radius in range(FOLLOW_ANCHOR_LOCAL_SEARCH_RADIUS):
		var next_frontier: Array[Vector2i] = []
		var best_anchor_id: int = -1
		var best_focus_dist: int = 1 << 30
		for frontier_cell in frontier:
			for neighbor in runtime_port._neighbors_of(frontier_cell):
				if visited.has(neighbor):
					continue
				visited[neighbor] = true
				next_frontier.append(neighbor)
				if not team_unit_by_cell.has(neighbor):
					continue
				var candidate_id: int = int(team_unit_by_cell.get(neighbor, -1))
				if candidate_id <= 0 or candidate_id == self_unit_id:
					continue
				var candidate_focus_dist: int = int(
					focus_distance_by_unit_id.get(candidate_id, 1 << 30)
				)
				if has_focus_cell and candidate_focus_dist >= self_focus_dist:
					continue
				if (
					best_anchor_id <= 0
					or candidate_focus_dist < best_focus_dist
					or (
						candidate_focus_dist == best_focus_dist
						and candidate_id < best_anchor_id
					)
				):
					best_anchor_id = candidate_id
					best_focus_dist = candidate_focus_dist
		if best_anchor_id > 0:
			return best_anchor_id
		frontier = next_frontier
		if frontier.is_empty():
			break
	return -1


func _find_nearest_follow_anchor_id_full_scan(
	self_unit_id: int,
	current_cell: Vector2i,
	self_focus_dist: int,
	has_focus_cell: bool,
	unit_ids: Array[int],
	cell_by_unit_id: Dictionary,
	focus_distance_by_unit_id: Dictionary
) -> int:
	var best_anchor_id: int = -1
	var best_anchor_dist: int = 1 << 30
	for candidate_id in unit_ids:
		if candidate_id == self_unit_id:
			continue
		var candidate_focus_dist: int = int(
			focus_distance_by_unit_id.get(candidate_id, 1 << 30)
		)
		if has_focus_cell and candidate_focus_dist >= self_focus_dist:
			continue
		var candidate_cell: Vector2i = cell_by_unit_id.get(candidate_id, Vector2i(-1, -1))
		if candidate_cell.x < 0:
			continue
		var anchor_dist: int = _axial_distance(current_cell, candidate_cell)
		if anchor_dist < best_anchor_dist:
			best_anchor_dist = anchor_dist
			best_anchor_id = candidate_id
	return best_anchor_id


# 跟随锚点必须来自当前队伍的 group focus；如果焦点失效，则整队回退到“最近友军”策略。
# 这里返回焦点单位当前 cell，缺失时统一用 (-1, -1) 表示“无焦点”。
# 锚点缓存构建和 move 决策都共用这条焦点解析口径。
func _resolve_team_focus_cell(
	runtime_port: Node,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary,
	team_id: int
) -> Vector2i:
	var focus_id: int = int(group_focus_target_id.get(team_id, -1))
	if focus_id <= 0 or not unit_by_id.has(focus_id):
		return Vector2i(-1, -1)
	var focus_target: Node = unit_by_id[focus_id]
	if not runtime_port._is_live_unit(focus_target):
		return Vector2i(-1, -1)
	if not runtime_port._is_unit_alive(focus_target):
		return Vector2i(-1, -1)
	return runtime_port._get_unit_cell(focus_target)


# 单位级锚点选择保留原规则：优先找“比自己更靠前”的最近友军。
# 返回 instance_id 便于 move 阶段按当前最新 cell 读取锚点位置，不把位置快照写死。
# 这里只有“找锚点”的职责，不处理邻格落点优劣。
func _axial_distance(a: Vector2i, b: Vector2i) -> int:
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2


# move 阶段只消费已经预构建好的锚点缓存，不再临时扫描全队。
# 锚点若已死亡或移出有效格子，会直接视作本帧没有可跟随友军。
# 这里返回的是锚点单位的当前 cell，而不是缓存构建时的旧位置。
func _resolve_cached_follow_anchor_cell(
	runtime_port: Node,
	unit: Node,
	current_cell: Vector2i,
	unit_by_id: Dictionary,
	follow_anchor_by_unit_id: Dictionary
) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)
	var unit_id: int = unit.get_instance_id()
	if not follow_anchor_by_unit_id.has(unit_id):
		return Vector2i(-1, -1)
	var anchor_id: int = int(follow_anchor_by_unit_id.get(unit_id, -1))
	if anchor_id <= 0 or not unit_by_id.has(anchor_id):
		return Vector2i(-1, -1)
	var anchor_unit: Node = unit_by_id[anchor_id]
	if not runtime_port._is_live_unit(anchor_unit):
		return Vector2i(-1, -1)
	if not runtime_port._is_unit_alive(anchor_unit):
		return Vector2i(-1, -1)
	var anchor_cell: Vector2i = runtime_port._get_unit_cell(anchor_unit)
	if anchor_cell.x < 0 or anchor_cell == current_cell:
		return Vector2i(-1, -1)
	return anchor_cell
