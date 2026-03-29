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


# 目标缓存约束：
# 1. 持久目标只记“攻击者 -> 目标”的轻量映射，不额外保存位置快照。
# 2. 所有持久目标在读取时都必须重新经过 registry、存活和阵营校验。
# 3. 嘲讽仍然拥有最高优先级；命中嘲讽时直接覆盖持久目标。
# 4. 只有达到固定重扫窗口，才允许切换到更优目标；不再按战场规模放大窗口。
# 5. 真正的行为改动范围只限于选敌频率，不碰伤害、移动和占格口径。
# 6. 清理持久目标时只清当前攻击者自己的记录，避免热路径上做全表删除。
# 7. 这层优化只为减少“同一单位连续几帧重复扫同一批敌人”的浪费。
# 8. 目标一旦死亡、换阵营或失效，仍然会立刻重选，不会被缓存拖住。
# 9. 这里不做“按人数自适应放大重扫窗口”，因为那会明显改变战斗观感。
# 10. 换句话说：允许短时间记忆，不允许长时间固执追旧目标。
# 11. 性能收益主要来自少做重复空间查询，而不是改变命中、移动或受击规则。
func pick_target_for_unit(
	runtime_port: Node,
	unit: Node,
	allow_target_refresh: bool,
	prioritize_targets_in_attack_range: bool,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary,
	spatial_hash,
	team_alive_cache: Dictionary,
	attack_range_target_memory: Dictionary,
	attack_range_target_frame: Dictionary,
	target_memory: Dictionary,
	target_refresh_frame: Dictionary,
	logic_frame: int,
	target_rescan_interval_frames: int,
	target_query_radius: float,
	target_query_scratch: Array[int]
) -> Node:
	var self_team: int = int(unit.get("team_id"))
	var enemy_team: int = 2 if self_team == 1 else 1
	var taunt_target: Node = _pick_taunt_forced_target(runtime_port, unit, enemy_team, unit_by_id)
	if taunt_target != null:
		# 嘲讽命中时直接覆盖缓存，确保控制类效果优先级最高。
		_remember_target(unit, taunt_target, target_memory, target_refresh_frame, logic_frame)
		return taunt_target

	var cached_target: Node = _resolve_persisted_target(
		runtime_port,
		unit,
		enemy_team,
		unit_by_id,
		target_memory,
		target_refresh_frame
	)
	if cached_target != null:
		if not allow_target_refresh:
			return cached_target
		# 旧目标仍有效时先沿用，只有窗口到点才允许为“更优目标”付出一次完整重扫成本。
		if not _should_refresh_target(
			unit,
			target_refresh_frame,
			logic_frame,
			target_rescan_interval_frames
		):
			return cached_target

	if prioritize_targets_in_attack_range:
		# 射程内目标仍然优先；这里省掉的是“每帧重扫”，不是这条规则本身。
		var in_range_target: Node = pick_target_in_attack_range(
			runtime_port,
			unit,
			enemy_team,
			spatial_hash,
			unit_by_id,
			attack_range_target_memory,
			attack_range_target_frame,
			target_memory,
			target_refresh_frame,
			logic_frame,
			target_rescan_interval_frames,
			target_query_radius,
			0.0,
			target_query_scratch
		)
		if in_range_target != null:
			return in_range_target

	var focus_target: Node = _resolve_focus_target(
		runtime_port,
		self_team,
		enemy_team,
		group_focus_target_id,
		unit_by_id
	)
	if focus_target != null:
		# 队伍焦点依然是命中的第二优先级，只是复用了缓存写回逻辑。
		_remember_target(unit, focus_target, target_memory, target_refresh_frame, logic_frame)
		return focus_target

	var best_target: Node = _pick_nearest_target_from_spatial_hash(
		runtime_port,
		unit,
		enemy_team,
		spatial_hash,
		unit_by_id,
		target_query_radius,
		target_query_scratch
	)
	if best_target == null:
		best_target = _pick_nearest_target_from_team_cache(
			runtime_port,
			unit,
			enemy_team,
			team_alive_cache
		)
	if best_target != null:
		# 兜底最近敌人一旦选定，也会写回缓存，避免下一帧再做同样的全量比较。
		_remember_target(unit, best_target, target_memory, target_refresh_frame, logic_frame)
		return best_target

	if cached_target != null:
		_mark_target_refresh(unit, target_refresh_frame, logic_frame)
		return cached_target
	_clear_persisted_target(unit, target_memory, target_refresh_frame)
	return null


