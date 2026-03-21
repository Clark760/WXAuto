extends RefCounted
class_name FlowField

# ===========================
# 流场寻路
# ===========================
# 优化要点：
# 1. 由字符串 key("q,r") 改为整数 key，消除大量格式化与拆分分配。
# 2. BFS 继续采用数组 + head 索引队列，避免 pop_front 触发内存搬移。
# 3. 方向图仍按“朝更低 cost 邻居”生成，逻辑行为保持不变。

const AXIAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1)
]

var _cost_map: Dictionary = {}      # int(cell_key) -> int cost
var _direction_map: Dictionary = {} # int(cell_key) -> Vector2 direction


func clear() -> void:
	_cost_map.clear()
	_direction_map.clear()


func build(hex_grid: Node, target_cells: Array[Vector2i], blocked_cells: Dictionary = {}) -> void:
	clear()
	if hex_grid == null:
		return
	if target_cells.is_empty():
		return

	var queue: Array[Vector2i] = []
	for cell in target_cells:
		if not _is_walkable(hex_grid, cell, blocked_cells):
			continue
		var key: int = _cell_key_int(cell)
		if _cost_map.has(key):
			continue
		_cost_map[key] = 0
		queue.append(cell)

	var head: int = 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1

		var current_key: int = _cell_key_int(current)
		var current_cost: int = int(_cost_map.get(current_key, 0))

		for next_cell in _get_neighbors(hex_grid, current):
			if not _is_walkable(hex_grid, next_cell, blocked_cells):
				continue
			var next_key: int = _cell_key_int(next_cell)
			if _cost_map.has(next_key):
				continue
			_cost_map[next_key] = current_cost + 1
			queue.append(next_cell)

	_rebuild_direction_map(hex_grid)


func sample_direction(cell: Vector2i) -> Vector2:
	return _direction_map.get(_cell_key_int(cell), Vector2.ZERO)


func sample_cost(cell: Vector2i) -> int:
	var key: int = _cell_key_int(cell)
	if not _cost_map.has(key):
		return -1
	return int(_cost_map[key])


func has_path(cell: Vector2i) -> bool:
	return _cost_map.has(_cell_key_int(cell))


func _rebuild_direction_map(hex_grid: Node) -> void:
	_direction_map.clear()
	for raw_key in _cost_map.keys():
		var cell_key: int = int(raw_key)
		var cell: Vector2i = _parse_cell_key_int(cell_key)
		var self_cost: int = int(_cost_map[cell_key])
		if self_cost <= 0:
			_direction_map[cell_key] = Vector2.ZERO
			continue

		var best_neighbor: Vector2i = cell
		var best_cost: int = self_cost
		for neighbor in _get_neighbors(hex_grid, cell):
			var neighbor_key: int = _cell_key_int(neighbor)
			if not _cost_map.has(neighbor_key):
				continue
			var cost: int = int(_cost_map[neighbor_key])
			if cost < best_cost:
				best_cost = cost
				best_neighbor = neighbor

		if best_neighbor == cell:
			_direction_map[cell_key] = Vector2.ZERO
			continue

		var from_world: Vector2 = hex_grid.call("axial_to_world", cell)
		var to_world: Vector2 = hex_grid.call("axial_to_world", best_neighbor)
		_direction_map[cell_key] = (to_world - from_world).normalized()


func _get_neighbors(hex_grid: Node, cell: Vector2i) -> Array[Vector2i]:
	if hex_grid != null and hex_grid.has_method("get_neighbor_cells"):
		var neighbors_value: Variant = hex_grid.call("get_neighbor_cells", cell)
		if neighbors_value is Array:
			var neighbors_typed: Array[Vector2i] = []
			for candidate in (neighbors_value as Array):
				if candidate is Vector2i:
					neighbors_typed.append(candidate)
			return neighbors_typed
	var fallback: Array[Vector2i] = []
	for direction in AXIAL_DIRS:
		fallback.append(cell + direction)
	return fallback


func _is_walkable(hex_grid: Node, cell: Vector2i, blocked_cells: Dictionary) -> bool:
	if not bool(hex_grid.call("is_inside_grid", cell)):
		return false
	if _blocked_has_cell(blocked_cells, cell):
		return false
	return true


func _blocked_has_cell(blocked_cells: Dictionary, cell: Vector2i) -> bool:
	if blocked_cells.is_empty():
		return false
	var int_key: int = _cell_key_int(cell)
	if blocked_cells.has(int_key):
		return true
	# 兼容旧调用方仍传 "q,r" 字符串 key 的情况。
	var str_key: String = "%d,%d" % [cell.x, cell.y]
	return blocked_cells.has(str_key)


func _cell_key_int(cell: Vector2i) -> int:
	# 用 16bit+16bit 打包 axial 坐标。当前地图远小于 32767，足够覆盖。
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


func _parse_cell_key_int(key: int) -> Vector2i:
	var q: int = (key >> 16) & 0xFFFF
	var r: int = key & 0xFFFF
	if q >= 0x8000:
		q -= 0x10000
	if r >= 0x8000:
		r -= 0x10000
	return Vector2i(q, r)
