extends RefCounted
class_name UnitAugmentTargetQueryService

const DEFAULT_HEX_SIZE: float = 26.0

var _spatial_query_ids_scratch: Array[int] = []

# query service 只负责目标与距离查询。
# 调用方拿到结果后再决定副作用，避免查询层回写运行时。


# effect 侧只依赖 `context.all_units` 快照，避免反查场景树。
# 这里会过滤成 `Array[Node]`，让上层 op 不再重复做类型判定。
func get_all_units(context: Dictionary) -> Array[Node]:
	var output: Array[Node] = []
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return output

	for unit_value in (all_units_value as Array):
		if unit_value is Node:
			output.append(unit_value as Node)

	return output


# 范围敌军查询是大量 op 的共用入口，统一写在 query service 里。
# `center/radius_world` 都是世界坐标口径，不能和格子半径直接混用。
func collect_enemy_units_in_radius(
	source: Node,
	center: Vector2,
	radius_world: float,
	context: Dictionary
) -> Array[Node]:
	var enemies: Array[Node] = []
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var state_service: Variant = _get_state_service(context)
	var combat_manager: Node = _get_query_combat_manager(context)
	if combat_manager != null and _append_spatial_units_in_radius(
		combat_manager,
		center,
		radius_world,
		source,
		source_team,
		false,
		false,
		state_service,
		enemies
	):
		return enemies

	for unit in get_all_units(context):
		if _passes_radius_team_filter(
			unit,
			source,
			source_team,
			false,
			false,
			center,
			radius_world,
			state_service
		):
			enemies.append(unit)

	return enemies


# 友军查询保留 `exclude_self` 选项，避免各个 op 重复判断。
# 这里默认只按 team_id 和存活状态筛选，不额外掺入职业或阵位规则。
func collect_ally_units_in_radius(
	source: Node,
	center: Vector2,
	radius_world: float,
	context: Dictionary,
	exclude_self: bool = false
) -> Array[Node]:
	var allies: Array[Node] = []
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var state_service: Variant = _get_state_service(context)
	var combat_manager: Node = _get_query_combat_manager(context)
	if combat_manager != null and _append_spatial_units_in_radius(
		combat_manager,
		center,
		radius_world,
		source,
		source_team,
		true,
		exclude_self,
		state_service,
		allies
	):
		return allies

	for unit in get_all_units(context):
		if _passes_radius_team_filter(
			unit,
			source,
			source_team,
			true,
			exclude_self,
			center,
			radius_world,
			state_service
		):
			allies.append(unit)

	return allies


# 最近敌军用于链伤和自动兜底目标。
# `visited` 用来排除已命中过的单位，保证链式效果不会回跳到旧目标。
func pick_nearest_enemy_unit(
	source: Node,
	context: Dictionary,
	center: Vector2,
	max_radius_world: float,
	visited: Dictionary = {}
) -> Node:
	var best: Node = null
	var best_d2: float = INF
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var max_d2: float = max_radius_world * max_radius_world
	var state_service: Variant = _get_state_service(context)
	var combat_manager: Node = _get_query_combat_manager(context)
	if combat_manager != null:
		var spatial_best: Node = _pick_nearest_enemy_from_spatial_query(
			combat_manager,
			center,
			max_radius_world,
			source_team,
			visited,
			state_service
		)
		if spatial_best != null:
			return spatial_best

	for unit in get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) == source_team:
			continue
		if not _is_unit_alive_in_context(unit, state_service):
			continue

		var unit_id: int = unit.get_instance_id()
		if visited.has(unit_id):
			continue

		var distance_value: float = distance_sq(node_pos(unit), center)
		if max_radius_world < INF and distance_value > max_d2:
			continue
		if distance_value >= best_d2:
			continue

		best_d2 = distance_value
		best = unit

	return best


