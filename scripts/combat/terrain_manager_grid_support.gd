extends RefCounted


# 负责 TerrainManager 的格子解析、可视缓存与 barrier 重建。
# 这里不处理战斗 phase，只负责把地形范围落成纯数据结构。
func rebuild_all_barrier_cells(manager, hex_grid: Node) -> Dictionary:
	var next_static: Dictionary = {} # 下一帧静态 barrier 快照。
	var next_dynamic: Dictionary = {} # 下一帧动态 barrier 快照。
	for terrain_value in manager._terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		if not bool(terrain.get("is_barrier", false)):
			continue
		var target_map: Dictionary = next_static if bool(terrain.get("is_static", false)) else next_dynamic
		for cell in get_effective_cells_for_terrain(manager, terrain, hex_grid):
			target_map[manager._cell_key_int(cell)] = true

	var static_changed: bool = manager._dict_keys_changed(manager._barrier_cells_static, next_static)
	var dynamic_changed: bool = manager._dict_keys_changed(manager._barrier_cells_dynamic, next_dynamic)
	manager._barrier_cells_static = next_static
	manager._barrier_cells_dynamic = next_dynamic
	return {
		"static_changed": static_changed,
		"dynamic_changed": dynamic_changed
	}


# 汇总全部地形颜色并输出 “格子 -> Color” 的缓存映射。
# 同一格命中多个地形时，这里负责维持旧版叠色行为。
func build_visual_cells(manager, hex_grid: Node) -> Dictionary:
	var cells_colors: Dictionary = {}
	for terrain_value in manager._terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		# terrain color 可能来自多种格式，这里统一规范成 Color 后再参与叠色。
		var color: Color = parse_color(
			terrain.get("color", Color(0.8, 0.8, 0.8, 0.25)),
			Color(0.8, 0.8, 0.8, 0.25)
		)
		for cell in get_effective_cells_for_terrain(manager, terrain, hex_grid):
			var key: int = manager._cell_key_int(cell)
			if cells_colors.has(key):
				var current: Color = cells_colors[key] as Color
				# 同格多地形时仍保留旧版 lerp 叠色，避免 HUD 表现和历史资源脱节。
				cells_colors[key] = current.lerp(color, clampf(color.a, 0.15, 0.75))
			else:
				cells_colors[key] = color
	return cells_colors


# 地形范围优先采用显式 cells；为空时再退回 center + radius 的圆形区域。
# 这样同一个 terrain entry 在 tooltip、barrier 和 visual 三处口径一致。
func get_effective_cells_for_terrain(manager, terrain: Dictionary, hex_grid: Node) -> Array[Vector2i]:
	var cells_value: Variant = terrain.get("cells", []) # 显式 cells 存在时不再展开 radius。
	var explicit_cells: Array[Vector2i] = parse_cells(cells_value, hex_grid)
	if not explicit_cells.is_empty():
		return explicit_cells
	var center_cell: Vector2i = to_cell(terrain.get("center_cell", Vector2i(-1, -1)))
	var radius: int = maxi(int(terrain.get("radius", 0)), 0)
	return collect_cells_in_radius(manager, hex_grid, center_cell, radius)


