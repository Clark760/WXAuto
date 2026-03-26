extends RefCounted
class_name UnitAugmentHexSpatialService

# hex spatial service 只负责六边形格子的空间推导。
# 位移、召唤和危险区共享这里的算法，但真正的战场副作用仍由上层决定。


# “闪到目标身后”本质是沿着远离锚点的方向连续选格。
# `target_cell` 是当前目标格，`source_cell` 是施法者格，用来决定“身后”的方向。
func find_cell_behind_target(
	target_cell: Vector2i,
	source_cell: Vector2i,
	distance_steps: int,
	combat_manager: Node,
	hex_grid: Node
) -> Vector2i:
	var current: Vector2i = target_cell

	for _index in range(maxi(distance_steps, 1)):
		var next_cell: Vector2i = pick_neighbor_away_from_anchor(current, source_cell, combat_manager, hex_grid)
		if next_cell == current:
			break
		current = next_cell

	return current


# 这里优先挑“离锚点更远且可走”的邻居，避免把位移效果塞进障碍格。
# `combat_manager` 只用来判断占位，真正的移动执行不在这个 service 里。
func pick_neighbor_away_from_anchor(
	current: Vector2i,
	anchor: Vector2i,
	combat_manager: Node,
	hex_grid: Node
) -> Vector2i:
	var neighbors: Array[Vector2i] = get_neighbor_cells(current, hex_grid)
	if neighbors.is_empty():
		return current

	var best: Vector2i = current
	var best_distance: int = hex_distance_by_cell(current, anchor, hex_grid)

	for neighbor in neighbors:
		# 只保留既可走又能让目标继续远离锚点的邻居，防止位移原地打转。
		if not is_cell_walkable_for_effect(neighbor, combat_manager, hex_grid):
			continue

		var distance_value: int = hex_distance_by_cell(neighbor, anchor, hex_grid)
		if distance_value <= best_distance:
			continue

		best_distance = distance_value
		best = neighbor

	return best


# 六边形邻居查询统一经由 `hex_grid`，避免 effect 层自己维护偏移表。
# 返回值会被后续 BFS 和位移逻辑直接消费，因此这里只做类型过滤，不做额外排序。
func get_neighbor_cells(cell: Vector2i, hex_grid: Node) -> Array[Vector2i]:
	var output: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return output
	if not hex_grid.has_method("get_neighbor_cells"):
		return output

	var neighbors_value: Variant = hex_grid.get_neighbor_cells(cell)
	if not (neighbors_value is Array):
		return output

	for neighbor_value in (neighbors_value as Array):
		if neighbor_value is Vector2i:
			output.append(neighbor_value as Vector2i)

	return output


# 位移类效果必须同时尊重边界和占位。
# `hex_grid` 判边界，`combat_manager` 判阻挡，两者缺一都可能把单位送进非法格。
func is_cell_walkable_for_effect(cell: Vector2i, combat_manager: Node, hex_grid: Node) -> bool:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("is_inside_grid"):
		if not bool(hex_grid.is_inside_grid(cell)):
			return false

	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("is_cell_blocked"):
		if bool(combat_manager.is_cell_blocked(cell)):
			return false

	return true


# 危险区和召唤都依赖“半径格收集”，这里统一做 BFS。
# `radius_cells` 是逻辑格半径，不是世界坐标距离，避免和查询 service 的世界距离换算混用。
func collect_cells_in_radius(hex_grid: Node, center_cell: Vector2i, radius_cells: int) -> Array[Vector2i]:
	var output: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return output
	if center_cell.x < 0 or center_cell.y < 0:
		return output
	if not bool(hex_grid.is_inside_grid(center_cell)):
		return output

	# BFS 能保证所有候选格都从中心逐层展开，便于后续半径裁剪。
	var queue: Array[Vector2i] = [center_cell]
	var visited: Dictionary = {"%d,%d" % [center_cell.x, center_cell.y]: true}

	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		# 超出逻辑半径的格子不再展开，但队列中的其他近格仍会继续处理。
		if hex_distance_by_cell(center_cell, cell, hex_grid) > radius_cells:
			continue

		output.append(cell)

		var neighbors_value: Variant = hex_grid.get_neighbor_cells(cell)
		if not (neighbors_value is Array):
			continue

		# 邻居收集阶段只负责扩圈，不在这里判断是否可走，让危险区覆盖能穿过障碍格传播。
		for neighbor_value in (neighbors_value as Array):
			if not (neighbor_value is Vector2i):
				continue

			var neighbor: Vector2i = neighbor_value as Vector2i
			if not bool(hex_grid.is_inside_grid(neighbor)):
				continue

			var neighbor_key: String = "%d,%d" % [neighbor.x, neighbor.y]
			if visited.has(neighbor_key):
				continue

			visited[neighbor_key] = true
			queue.append(neighbor)

	return output


# 危险区中心支持“围绕自身”与“全图随机”两种模式。
# `query_service` 只用来拿 source 的世界坐标，真正的格子采样仍由本 service 完成。
# `radius_cells` 只在 around_self 模式下参与候选格采样。
func pick_hazard_center_cell(
	mode: String,
	source: Node,
	hex_grid: Node,
	radius_cells: int,
	query_service: Variant
) -> Vector2i:
	if mode == "around_self" and source != null and is_instance_valid(source):
		var source_cell: Vector2i = hex_grid.world_to_axial(query_service.node_pos(source))
		var cell_pool: Array[Vector2i] = collect_cells_in_radius(hex_grid, source_cell, radius_cells)
		if cell_pool.is_empty():
			return source_cell

		cell_pool.shuffle()
		return cell_pool[0]

	var width: int = maxi(int(hex_grid.get("grid_width")), 1)
	var height: int = maxi(int(hex_grid.get("grid_height")), 1)
	# 全图随机模式只返回中心格，具体覆盖范围由上层再按半径展开。
	return Vector2i(randi() % width, randi() % height)


# 优先复用 `hex_grid` 提供的距离实现，缺失时才走轴坐标兜底。
# 这样 effect 层不会因为不同地图实现而各自维护一套距离公式。
func hex_distance_by_cell(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.get_cell_distance(a, b))

	# 轴坐标兜底公式只在地图实现没提供距离接口时使用。
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)
