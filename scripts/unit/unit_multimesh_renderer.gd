extends Node2D

# ===========================
# MultiMesh 批量渲染器（M1）
# ===========================
# 说明：
# 1. M1 阶段用于验证“同屏大量单位合批渲染”的基础能力。
# 2. 当前实现以单位位置生成实例矩阵，颜色按品质/星级编码。
# 3. 渲染器不会接管单位逻辑，仅做可视化层；单位本体仍保留以支持拖拽交互。

@export var marker_size: float = 10.0
@export var marker_alpha: float = 0.5

@onready var _multimesh_node: MultiMeshInstance2D = $MultiMeshInstance2D

var _tracked_units: Array[Node] = []


func _ready() -> void:
	_init_multimesh()


func set_units(units: Array[Node]) -> void:
	_tracked_units.clear()
	for unit in units:
		if unit != null:
			_tracked_units.append(unit)
	_rebuild_instances()


func _process(_delta: float) -> void:
	# 每帧只更新 transform/color，不重建实例数量，降低频繁分配开销。
	_update_instances()


func _init_multimesh() -> void:
	if _multimesh_node.multimesh == null:
		_multimesh_node.multimesh = MultiMesh.new()

	var mm: MultiMesh = _multimesh_node.multimesh
	# 关键：MultiMesh 渲染前必须有 mesh，否则会在渲染阶段报
	# `_render_batch: Condition "mesh.is_null()" is true.`
	if mm.mesh == null:
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		mm.mesh = quad

	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.instance_count = 0

	if _multimesh_node.texture == null:
		var image: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color(1, 1, 1, 1))
		_multimesh_node.texture = ImageTexture.create_from_image(image)


func _rebuild_instances() -> void:
	var mm: MultiMesh = _multimesh_node.multimesh
	if mm == null:
		return
	mm.instance_count = _tracked_units.size()
	_update_instances()


func _update_instances() -> void:
	var mm: MultiMesh = _multimesh_node.multimesh
	if mm == null:
		return
	if mm.instance_count != _tracked_units.size():
		mm.instance_count = _tracked_units.size()

	for i in range(_tracked_units.size()):
		var unit: Node = _tracked_units[i]
		if unit == null or not is_instance_valid(unit):
			mm.set_instance_transform_2d(i, Transform2D.IDENTITY)
			mm.set_instance_color(i, Color(0, 0, 0, 0))
			continue

		var unit_node: Node2D = unit as Node2D
		# 避免局部变量名与 Node2D.transform 属性重名，减少调试器告警噪音。
		var instance_transform := Transform2D(
			Vector2(marker_size, 0),
			Vector2(0, marker_size),
			unit_node.global_position
		)
		mm.set_instance_transform_2d(i, instance_transform)
		mm.set_instance_color(i, _build_color_for_unit(unit))


func _build_color_for_unit(unit: Node) -> Color:
	var quality: String = str(unit.get("quality"))
	var star_level: int = int(unit.get("star_level"))

	var base_color: Color = Color(1, 1, 1, marker_alpha)
	match quality:
		"white":
			base_color = Color(0.95, 0.95, 0.95, marker_alpha)
		"green":
			base_color = Color(0.55, 0.9, 0.58, marker_alpha)
		"blue":
			base_color = Color(0.5, 0.7, 0.95, marker_alpha)
		"purple":
			base_color = Color(0.8, 0.58, 0.95, marker_alpha)
		"orange":
			base_color = Color(1.0, 0.7, 0.35, marker_alpha)
		"red":
			base_color = Color(0.95, 0.35, 0.35, marker_alpha)
		_:
			base_color = Color(1, 1, 1, marker_alpha)

	# 星级越高，亮度越高，用于快速观测升星结果。
	var boost: float = 1.0 + float(star_level - 1) * 0.15
	return Color(
		clampf(base_color.r * boost, 0.0, 1.0),
		clampf(base_color.g * boost, 0.0, 1.0),
		clampf(base_color.b * boost, 0.0, 1.0),
		base_color.a
	)
