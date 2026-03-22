extends Node2D
class_name HexGrid

# Pointy-top hex grid.
# Supports two coordinate layouts:
# 1) axial rectangle window (rhombus-shaped board),
# 2) odd-r offset rectangle (staggered 32x32 style board).
const SQRT3 := 1.7320508
const AXIAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1)
]
const OFFSET_DIRS_EVEN_ROW: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(0, -1),
	Vector2i(-1, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1)
]
const OFFSET_DIRS_ODD_ROW: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(1, 1)
]

@export var grid_width: int = 16
@export var grid_height: int = 8
@export var hex_size: float = 28.0
@export var origin_offset: Vector2 = Vector2(220.0, 120.0)
@export var use_staggered_square_layout: bool = true
@export var draw_coordinates: bool = true
@export var fill_color: Color = Color(0.18, 0.22, 0.28, 0.35)
@export var line_color: Color = Color(0.75, 0.82, 0.88, 0.85)
@export var coordinate_color: Color = Color(0.95, 0.95, 0.98, 0.9)

# 障碍物格渲染缓存：key 为打包后的坐标 int，value 为对应填充颜色。
var _obstacle_cells: Dictionary = {} # int(cell_key) -> Color
var _terrain_cells: Dictionary = {} # int(cell_key) -> Color


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	var font_size: int = ThemeDB.fallback_font_size
	for r in range(grid_height):
		for q in range(grid_width):
			var cell: Vector2i = Vector2i(q, r)
			var center: Vector2 = axial_to_local(cell)
			var points: PackedVector2Array = _build_hex_points(center)
			# 统一在 HexGrid 内绘制障碍颜色，避免外部 Polygon2D 因坐标系/hex_size 变化产生错位。
			var cell_key: int = ((q & 0xFFFF) << 16) | (r & 0xFFFF)
			var cell_fill: Color = fill_color
			if _obstacle_cells.has(cell_key):
				cell_fill = _obstacle_cells[cell_key] as Color
			if _terrain_cells.has(cell_key):
				var terrain_color: Color = _terrain_cells[cell_key] as Color
				cell_fill = cell_fill.lerp(terrain_color, clampf(terrain_color.a, 0.2, 0.8))
			draw_colored_polygon(points, cell_fill)
			var outline: PackedVector2Array = points.duplicate()
			outline.append(points[0])
			draw_polyline(outline, line_color, 1.2, true)
			if draw_coordinates and font != null:
				var text: String = "%d,%d" % [q, r]
				draw_string(font, center + Vector2(-14, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, coordinate_color)


func set_obstacle_cells(cells: Dictionary) -> void:
	# cells: { packed_cell_key_int: Color }
	_obstacle_cells = cells.duplicate(true)
	queue_redraw()


func clear_obstacle_cells() -> void:
	_obstacle_cells.clear()
	queue_redraw()


func set_terrain_cells(cells: Dictionary) -> void:
	# cells: { packed_cell_key_int: Color }
	_terrain_cells = cells.duplicate(true)
	queue_redraw()


func clear_terrain_cells() -> void:
	_terrain_cells.clear()
	queue_redraw()


func axial_to_world(cell: Vector2i) -> Vector2:
	return transform * axial_to_local(cell)


func axial_to_local(cell: Vector2i) -> Vector2:
	var axial_cell: Vector2i = _to_axial_cell(cell)
	var x: float = hex_size * SQRT3 * (float(axial_cell.x) + float(axial_cell.y) * 0.5)
	var y: float = hex_size * 1.5 * float(axial_cell.y)
	return Vector2(x, y) + origin_offset


func world_to_axial(world_pos: Vector2) -> Vector2i:
	var local_world: Vector2 = transform.affine_inverse() * world_pos
	var local: Vector2 = local_world - origin_offset
	var q: float = ((SQRT3 / 3.0) * local.x - (1.0 / 3.0) * local.y) / maxf(hex_size, 0.001)
	var r: float = ((2.0 / 3.0) * local.y) / maxf(hex_size, 0.001)
	var axial_cell: Vector2i = _axial_round(Vector2(q, r))
	return _from_axial_cell(axial_cell)


func get_hex_points_local(cell: Vector2i) -> PackedVector2Array:
	return _build_hex_points(axial_to_local(cell))


func is_inside_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < grid_width and cell.y >= 0 and cell.y < grid_height


func get_all_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for r in range(grid_height):
		for q in range(grid_width):
			cells.append(Vector2i(q, r))
	return cells


func get_neighbor_cells(cell: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if use_staggered_square_layout:
		var dirs: Array[Vector2i] = OFFSET_DIRS_ODD_ROW if ((cell.y & 1) == 1) else OFFSET_DIRS_EVEN_ROW
		for d in dirs:
			var next: Vector2i = cell + d
			if is_inside_grid(next):
				result.append(next)
		return result
	for d in AXIAL_DIRS:
		var next_axial: Vector2i = cell + d
		if is_inside_grid(next_axial):
			result.append(next_axial)
	return result


func get_layout_fit_hex_size(available_w: float, available_h: float) -> float:
	var grid_w: int = maxi(grid_width, 1)
	var grid_h: int = maxi(grid_height, 1)
	var width_coeff: float
	var height_coeff: float
	if use_staggered_square_layout:
		width_coeff = SQRT3 * (float(grid_w) + 0.5)
		height_coeff = 1.5 * float(grid_h - 1) + 2.0
	else:
		width_coeff = SQRT3 * (float(grid_w - 1) + float(grid_h - 1) * 0.5) + 1.7320508
		height_coeff = 1.5 * float(grid_h - 1) + 2.0
	return clampf(minf(available_w / maxf(width_coeff, 1.0), available_h / maxf(height_coeff, 1.0)), 1.0, 2048.0)


func get_layout_board_size(target_hex_size: float = -1.0) -> Vector2:
	var size_value: float = hex_size if target_hex_size <= 0.0 else target_hex_size
	var grid_w: int = maxi(grid_width, 1)
	var grid_h: int = maxi(grid_height, 1)
	if use_staggered_square_layout:
		var board_w_offset: float = size_value * SQRT3 * (float(grid_w) + 0.5)
		var board_h_offset: float = size_value * 1.5 * float(grid_h - 1) + size_value * 2.0
		return Vector2(board_w_offset, board_h_offset)
	var x_radius: float = size_value * 0.8660254
	var board_w: float = size_value * SQRT3 * (float(grid_w - 1) + float(grid_h - 1) * 0.5) + x_radius * 2.0
	var board_h: float = size_value * 1.5 * float(grid_h - 1) + size_value * 2.0
	return Vector2(board_w, board_h)


func get_cell_distance(a: Vector2i, b: Vector2i) -> int:
	var a_axial: Vector2i = _to_axial_cell(a)
	var b_axial: Vector2i = _to_axial_cell(b)
	var dq: int = b_axial.x - a_axial.x
	var dr: int = b_axial.y - a_axial.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


func _to_axial_cell(cell: Vector2i) -> Vector2i:
	if not use_staggered_square_layout:
		return cell
	var q: int = cell.x - int((cell.y - (cell.y & 1)) / 2.0)
	return Vector2i(q, cell.y)


func _from_axial_cell(axial_cell: Vector2i) -> Vector2i:
	if not use_staggered_square_layout:
		return axial_cell
	var col: int = axial_cell.x + int((axial_cell.y - (axial_cell.y & 1)) / 2.0)
	return Vector2i(col, axial_cell.y)


func _build_hex_points(center: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(6):
		var angle: float = deg_to_rad(float(i) * 60.0 - 30.0)
		var point: Vector2 = center + Vector2(cos(angle), sin(angle)) * hex_size
		points.append(point)
	return points


func _axial_round(frac_axial: Vector2) -> Vector2i:
	var x: float = frac_axial.x
	var z: float = frac_axial.y
	var y: float = -x - z

	var rx: float = round(x)
	var ry: float = round(y)
	var rz: float = round(z)

	var dx: float = abs(rx - x)
	var dy: float = abs(ry - y)
	var dz: float = abs(rz - z)

	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry

	return Vector2i(int(rx), int(rz))
