extends RefCounted
class_name CellOccupancy

const DOMAIN_RULES_SCRIPT: Script = preload("res://scripts/domain/combat/cell_occupancy.gd")

var _rules = DOMAIN_RULES_SCRIPT.new()

# 兼容壳
# 说明：
# 1. manager 仍按旧 owner 签名调用本文件。
# 2. 真实占格规则已迁到 domain/combat/cell_occupancy.gd。


# int key 口径继续暴露给 manager 和 targeting adapter 复用。
func cell_key_int(cell: Vector2i) -> int:
	return _rules.cell_key_int(cell)


# 旧 runtime 仍通过 owner 注入运行态，这里只做字段拆包。
func occupy_cell(owner: Node, cell: Vector2i, unit: Node) -> bool:
	return _rules.occupy_cell(
		owner,
		owner.get("_hex_grid"),
		owner.get("_cell_occupancy"),
		owner.get("_unit_cell"),
		cell,
		unit
	)


# 兼容旧的“按格退格”入口。
func vacate_cell(owner: Node, cell: Vector2i) -> void:
	_rules.vacate_cell(
		owner,
		owner.get("_cell_occupancy"),
		owner.get("_unit_cell"),
		cell
	)


# 兼容旧的“按单位退格”入口。
func vacate_unit(owner: Node, unit: Node) -> void:
	_rules.vacate_unit(
		owner,
		owner.get("_cell_occupancy"),
		owner.get("_unit_cell"),
		unit
	)


# manager 继续按旧签名读取空格判定。
func is_cell_free(owner: Node, cell: Vector2i) -> bool:
	return _rules.is_cell_free(
		owner,
		owner.get("_hex_grid"),
		owner.get("_cell_occupancy"),
		cell
	)


# manager 继续按旧签名读取单位逻辑格。
func get_unit_cell(owner: Node, unit: Node) -> Vector2i:
	return _rules.get_unit_cell(
		owner,
		owner.get("_hex_grid"),
		owner.get("_unit_cell"),
		unit
	)


# 旧开战注册流程保持不变，但实现体已切到 domain。
func resolve_and_register_unit_cell(owner: Node, unit: Node) -> Vector2i:
	return _rules.resolve_and_register_unit_cell(
		owner,
		owner.get("_hex_grid"),
		owner.get("_cell_occupancy"),
		owner.get("_unit_cell"),
		unit
	)


# 轻量占格校验仍走旧入口，便于 manager 无感迁移。
func validate_occupancy(owner: Node) -> void:
	_rules.validate_occupancy(
		owner.get("_cell_occupancy"),
		owner.get("_unit_cell")
	)


# 最近空格搜索继续暴露旧接口，供 manager 和测试复用。
func find_nearest_free_cell(owner: Node, start_cell: Vector2i) -> Vector2i:
	return _rules.find_nearest_free_cell(
		owner,
		owner.get("_hex_grid"),
		owner.get("_cell_occupancy"),
		start_cell,
		_get_neighbor_cache(owner)
	)


# 邻接格读取继续暴露旧接口，供 pathfinding 和 targeting adapter 复用。
func neighbors_of(owner: Node, cell: Vector2i) -> Array[Vector2i]:
	return _rules.neighbors_of(owner.get("_hex_grid"), cell, _get_neighbor_cache(owner))


func _get_neighbor_cache(owner: Node) -> Dictionary:
	var cache_value: Variant = owner.get("_neighbor_cells_cache")
	if cache_value is Dictionary:
		return cache_value as Dictionary
	return {}
