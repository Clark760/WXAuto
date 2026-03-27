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
	var blocked_for_ally: Dictionary = {}
	var blocked_for_enemy: Dictionary = {}
	if bool(owner.get("block_teammate_cells_in_flow")):
		blocked_for_ally = build_blocked_cells_for_team(owner, 1)
		blocked_for_enemy = build_blocked_cells_for_team(owner, 2)
	_rules.rebuild_flow_fields(
		owner,
		owner.get("_flow_to_enemy"),
		owner.get("_flow_to_ally"),
		owner.get("_team_cells_cache"),
		blocked_for_ally,
		blocked_for_enemy
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


# 邻格选点仍按旧签名暴露给 movement service。
func pick_best_adjacent_cell(owner: Node, unit: Node, current_cell: Vector2i) -> Vector2i:
	return _rules.pick_best_adjacent_cell(
		owner,
		unit,
		current_cell,
		owner.get("_flow_to_enemy"),
		owner.get("_flow_to_ally"),
		bool(owner.get("allow_equal_cost_side_step")),
		owner.get("_group_focus_target_id"),
		owner.get("_unit_by_instance_id")
	)


# hex 距离旧入口继续保留，便于 manager 和 targeting adapter 共用。
func hex_distance(owner: Node, a: Vector2i, b: Vector2i) -> int:
	return _rules.hex_distance(owner.get("_hex_grid"), a, b)
