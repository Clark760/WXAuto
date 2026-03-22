extends RefCounted
class_name CombatTargeting

# ===========================
# 目标选择与分组AI模块
# ===========================

func update_group_ai_focus(owner: Node) -> void:
	(owner.get("_group_focus_target_id") as Dictionary).clear()
	(owner.get("_group_center") as Dictionary).clear()
	update_team_focus(owner, 1, 2)
	update_team_focus(owner, 2, 1)


func update_team_focus(owner: Node, self_team: int, enemy_team: int) -> void:
	var team_alive_cache: Dictionary = owner.get("_team_alive_cache")
	var own_alive: Array = team_alive_cache.get(self_team, [])
	var enemy_alive: Array = team_alive_cache.get(enemy_team, [])
	if own_alive.is_empty() or enemy_alive.is_empty():
		return

	var center: Vector2 = Vector2.ZERO
	for unit in own_alive:
		center += (unit as Node2D).position
	center /= float(maxi(own_alive.size(), 1))
	(owner.get("_group_center") as Dictionary)[self_team] = center

	var best_enemy: Node = null
	var best_dist_sq: float = INF
	for enemy in enemy_alive:
		var d2: float = center.distance_squared_to((enemy as Node2D).position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_enemy = enemy
	if best_enemy != null:
		(owner.get("_group_focus_target_id") as Dictionary)[self_team] = best_enemy.get_instance_id()


func pick_target_for_unit(owner: Node, unit: Node) -> Node:
	var self_team: int = int(unit.get("team_id"))
	var team_ally: int = 1
	var team_enemy: int = 2
	var enemy_team: int = team_enemy if self_team == team_ally else team_ally
	var taunt_target: Node = _pick_taunt_forced_target(owner, unit, enemy_team)
	if taunt_target != null:
		return taunt_target

	if bool(owner.get("prioritize_targets_in_attack_range")):
		var in_range_target: Node = pick_target_in_attack_range(owner, unit, enemy_team)
		if in_range_target != null:
			return in_range_target

	var focus_map: Dictionary = owner.get("_group_focus_target_id")
	var unit_by_id: Dictionary = owner.get("_unit_by_instance_id")
	var focus_id: int = int(focus_map.get(self_team, -1))
	if focus_id > 0 and unit_by_id.has(focus_id):
		var focus_target: Node = unit_by_id[focus_id]
		if bool(owner.call("_is_live_unit", focus_target)) and bool(owner.call("_is_unit_alive", focus_target)):
			if int(focus_target.get("team_id")) == enemy_team:
				return focus_target

	var spatial_hash: SpatialHash = owner.get("_spatial_hash")
	var target_query_radius: float = float(owner.get("target_query_radius"))
	var best_target: Node = null
	var best_dist_sq: float = INF
	for candidate_id in spatial_hash.query_radius(unit.position, target_query_radius):
		if not unit_by_id.has(candidate_id):
			continue
		var candidate: Node = unit_by_id[candidate_id]
		if not bool(owner.call("_is_live_unit", candidate)):
			continue
		if not bool(owner.call("_is_unit_alive", candidate)):
			continue
		if int(candidate.get("team_id")) != enemy_team:
			continue
		var d2: float = unit.position.distance_squared_to(candidate.position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_target = candidate
	if best_target != null:
		return best_target

	var team_alive_cache: Dictionary = owner.get("_team_alive_cache")
	for enemy in team_alive_cache.get(enemy_team, []):
		var d2: float = unit.position.distance_squared_to((enemy as Node2D).position)
		if d2 < best_dist_sq:
			best_dist_sq = d2
			best_target = enemy
	return best_target


func _pick_taunt_forced_target(owner: Node, unit: Node, enemy_team: int) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var until_time: float = float(unit.get_meta("status_taunt_until", 0.0))
	if until_time <= 0.0:
		return null
	var now_time: float = 0.0
	if owner != null and owner.has_method("get_logic_time"):
		now_time = float(owner.call("get_logic_time"))
	if until_time <= now_time:
		unit.remove_meta("status_taunt_until")
		unit.remove_meta("status_taunt_source_id")
		unit.remove_meta("status_taunt_source_team")
		return null
	var source_id: int = int(unit.get_meta("status_taunt_source_id", -1))
	if source_id <= 0:
		return null
	var unit_by_id: Dictionary = owner.get("_unit_by_instance_id")
	if not unit_by_id.has(source_id):
		return null
	var forced_target: Node = unit_by_id[source_id]
	if not bool(owner.call("_is_live_unit", forced_target)):
		return null
	if not bool(owner.call("_is_unit_alive", forced_target)):
		return null
	if int(forced_target.get("team_id")) != enemy_team:
		return null
	return forced_target


func pick_target_in_attack_range(owner: Node, unit: Node, enemy_team: int) -> Node:
	var combat: Node = owner.call("_get_combat", unit)
	if combat == null:
		return null
	var self_cell: Vector2i = owner.call("_get_unit_cell", unit)
	if self_cell.x < 0:
		return null
	var range_cells: int = maxi(int(combat.call("get_attack_range_cells")), 1)
	if range_cells == 1:
		for neighbor in owner.call("_neighbors_of", self_cell):
			var occupant: Node = get_occupant_unit_at_cell(owner, neighbor)
			if occupant != null and int(occupant.get("team_id")) == enemy_team:
				return occupant
		return null

	var query_radius: float = float(owner.get("target_query_radius"))
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid != null:
		var hex_size: float = maxf(float(hex_grid.get("hex_size")), 1.0)
		query_radius = maxf(float(range_cells) * hex_size * 1.35, hex_size * 1.2)

	var spatial_hash: SpatialHash = owner.get("_spatial_hash")
	var unit_by_id: Dictionary = owner.get("_unit_by_instance_id")
	var best_target: Node = null
	var best_hex_dist: int = 1 << 30
	var best_world_dist_sq: float = INF
	for candidate_id in spatial_hash.query_radius(unit.position, query_radius):
		if not unit_by_id.has(candidate_id):
			continue
		var candidate: Node = unit_by_id[candidate_id]
		if not bool(owner.call("_is_live_unit", candidate)):
			continue
		if not bool(owner.call("_is_unit_alive", candidate)):
			continue
		if int(candidate.get("team_id")) != enemy_team:
			continue
		var candidate_cell: Vector2i = owner.call("_get_unit_cell", candidate)
		if candidate_cell.x < 0:
			continue
		var hex_dist: int = int(owner.call("_hex_distance", self_cell, candidate_cell))
		if hex_dist > range_cells:
			continue
		var world_dist_sq: float = unit.position.distance_squared_to(candidate.position)
		if hex_dist < best_hex_dist or (hex_dist == best_hex_dist and world_dist_sq < best_world_dist_sq):
			best_hex_dist = hex_dist
			best_world_dist_sq = world_dist_sq
			best_target = candidate
	return best_target


func get_occupant_unit_at_cell(owner: Node, cell: Vector2i) -> Node:
	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	var unit_by_id: Dictionary = owner.get("_unit_by_instance_id")
	var cell_key: int = int(owner.call("_cell_key_int", cell))
	if not cell_occupancy.has(cell_key):
		return null
	var iid: int = int(cell_occupancy[cell_key])
	if not unit_by_id.has(iid):
		return null
	var unit: Node = unit_by_id[iid]
	if not bool(owner.call("_is_live_unit", unit)):
		return null
	if not bool(owner.call("_is_unit_alive", unit)):
		return null
	return unit


func is_target_in_attack_range(owner: Node, attacker: Node, target: Node) -> bool:
	var combat: Node = owner.call("_get_combat", attacker)
	if combat == null:
		return false
	var attacker_cell: Vector2i = owner.call("_get_unit_cell", attacker)
	var target_cell: Vector2i = owner.call("_get_unit_cell", target)
	if attacker_cell.x < 0 or target_cell.x < 0:
		return false
	var hex_dist: int = int(owner.call("_hex_distance", attacker_cell, target_cell))
	var range_cells: int = 1
	if combat.has_method("get_max_effective_range_cells"):
		range_cells = maxi(int(combat.call("get_max_effective_range_cells")), 1)
	else:
		range_cells = maxi(int(combat.call("get_attack_range_cells")), 1)
	return hex_dist <= range_cells
