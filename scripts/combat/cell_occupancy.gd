extends RefCounted
class_name CellOccupancy

# ===========================
# 占格系统模块
# ===========================
# 通过 owner 注入 CombatManager 运行态，
# 对外提供“格子占用查询/登记/校验”能力。

func cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


func occupy_cell(owner: Node, cell: Vector2i, unit: Node) -> bool:
	if not bool(owner.call("_is_live_unit", unit)):
		return false
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid != null and not bool(hex_grid.call("is_inside_grid", cell)):
		return false
	if bool(owner.call("_is_cell_blocked", cell)):
		return false

	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	var unit_cell: Dictionary = owner.get("_unit_cell")
	var iid: int = unit.get_instance_id()
	var key: int = cell_key_int(cell)
	if cell_occupancy.has(key) and int(cell_occupancy[key]) != iid:
		return false

	var old_cell: Vector2i = Vector2i(-1, -1)
	var had_old_cell: bool = false
	if unit_cell.has(iid):
		old_cell = unit_cell[iid]
		had_old_cell = true
		if old_cell != cell:
			var old_key: int = cell_key_int(old_cell)
			if cell_occupancy.has(old_key) and int(cell_occupancy[old_key]) == iid:
				cell_occupancy.erase(old_key)

	cell_occupancy[key] = iid
	unit_cell[iid] = cell
	var from_cell: Vector2i = old_cell if had_old_cell else Vector2i(-1, -1)
	if from_cell != cell and owner.has_method("_notify_unit_cell_changed"):
		owner.call("_notify_unit_cell_changed", unit, from_cell, cell)
	return true


func vacate_cell(owner: Node, cell: Vector2i) -> void:
	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	var unit_cell: Dictionary = owner.get("_unit_cell")
	var key: int = cell_key_int(cell)
	if not cell_occupancy.has(key):
		return
	var iid: int = int(cell_occupancy[key])
	cell_occupancy.erase(key)
	if unit_cell.has(iid):
		var occupied_cell: Vector2i = unit_cell[iid]
		if occupied_cell == cell:
			unit_cell.erase(iid)
			if owner.has_method("_notify_unit_cell_changed"):
				var unit: Node = owner.call("get_unit_by_instance_id", iid)
				owner.call("_notify_unit_cell_changed", unit, occupied_cell, Vector2i(-1, -1))


func vacate_unit(owner: Node, unit: Node) -> void:
	if not bool(owner.call("_is_live_unit", unit)):
		return
	var unit_cell: Dictionary = owner.get("_unit_cell")
	var iid: int = unit.get_instance_id()
	if not unit_cell.has(iid):
		return
	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	var cell: Vector2i = unit_cell[iid]
	var key: int = cell_key_int(cell)
	if cell_occupancy.has(key) and int(cell_occupancy[key]) == iid:
		cell_occupancy.erase(key)
	unit_cell.erase(iid)
	if owner.has_method("_notify_unit_cell_changed"):
		owner.call("_notify_unit_cell_changed", unit, cell, Vector2i(-1, -1))


func is_cell_free(owner: Node, cell: Vector2i) -> bool:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid != null and not bool(hex_grid.call("is_inside_grid", cell)):
		return false
	if bool(owner.call("_is_cell_blocked", cell)):
		return false
	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	return not cell_occupancy.has(cell_key_int(cell))


func get_unit_cell(owner: Node, unit: Node) -> Vector2i:
	if not bool(owner.call("_is_live_unit", unit)):
		return Vector2i(-1, -1)
	var unit_cell: Dictionary = owner.get("_unit_cell")
	var iid: int = unit.get_instance_id()
	if unit_cell.has(iid):
		var cached_cell: Vector2i = unit_cell[iid]
		var hex_grid: Node = owner.get("_hex_grid")
		if hex_grid == null or bool(hex_grid.call("is_inside_grid", cached_cell)):
			return cached_cell
	return Vector2i(-1, -1)


func resolve_and_register_unit_cell(owner: Node, unit: Node) -> Vector2i:
	if not bool(owner.call("_is_live_unit", unit)):
		return Vector2i(-1, -1)
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid == null:
		return Vector2i(-1, -1)
	var fallback_cell: Vector2i = hex_grid.call("world_to_axial", unit.position)
	if not bool(hex_grid.call("is_inside_grid", fallback_cell)):
		return Vector2i(-1, -1)
	var resolved_cell: Vector2i = fallback_cell
	if not is_cell_free(owner, resolved_cell):
		resolved_cell = find_nearest_free_cell(owner, fallback_cell)
	if resolved_cell.x < 0:
		return Vector2i(-1, -1)
	# M5-FIX: 若当前世界坐标映射格(fallback_cell)被占，不强制改写到邻格。
	# 这样可以避免 Tween 中途造成“逻辑格”和“视觉位置”错位引发重叠。
	if resolved_cell != fallback_cell:
		return Vector2i(-1, -1)
	if not occupy_cell(owner, resolved_cell, unit):
		return Vector2i(-1, -1)
	var unit_node: Node2D = unit as Node2D
	if unit_node != null:
		unit_node.position = hex_grid.call("axial_to_world", resolved_cell)
	return resolved_cell


func validate_occupancy(owner: Node) -> void:
	# 轻量校验：仅清理“格子->单位”错配项，避免引入额外并发副作用。
	var cell_occupancy: Dictionary = owner.get("_cell_occupancy")
	var unit_cell: Dictionary = owner.get("_unit_cell")
	var stale_keys: Array[int] = []
	for raw_key in cell_occupancy.keys():
		var key: int = int(raw_key)
		var iid: int = int(cell_occupancy[key])
		if not unit_cell.has(iid):
			stale_keys.append(key)
			continue
		var expected_key: int = cell_key_int(unit_cell[iid])
		if expected_key != key:
			stale_keys.append(key)
	for key in stale_keys:
		cell_occupancy.erase(key)


func find_nearest_free_cell(owner: Node, start_cell: Vector2i) -> Vector2i:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid == null:
		return Vector2i(-1, -1)
	if not bool(hex_grid.call("is_inside_grid", start_cell)):
		return Vector2i(-1, -1)
	if is_cell_free(owner, start_cell):
		return start_cell
	var queue: Array[Vector2i] = [start_cell]
	var visited: Dictionary = {cell_key_int(start_cell): true}
	var head: int = 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for neighbor in neighbors_of(owner, current):
			var key: int = cell_key_int(neighbor)
			if visited.has(key):
				continue
			visited[key] = true
			if is_cell_free(owner, neighbor):
				return neighbor
			queue.append(neighbor)
	return Vector2i(-1, -1)


func neighbors_of(owner: Node, cell: Vector2i) -> Array[Vector2i]:
	var hex_grid: Node = owner.get("_hex_grid")
	if hex_grid != null and hex_grid.has_method("get_neighbor_cells"):
		var neighbors_value: Variant = hex_grid.call("get_neighbor_cells", cell)
		if neighbors_value is Array:
			var typed_neighbors: Array[Vector2i] = []
			for candidate in (neighbors_value as Array):
				if candidate is Vector2i:
					typed_neighbors.append(candidate)
			return typed_neighbors
	var fallback: Array[Vector2i] = []
	for dir in FlowField.AXIAL_DIRS:
		var next_cell: Vector2i = cell + dir
		if hex_grid == null or bool(hex_grid.call("is_inside_grid", next_cell)):
			fallback.append(next_cell)
	return fallback
