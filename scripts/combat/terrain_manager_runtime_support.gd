extends RefCounted


# 负责 TerrainManager 的目标收集、phase 事件和外部效果执行。
# 这里集中处理 `context`、`source`、`target` 这类运行时对象边界。
func apply_terrain_tick(
	manager,
	terrain: Dictionary,
	targets: Array[Node],
	context: Dictionary
) -> Array[Dictionary]:
	return execute_terrain_phase_effects(manager, terrain, targets, "tick", context)


# enter 和 exit 的判断基于上一帧 occupied_iids 与当前命中快照做差集。
# `current_targets` 必须是本帧完整命中集合，不能传增量结果。
func apply_terrain_enter_exit_effects(
	manager,
	terrain: Dictionary,
	current_targets: Array[Node],
	context: Dictionary
) -> Array[Dictionary]:
	var phase_events: Array[Dictionary] = []
	var previous_map: Dictionary = {}
	var previous_value: Variant = terrain.get("occupied_iids", {}) # 上一帧命中快照。
	if previous_value is Dictionary:
		previous_map = (previous_value as Dictionary).duplicate(true)

	var current_map: Dictionary = manager._build_target_iid_map(current_targets) # 当前帧命中快照。
	var enter_targets: Array[Node] = [] # 新命中的单位只触发 enter，不补 tick。
	for target in current_targets:
		if target == null or not is_instance_valid(target):
			continue
		var iid: int = target.get_instance_id()
		if previous_map.has(iid):
			continue
		enter_targets.append(target)

	var exit_targets: Array[Node] = [] # 退出集合只来自上一帧命中、当前帧未命中的单位。
	for iid_value in previous_map.keys():
		var iid: int = int(iid_value)
		if current_map.has(iid):
			continue
		var unit: Node = resolve_unit_by_instance_id(manager, iid, context) # exit 只能回查仍然存活的单位。
		if unit == null or not is_instance_valid(unit):
			continue
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null or not bool(combat.get("is_alive")):
			continue
		exit_targets.append(unit)

	# 当前帧统一先结算 enter，再结算 exit，避免桥接层看到漂移顺序。
	phase_events.append_array(
		execute_terrain_phase_effects(manager, terrain, enter_targets, "enter", context)
	)
	phase_events.append_array(
		execute_terrain_phase_effects(manager, terrain, exit_targets, "exit", context)
	)
	return phase_events


# 所有地形 phase 都统一走 external effects，确保 telemetry 与 trigger 口径一致。
# `context.unit_augment_manager` 是唯一允许执行外部效果的入口。
func execute_terrain_phase_effects(
	manager,
	terrain: Dictionary,
	targets: Array[Node],
	phase: String,
	context: Dictionary
) -> Array[Dictionary]:
	var phase_events: Array[Dictionary] = []
	if targets.is_empty():
		if phase == "expire":
			# 过期事件即使没有 target，也要保留一条 phase event 给回放层。
			phase_events.append(build_terrain_phase_event(manager, terrain, phase, null, context))
		return phase_events

	for target in targets:
		if target == null or not is_instance_valid(target):
			continue
		# phase event 先落地，后续外部效果失败时回放层仍能看到触发记录。
		phase_events.append(build_terrain_phase_event(manager, terrain, phase, target, context))

	# effects 为空时只返回 phase event，不额外触发外部执行链。
	var effects: Array[Dictionary] = manager._get_terrain_phase_effects(terrain, phase)
	if effects.is_empty():
		return phase_events

	# unit_augment_manager 是唯一执行口，缺失时保持事件存在但不补效果。
	var unit_augment_manager: Node = context.get("unit_augment_manager", null)
	if unit_augment_manager == null or not is_instance_valid(unit_augment_manager):
		return phase_events
	if not unit_augment_manager.has_method("execute_external_effects"):
		return phase_events

	var source_node: Node = resolve_source_node(manager, terrain, context)
	var source_fallback: Dictionary = build_source_fallback_from_terrain(terrain) # source 失效后继续补归因字段。
	# extra_fields 只放稳定归因字段，避免把每目标瞬时状态塞进公共 telemetry。
	var extra_fields: Dictionary = {
		"terrain_id": str(terrain.get("terrain_id", "")),
		"terrain_def_id": str(terrain.get("terrain_def_id", "")),
		"terrain_type": str(terrain.get("terrain_type", "")),
		"terrain_phase": phase,
		"is_environment": true
	}
	if source_node == null and not source_fallback.is_empty():
		# 删除 source 节点后，telemetry 仍然需要完整的来源快照。
		extra_fields["source_id"] = int(source_fallback.get("source_id", -1))
		extra_fields["source_unit_id"] = str(source_fallback.get("source_unit_id", ""))
		extra_fields["source_name"] = str(source_fallback.get("source_name", ""))
		extra_fields["source_team"] = int(source_fallback.get("source_team", 0))

	# terrain_phase 会同时写进 origin 和 trigger，方便下游统一按 phase 分类统计。
	var origin: String = "terrain_%s" % phase # origin / trigger 统一复用同一口径。
	var augment_api: Variant = unit_augment_manager
	for target in targets:
		if target == null or not is_instance_valid(target):
			continue
		# 每个目标单独复制 context，避免下游 effect 回写污染同轮其他目标。
		var effect_context: Dictionary = context.duplicate(false) # 每个目标单独带一份 phase 上下文。
		effect_context["terrain"] = terrain
		effect_context["terrain_phase"] = phase
		effect_context["is_environment"] = true
		augment_api.execute_external_effects(source_node, target, effects, effect_context, {
			"origin": origin,
			"trigger": origin,
			"extra_fields": extra_fields
		})
	return phase_events


