extends Node2D

# ===========================
# 部署区覆盖层
# ===========================
# 说明：
# 1. 该层挂在 HexGrid 下，使用同一坐标空间绘制己方部署区高亮。
# 2. 仅负责视觉提示，不参与格子合法性判定。

@export var ally_columns: int = 16
@export var deploy_x_min: int = 0
@export var deploy_x_max: int = 15
@export var deploy_y_min: int = 0
@export var deploy_y_max: int = 15
@export var overlay_color: Color = Color(0.32, 0.46, 0.68, 0.18)
@export var border_color: Color = Color(0.62, 0.82, 1.0, 0.48)

@onready var _grid: HexGrid = get_parent() as HexGrid


func _ready() -> void:
	queue_redraw()


func set_ally_columns(value: int) -> void:
	ally_columns = maxi(value, 1)
	deploy_x_min = 0
	deploy_x_max = ally_columns - 1
	deploy_y_min = 0
	if _grid != null:
		deploy_y_max = int(_grid.grid_height) - 1
	queue_redraw()


func set_deploy_zone_rect(x_min: int, x_max: int, y_min: int, y_max: int) -> void:
	deploy_x_min = x_min
	deploy_x_max = x_max
	deploy_y_min = y_min
	deploy_y_max = y_max
	queue_redraw()


func _draw() -> void:
	if _grid == null:
		return
	if not visible:
		return

	var width: int = int(_grid.grid_width)
	var height: int = int(_grid.grid_height)
	var x_min: int = clampi(deploy_x_min, 0, width - 1)
	var x_max: int = clampi(deploy_x_max, 0, width - 1)
	var y_min: int = clampi(deploy_y_min, 0, height - 1)
	var y_max: int = clampi(deploy_y_max, 0, height - 1)
	if x_min > x_max:
		var sx: int = x_min
		x_min = x_max
		x_max = sx
	if y_min > y_max:
		var sy: int = y_min
		y_min = y_max
		y_max = sy

	for r in range(y_min, y_max + 1):
		for q in range(x_min, x_max + 1):
			var cell: Vector2i = Vector2i(q, r)
			var points: PackedVector2Array = _grid.get_hex_points_local(cell)
			if points.size() < 3:
				continue
			draw_colored_polygon(points, overlay_color)
			var border: PackedVector2Array = points.duplicate()
			border.append(points[0])
			draw_polyline(border, border_color, 1.0, true)
