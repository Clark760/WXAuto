extends RefCounted
class_name UnitAugmentBattlefieldEffectRuntime

var _battlefield_query_ids_scratch: Array[int] = []


# 战场级效果要求最小结构完整，尤其是中心格、tick_effects 和来源元数据。
# 这里只负责把配置归一化后塞进运行时数组，不直接执行效果。
func add_battlefield_effect(manager, effect_config: Dictionary, source: Node = null) -> bool:
	if effect_config.is_empty():
		return false
	var center_cell_value: Variant = effect_config.get("center_cell", Vector2i(-1, -1))
	if not (center_cell_value is Vector2i):
		return false
	var center_cell: Vector2i = center_cell_value as Vector2i
	if center_cell.x < 0 or center_cell.y < 0:
		return false

	var tick_effects_value: Variant = effect_config.get("tick_effects", [])
	if not (tick_effects_value is Array) or (tick_effects_value as Array).is_empty():
		return false

	# 来源元数据优先读显式配置，缺失时再从 live source 补齐。
	# 这样测试和运行时都能共用这套入口，不要求外层先把所有字段填满。
	var source_id: int = int(effect_config.get("source_id", -1))
	if source_id <= 0 and source != null and is_instance_valid(source):
		source_id = source.get_instance_id()
	var source_unit_id: String = str(effect_config.get("source_unit_id", "")).strip_edges()
	if source_unit_id.is_empty() and source != null and is_instance_valid(source):
		source_unit_id = str(source.get("unit_id"))
	var source_name: String = str(effect_config.get("source_name", "")).strip_edges()
	if source_name.is_empty() and source != null and is_instance_valid(source):
		source_name = str(source.get("unit_name"))
	var source_team: int = int(effect_config.get("source_team", 0))
	if source_team == 0 and source != null and is_instance_valid(source):
		source_team = int(source.get("team_id"))

	var duration: float = float(effect_config.get("duration", 0.0))
	if duration < 0.0:
		duration = -1.0

	# 运行时条目只保留执行所需的最小快照。
	# 真正的 op 执行仍由 effect runtime gateway 按 tick_request 统一处理。
	manager._battlefield_effects.append({
		"effect_id": str(effect_config.get("effect_id", "battlefield_effect")).strip_edges(),
		"source_id": source_id,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"source_team": source_team,
		"center_cell": center_cell,
		"radius_cells": maxi(int(effect_config.get("radius_cells", 1)), 0),
		"target_mode": str(effect_config.get("target_mode", "enemies")).strip_edges().to_lower(),
		"remaining": duration,
		"tick_interval": maxf(float(effect_config.get("tick_interval", 0.5)), 0.05),
		"tick_accum": 0.0,
		"warning_remaining": maxf(float(effect_config.get("warning_seconds", 0.0)), 0.0),
		"tick_effects": (tick_effects_value as Array).duplicate(true)
	})
	return true


# tick 同时推进单位身上的 buff tick 和战场级 effect tick。
# 返回值继续只暴露 `changed_unit_ids` 与 `tick_requests`，不改变现有 battle runtime 契约。
func tick(manager, delta: float, context: Dictionary = {}) -> Dictionary:
	var changed_units: Dictionary = {}
	var tick_requests: Array[Dictionary] = []

	_tick_unit_buffs(manager, delta, context, changed_units, tick_requests)
	_tick_battlefield_effects(manager, delta, context, tick_requests)

	# 对外仍只暴露变更过的单位 id 列表。
	# battle runtime 不需要知道内部是 buff tick 还是战场 effect tick 导致的变化。
	var changed_unit_ids: Array[int] = []
	for changed_id in changed_units.keys():
		changed_unit_ids.append(int(changed_id))
	return {
		"changed_unit_ids": changed_unit_ids,
		"tick_requests": tick_requests
	}