# 射程内选敌优先走近邻格，其次才用空间索引粗筛再走 hex 距离精筛。
func pick_target_in_attack_range(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	spatial_hash,
	unit_by_id: Dictionary,
	attack_range_target_memory: Dictionary,
	attack_range_target_frame: Dictionary,
	target_memory: Dictionary,
	target_refresh_frame: Dictionary,
	logic_frame: int,
	target_rescan_interval_frames: int,
	target_query_radius: float,
	hex_size: float,
	target_query_scratch: Array[int]
) -> Node:
	var cached_in_range_target: Node = _resolve_attack_range_cached_target(
		runtime_port,
		unit,
		enemy_team,
		unit_by_id,
		attack_range_target_memory,
		attack_range_target_frame,
		logic_frame
	)
	if cached_in_range_target != null or _has_attack_range_cached_result(
		unit,
		attack_range_target_frame,
		logic_frame
	):
		return cached_in_range_target

	var cached_target: Node = _resolve_persisted_target(
		runtime_port,
		unit,
		enemy_team,
		unit_by_id,
		target_memory,
		target_refresh_frame
	)
	# 已缓存目标若仍在射程内，就直接复用，不再重复扫邻格或空间索引。
	if cached_target != null and is_target_in_attack_range(runtime_port, unit, cached_target):
		_store_attack_range_cached_result(
			unit,
			cached_target,
			attack_range_target_memory,
			attack_range_target_frame,
			logic_frame
		)
		return cached_target
	if (
		cached_target != null
		and not _should_refresh_target(
			unit,
			target_refresh_frame,
			logic_frame,
			target_rescan_interval_frames
		)
	):
		return null

	var combat: Node = runtime_port._get_combat(unit)
	if combat == null:
		return null
	var self_cell: Vector2i = runtime_port._get_unit_cell(unit)
	if self_cell.x < 0:
		return null

	var range_cells: int = maxi(int(combat.get_attack_range_cells()), 1)
	# 近战优先邻格反查；这条路径最便宜，也最接近原始规则口径。
	if range_cells == 1:
		for neighbor in runtime_port._neighbors_of(self_cell):
			var occupant: Node = get_occupant_unit_at_cell(
				runtime_port,
				neighbor,
				runtime_port.get("_cell_occupancy"),
				unit_by_id
			)
			if occupant != null and int(occupant.get("team_id")) == enemy_team:
				_store_attack_range_cached_result(
					unit,
					occupant,
					attack_range_target_memory,
					attack_range_target_frame,
					logic_frame
				)
				_remember_target(unit, occupant, target_memory, target_refresh_frame, logic_frame)
				return occupant
		_store_attack_range_cached_result(
			unit,
			null,
			attack_range_target_memory,
			attack_range_target_frame,
			logic_frame
		)
		_mark_target_refresh(unit, target_refresh_frame, logic_frame)
		return null

	var cell_occupancy_value: Variant = runtime_port.get("_cell_occupancy")
	if range_cells <= 4 and cell_occupancy_value is Dictionary:
		var occupancy_target: Node = _pick_target_in_attack_range_from_occupancy(
			runtime_port,
			unit,
			enemy_team,
			self_cell,
			range_cells,
			cell_occupancy_value as Dictionary,
			unit_by_id
		)
		if occupancy_target != null:
			_store_attack_range_cached_result(
				unit,
				occupancy_target,
				attack_range_target_memory,
				attack_range_target_frame,
				logic_frame
			)
			_remember_target(unit, occupancy_target, target_memory, target_refresh_frame, logic_frame)
			return occupancy_target
		_store_attack_range_cached_result(
			unit,
			null,
			attack_range_target_memory,
			attack_range_target_frame,
			logic_frame
		)
		_mark_target_refresh(unit, target_refresh_frame, logic_frame)
		return null

	var query_radius: float = target_query_radius
	if hex_size > 0.0:
		query_radius = maxf(float(range_cells) * hex_size * 1.35, hex_size * 1.2)

	var best_target: Node = null
	var best_hex_dist: int = 1 << 30
	var best_world_dist_sq: float = INF
	var candidate_ids: Array[int] = _query_radius_ids(
		spatial_hash,
		unit.position,
		query_radius,
		target_query_scratch
	)
	for candidate_id in candidate_ids:
		if not unit_by_id.has(candidate_id):
			continue
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
	if best_target != null:
		_store_attack_range_cached_result(
			unit,
			best_target,
			attack_range_target_memory,
			attack_range_target_frame,
			logic_frame
		)
		_remember_target(unit, best_target, target_memory, target_refresh_frame, logic_frame)
		return best_target
	_store_attack_range_cached_result(
		unit,
		null,
		attack_range_target_memory,
		attack_range_target_frame,
		logic_frame
	)
	_mark_target_refresh(unit, target_refresh_frame, logic_frame)
	return null


