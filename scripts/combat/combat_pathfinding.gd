extends RefCounted
class_name CombatPathfinding

# ===========================
# 流场与移动决策模块
# ===========================

func rebuild_flow_fields(owner: Node) -> void:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid == null:
		return

	var blocked_for_ally: Dictionary = {}
	var blocked_for_enemy: Dictionary = {}
	if bool(owner.get("block_teammate_cells_in_flow")):
		blocked_for_ally = build_blocked_cells_for_team(owner, 1)
		blocked_for_enemy = build_blocked_cells_for_team(owner, 2)

	var team_enemy: int = 2
	var team_ally: int = 1
	var team_cells_cache: Dictionary = owner.get("_team_cells_cache")
	var ally_targets: Array[Vector2i] = []
	var enemy_targets: Array[Vector2i] = []

	for cell in team_cells_cache.get(team_enemy, []):
		ally_targets.append(cell)
		for neighbor in owner.call("_neighbors_of", cell):
			if bool(owner.call("_is_cell_free", neighbor)):
				ally_targets.append(neighbor)
	for cell in team_cells_cache.get(team_ally, []):
		enemy_targets.append(cell)
		for neighbor in owner.call("_neighbors_of", cell):
			if bool(owner.call("_is_cell_free", neighbor)):
				enemy_targets.append(neighbor)

	var flow_to_enemy: FlowField = owner.get("_flow_to_enemy")
	var flow_to_ally: FlowField = owner.get("_flow_to_ally")
	flow_to_enemy.build(hex_grid, ally_targets, blocked_for_ally)
	flow_to_ally.build(hex_grid, enemy_targets, blocked_for_enemy)


func build_blocked_cells_for_team(owner: Node, self_team: int) -> Dictionary:
	var blocked: Dictionary = (owner.get("_static_blocked_cells") as Dictionary).duplicate()
	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	var unit_by_id: Dictionary = owner.get("_unit_by_instance_id")
	for raw_key in cell_occupancy.keys():
		var cell_key: int = int(raw_key)
		var iid: int = int(cell_occupancy[cell_key])
		if not unit_by_id.has(iid):
			continue
		var unit: Node = unit_by_id[iid]
		if not bool(owner.call("_is_live_unit", unit)) or not bool(owner.call("_is_unit_alive", unit)):
			continue
		if int(unit.get("team_id")) == self_team:
			blocked[cell_key] = true
	return blocked


func pick_best_adjacent_cell(owner: Node, unit: Node, current_cell: Vector2i) -> Vector2i:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid == null:
		return current_cell

	var team_ally: int = 1
	var team_enemy: int = 2
	var team_id: int = int(unit.get("team_id"))
	var enemy_team: int = team_enemy if team_id == team_ally else team_ally
	if owner.call("_pick_target_in_attack_range", unit, enemy_team) != null:
		return current_cell

	var flow_field: FlowField = owner.get("_flow_to_enemy") if team_id == team_ally else owner.get("_flow_to_ally")
	var current_cost: int = flow_field.sample_cost(current_cell)
	var best_cell: Vector2i = current_cell
	var best_cost: float = INF
	var best_focus_dist: int = 1 << 30
	var side_step_cell: Vector2i = current_cell
	var side_step_found: bool = false
	var side_step_focus_dist: int = 1 << 30
	var has_focus_cell: bool = false
	var focus_cell: Vector2i = Vector2i.ZERO

	var focus_target_id: int = int((owner.get("_group_focus_target_id") as Dictionary).get(team_id, -1))
	var unit_by_id: Dictionary = owner.get("_unit_by_instance_id")
	if focus_target_id > 0 and unit_by_id.has(focus_target_id):
		var focus_target: Node = unit_by_id[focus_target_id]
		if bool(owner.call("_is_live_unit", focus_target)) and bool(owner.call("_is_unit_alive", focus_target)):
			var resolved_focus_cell: Vector2i = owner.call("_get_unit_cell", focus_target)
			if resolved_focus_cell.x >= 0:
				has_focus_cell = true
				focus_cell = resolved_focus_cell

	best_cost = INF if current_cost < 0 else float(current_cost)
	for neighbor in owner.call("_neighbors_of", current_cell):
		if not bool(owner.call("_is_cell_free", neighbor)):
			continue
		var neighbor_cost: int = flow_field.sample_cost(neighbor)
		if neighbor_cost < 0:
			continue
		var neighbor_focus_dist: int = 0
		if has_focus_cell:
			neighbor_focus_dist = hex_distance(owner, neighbor, focus_cell)

		if current_cost < 0:
			if float(neighbor_cost) < best_cost or (is_equal_approx(float(neighbor_cost), best_cost) and neighbor_focus_dist < best_focus_dist):
				best_cost = float(neighbor_cost)
				best_focus_dist = neighbor_focus_dist
				best_cell = neighbor
			continue
		if neighbor_cost < current_cost:
			if float(neighbor_cost) < best_cost or (is_equal_approx(float(neighbor_cost), best_cost) and neighbor_focus_dist < best_focus_dist):
				best_cost = float(neighbor_cost)
				best_focus_dist = neighbor_focus_dist
				best_cell = neighbor
			continue
		if bool(owner.get("allow_equal_cost_side_step")) and neighbor_cost == current_cost:
			if current_cost <= 2:
				continue
			if not side_step_found or neighbor_focus_dist < side_step_focus_dist:
				side_step_found = true
				side_step_focus_dist = neighbor_focus_dist
				side_step_cell = neighbor
			continue
		# M5-FIX: 禁用“上坡逃逸步”。开启队友阻挡流场后，允许上坡会导致后排反复抖动。

	if best_cell != current_cell:
		return best_cell
	if bool(owner.get("allow_equal_cost_side_step")) and side_step_found and current_cost > 2:
		return side_step_cell
	# M5-FIX: 上坡逃逸步已禁用，避免单位远离目标后再折返。
	return best_cell


func hex_distance(owner: Node, a: Vector2i, b: Vector2i) -> int:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid != null and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2
