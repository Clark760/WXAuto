extends RefCounted
class_name SpatialHash

# ===========================
# 空间哈希分区（Spatial Hash）
# ===========================
# 使用场景：
# 1. 大规模单位寻敌与邻近查询（替代 O(n^2) 全量遍历）。
# 2. 将连续世界坐标映射到固定网格桶（cell），仅查询相邻桶。
#
# 注意：
# - 该类只管理“对象 ID 与坐标”关系，不绑定具体 Node。
# - 业务层可用 unit_id / instance_id 作为 object_id。

var cell_size: float = 64.0

# 桶结构：cell(Vector2i) -> Array[int(object_id)]
var _buckets: Dictionary = {}

# 快速反查：object_id -> cell(Vector2i)
var _object_cells: Dictionary = {}

# 位置缓存：object_id -> world_position(Vector2)
var _object_positions: Dictionary = {}


func _init(custom_cell_size: float = 64.0) -> void:
	cell_size = max(custom_cell_size, 1.0)


func clear() -> void:
	_buckets.clear()
	_object_cells.clear()
	_object_positions.clear()


func insert(object_id: int, world_position: Vector2) -> void:
	# 同 ID 重复插入时，先移除旧记录，保证桶索引一致。
	if _object_cells.has(object_id):
		remove(object_id)

	var cell: Vector2i = _to_cell(world_position)
	if not _buckets.has(cell):
		_buckets[cell] = []

	var bucket: Array = _buckets[cell]
	bucket.append(object_id)
	_buckets[cell] = bucket

	_object_cells[object_id] = cell
	_object_positions[object_id] = world_position


func remove(object_id: int) -> void:
	if not _object_cells.has(object_id):
		return

	var old_cell: Vector2i = _object_cells[object_id]
	if _buckets.has(old_cell):
		var bucket: Array = _buckets[old_cell]
		bucket.erase(object_id)
		if bucket.is_empty():
			_buckets.erase(old_cell)
		else:
			_buckets[old_cell] = bucket

	_object_cells.erase(object_id)
	_object_positions.erase(object_id)


func update(object_id: int, new_world_position: Vector2) -> void:
	if not _object_cells.has(object_id):
		insert(object_id, new_world_position)
		return

	var old_cell: Vector2i = _object_cells[object_id]
	var new_cell: Vector2i = _to_cell(new_world_position)

	# 仍在同一桶时，只更新坐标缓存，避免无意义移桶操作。
	if old_cell == new_cell:
		_object_positions[object_id] = new_world_position
		return

	remove(object_id)
	insert(object_id, new_world_position)


func query_radius(center: Vector2, radius: float) -> Array[int]:
	var output: Array[int] = []
	query_radius_into(center, radius, output)
	return output


func query_radius_into(center: Vector2, radius: float, output: Array[int]) -> void:
	output.clear()
	var min_cell: Vector2i = _to_cell(center - Vector2(radius, radius))
	var max_cell: Vector2i = _to_cell(center + Vector2(radius, radius))
	var radius_sq: float = radius * radius

	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			var cell: Vector2i = Vector2i(x, y)
			if not _buckets.has(cell):
				continue
			var bucket: Array = _buckets[cell]
			for object_id in bucket:
				var pos: Vector2 = _object_positions.get(object_id, Vector2.ZERO)
				if pos.distance_squared_to(center) <= radius_sq:
					output.append(int(object_id))


func query_aabb(rect: Rect2) -> Array[int]:
	var output: Array[int] = []
	query_aabb_into(rect, output)
	return output


func query_aabb_into(rect: Rect2, output: Array[int]) -> void:
	output.clear()
	var min_cell: Vector2i = _to_cell(rect.position)
	var max_cell: Vector2i = _to_cell(rect.position + rect.size)

	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			var cell: Vector2i = Vector2i(x, y)
			if not _buckets.has(cell):
				continue
			var bucket: Array = _buckets[cell]
			for object_id in bucket:
				var pos: Vector2 = _object_positions.get(object_id, Vector2.ZERO)
				if rect.has_point(pos):
					output.append(int(object_id))


func get_bucket_count() -> int:
	return _buckets.size()


func get_object_count() -> int:
	return _object_cells.size()


func _to_cell(world_position: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(world_position.x / cell_size)),
		int(floor(world_position.y / cell_size))
	)