func _pick_target_in_attack_range_from_occupancy(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	self_cell: Vector2i,
	range_cells: int,
	cell_occupancy: Dictionary,
	unit_by_id: Dictionary
) -> Node:
	var best_target: Node = null
	var best_cell_dist: int = 1 << 30
	var best_world_dist_sq: float = INF
	for dq in range(-range_cells, range_cells + 1):
		var min_dr: int = maxi(-range_cells, -dq - range_cells)
		var max_dr: int = mini(range_cells, -dq + range_cells)
		for dr in range(min_dr, max_dr + 1):
			if dq == 0 and dr == 0:
				continue
			var candidate_cell: Vector2i = Vector2i(self_cell.x + dq, self_cell.y + dr)
			var occupant: Node = get_occupant_unit_at_cell(
				runtime_port,
				candidate_cell,
				cell_occupancy,
				unit_by_id
			)
			if occupant == null or int(occupant.get("team_id")) != enemy_team:
				continue
			var cell_dist: int = _hex_cell_distance(self_cell, candidate_cell)
			if cell_dist > range_cells:
				continue
			var world_dist_sq: float = unit.position.distance_squared_to(occupant.position)
			if cell_dist < best_cell_dist or (cell_dist == best_cell_dist and world_dist_sq < best_world_dist_sq):
				best_cell_dist = cell_dist
				best_world_dist_sq = world_dist_sq
				best_target = occupant
	return best_target


func _hex_cell_distance(a: Vector2i, b: Vector2i) -> int:
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2


# 解析当前队伍的集火目标；只有目标仍存活且阵营正确时才允许沿用。
func _resolve_focus_target(
	runtime_port: Node,
	self_team: int,
	enemy_team: int,
	group_focus_target_id: Dictionary,
	unit_by_id: Dictionary
) -> Node:
	var focus_id: int = int(group_focus_target_id.get(self_team, -1))
	if focus_id <= 0 or not unit_by_id.has(focus_id):
		return null
	var focus_target: Node = unit_by_id[focus_id]
	if not runtime_port._is_live_unit(focus_target):
		return null
	if not runtime_port._is_unit_alive(focus_target):
		return null
	if int(focus_target.get("team_id")) != enemy_team:
		return null
	return focus_target


# 近邻格与队伍焦点都未命中时，才退回空间索引做最近敌人搜索。
func _pick_nearest_target_from_spatial_hash(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	spatial_hash,
	unit_by_id: Dictionary,
	target_query_radius: float,
	target_query_scratch: Array[int]
) -> Node:
	var best_target: Node = null
	var best_dist_sq: float = INF
	var candidate_ids: Array[int] = _query_radius_ids(
		spatial_hash,
		unit.position,
		target_query_radius,
		target_query_scratch
	)
	for candidate_id in candidate_ids:
		if not unit_by_id.has(candidate_id):
			continue
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
	return best_target


func _query_radius_ids(
	spatial_hash,
	center: Vector2,
	radius: float,
	output: Array[int]
) -> Array[int]:
	spatial_hash.query_radius_into(center, radius, output)
	return output


# 整队兜底只负责在极端情况下给出一个仍然有效的最近敌人。
func _pick_nearest_target_from_team_cache(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	team_alive_cache: Dictionary
) -> Node:
	var best_target: Node = null
	var best_dist_sq: float = INF
	for enemy in team_alive_cache.get(enemy_team, []):
		if not runtime_port._is_live_unit(enemy):
			continue
		var enemy_node: Node2D = enemy as Node2D
		if enemy_node == null:
			continue
		var fallback_dist_sq: float = unit.position.distance_squared_to(enemy_node.position)
		if fallback_dist_sq < best_dist_sq:
			best_dist_sq = fallback_dist_sq
			best_target = enemy_node
	return best_target


# 持久目标命中后仍要重新过存活、阵营和 registry 校验，避免脏引用。
func _resolve_persisted_target(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	unit_by_id: Dictionary,
	target_memory: Dictionary,
	target_refresh_frame: Dictionary
) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var unit_id: int = unit.get_instance_id()
	if not target_memory.has(unit_id):
		return null
	var target_id: int = int(target_memory.get(unit_id, -1))
	if target_id <= 0 or not unit_by_id.has(target_id):
		_clear_persisted_target(unit, target_memory, target_refresh_frame)
		return null
	var target: Node = unit_by_id[target_id]
	if not runtime_port._is_live_unit(target):
		_clear_persisted_target(unit, target_memory, target_refresh_frame)
		return null
	if not runtime_port._is_unit_alive(target):
		_clear_persisted_target(unit, target_memory, target_refresh_frame)
		return null
	if int(target.get("team_id")) != enemy_team:
		_clear_persisted_target(unit, target_memory, target_refresh_frame)
		return null
	return target


