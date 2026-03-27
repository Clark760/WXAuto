extends RefCounted
class_name CombatFlowFieldRules

# 流场规则
# 说明：
# 1. 这里只保留 cost/direction 的纯算法，不再依赖 facade 动态属性袋。
# 2. grid_port 只提供棋盘边界、邻接格和坐标换算三种能力。
# 3. runtime 层是否使用 HexGrid 节点，不会泄漏到规则实现内部。

const AXIAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1)
]

var _cost_map: Dictionary = {}
var _direction_map: Dictionary = {}


# 清空旧的代价图与方向图，供下一次完整重建复用。
func clear() -> void:
	_cost_map.clear()
	_direction_map.clear()


# 目标格和阻挡格由调用方显式给出，流场本体只负责 BFS 展开与方向回填。
func build(grid_port: Node, target_cells: Array[Vector2i], blocked_cells: Dictionary = {}) -> void:
	clear()
	if grid_port == null or target_cells.is_empty():
		return

	var queue: Array[Vector2i] = []
	for cell in target_cells:
		if not _is_walkable(grid_port, cell, blocked_cells):
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
		for next_cell in _get_neighbors(grid_port, current):
			if not _is_walkable(grid_port, next_cell, blocked_cells):
				continue
			var next_key: int = _cell_key_int(next_cell)
			if _cost_map.has(next_key):
				continue
			_cost_map[next_key] = current_cost + 1
			queue.append(next_cell)

	_rebuild_direction_map(grid_port)


# 查询某格朝向目标的单位方向；不可达格返回零向量。
func sample_direction(cell: Vector2i) -> Vector2:
	return _direction_map.get(_cell_key_int(cell), Vector2.ZERO)


# 查询某格到目标圈的代价；未写入代价图时返回 -1。
func sample_cost(cell: Vector2i) -> int:
	var key: int = _cell_key_int(cell)
	if not _cost_map.has(key):
		return -1
	return int(_cost_map[key])


# 仅判断格子是否已被流场覆盖，供移动侧快速判定可达性。
func has_path(cell: Vector2i) -> bool:
	return _cost_map.has(_cell_key_int(cell))


# 方向图始终指向“代价更低的相邻格”，这样移动侧只需要读一跳趋势。
func _rebuild_direction_map(grid_port: Node) -> void:
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
		for neighbor in _get_neighbors(grid_port, cell):
			var neighbor_key: int = _cell_key_int(neighbor)
			if not _cost_map.has(neighbor_key):
				continue
			var neighbor_cost: int = int(_cost_map[neighbor_key])
			if neighbor_cost < best_cost:
				best_cost = neighbor_cost
				best_neighbor = neighbor

		if best_neighbor == cell:
			_direction_map[cell_key] = Vector2.ZERO
			continue

		var from_world: Vector2 = grid_port.axial_to_world(cell)
		var to_world: Vector2 = grid_port.axial_to_world(best_neighbor)
		_direction_map[cell_key] = (to_world - from_world).normalized()


# 邻接格优先走正式棋盘口径；缺失时再回退到 axial 六方向。
func _get_neighbors(grid_port: Node, cell: Vector2i) -> Array[Vector2i]:
	if grid_port.has_method("get_neighbor_cells"):
		var neighbors_value: Variant = grid_port.get_neighbor_cells(cell)
		if neighbors_value is Array:
			var typed_neighbors: Array[Vector2i] = []
			for candidate in (neighbors_value as Array):
				if candidate is Vector2i:
					typed_neighbors.append(candidate)
			if not typed_neighbors.is_empty():
				return typed_neighbors
	var fallback: Array[Vector2i] = []
	for direction in AXIAL_DIRS:
		fallback.append(cell + direction)
	return fallback


# 流场只认“棋盘内且非阻挡”的格子，边界判断不混进移动逻辑。
func _is_walkable(grid_port: Node, cell: Vector2i, blocked_cells: Dictionary) -> bool:
	if not grid_port.is_inside_grid(cell):
		return false
	if blocked_cells.has(_cell_key_int(cell)):
		return false
	return true


# int key 继续作为占格/流场的统一主键，避免反复拼字符串。
func _cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


# 回读 int key 时同时处理负数坐标，保证测试棋盘和正式棋盘口径一致。
func _parse_cell_key_int(key: int) -> Vector2i:
	var q: int = (key >> 16) & 0xFFFF
	var r: int = key & 0xFFFF
	if q >= 0x8000:
		q -= 0x10000
	if r >= 0x8000:
		r -= 0x10000
	return Vector2i(q, r)
