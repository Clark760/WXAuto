extends Node2D

# ===========================
# 部署区覆盖层
# ===========================
# 说明：
# 1. 该层挂在 HexGrid 下，使用同一坐标空间绘制己方部署区高亮。
# 2. 仅负责视觉提示，不参与格子合法性判定。

@export var deploy_x_min: int = 0
@export var deploy_x_max: int = 15
@export var deploy_y_min: int = 0
@export var deploy_y_max: int = 15
@export var overlay_color: Color = Color(0.32, 0.46, 0.68, 0.18)
@export var border_color: Color = Color(0.62, 0.82, 1.0, 0.48)

# 覆盖层直接挂在 HexGrid 下，因此默认父节点就是绘制所需的棋盘引用。
@onready var _grid: Node = get_parent() as Node


# 进入场景后立即触发一次重绘，保证部署区高亮和当前 HexGrid 配置同步。
func _ready() -> void:
	queue_redraw()


# coordinator 或关卡加载更新部署区时，通过这个入口改矩形并刷新表现。
func set_deploy_zone_rect(x_min: int, x_max: int, y_min: int, y_max: int) -> void:
	deploy_x_min = x_min
	deploy_x_max = x_max
	deploy_y_min = y_min
	deploy_y_max = y_max
	queue_redraw()


# 绘制前统一做边界裁剪和顺序修正，避免坏配置把高亮画出棋盘外。
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
	# 配置允许外层传反向区间，这里统一修正顺序，避免绘制阶段再分支判断。
	if x_min > x_max:
		var sx: int = x_min
		x_min = x_max
		x_max = sx
	if y_min > y_max:
		var sy: int = y_min
		y_min = y_max
		y_max = sy

	# 每个格子的填充和描边都直接复用 HexGrid 提供的六边形顶点。
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
