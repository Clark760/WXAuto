extends Node2D

# ===========================
# MultiMesh 批量渲染器
# ===========================
# 优化要点：
# 1. 将实例更新频率降到固定间隔（默认 10fps），避免每渲染帧全量遍历。
# 2. 颜色在重建实例时缓存，热路径仅更新 transform。
# 3. 保留“无 mesh 时自动填充 QuadMesh”防御逻辑，避免渲染报错。

@export var marker_size: float = 10.0
@export var marker_alpha: float = 0.5
@export var update_interval: float = 0.1

@onready var _multimesh_node: MultiMeshInstance2D = $MultiMeshInstance2D

var _tracked_units: Array[Node] = []
var _cached_colors: PackedColorArray = PackedColorArray()
var _update_accum: float = 0.0


func _ready() -> void:
	_init_multimesh()


func set_units(units: Array[Node]) -> void:
	_tracked_units.clear()
	for unit in units:
		if unit != null:
			_tracked_units.append(unit)
	_rebuild_instances()


func _process(delta: float) -> void:
	if _tracked_units.is_empty():
		return
	_update_accum += delta
	if _update_accum < maxf(update_interval, 0.01):
		return
	_update_accum = 0.0
	_update_instances()


func _init_multimesh() -> void:
	if _multimesh_node.multimesh == null:
		_multimesh_node.multimesh = MultiMesh.new()

	var mm: MultiMesh = _multimesh_node.multimesh
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

	var count: int = _tracked_units.size()
	mm.instance_count = count
	_cached_colors.resize(count)

	for i in range(count):
		var unit: Node = _tracked_units[i]
		if unit == null or not is_instance_valid(unit):
			_cached_colors[i] = Color(0, 0, 0, 0)
		else:
			_cached_colors[i] = _build_color_for_unit(unit)

	_update_accum = 0.0
	_update_instances()


func _update_instances() -> void:
	var mm: MultiMesh = _multimesh_node.multimesh
	if mm == null:
		return
	if mm.instance_count != _tracked_units.size():
		_rebuild_instances()
		return

	for i in range(_tracked_units.size()):
		var unit: Node = _tracked_units[i]
		if unit == null or not is_instance_valid(unit):
			mm.set_instance_transform_2d(i, Transform2D.IDENTITY)
			mm.set_instance_color(i, Color(0, 0, 0, 0))
			continue

		var unit_node: Node2D = unit as Node2D
		if unit_node == null:
			mm.set_instance_transform_2d(i, Transform2D.IDENTITY)
			mm.set_instance_color(i, Color(0, 0, 0, 0))
			continue

		var instance_transform := Transform2D(
			Vector2(marker_size, 0),
			Vector2(0, marker_size),
			unit_node.position
		)
		mm.set_instance_transform_2d(i, instance_transform)
		mm.set_instance_color(i, _cached_colors[i] if i < _cached_colors.size() else _build_color_for_unit(unit))


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
		_:
			base_color = Color(1, 1, 1, marker_alpha)

	# 星级越高亮度越高，便于观察升星链路。
	var boost: float = 1.0 + float(star_level - 1) * 0.15
	return Color(
		clampf(base_color.r * boost, 0.0, 1.0),
		clampf(base_color.g * boost, 0.0, 1.0),
		clampf(base_color.b * boost, 0.0, 1.0),
		base_color.a
	)