# 最低血量友军用于定向治疗与净化。
# 这里比较的是血量比例而不是绝对值，避免高血量单位因为数值大而被误判为更“残”。
func find_lowest_hp_ally(source: Node, context: Dictionary) -> Node:
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var best: Node = null
	var best_ratio: float = INF

	for unit in get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) != source_team:
			continue
		if not is_unit_alive(unit):
			continue

		var max_hp: float = maxf(get_combat_value(unit, "max_hp"), 1.0)
		var hp_ratio: float = get_combat_value(unit, "current_hp") / max_hp
		if hp_ratio >= best_ratio:
			continue

		best_ratio = hp_ratio
		best = unit

	return best


# 这个判断同时支持“任意 Debuff”与“指定 Debuff”两种语义。
# 数据来源统一读 `active_debuff_ids`，避免每个效果自己猜 BuffManager 的内部结构。
func target_has_debuff(target: Node, debuff_id: String = "") -> bool:
	if target == null or not is_instance_valid(target):
		return false

	var debuffs_value: Variant = target.get_meta("active_debuff_ids", [])
	if not (debuffs_value is Array):
		return false

	var debuffs: Array = debuffs_value as Array
	if debuff_id.strip_edges().is_empty():
		return not debuffs.is_empty()

	for debuff in debuffs:
		if str(debuff).strip_edges() == debuff_id.strip_edges():
			return true

	return false


# 血量比例被 execute、斩杀和复活相关效果反复使用。
# 返回值固定夹在 `0..1`，避免调用方再各自做边界裁剪。
func get_hp_ratio(unit: Node) -> float:
	if unit == null or not is_instance_valid(unit):
		return 1.0

	var max_hp: float = maxf(get_combat_value(unit, "max_hp"), 1.0)
	var current_hp: float = get_combat_value(unit, "current_hp")
	return clampf(current_hp / max_hp, 0.0, 1.0)


# `scale_stat` 同时支持 `runtime_stats` 与 `combat` 两种来源。
# 这里把取值口径收口，避免不同 scaling op 对同一属性拿到不同来源。
func resolve_scale_stat_value(node: Node, scale_stat: String) -> float:
	match scale_stat:
		"max_hp":
			return get_combat_value(node, "max_hp")
		"current_hp":
			return get_combat_value(node, "current_hp")
		"atk", "iat", "def", "idr":
			if node == null or not is_instance_valid(node):
				return 0.0

			var stats_value: Variant = node.get("runtime_stats")
			if not (stats_value is Dictionary):
				return 0.0

			return float((stats_value as Dictionary).get(scale_stat, 0.0))
		_:
			return 0.0


# 世界坐标距离统一按 hex size 转换，避免各 op 自己乘系数。
# `context.hex_size` 缺失时使用默认值，保证测试环境也能复用同一换算。
func cells_to_world_distance(cells: float, context: Dictionary) -> float:
	var hex_size: float = float(context.get("hex_size", DEFAULT_HEX_SIZE))
	return maxf(cells, 0.0) * maxf(hex_size, 1.0) * 1.2


# 存活判断只认 `UnitCombat`，不依赖外部散落标记。
# 这样 effect 层不会因为某个测试桩没同步 meta 而得到和战斗层不同的结论。
func is_unit_alive(unit: Node) -> bool:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false

	return bool(combat.get("is_alive"))


# combat 组件上的数值读取统一收口，减少调用方空判断。
# `key` 只解释成 combat 字段名，不会回退去读 unit 根节点属性。
func get_combat_value(unit: Node, key: String) -> float:
	if unit == null or not is_instance_valid(unit):
		return 0.0

	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0

	# 所有 combat 字段最终都按 float 暴露，避免调用方再各自做数值标准化。
	return float(combat.get(key))


# effect 层只读 `Node2D` 位置，不让上层再去猜节点类型。
# 非 `Node2D` 节点统一返回零点，保持查询层行为可预期。
func node_pos(node: Node) -> Vector2:
	if node == null or not is_instance_valid(node):
		return Vector2.ZERO

	var node_2d: Node2D = node as Node2D
	if node_2d == null:
		return Vector2.ZERO

	return node_2d.position


# 距离平方用于范围查询，避免不必要的开根号。
# 所有世界坐标半径比较都应该优先走这个入口，保持计算口径一致。
func distance_sq(a: Vector2, b: Vector2) -> float:
	return a.distance_squared_to(b)


