extends Node2D

# ===========================
# 备战席（M1）
# ===========================
# 功能：
# 1. 管理最多 20 个待部署角色。
# 2. 提供插入、移除、拖拽拾取、自动排布。
# 3. 实现 3 合 1 升星规则（1->2, 2->3）。

signal bench_changed()
signal unit_added(unit: Node)
signal unit_removed(unit: Node)
signal unit_star_upgraded(result_unit: Node, consumed_units: Array[Node], new_star: int)

@export var max_slots: int = 50
@export var slots_per_row: int = 10
@export var slot_size: Vector2 = Vector2(48, 48)
@export var slot_gap: float = 8.0
@export var local_origin: Vector2 = Vector2(80, 620)
@export var auto_layout_to_viewport: bool = true
@export var edge_margin: float = 20.0

var _slots: Array[Node] = []


func _ready() -> void:
	_slots.resize(max_slots)
	for i in range(max_slots):
		_slots[i] = null
	_bind_viewport_resize()
	_apply_layout_from_viewport()
	queue_redraw()


func _draw() -> void:
	# 使用简单矩形绘制 20 格备战席，便于 M1 阶段直接验证拖拽行为。
	for i in range(max_slots):
		var slot_rect: Rect2 = _slot_rect(i)
		draw_rect(slot_rect, Color(0.12, 0.15, 0.18, 0.45), true)
		draw_rect(slot_rect, Color(0.65, 0.72, 0.78, 0.85), false, 1.5)


func add_unit(unit: Node) -> bool:
	var slot_index: int = _first_empty_slot()
	if slot_index < 0:
		return false

	_slots[slot_index] = unit
	_place_unit_to_slot(unit, slot_index)
	_try_star_upgrade_loop()
	bench_changed.emit()
	unit_added.emit(unit)
	return true


func remove_unit(unit: Node) -> bool:
	var slot_index: int = find_slot_of_unit(unit)
	if slot_index < 0:
		return false
	_slots[slot_index] = null
	bench_changed.emit()
	unit_removed.emit(unit)
	return true


func find_slot_of_unit(unit: Node) -> int:
	for i in range(_slots.size()):
		if _slots[i] == unit:
			return i
	return -1


func pick_unit_at_world(world_position: Vector2) -> Node:
	# 逆序遍历保证后放入/后显示角色优先被拾取，符合拖拽直觉。
	for i in range(_slots.size() - 1, -1, -1):
		var unit: Node = _slots[i]
		if unit == null:
			continue
		if bool(unit.call("contains_point", world_position)):
			return unit
	return null


func get_all_units() -> Array[Node]:
	var units: Array[Node] = []
	for unit in _slots:
		if unit != null:
			units.append(unit)
	return units


func slot_world_position(slot_index: int) -> Vector2:
	var rect: Rect2 = _slot_rect(slot_index)
	return rect.position + rect.size * 0.5


func reflow() -> void:
	for i in range(_slots.size()):
		var unit: Node = _slots[i]
		if unit == null:
			continue
		_place_unit_to_slot(unit, i)
	bench_changed.emit()


func _place_unit_to_slot(unit: Node, slot_index: int) -> void:
	if unit is Node2D:
		var unit_node: Node2D = unit as Node2D
		unit_node.global_position = to_global(slot_world_position(slot_index))
	unit.call("set_on_bench_state", true, slot_index)


func _first_empty_slot() -> int:
	for i in range(_slots.size()):
		if _slots[i] == null:
			return i
	return -1


func _slot_rect(slot_index: int) -> Rect2:
	# 使用 floori 规避“整数除法小数被丢弃”的调试告警。
	var row: int = floori(float(slot_index) / float(slots_per_row))
	var col: int = slot_index % slots_per_row
	var x: float = local_origin.x + float(col) * (slot_size.x + slot_gap)
	var y: float = local_origin.y + float(row) * (slot_size.y + slot_gap)
	return Rect2(Vector2(x, y), slot_size)


func _bind_viewport_resize() -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var cb: Callable = Callable(self, "_on_viewport_size_changed")
	if not viewport.is_connected("size_changed", cb):
		viewport.connect("size_changed", cb)


func _on_viewport_size_changed() -> void:
	_apply_layout_from_viewport()


func _apply_layout_from_viewport() -> void:
	if not auto_layout_to_viewport:
		return

	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var size: Vector2 = viewport.get_visible_rect().size
	if size.x <= 1.0 or size.y <= 1.0:
		return

	var rows: int = int(ceil(float(max_slots) / float(maxi(slots_per_row, 1))))
	var total_width: float = float(slots_per_row) * slot_size.x + float(maxi(slots_per_row - 1, 0)) * slot_gap
	var total_height: float = float(rows) * slot_size.y + float(maxi(rows - 1, 0)) * slot_gap

	local_origin = Vector2(
		maxf((size.x - total_width) * 0.5, edge_margin),
		maxf(size.y - total_height - edge_margin, edge_margin)
	)

	reflow()
	queue_redraw()


func _try_star_upgrade_loop() -> void:
	# 合成规则（总纲）：
	# 3 个同名 1 星 -> 1 个 2 星
	# 3 个同名 2 星 -> 1 个 3 星
	while true:
		var merged: bool = _try_merge_once()
		if not merged:
			break


func _try_merge_once() -> bool:
	var grouped: Dictionary = {} # key = "unit_id:star" -> Array[Node]

	for unit in get_all_units():
		var unit_id: String = str(unit.get("unit_id"))
		var star: int = int(unit.get("star_level"))
		if star >= 3:
			continue
		var key: String = "%s:%d" % [unit_id, star]
		if not grouped.has(key):
			grouped[key] = []
		(grouped[key] as Array).append(unit)

	for key in grouped.keys():
		var group: Array = grouped[key]
		if group.size() < 3:
			continue

		var result_unit: Node = group[0]
		var consume_a: Node = group[1]
		var consume_b: Node = group[2]

		var consumed: Array[Node] = [consume_a, consume_b]
		remove_unit(consume_a)
		remove_unit(consume_b)

		# 先把被消耗单位立即隐藏，避免在信号回调释放前出现“残影仍在”的错觉。
		for consumed_unit in consumed:
			if consumed_unit is CanvasItem:
				(consumed_unit as CanvasItem).visible = false

		result_unit.call("set_star_level", int(result_unit.get("star_level")) + 1)
		_compact_slots()
		reflow()

		unit_star_upgraded.emit(result_unit, consumed, int(result_unit.get("star_level")))
		return true

	return false


func _compact_slots() -> void:
	# 将非空单位向前压缩，消除中间空洞，保证 UI 排列与逻辑分组更稳定。
	var compacted: Array[Node] = []
	for unit in _slots:
		if unit != null:
			compacted.append(unit)

	_slots.clear()
	_slots.resize(max_slots)
	for i in range(max_slots):
		_slots[i] = compacted[i] if i < compacted.size() else null