# phase 事件里保留 terrain/source/target 快照，供战斗桥接和回放直接消费。
# 这里产出的结构会直接进入 CombatTerrainService 的 signal。
func build_terrain_phase_event(
	manager,
	terrain: Dictionary,
	phase: String,
	target: Node,
	context: Dictionary
) -> Dictionary:
	# 事件结构保持扁平字段，桥接层不用再深挖 terrain/source 嵌套字典。
	var event: Dictionary = {
		"phase": phase,
		"terrain": terrain.duplicate(true), # 回放层不应直接拿到内部实例引用。
		"terrain_id": str(terrain.get("terrain_id", "")),
		"terrain_def_id": str(terrain.get("terrain_def_id", "")),
		"terrain_type": str(terrain.get("terrain_type", "")),
		"terrain_tags": manager._normalize_tags(terrain.get("tags", []))
	}

	var source_node: Node = resolve_source_node(manager, terrain, context)
	if source_node != null and is_instance_valid(source_node):
		event["source"] = source_node # 节点还活着时优先保留真实引用。
		event["source_id"] = source_node.get_instance_id()
		event["source_team"] = int(source_node.get("team_id"))
	else:
		# 来源节点失效时只回退到快照字段，不伪造一个可访问的 source 节点。
		var source_fallback: Dictionary = build_source_fallback_from_terrain(terrain)
		event["source_id"] = int(source_fallback.get("source_id", -1))
		event["source_team"] = int(source_fallback.get("source_team", 0))
		event["source_unit_id"] = str(source_fallback.get("source_unit_id", ""))
		event["source_name"] = str(source_fallback.get("source_name", ""))

	if target != null and is_instance_valid(target):
		event["target"] = target
		event["target_id"] = target.get_instance_id()
		event["target_team"] = int(target.get("team_id"))
	else:
		# expire 或者空目标场景也要维持稳定字段结构。
		event["target"] = null
		event["target_id"] = -1
		event["target_team"] = 0
	return event


