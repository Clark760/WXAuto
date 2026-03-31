extends RefCounted
class_name CombatCellOccupancyRules

# 占格规则
# 说明：
# 1. 规则层只操作显式传入的占格状态与 grid/runtime port。
# 2. 不再通过 owner.get/call 访问 facade 私有字段。
# 3. runtime adapter 仍可保留旧签名，但真正实现收口在这里。

const AXIAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1)
]


# 占格表和流场统一使用 int key，避免频繁拼接坐标字符串。
func cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


# 占格提交时同时维护 cell_occupancy 与 unit_cell，保证双向索引始终同步。
func occupy_cell(
	runtime_port: Node,
	hex_grid: Node,
	cell_occupancy: Dictionary,
	unit_cell: Dictionary,
	cell: Vector2i,
	unit: Node
) -> bool:
	if not runtime_port._is_live_unit(unit):
		return false
	if hex_grid != null and not hex_grid.is_inside_grid(cell):
		return false
	if runtime_port._is_cell_blocked(cell):
		return false

	var iid: int = unit.get_instance_id()
	var key: int = cell_key_int(cell)
	# 目标格已被他人占住时直接拒绝，避免覆盖式写入造成双占格。
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
	# 只有真的换格时才广播，避免初始化或重复登记刷出无意义事件。
	if from_cell != cell:
		runtime_port._notify_unit_cell_changed(unit, from_cell, cell)
	return true


# 按格回收占格时，同时清理反向索引，避免留下 unit_cell 脏缓存。
func vacate_cell(
	runtime_port: Node,
	cell_occupancy: Dictionary,
	unit_cell: Dictionary,
	cell: Vector2i
) -> void:
	var key: int = cell_key_int(cell)
	if not cell_occupancy.has(key):
		return
	var iid: int = int(cell_occupancy[key])
	cell_occupancy.erase(key)
	# 这里先删正向表，再处理反向表，避免中途查询看到半旧状态。
	if not unit_cell.has(iid):
		return
	var occupied_cell: Vector2i = unit_cell[iid]
	if occupied_cell != cell:
		return
	unit_cell.erase(iid)
	var unit: Node = runtime_port.get_unit_by_instance_id(iid)
	runtime_port._notify_unit_cell_changed(unit, occupied_cell, Vector2i(-1, -1))


# 按单位退格时优先走 unit_cell，避免扫描整张占格表。
func vacate_unit(
	runtime_port: Node,
	cell_occupancy: Dictionary,
	unit_cell: Dictionary,
	unit: Node
) -> void:
	if not runtime_port._is_live_unit(unit):
		return
	var iid: int = unit.get_instance_id()
	if not unit_cell.has(iid):
		return
	var cell: Vector2i = unit_cell[iid]
	var key: int = cell_key_int(cell)
	if cell_occupancy.has(key) and int(cell_occupancy[key]) == iid:
		cell_occupancy.erase(key)
	unit_cell.erase(iid)
	# 单位退场时总是广播离格，供预扫描和事件桥同步清理缓存。
	runtime_port._notify_unit_cell_changed(unit, cell, Vector2i(-1, -1))


# 空格判定统一收口在这里，供注册、移动和 BFS 复用同一条口径。
func is_cell_free(
	runtime_port: Node,
	hex_grid: Node,
	cell_occupancy: Dictionary,
	cell: Vector2i
) -> bool:
	if hex_grid != null and not hex_grid.is_inside_grid(cell):
		return false
	if runtime_port._is_cell_blocked(cell):
		return false
	return not cell_occupancy.has(cell_key_int(cell))


# 读取单位逻辑格时优先信任缓存，但仍会兜底校验棋盘边界。
func get_unit_cell(
	runtime_port: Node,
	hex_grid: Node,
	unit_cell: Dictionary,
	unit: Node
) -> Vector2i:
	if not runtime_port._is_live_unit(unit):
		return Vector2i(-1, -1)
	var iid: int = unit.get_instance_id()
	if not unit_cell.has(iid):
		return Vector2i(-1, -1)
	var cached_cell: Vector2i = unit_cell[iid]
	if hex_grid == null or hex_grid.is_inside_grid(cached_cell):
		return cached_cell
	return Vector2i(-1, -1)


