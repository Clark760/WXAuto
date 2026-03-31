extends RefCounted
class_name CombatPathfinding

const DOMAIN_RULES_SCRIPT: Script = preload("res://scripts/domain/combat/combat_pathfinding.gd")

var _rules = DOMAIN_RULES_SCRIPT.new()

# 兼容壳
# 说明：
# 1. manager 仍按旧 owner 签名调用本文件。
# 2. 真正规则实现已迁到 scripts/domain/combat/combat_pathfinding.gd。


# 流场刷新继续沿用旧入口，但 blocked map 和目标格生成已切到 domain。
func rebuild_flow_fields(owner: Node) -> void:
	var blocked_for_ally: Dictionary = owner._get_blocked_cells_snapshot()
	var blocked_for_enemy: Dictionary = owner._get_blocked_cells_snapshot()
	var weighted_for_ally: Dictionary = {}
	var weighted_for_enemy: Dictionary = {}
	if bool(owner.get("block_teammate_cells_in_flow")):
		var extra_cost: int = maxi(int(owner.get("teammate_flow_weight_penalty")), 0)
		weighted_for_ally = build_weighted_cells_for_team(owner, 1, extra_cost)
		weighted_for_enemy = build_weighted_cells_for_team(owner, 2, extra_cost)
	_rules.rebuild_flow_fields(
		owner,
		owner.get("_flow_to_enemy"),
		owner.get("_flow_to_ally"),
		owner.get("_team_cells_cache"),
		blocked_for_ally,
		blocked_for_enemy,
		weighted_for_ally,
		weighted_for_enemy
	)


# 跟随友军锚点缓存和流场一样按 manager 当前缓存重建，供 move 阶段重复复用。
func rebuild_follow_anchor_cache(owner: Node) -> Dictionary:
	return _rules.rebuild_follow_anchor_cache(
		owner,
		owner.get("_group_focus_target_id"),
		owner.get("_unit_by_instance_id"),
		owner.get("_team_alive_cache")
	)


# 兼容旧的 blocked map 构造入口，供 manager 和测试复用。
func build_blocked_cells_for_team(owner: Node, self_team: int) -> Dictionary:
	return _rules.build_blocked_cells_for_team(
		owner,
		owner._get_blocked_cells_snapshot(),
		owner.get("_cell_occupancy"),
		owner.get("_unit_by_instance_id"),
		self_team
	)


func build_weighted_cells_for_team(owner: Node, self_team: int, extra_cost: int) -> Dictionary:
	return _rules.build_weighted_cells_for_team(
		owner,
		owner.get("_cell_occupancy"),
		owner.get("_unit_by_instance_id"),
		self_team,
		extra_cost
	)


# 邻格选点仍按旧签名暴露给 movement service。
func pick_best_adjacent_cell(
	owner: Node,
	unit: Node,
	current_cell: Vector2i,
	attack_range_target: Node = null,
	skip_equal_cost_side_step: bool = false
) -> Vector2i:
	var allow_equal_cost_side_step: bool = bool(owner.get("allow_equal_cost_side_step")) \
		and not skip_equal_cost_side_step
	var last_move_from_cell: Vector2i = current_cell
	if owner.get("_last_move_from_cell") is Dictionary:
		last_move_from_cell = (owner.get("_last_move_from_cell") as Dictionary).get(
			unit.get_instance_id(),
			current_cell
		)
	return _rules.pick_best_adjacent_cell(
		owner,
		unit,
		current_cell,
		owner.get("_flow_to_enemy"),
		owner.get("_flow_to_ally"),
		allow_equal_cost_side_step,
		owner.get("_group_focus_target_id"),
		owner.get("_unit_by_instance_id"),
		owner.get("_follow_anchor_by_unit_id"),
		attack_range_target,
		last_move_from_cell
	)


# hex 距离旧入口继续保留，便于 manager 和 targeting adapter 共用。
func hex_distance(owner: Node, a: Vector2i, b: Vector2i) -> int:
	return _rules.hex_distance(owner.get("_hex_grid"), a, b)