# 单位 buff tick 负责推进 remaining、tick_accum 和过期移除。
# 每个桶都独立保留自己的 source 元数据，保证 DOT 和 aura 桶不会串线。
func _tick_unit_buffs(
	manager,
	delta: float,
	context: Dictionary,
	changed_units: Dictionary,
	tick_requests: Array[Dictionary]
) -> void:
	for key in manager._active_by_unit.keys():
		var unit_iid: int = int(key)
		var entries: Array = manager._active_by_unit.get(unit_iid, [])
		var next_entries: Array = []
		var structure_changed: bool = false

		# 每个单位的 buff 桶独立推进 remaining 和 tick_accum。
		# 这里不合并同 buff_id 项，避免 application_key/source_id 桶被冲平。
		for entry_value in entries:
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = entry_value as Dictionary
			var buff_data: Dictionary = entry.get("data", {})
			var previous_remaining: float = float(entry.get("remaining", 0.0))
			var remaining: float = previous_remaining
			if remaining >= 0.0:
				remaining -= delta
				entry["remaining"] = remaining

			var tick_interval: float = float(buff_data.get("tick_interval", 0.0))
			var tick_effects_value: Variant = buff_data.get("tick_effects", [])
			if tick_interval > 0.0 and tick_effects_value is Array and not (tick_effects_value as Array).is_empty():
				var tick_accum: float = float(entry.get("tick_accum", 0.0)) + delta
				while tick_accum >= tick_interval:
					tick_accum -= tick_interval
					# 这里只生成统一的 tick request。
					# 具体是伤害、治疗还是上状态，仍交给效果执行入口判断。
					tick_requests.append({
						"source_id": int(entry.get("source_id", -1)),
						"source_unit_id": str(entry.get("source_unit_id", "")).strip_edges(),
						"source_name": str(entry.get("source_name", "")).strip_edges(),
						"source_team": int(entry.get("source_team", 0)),
						"target_id": unit_iid,
						"buff_id": str(entry.get("buff_id", "")).strip_edges(),
						"effects": (tick_effects_value as Array).duplicate(true)
					})
				entry["tick_accum"] = tick_accum

			var expired: bool = previous_remaining >= 0.0 and remaining <= 0.0
			if expired:
				# 过期时先发移除事件，再真正把条目摘掉。
				# 这样 trigger 和日志仍能拿到完整的 buff/source 快照。
				var expired_buff_id: String = str(entry.get("buff_id", "")).strip_edges()
				if not expired_buff_id.is_empty():
					manager._on_buff_entry_removed(unit_iid, entry, "expired")
					manager._emit_buff_removed(unit_iid, expired_buff_id, int(entry.get("source_id", -1)), "expired")
				changed_units[unit_iid] = true
				structure_changed = true
				continue

			next_entries.append(entry)

		manager._active_by_unit[unit_iid] = next_entries
		var unit_node: Node = manager._find_unit_in_context(unit_iid, context)
		if structure_changed and unit_node != null and is_instance_valid(unit_node):
			# 只要节点还在上下文里，就同步回最新的 buff/debuff 展示 meta。
			# 这样 UI 和条件查询不需要等下一帧再读到状态变化。
			manager._sync_unit_runtime_meta(unit_node, next_entries)
		if structure_changed:
			changed_units[unit_iid] = true
		if next_entries.is_empty():
			manager._active_by_unit.erase(unit_iid)
			if unit_node != null and is_instance_valid(unit_node):
				manager._clear_unit_runtime_meta(unit_node)