# 开战登记只允许“视觉格”和“逻辑格”一致，避免 tween 中途把单位写到邻格。
func resolve_and_register_unit_cell(
	runtime_port: Node,
	hex_grid: Node,
	cell_occupancy: Dictionary,
	unit_cell: Dictionary,
	unit: Node
) -> Vector2i:
	if not runtime_port._is_live_unit(unit) or hex_grid == null:
		return Vector2i(-1, -1)
	var fallback_cell: Vector2i = hex_grid.world_to_axial(unit.position)
	if not hex_grid.is_inside_grid(fallback_cell):
		return Vector2i(-1, -1)

	var resolved_cell: Vector2i = fallback_cell
	# 注册阶段允许找最近空格，但最终仍要求与视觉格一致才正式落表。
	if not is_cell_free(runtime_port, hex_grid, cell_occupancy, resolved_cell):
		resolved_cell = find_nearest_free_cell(
			runtime_port,
			hex_grid,
			cell_occupancy,
			fallback_cell,
			{}
		)
	if resolved_cell.x < 0 or resolved_cell != fallback_cell:
		return Vector2i(-1, -1)
	if not occupy_cell(runtime_port, hex_grid, cell_occupancy, unit_cell, resolved_cell, unit):
		return Vector2i(-1, -1)

	var unit_node: Node2D = unit as Node2D
	if unit_node != null:
		unit_node.position = hex_grid.axial_to_world(resolved_cell)
	return resolved_cell


# 轻量校验只清掉双向索引错配项，不重新推导所有单位位置。
func validate_occupancy(cell_occupancy: Dictionary, unit_cell: Dictionary) -> void:
	var stale_keys: Array[int] = []
	for raw_key in cell_occupancy.keys():
		var key: int = int(raw_key)
		var iid: int = int(cell_occupancy[key])
		if not unit_cell.has(iid):
			stale_keys.append(key)
			continue
		if cell_key_int(unit_cell[iid]) != key:
			stale_keys.append(key)
	for key in stale_keys:
		cell_occupancy.erase(key)


# BFS 最近空格搜索只服务注册阶段，不负责战斗内的重排策略。
func find_nearest_free_cell(
	runtime_port: Node,
	hex_grid: Node,
	cell_occupancy: Dictionary,
	start_cell: Vector2i,
	neighbor_cache: Dictionary = {}
) -> Vector2i:
	if hex_grid == null or not hex_grid.is_inside_grid(start_cell):
		return Vector2i(-1, -1)
	if is_cell_free(runtime_port, hex_grid, cell_occupancy, start_cell):
		return start_cell

	var queue: Array[Vector2i] = [start_cell]
	var visited: Dictionary = {cell_key_int(start_cell): true}
	var head: int = 0
	# BFS 一圈圈外扩，命中的第一个空格就是最近可用落脚点。
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for neighbor in neighbors_of(hex_grid, current, neighbor_cache):
			var key: int = cell_key_int(neighbor)
			if visited.has(key):
				continue
			visited[key] = true
			if is_cell_free(runtime_port, hex_grid, cell_occupancy, neighbor):
				return neighbor
			queue.append(neighbor)
	return Vector2i(-1, -1)


# 邻接格优先读 HexGrid 的正式实现；缺失时再回退到 axial 六方向。
func neighbors_of(
	hex_grid: Node,
	cell: Vector2i,
	neighbor_cache: Dictionary = {}
) -> Array[Vector2i]:
	var key: int = cell_key_int(cell)
	if neighbor_cache.has(key):
		var cached_neighbors: Array = neighbor_cache[key]
		return cached_neighbors
	if hex_grid != null and hex_grid.has_method("get_neighbor_cells"):
		var neighbors_value: Variant = hex_grid.get_neighbor_cells(cell)
		if neighbors_value is Array:
			var typed_neighbors: Array[Vector2i] = []
			for candidate in (neighbors_value as Array):
				if candidate is Vector2i:
					typed_neighbors.append(candidate)
			neighbor_cache[key] = typed_neighbors
			return typed_neighbors
	var fallback: Array[Vector2i] = []
	for dir in AXIAL_DIRS:
		var next_cell: Vector2i = cell + dir
		if hex_grid == null or hex_grid.is_inside_grid(next_cell):
			fallback.append(next_cell)
	neighbor_cache[key] = fallback
	return fallback
