extends Node2D
class_name HexGrid

# 支持两种坐标布局：
# 1) 轴向矩形窗口（菱形棋盘）
# 2) 奇行偏移矩形（交错式 32x32 风格棋盘）
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
@export var fill_color: Color = Color(0.36, 0.32, 0.27, 0.08)
@export var line_color: Color = Color(0.36, 0.32, 0.27, 0.25)
@export var coordinate_color: Color = Color(0.95, 0.95, 0.98, 0.9)

# 障碍物格渲染缓存：key 为打包后的坐标 int，value 为对应填充颜色。
var _overlay_cells: Dictionary = {} # int(cell_key) -> Color


# 节点进入树后立即请求重绘，确保编辑器和运行时首帧都能看到棋盘。
func _ready() -> void:
	queue_redraw()


# 统一绘制六边格填充、描边和坐标文本，外部不再追加额外 Polygon2D。
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
			if _overlay_cells.has(cell_key):
				var overlay_color: Color = _overlay_cells[cell_key] as Color
				cell_fill = cell_fill.lerp(overlay_color, clampf(overlay_color.a, 0.2, 0.85))
			draw_colored_polygon(points, cell_fill)
			var outline: PackedVector2Array = points.duplicate()
			outline.append(points[0])
			draw_polyline(outline, line_color, 1.2, true)
			if draw_coordinates and font != null:
				var text: String = "%d,%d" % [q, r]
				draw_string(font, center + Vector2(-14, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, coordinate_color)


# 兼容旧入口：障碍色块直接复用 overlay 渲染缓存。
func set_obstacle_cells(cells: Dictionary) -> void:
	set_overlay_cells(cells)
	queue_redraw()


# 清空障碍格覆盖层，恢复基础棋盘底色。
func clear_obstacle_cells() -> void:
	clear_overlay_cells()
	queue_redraw()


# 地形色块与障碍共用同一批 overlay 数据结构，避免两套缓存漂移。
func set_terrain_cells(cells: Dictionary) -> void:
	set_overlay_cells(cells)
	queue_redraw()


# 清空地形覆盖层，供重开战场或切图时复位。
func clear_terrain_cells() -> void:
	clear_overlay_cells()
	queue_redraw()


# 直接替换覆盖层缓存，约定传入的是 packed cell key 到 Color 的映射。
func set_overlay_cells(cells: Dictionary) -> void:
	# cells: { packed_cell_key_int: Color }
	_overlay_cells = cells.duplicate(true)
	queue_redraw()


# 覆盖层缓存只做本地清空，不推导任何默认状态。
func clear_overlay_cells() -> void:
	_overlay_cells.clear()
	queue_redraw()


# 把棋盘局部坐标结果转换到世界坐标，供单位和特效对位使用。
func axial_to_world(cell: Vector2i) -> Vector2:
	return transform * axial_to_local(cell)


# 根据当前布局模式把格子坐标映射到本地空间中心点。
func axial_to_local(cell: Vector2i) -> Vector2:
	var axial_cell: Vector2i = _to_axial_cell(cell)
	var x: float = hex_size * SQRT3 * (float(axial_cell.x) + float(axial_cell.y) * 0.5)
	var y: float = hex_size * 1.5 * float(axial_cell.y)
	return Vector2(x, y) + origin_offset


# 把世界坐标反解回棋盘格坐标，统一收口点击拾取逻辑。
func world_to_axial(world_pos: Vector2) -> Vector2i:
	var local_world: Vector2 = transform.affine_inverse() * world_pos
	var local: Vector2 = local_world - origin_offset
	var q: float = ((SQRT3 / 3.0) * local.x - (1.0 / 3.0) * local.y) / maxf(hex_size, 0.001)
	var r: float = ((2.0 / 3.0) * local.y) / maxf(hex_size, 0.001)
	var axial_cell: Vector2i = _axial_round(Vector2(q, r))
	return _from_axial_cell(axial_cell)


# 对外暴露单格六边形顶点，供外部命中框或装饰绘制复用。
func get_hex_points_local(cell: Vector2i) -> PackedVector2Array:
	return _build_hex_points(axial_to_local(cell))


# 统一边界判断，避免外部重复硬编码宽高范围。
func is_inside_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < grid_width and cell.y >= 0 and cell.y < grid_height


# 返回当前棋盘所有合法格子，供部署区和寻路初始化遍历。
func get_all_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for r in range(grid_height):
		for q in range(grid_width):
			cells.append(Vector2i(q, r))
	return cells


# 按布局模式返回相邻六方向格子，自动过滤越界目标。
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


# 根据可用宽高反推适配 hex_size，保证整块棋盘能装进目标区域。
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


# 计算指定 hex_size 下棋盘整体包围尺寸，供相机或容器布局使用。
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


# 六边格距离统一换算到轴向坐标后计算，避免偏移布局下距离失真。
func get_cell_distance(a: Vector2i, b: Vector2i) -> int:
	var a_axial: Vector2i = _to_axial_cell(a)
	var b_axial: Vector2i = _to_axial_cell(b)
	var dq: int = b_axial.x - a_axial.x
	var dr: int = b_axial.y - a_axial.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


# 偏移布局下把显示坐标换成轴向坐标，纯轴向模式直接透传。
func _to_axial_cell(cell: Vector2i) -> Vector2i:
	if not use_staggered_square_layout:
		return cell
	var q: int = cell.x - int((cell.y - (cell.y & 1)) / 2.0)
	return Vector2i(q, cell.y)


# 把轴向坐标还原回偏移布局显示坐标，供外部接口保持统一口径。
func _from_axial_cell(axial_cell: Vector2i) -> Vector2i:
	if not use_staggered_square_layout:
		return axial_cell
	var col: int = axial_cell.x + int((axial_cell.y - (axial_cell.y & 1)) / 2.0)
	return Vector2i(col, axial_cell.y)


# 按 pointy-top 六边形规则生成 6 个顶点，用于填充与描边。
func _build_hex_points(center: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(6):
		var angle: float = deg_to_rad(float(i) * 60.0 - 30.0)
		var point: Vector2 = center + Vector2(cos(angle), sin(angle)) * hex_size
		points.append(point)
	return points


# 对轴向浮点坐标做标准六边格 round，保证点击落格稳定。
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
