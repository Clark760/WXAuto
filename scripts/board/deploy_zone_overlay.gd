extends Node2D

# ===========================
# 部署区覆盖层（M2）
# ===========================
# 说明：
# 1. 该层挂在 HexGrid 下，使用同一坐标空间绘制己方部署区高亮。
# 2. 仅负责视觉提示，不参与格子合法性判定。

@export var ally_columns: int = 16
@export var overlay_color: Color = Color(0.32, 0.46, 0.68, 0.18)
@export var border_color: Color = Color(0.62, 0.82, 1.0, 0.48)

@onready var _grid: HexGrid = get_parent() as HexGrid


func _ready() -> void:
	queue_redraw()


func set_ally_columns(value: int) -> void:
	ally_columns = maxi(value, 1)
	queue_redraw()


func _draw() -> void:
	if _grid == null:
		return
	if not visible:
		return

	var width: int = int(_grid.grid_width)
	var height: int = int(_grid.grid_height)
	var max_col: int = mini(ally_columns, width)

	for r in range(height):
		for q in range(max_col):
			var cell: Vector2i = Vector2i(q, r)
			var points: PackedVector2Array = _grid.get_hex_points_local(cell)
			if points.size() < 3:
				continue
			draw_colored_polygon(points, overlay_color)
			var border: PackedVector2Array = points.duplicate()
			border.append(points[0])
			draw_polyline(border, border_color, 1.0, true)
