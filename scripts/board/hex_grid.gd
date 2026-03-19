extends Node2D
class_name HexGrid

# ===========================
# 六边形网格系统（Pointy-Top）
# ===========================
# 功能：
# 1. 提供轴坐标(q, r) <-> 世界坐标转换。
# 2. 提供世界坐标拾取到最近六边形格子的能力。
# 3. 通过 _draw() 可视化网格，便于 M0 原型验证。

const SQRT3 := 1.7320508

@export var grid_width: int = 16
@export var grid_height: int = 8
@export var hex_size: float = 28.0
@export var origin_offset: Vector2 = Vector2(220.0, 120.0)
@export var draw_coordinates: bool = true
@export var fill_color: Color = Color(0.18, 0.22, 0.28, 0.35)
@export var line_color: Color = Color(0.75, 0.82, 0.88, 0.85)
@export var coordinate_color: Color = Color(0.95, 0.95, 0.98, 0.9)


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	var font_size: int = ThemeDB.fallback_font_size

	for r in range(grid_height):
		for q in range(grid_width):
			var axial: Vector2i = Vector2i(q, r)
			var center: Vector2 = axial_to_local(axial)
			var points: PackedVector2Array = _build_hex_points(center)

			# 先填充再描边，确保格子轮廓清晰可见。
			draw_colored_polygon(points, fill_color)
			var outline: PackedVector2Array = points.duplicate()
			outline.append(points[0])
			draw_polyline(outline, line_color, 1.2, true)

			# 绘制坐标文本（可关闭），用于调试部署与寻路坐标映射。
			if draw_coordinates and font != null:
				var text: String = "%d,%d" % [q, r]
				draw_string(font, center + Vector2(-14, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, coordinate_color)


func axial_to_world(axial: Vector2i) -> Vector2:
	# M2 中“世界坐标”定义为 WorldContainer 内本地坐标。
	# 因此这里返回 HexGrid 变换后的父空间坐标，而不是全局屏幕坐标。
	return transform * axial_to_local(axial)


func axial_to_local(axial: Vector2i) -> Vector2:
	# Pointy-Top 轴坐标换算公式：
	# x = size * sqrt(3) * (q + r/2)
	# y = size * 3/2 * r
	var x: float = hex_size * SQRT3 * (float(axial.x) + float(axial.y) * 0.5)
	var y: float = hex_size * 1.5 * float(axial.y)
	return Vector2(x, y) + origin_offset


func world_to_axial(world_pos: Vector2) -> Vector2i:
	# 将世界坐标逆变换为分数轴坐标，再做 cube-round 得到最近格子。
	# 注意：world_pos 来自 WorldContainer 本地坐标，需要先用当前局部变换逆变换。
	var local_world: Vector2 = transform.affine_inverse() * world_pos
	var local: Vector2 = local_world - origin_offset
	var q: float = ((SQRT3 / 3.0) * local.x - (1.0 / 3.0) * local.y) / hex_size
	var r: float = ((2.0 / 3.0) * local.y) / hex_size
	return _axial_round(Vector2(q, r))


func get_hex_points_local(axial: Vector2i) -> PackedVector2Array:
	# 对外暴露本地六边形顶点，供部署区高亮等叠加绘制层复用。
	return _build_hex_points(axial_to_local(axial))


func is_inside_grid(axial: Vector2i) -> bool:
	return axial.x >= 0 and axial.x < grid_width and axial.y >= 0 and axial.y < grid_height


func get_all_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for r in range(grid_height):
		for q in range(grid_width):
			cells.append(Vector2i(q, r))
	return cells


func _build_hex_points(center: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(6):
		# Pointy-Top 六边形每个顶点相差 60°，首顶点偏移 -30°。
		var angle: float = deg_to_rad(float(i) * 60.0 - 30.0)
		var point: Vector2 = center + Vector2(cos(angle), sin(angle)) * hex_size
		points.append(point)
	return points


func _axial_round(frac_axial: Vector2) -> Vector2i:
	# 经典 cube-round：
	# q -> x, r -> z, y = -x-z
	# 对 xyz 分别四舍五入，再修正偏差最大轴。
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
