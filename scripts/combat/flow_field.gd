extends RefCounted
class_name FlowField

const DOMAIN_RULES_SCRIPT: Script = preload("res://scripts/domain/combat/flow_field.gd")

var _rules = DOMAIN_RULES_SCRIPT.new()

# 兼容壳
# 说明：
# 1. 旧路径继续暴露原先的 FlowField API。
# 2. 真正规则实现已迁到 scripts/domain/combat/flow_field.gd。


# 兼容旧调用方的显式清空入口。
func clear() -> void:
	_rules.clear()


# 旧 runtime 仍按 HexGrid + 目标格数组的方式构建流场。
func build(hex_grid: Node, target_cells: Array[Vector2i], blocked_cells: Dictionary = {}) -> void:
	_rules.build(hex_grid, target_cells, blocked_cells)


# 对外查询方向时继续保持旧契约。
func sample_direction(cell: Vector2i) -> Vector2:
	return _rules.sample_direction(cell)


# 对外查询 cost 时继续保持旧契约。
func sample_cost(cell: Vector2i) -> int:
	return _rules.sample_cost(cell)


# 兼容旧移动侧对 has_path 的读取方式。
func has_path(cell: Vector2i) -> bool:
	return _rules.has_path(cell)
