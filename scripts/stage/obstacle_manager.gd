extends Node
class_name ObstacleManager

# ===========================
# 障碍物管理器（M5）
# ===========================
# 目标：
# 1. 维护关卡障碍物生命周期与阻挡格集合；
# 2. 提供“是否阻挡”查询，供战场部署与战斗寻路读取；
# 3. 提供轻量可视化，方便调试关卡地形配置。

const BLOCK_MOVE_TYPES: Dictionary = {
	"rock": true,
	"bamboo": true,
	"fire_pit": true,
	# 水地形可通过（后续可叠加减速逻辑），当前不阻挡路径。
	"water": false
}

const OBSTACLE_COLORS: Dictionary = {
	"rock": Color(0.45, 0.46, 0.48, 0.82),
	"bamboo": Color(0.34, 0.58, 0.36, 0.72),
	"water": Color(0.25, 0.46, 0.66, 0.55),
	"fire_pit": Color(0.78, 0.34, 0.22, 0.76)
}

var _obstacles: Array[Dictionary] = []
var _blocked_cells: Dictionary = {} # int(cell_key) -> true


func spawn_obstacles(obstacles: Array, hex_grid: Node) -> void:
	clear_all_obstacles()
	clear_visuals_from_grid(hex_grid)
	if hex_grid == null or not is_instance_valid(hex_grid):
		return
	for obstacle_value in obstacles:
		if not (obstacle_value is Dictionary):
			continue
		var obstacle: Dictionary = obstacle_value
		var obstacle_type: String = str(obstacle.get("type", "rock")).strip_edges().to_lower()
		var cells_value: Variant = obstacle.get("cells", [])
		if not (cells_value is Array):
			continue
		var cells: Array = cells_value
		if cells.is_empty():
			continue
		var normalized_cells: Array[Vector2i] = []
		for cell_value in cells:
			var cell: Vector2i = _to_cell(cell_value)
			if cell.x < 0 or cell.y < 0:
				continue
			if not bool(hex_grid.call("is_inside_grid", cell)):
				continue
			normalized_cells.append(cell)
			if _is_move_block_type(obstacle_type):
				_blocked_cells[_cell_key_int(cell)] = true
		if normalized_cells.is_empty():
			continue
		_obstacles.append({
			"type": obstacle_type,
			"cells": normalized_cells
		})
	# 统一交由 HexGrid 按当前网格参数绘制障碍格，避免独立节点错位。
	apply_visuals_to_grid(hex_grid)


func clear_all_obstacles() -> void:
	_obstacles.clear()
	_blocked_cells.clear()


func apply_visuals_to_grid(hex_grid: Node) -> void:
	# 将障碍物格颜色映射注入 HexGrid，由 HexGrid._draw() 统一绘制。
	if hex_grid == null or not is_instance_valid(hex_grid):
		return
	if not hex_grid.has_method("set_obstacle_cells"):
		return
	var cells_colors: Dictionary = {}
	for obstacle in _obstacles:
		var obstacle_type: String = str(obstacle.get("type", "rock"))
		var color: Color = OBSTACLE_COLORS.get(obstacle_type, Color(0.62, 0.42, 0.24, 0.72))
		var cells_value: Variant = obstacle.get("cells", [])
		if not (cells_value is Array):
			continue
		for cell_value in (cells_value as Array):
			if cell_value is Vector2i:
				var cell: Vector2i = cell_value as Vector2i
				cells_colors[_cell_key_int(cell)] = color
	hex_grid.call("set_obstacle_cells", cells_colors)


func clear_visuals_from_grid(hex_grid: Node) -> void:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("clear_obstacle_cells"):
		hex_grid.call("clear_obstacle_cells")


func is_cell_blocked(cell: Vector2i) -> bool:
	return _blocked_cells.has(_cell_key_int(cell))


func get_obstacle_at(cell: Vector2i) -> Dictionary:
	for obstacle in _obstacles:
		var cells_value: Variant = obstacle.get("cells", [])
		if not (cells_value is Array):
			continue
		for c in (cells_value as Array):
			if c is Vector2i and c == cell:
				return obstacle.duplicate(true)
	return {}


func get_all_blocked_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for key_value in _blocked_cells.keys():
		var packed_key: int = int(key_value)
		cells.append(_cell_from_int_key(packed_key))
	return cells


func _is_move_block_type(obstacle_type: String) -> bool:
	if BLOCK_MOVE_TYPES.has(obstacle_type):
		return bool(BLOCK_MOVE_TYPES[obstacle_type])
	return true


func _to_cell(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Array:
		var arr: Array = value
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	if value is Dictionary:
		var dict: Dictionary = value
		return Vector2i(int(dict.get("x", -1)), int(dict.get("y", -1)))
	return Vector2i(-1, -1)


func _cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


func _cell_from_int_key(int_key: int) -> Vector2i:
	var x_raw: int = (int_key >> 16) & 0xFFFF
	var y_raw: int = int_key & 0xFFFF
	if x_raw > 0x7FFF:
		x_raw -= 0x10000
	if y_raw > 0x7FFF:
		y_raw -= 0x10000
	return Vector2i(x_raw, y_raw)