func _passes_radius_team_filter(
	unit: Node,
	source: Node,
	source_team: int,
	require_allies: bool,
	exclude_self: bool,
	center: Vector2,
	radius_world: float,
	state_service: Variant = null
) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if exclude_self and unit == source:
		return false
	if unit == source and not require_allies:
		return false
	var team_id: int = int(unit.get("team_id"))
	if require_allies:
		if source_team != 0 and team_id != source_team:
			return false
	else:
		if source_team != 0 and team_id == source_team:
			return false
	if not _is_unit_alive_in_context(unit, state_service):
		return false
	return distance_sq(node_pos(unit), center) <= radius_world * radius_world


func _get_query_combat_manager(context: Dictionary) -> Node:
	var combat_manager: Variant = context.get("combat_manager", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return null
	return combat_manager as Node


func _append_spatial_units_in_radius(
	combat_manager: Node,
	center: Vector2,
	radius_world: float,
	source: Node,
	source_team: int,
	require_allies: bool,
	exclude_self: bool,
	state_service: Variant,
	output: Array[Node]
) -> bool:
	var spatial_hash: Variant = combat_manager.get("_spatial_hash")
	var unit_lookup_value: Variant = combat_manager.get("_unit_by_instance_id")
	if spatial_hash == null or not is_instance_valid(spatial_hash):
		return false
	if not (unit_lookup_value is Dictionary):
		return false

	var unit_lookup: Dictionary = unit_lookup_value as Dictionary
	spatial_hash.query_radius_into(center, maxf(radius_world, 0.0), _spatial_query_ids_scratch)
	for candidate_id in _spatial_query_ids_scratch:
		if not unit_lookup.has(candidate_id):
			continue
		var unit: Node = unit_lookup[candidate_id]
		if not _passes_radius_team_filter(
			unit,
			source,
			source_team,
			require_allies,
			exclude_self,
			center,
			radius_world,
			state_service
		):
			continue
		output.append(unit)
	return true


func _pick_nearest_enemy_from_spatial_query(
	combat_manager: Node,
	center: Vector2,
	max_radius_world: float,
	source_team: int,
	visited: Dictionary,
	state_service: Variant = null
) -> Node:
	var spatial_hash: Variant = combat_manager.get("_spatial_hash")
	var unit_lookup_value: Variant = combat_manager.get("_unit_by_instance_id")
	if spatial_hash == null or not is_instance_valid(spatial_hash):
		return null
	if not (unit_lookup_value is Dictionary):
		return null

	var unit_lookup: Dictionary = unit_lookup_value as Dictionary
	var query_radius: float = max_radius_world
	if query_radius >= INF:
		query_radius = 1000000.0
	spatial_hash.query_radius_into(center, maxf(query_radius, 0.0), _spatial_query_ids_scratch)
	var best: Node = null
	var best_d2: float = INF
	var max_d2: float = max_radius_world * max_radius_world
	for candidate_id in _spatial_query_ids_scratch:
		if not unit_lookup.has(candidate_id):
			continue
		var unit: Node = unit_lookup[candidate_id]
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) == source_team:
			continue
		if not _is_unit_alive_in_context(unit, state_service):
			continue
		if visited.has(int(candidate_id)):
			continue

		var distance_value: float = distance_sq(node_pos(unit), center)
		if max_radius_world < INF and distance_value > max_d2:
			continue
		if distance_value >= best_d2:
			continue

		best_d2 = distance_value
		best = unit
	return best


func _get_state_service(context: Dictionary) -> Variant:
	var state_service: Variant = context.get("state_service", null)
	if state_service != null:
		return state_service
	var manager: Variant = context.get("unit_augment_manager", null)
	if manager != null and manager.has_method("get_state_service"):
		return manager.get_state_service()
	return null


func _is_unit_alive_in_context(unit: Node, state_service: Variant = null) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if state_service != null and state_service.has_method("is_unit_alive"):
		return bool(state_service.is_unit_alive(unit))
	return is_unit_alive(unit)