# 六角网格半径搜索沿用旧 BFS 方案，保证关卡旧地形布局不漂移。
# `center_cell` 越界时直接返回空，避免 helper 在这里偷偷纠偏。
func collect_cells_in_radius(
	manager,
	hex_grid: Node,
	center_cell: Vector2i,
	radius_cells: int
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	if center_cell.x < 0 or center_cell.y < 0:
		return out
	if not hex_grid.has_method("is_inside_grid"):
		return out

	var hex_grid_api: Variant = hex_grid
	if not bool(hex_grid_api.is_inside_grid(center_cell)):
		return out

	var queue: Array[Vector2i] = [center_cell] # BFS 保证 radius 展开顺序稳定。
	var visited: Dictionary = {manager._cell_key_int(center_cell): true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if hex_distance_cells(hex_grid, center_cell, cell) > radius_cells:
			continue
		out.append(cell)
		if not hex_grid.has_method("get_neighbor_cells"):
			continue
		var neighbors_value: Variant = hex_grid_api.get_neighbor_cells(cell)
		if not (neighbors_value is Array):
			continue
		for neighbor_value in (neighbors_value as Array):
			if not (neighbor_value is Vector2i):
				continue
			var neighbor: Vector2i = neighbor_value as Vector2i
			if not bool(hex_grid_api.is_inside_grid(neighbor)):
				continue
			var key: int = manager._cell_key_int(neighbor) # visited 统一按压缩 key 去重。
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


# 中心格先取配置，配置缺失时才从 source 世界坐标反推。
# 这里不会自己猜默认值，拿不到就返回非法格给上层兜底。
func extract_center_cell(config: Dictionary, source: Node, hex_grid: Node) -> Vector2i:
	var center_cell: Vector2i = to_cell(config.get("center_cell", config.get("cell", null))) # 兼容 center_cell / cell 两种键。
	if center_cell.x >= 0:
		return center_cell
	if source == null or not is_instance_valid(source):
		return center_cell
	if hex_grid == null or not is_instance_valid(hex_grid):
		return center_cell
	if not hex_grid.has_method("world_to_axial"):
		return center_cell

	# 只有 Node2D 才能从 position 反推格子，纯逻辑节点不会在这里硬转。
	var source_node: Node2D = source as Node2D
	if source_node == null:
		return center_cell
	var hex_grid_api: Variant = hex_grid
	return to_cell(hex_grid_api.world_to_axial(source_node.position))


# cells 字段兼容 Vector2i、数组和字典写法，并在这里完成去重与越界过滤。
# 过滤越界格的职责在 helper 内收口，调用方只关心结果。
func parse_cells(value: Variant, hex_grid: Node) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var input: Array = [] # 统一摊平成数组后再做去重和越界过滤。
	if value is Array:
		input = value as Array
	elif value is Vector2i:
		input = [value]
	else:
		# 非 cells 写法直接返回空，center + radius 的展开交给另一条路径处理。
		return cells

	var seen: Dictionary = {} # 同一地形重复给同一格时只保留一次。
	var hex_grid_api: Variant = hex_grid
	for raw in input:
		var cell: Vector2i = to_cell(raw)
		if cell.x < 0 or cell.y < 0:
			continue
		if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("is_inside_grid"):
			if not bool(hex_grid_api.is_inside_grid(cell)):
				continue
		var key: int = ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF) # 这里不依赖 manager，保持 helper 纯度。
		if seen.has(key):
			continue
		seen[key] = true
		cells.append(cell)
	return cells


# 输入统一转换为 Vector2i，避免上层反复做格式分支。
# 任何未知格式都返回非法格，让调用方决定是否丢弃。
func to_cell(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value as Vector2i
	if value is Array:
		var arr: Array = value as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	if value is Dictionary:
		var dict: Dictionary = value as Dictionary
		return Vector2i(int(dict.get("x", -1)), int(dict.get("y", -1)))
	return Vector2i(-1, -1)


# 安全读取节点属性，节点无效或字段为空时直接回退。
# source 快照提取会复用这里，避免到处散落空值判断。
func safe_node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	# 节点字段缺失或值为空时统一回退，避免来源快照里混进 null。
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value


# 颜色字段兼容 Color、字符串和字典输入，便于数据表与测试共用。
# helper 在这里把配置值夹到合法范围，避免 visual cache 出现脏数据。
func parse_color(value: Variant, fallback: Color) -> Color:
	if value is Color:
		return value as Color
	if value is String:
		# 字符串颜色直接复用 Godot 解析，保证数据表和测试写法一致。
		return Color.from_string(str(value), fallback)
	if value is Dictionary:
		var data: Dictionary = value as Dictionary
		return Color(
			clampf(float(data.get("r", fallback.r)), 0.0, 1.0),
			clampf(float(data.get("g", fallback.g)), 0.0, 1.0),
			clampf(float(data.get("b", fallback.b)), 0.0, 1.0),
			clampf(float(data.get("a", fallback.a)), 0.0, 1.0)
		)
	return fallback


# 六角距离优先复用 HexGrid 实现；MockGrid 没提供时再走轴坐标公式。
# 测试里的 MockHexGrid 没实现距离时，也要保持 radius 地形可用。
func hex_distance_cells(hex_grid: Node, a: Vector2i, b: Vector2i) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		var hex_grid_api: Variant = hex_grid
		return int(hex_grid_api.get_cell_distance(a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	# 这里沿用轴坐标距离公式，保证测试 fallback 与正式 HexGrid 半径一致。
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)
