extends RefCounted
class_name UnitAugmentSkillTargetService


# 这里统一把“技能选敌”和“技能射程”约束从 trigger runtime 中拆出来。
# `battle_units` 是当前战斗视图，`state_service` 负责提供统一的存活判定口径。
# 返回值始终是最近的合法敌方单位，不会额外做射程过滤。
# 这个 helper 只按直线世界距离挑最近目标，不参与技能级范围裁剪。
func pick_nearest_enemy(battle_units: Array[Node], source: Node, state_service: Variant) -> Node:
	if source == null or not is_instance_valid(source):
		return null
	var source_pos: Vector2 = (source as Node2D).position
	var source_team: int = int(source.get("team_id"))
	var best: Node = null
	var best_d2: float = INF

	for unit in battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		if unit == source:
			continue
		if int(unit.get("team_id")) == source_team:
			continue
		if not state_service.is_unit_alive(unit):
			continue
		var d2: float = source_pos.distance_squared_to((unit as Node2D).position)
		if d2 < best_d2:
			best_d2 = d2
			best = unit

	return best


# `range_cells` 是技能级射程，不是单位普攻射程；这里统一做世界距离换算。
# `hex_grid` 只提供 hex_size，不参与路径或障碍计算。
# 这里返回的是“范围内最近敌人”，超出范围的单位会被直接跳过。
# 如果 range 配成 0 或负数，最终会在距离换算里视作无限接近 0 的特殊值处理。
func pick_nearest_enemy_in_range(
	battle_units: Array[Node],
	source: Node,
	range_cells: float,
	hex_grid: Node,
	state_service: Variant
) -> Node:
	if source == null or not is_instance_valid(source):
		return null
	var source_pos: Vector2 = (source as Node2D).position
	var source_team: int = int(source.get("team_id"))
	var max_world: float = cells_to_world_distance(range_cells, hex_grid)
	var max_d2: float = max_world * max_world
	var best: Node = null
	var best_d2: float = INF

	for unit in battle_units:
		if unit == null or not is_instance_valid(unit):
			continue
		if unit == source:
			continue
		if int(unit.get("team_id")) == source_team:
			continue
		if not state_service.is_unit_alive(unit):
			continue
		var d2: float = source_pos.distance_squared_to((unit as Node2D).position)
		if d2 > max_d2:
			continue
		if d2 < best_d2:
			best_d2 = d2
			best = unit

	return best


# 只有明确指向敌方目标的 op，才要求 trigger runtime 在释放前强制锁敌。
# 这里返回的是“是否需要敌方目标”，不是“是否已经找到目标”。
# 未列入名单的 op 默认允许把 source 自己当成目标。
func skill_requires_enemy_target(effects: Array) -> bool:
	var enemy_target_ops: Dictionary = {
		"damage_target": true,
		"debuff_target": true,
		"teleport_behind": true,
		"dash_forward": true,
		"knockback_target": true,
		"damage_target_scaling": true,
		"damage_if_debuffed": true,
		"damage_chain": true,
		"damage_cone": true,
		"steal_buff": true,
		"dispel_target": true,
		"pull_target": true,
		"swap_position": true,
		"mark_target": true,
		"damage_if_marked": true,
		"execute_target": true,
		"drain_mp": true,
		"silence_target": true,
		"stun_target": true,
		"freeze_target": true
	}

	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value as Dictionary
		var op: String = str(effect.get("op", "")).strip_edges()
		if enemy_target_ops.has(op):
			return true

	return false


# 技能射程优先读技能自己的 `range`，未配置时才退回单位当前射程。
# `default_range_cells` 是 facade 级保底值，避免配置缺省时出现 0 射程。
# 这里不会读取普攻 AI 的寻敌半径，口径只看技能配置和 runtime stats。
# 这样主动技能的射程口径始终和 effect/trigger 配置绑定，不受 AI 搜敌半径影响。
func resolve_skill_cast_range_cells(source: Node, skill_data: Dictionary, default_range_cells: float) -> float:
	if skill_data.has("range"):
		return maxf(float(skill_data.get("range", default_range_cells)), 0.0)
	if source == null or not is_instance_valid(source):
		return default_range_cells
	var runtime_stats: Variant = source.get("runtime_stats")
	if runtime_stats is Dictionary:
		return maxf(float((runtime_stats as Dictionary).get("rng", default_range_cells)), 1.0)
	return default_range_cells


# 这里校验的只是“能不能当敌方技能目标”，不处理更细的技能条件。
# 队伍、存活和“不能指向自己”三条约束统一在这里收口。
# 更细的条件如 tag、护盾、debuff 仍由 trigger 或 effect 层决定。
func is_valid_enemy_target(source: Node, target: Node, state_service: Variant) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	if target == source:
		return false
	if int(target.get("team_id")) == int(source.get("team_id")):
		return false
	return state_service.is_unit_alive(target)


# 射程判断统一基于世界坐标，避免技能和普攻各自写一套距离换算。
# 这里只判断空间距离，不负责敌我和存活校验。
# `range_cells <= 0` 时视为无限射程，直接放行。
func is_target_in_skill_range(source: Node, target: Node, range_cells: float, hex_grid: Node) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	if range_cells <= 0.0:
		return true
	var max_world: float = cells_to_world_distance(range_cells, hex_grid)
	return (source as Node2D).position.distance_squared_to((target as Node2D).position) <= max_world * max_world


# 这里的 `hex_grid` 只用于读取当前 hex_size，不参与格子路径计算。
# 返回值是粗略世界距离，供技能目标预选使用，不要求完全贴合寻路长度。
# 乘以 1.2 的目的是给六角格中心点距离留一点容差。
func cells_to_world_distance(cells: float, hex_grid: Node) -> float:
	var hex_size: float = 26.0
	if hex_grid != null:
		hex_size = float(hex_grid.get("hex_size"))
	return maxf(cells, 0.0) * maxf(hex_size, 1.0) * 1.2