# 战场级效果只负责在命中目标时生成统一的 tick_requests。
# 真正的效果执行仍由 effect runtime gateway 按 `event_type = battlefield_tick` 继续走原链路。
func _tick_battlefield_effects(
	manager,
	delta: float,
	context: Dictionary,
	tick_requests: Array[Dictionary]
) -> void:
	var next_battlefield_effects: Array[Dictionary] = []
	for effect_value in manager._battlefield_effects:
		if not (effect_value is Dictionary):
			continue
		var effect_entry: Dictionary = effect_value as Dictionary
		var previous_remaining: float = float(effect_entry.get("remaining", 0.0))
		var remaining: float = previous_remaining
		if remaining >= 0.0:
			remaining -= delta
			effect_entry["remaining"] = remaining

		var warning_remaining: float = float(effect_entry.get("warning_remaining", 0.0))
		if warning_remaining > 0.0:
			warning_remaining = maxf(warning_remaining - delta, 0.0)
			effect_entry["warning_remaining"] = warning_remaining

		var expired: bool = previous_remaining >= 0.0 and remaining <= 0.0
		if expired:
			continue

		# warning 阶段只倒计时，不真正出伤害。
		# 等警示时间结束后，才允许按 tick_interval 批量生成命中请求。
		if warning_remaining <= 0.0:
			var tick_interval: float = maxf(float(effect_entry.get("tick_interval", 0.5)), 0.05)
			var tick_accum: float = float(effect_entry.get("tick_accum", 0.0)) + delta
			while tick_accum >= tick_interval:
				tick_accum -= tick_interval
				var target_ids: Array[int] = _collect_battlefield_target_ids(manager, effect_entry, context)
				var tick_effects: Array = effect_entry.get("tick_effects", [])
				for target_iid in target_ids:
					# event_type 继续标成 battlefield_tick。
					# 旧 battle runtime 和 contract test 仍靠这个字段识别地形 AoE 来源。
					tick_requests.append({
						"source_id": int(effect_entry.get("source_id", -1)),
						"source_unit_id": str(effect_entry.get("source_unit_id", "")).strip_edges(),
						"source_name": str(effect_entry.get("source_name", "")).strip_edges(),
						"source_team": int(effect_entry.get("source_team", 0)),
						"target_id": int(target_iid),
						"buff_id": str(effect_entry.get("effect_id", "battlefield_effect")).strip_edges(),
						"effects": tick_effects.duplicate(true),
						"event_type": "battlefield_tick"
					})
			effect_entry["tick_accum"] = tick_accum

		# 没过期的 effect 都继续留在运行时数组。
		# warning 倒计时和 tick_accum 都会一起随条目被保留下来。
		next_battlefield_effects.append(effect_entry)
	manager._battlefield_effects = next_battlefield_effects


# 目标筛选按中心格、半径和 target_mode 做最小判定。
# 只要 combat manager 或 hex grid 能给出格子位置，就保持原先的地形 AoE 语义。
func _collect_battlefield_target_ids(manager, effect_entry: Dictionary, context: Dictionary) -> Array[int]:
	var output: Array[int] = []
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return output
	var center_value: Variant = effect_entry.get("center_cell", Vector2i(-1, -1))
	if not (center_value is Vector2i):
		return output

	# 中心格和半径共同定义这次地形 AoE 的命中圈。
	# target_mode 只在圈内单位上继续细分 ally/enemy/allies 过滤。
	var center_cell: Vector2i = center_value as Vector2i
	var radius_cells: int = maxi(int(effect_entry.get("radius_cells", 0)), 0)
	var source_team: int = int(effect_entry.get("source_team", 0))
	var target_mode: String = str(effect_entry.get("target_mode", "enemies")).strip_edges().to_lower()
	var combat_manager: Variant = context.get("combat_manager", null)
	var hex_grid: Variant = context.get("hex_grid", null)
	if _append_spatial_battlefield_targets(
		manager,
		combat_manager,
		hex_grid,
		center_cell,
		radius_cells,
		source_team,
		target_mode,
		output
	):
		return output

	for unit_value in (all_units_value as Array):
		# 这里先过活体、队伍和空间三道门。
		# 只有全部命中后，才把 target_id 交给上层统一执行 tick_effects。
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if not manager._is_unit_alive_node(unit):
			continue
		var team_id: int = int(unit.get("team_id"))
		if target_mode == "allies" and source_team != 0 and team_id != source_team:
			continue
		if target_mode == "enemies" and source_team != 0 and team_id == source_team:
			continue
		var unit_cell: Vector2i = _resolve_unit_cell(unit, combat_manager, hex_grid)
		if unit_cell.x < 0:
			continue
		if _hex_distance_cells(center_cell, unit_cell, hex_grid) > radius_cells:
			continue
		output.append(unit.get_instance_id())
	return output