# 目标采样仍以当前战场存活单位为准，不从地形缓存反推单位列表。
# `context.combat_manager` 优先提供占格；缺失时才回退世界坐标。
func collect_targets_in_terrain(manager, terrain: Dictionary, context: Dictionary) -> Array[Node]:
	var output: Array[Node] = []
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return output

	var target_mode: String = str(terrain.get("target_mode", manager.DEFAULT_TARGET_MODE)).strip_edges().to_lower()
	if target_mode == "none":
		return output

	var hex_grid: Node = context.get("hex_grid", null)
	var area_cells: Array[Vector2i] = manager._grid_support.get_effective_cells_for_terrain(manager, terrain, hex_grid)
	if area_cells.is_empty():
		return output

	var area_map: Dictionary = {} # 命中判定先转成 key map，避免每个单位重复扫数组。
	for cell in area_cells:
		area_map[manager._cell_key_int(cell)] = true

	var combat_manager: Node = context.get("combat_manager", null)
	var combat_api: Variant = combat_manager
	var hex_grid_api: Variant = hex_grid
	var source_team: int = int(terrain.get("source_team", 0)) # source_team=0 时不做敌我过滤。
	for unit_value in (all_units_value as Array):
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null or not bool(combat.get("is_alive")):
			continue

		# source_team=0 代表环境来源，allies / enemies 都不做阵营裁剪。
		var team_id: int = int(unit.get("team_id"))
		if target_mode == "allies" and source_team != 0 and team_id != source_team:
			continue
		if target_mode == "enemies" and source_team != 0 and team_id == source_team:
			continue

		var unit_cell: Vector2i = Vector2i(-1, -1)
		if combat_manager != null and combat_manager.has_method("get_unit_cell_of"):
			var cell_value: Variant = combat_api.get_unit_cell_of(unit) # 占格缓存比世界坐标更可靠。
			if cell_value is Vector2i:
				unit_cell = cell_value as Vector2i
		if unit_cell.x < 0 \
		and hex_grid != null \
		and is_instance_valid(hex_grid) \
		and hex_grid.has_method("world_to_axial"):
			# 只有占格未知时，才退回到世界坐标反推格子。
			var node2d: Node2D = unit as Node2D
			if node2d != null:
				unit_cell = manager._grid_support.to_cell(hex_grid_api.world_to_axial(node2d.position))
		if unit_cell.x < 0:
			continue
		# 只处理真正落在地形覆盖格里的单位，边界外目标不进入 effect 执行。
		if not area_map.has(manager._cell_key_int(unit_cell)):
			continue
		output.append(unit)
	return output


# source_id 反查优先走 CombatManager，其次退回 all_units 线性扫描。
# `context.combat_manager` 是一等数据源，回退扫描只用于兼容测试与回放。
func resolve_source_node(manager, terrain: Dictionary, context: Dictionary) -> Node:
	var source_id: int = int(terrain.get("source_id", -1))
	if source_id <= 0:
		return null

	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager != null and combat_manager.has_method("get_unit_by_instance_id"):
		var combat_api: Variant = combat_manager
		var resolved: Variant = combat_api.get_unit_by_instance_id(source_id)
		if resolved is Node:
			return resolved as Node

	# 回放和单测可能没有 CombatManager 索引，只能从 all_units 兜底扫描。
	var all_units_value: Variant = context.get("all_units", []) # 兼容没有 CombatManager 的测试场景。
	if all_units_value is Array:
		for unit_value in (all_units_value as Array):
			if unit_value is Node and (unit_value as Node).get_instance_id() == source_id:
				return unit_value as Node
	return null


# 地形实例自身保留来源快照，用于施放者节点已失效时继续归因。
# 这里返回的字典会直接写进 extra_fields 和 phase event。
func build_source_fallback_from_terrain(terrain: Dictionary) -> Dictionary:
	var source_id: int = int(terrain.get("source_id", -1))
	var source_unit_id: String = str(terrain.get("source_unit_id", "")).strip_edges()
	var source_name: String = str(terrain.get("source_name", "")).strip_edges()
	var source_team: int = int(terrain.get("source_team", 0))
	# 只有保留了 source_id 时才补默认 unit_id，避免给纯环境来源捏造单位标识。
	if source_unit_id.is_empty() and source_id > 0:
		source_unit_id = "iid_%d" % source_id
	if source_name.is_empty() and not source_unit_id.is_empty():
		source_name = source_unit_id
	if source_id <= 0 and source_unit_id.is_empty() and source_name.is_empty() and source_team == 0:
		return {}
	return {
		"source_id": source_id,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"source_team": source_team
	}


# instance_id 反查统一收口，避免 enter/exit 再各自维护一套回查逻辑。
# 这里要求返回活节点；找不到时直接给 null，调用方自行兜底。
func resolve_unit_by_instance_id(manager, instance_id: int, context: Dictionary) -> Node:
	if instance_id <= 0:
		return null

	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager != null \
	and is_instance_valid(combat_manager) \
	and combat_manager.has_method("get_unit_by_instance_id"):
		var combat_api: Variant = combat_manager
		var result: Variant = combat_api.get_unit_by_instance_id(instance_id)
		if result is Node:
			return result as Node

	# MockCombatManager 可能没有全量索引，enter / exit 需要保留这条线性回查兜底。
	var all_units_value: Variant = context.get("all_units", []) # 测试里的 MockCombatManager 可能不维护全量索引。
	if all_units_value is Array:
		for unit_value in (all_units_value as Array):
			if not (unit_value is Node):
				continue
			var unit: Node = unit_value as Node
			if unit == null or not is_instance_valid(unit):
				continue
			if unit.get_instance_id() == instance_id:
				return unit
	return null