# 固定频率重扫只控制“何时允许重新找更优目标”，不阻止失效目标立刻重选。
func _should_refresh_target(
	unit: Node,
	target_refresh_frame: Dictionary,
	logic_frame: int,
	target_rescan_interval_frames: int
) -> bool:
	# 这里记录的是“上次完整选敌帧”，不是“上次攻击成功帧”。
	# 只要窗口到了，就重新允许比较更优目标；没到就继续追当前有效目标。
	if unit == null or not is_instance_valid(unit):
		return true
	if target_rescan_interval_frames <= 1:
		return true
	var unit_id: int = unit.get_instance_id()
	if not target_refresh_frame.has(unit_id):
		return true
	var last_refresh_frame: int = int(target_refresh_frame.get(unit_id, -target_rescan_interval_frames))
	return (logic_frame - last_refresh_frame) >= target_rescan_interval_frames


# 记住本单位当前选择的目标，并把本次重扫帧一起写回。
func _remember_target(
	unit: Node,
	target: Node,
	target_memory: Dictionary,
	target_refresh_frame: Dictionary,
	logic_frame: int
) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if target == null or not is_instance_valid(target):
		_clear_persisted_target(unit, target_memory, target_refresh_frame)
		return
	var unit_id: int = unit.get_instance_id()
	target_memory[unit_id] = target.get_instance_id()
	target_refresh_frame[unit_id] = logic_frame


# 仅记录“本帧已经做过一次重扫”，避免短时间重复查询。
func _mark_target_refresh(unit: Node, target_refresh_frame: Dictionary, logic_frame: int) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	target_refresh_frame[unit.get_instance_id()] = logic_frame


# 清空攻击者自己的持久目标，不顺手扫别人，避免热路径扩散成全表遍历。
func _clear_persisted_target(
	unit: Node,
	target_memory: Dictionary,
	target_refresh_frame: Dictionary
) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var unit_id: int = unit.get_instance_id()
	target_memory.erase(unit_id)
	target_refresh_frame.erase(unit_id)


func _resolve_attack_range_cached_target(
	runtime_port: Node,
	unit: Node,
	enemy_team: int,
	unit_by_id: Dictionary,
	attack_range_target_memory: Dictionary,
	attack_range_target_frame: Dictionary,
	logic_frame: int
) -> Node:
	if unit == null or not is_instance_valid(unit):
		return null
	var unit_id: int = unit.get_instance_id()
	if int(attack_range_target_frame.get(unit_id, -1)) != logic_frame:
		return null
	var target_id: int = int(attack_range_target_memory.get(unit_id, 0))
	if target_id <= 0:
		return null
	if not unit_by_id.has(target_id):
		attack_range_target_memory[unit_id] = 0
		return null
	var target: Node = unit_by_id[target_id]
	if not runtime_port._is_live_unit(target):
		attack_range_target_memory[unit_id] = 0
		return null
	if not runtime_port._is_unit_alive(target):
		attack_range_target_memory[unit_id] = 0
		return null
	if int(target.get("team_id")) != enemy_team:
		attack_range_target_memory[unit_id] = 0
		return null
	return target


func _has_attack_range_cached_result(
	unit: Node,
	attack_range_target_frame: Dictionary,
	logic_frame: int
) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	return int(attack_range_target_frame.get(unit.get_instance_id(), -1)) == logic_frame


func _store_attack_range_cached_result(
	unit: Node,
	target: Node,
	attack_range_target_memory: Dictionary,
	attack_range_target_frame: Dictionary,
	logic_frame: int
) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var unit_id: int = unit.get_instance_id()
	attack_range_target_frame[unit_id] = logic_frame
	attack_range_target_memory[unit_id] = (
		target.get_instance_id()
		if target != null and is_instance_valid(target)
		else 0
	)


# 占格表反查单位时，会同步过滤失效节点和死亡单位。
func get_occupant_unit_at_cell(
	runtime_port: Node,
	cell: Vector2i,
	cell_occupancy: Dictionary,
	unit_by_id: Dictionary
) -> Node:
	var cell_key: int = int(runtime_port._cell_key_int(cell))
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