func _append_spatial_battlefield_targets(
	manager,
	combat_manager: Variant,
	hex_grid: Variant,
	center_cell: Vector2i,
	radius_cells: int,
	source_team: int,
	target_mode: String,
	output: Array[int]
) -> bool:
	if combat_manager == null or not is_instance_valid(combat_manager):
		return false
	if hex_grid == null or not is_instance_valid(hex_grid):
		return false
	if not hex_grid.has_method("axial_to_world"):
		return false

	var spatial_hash: Variant = combat_manager.get("_spatial_hash")
	var unit_lookup_value: Variant = combat_manager.get("_unit_by_instance_id")
	if spatial_hash == null or not is_instance_valid(spatial_hash):
		return false
	if not (unit_lookup_value is Dictionary):
		return false

	var center_world: Vector2 = hex_grid.axial_to_world(center_cell)
	var query_radius: float = _build_battlefield_query_radius(radius_cells, hex_grid)
	var unit_lookup: Dictionary = unit_lookup_value as Dictionary
	spatial_hash.query_radius_into(center_world, query_radius, _battlefield_query_ids_scratch)

	for candidate_id in _battlefield_query_ids_scratch:
		if not unit_lookup.has(candidate_id):
			continue
		var unit: Node = unit_lookup[candidate_id]
		if unit == null or not is_instance_valid(unit):
			continue
		if not manager._is_unit_alive_node(unit):
			continue
		var team_id: int = int(unit.get("team_id"))
		if target_mode == "allies" and source_team != 0 and team_id != source_team:
			continue
		if target_mode == "enemies" and source_team != 0 and team_id == source_team:
			continue
		var unit_cell: Vector2i = _resolve_unit_cell(unit, combat_manager, hex_grid)
		if unit_cell.x < 0:
			continue
		if _hex_distance_cells(center_cell, unit_cell, hex_grid) > radius_cells:
			continue
		output.append(unit.get_instance_id())
	return true


func _build_battlefield_query_radius(radius_cells: int, hex_grid: Variant) -> float:
	var hex_size: float = 26.0
	if hex_grid != null and is_instance_valid(hex_grid):
		hex_size = float(hex_grid.get("hex_size"))
	return maxf(float(radius_cells) + 1.0, 1.0) * maxf(hex_size, 1.0) * 1.2


# 单位格子优先读 combat manager 的运行时映射。
# 只有 manager 缺席时，才使用 hex grid 从 world position 推算。
func _resolve_unit_cell(unit: Node, combat_manager: Variant, hex_grid: Variant) -> Vector2i:
	# 目标格子优先读 combat manager 当前占位。
	# 只有运行时映射缺席时，才退回 world_to_axial 的空间推算。
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of"):
		var cell_value: Variant = combat_manager.get_unit_cell_of(unit)
		if cell_value is Vector2i:
			return cell_value as Vector2i
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
		var node2d: Node2D = unit as Node2D
		if node2d != null:
			return hex_grid.world_to_axial(node2d.position)
	return Vector2i(-1, -1)


# 距离优先复用 grid 原生 helper。
# 没有 helper 时退回 axial distance 公式，避免测试和运行时语义分叉。
func _hex_distance_cells(a: Vector2i, b: Vector2i, hex_grid: Variant) -> int:
	# grid helper 存在时优先复用原生实现。
	# 否则退回标准 axial distance，保证测试和运行时的命中半径一致。
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.get_cell_distance(a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)
