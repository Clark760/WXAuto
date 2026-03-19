extends ScrollContainer
class_name M2BenchUI

# ===========================
# M2 备战席 UI（CanvasLayer）
# ===========================
# 设计目标：
# 1. 备战席完全处于 UI 坐标空间，不参与战场缩放与平移。
# 2. 负责 50 格槽位管理、显示与 3 合 1 升星逻辑。
# 3. 仅管理“角色节点引用 + UI 显示”，不直接决定战场部署规则。

signal bench_changed()
signal unit_star_upgraded(result_unit: Node, consumed_units: Array[Node], new_star: int)

@export var max_slots: int = 50
@export var slots_per_row: int = 10
@export var slot_size: Vector2 = Vector2(56, 68)
@export var slot_gap: float = 6.0
@export var grid_path: NodePath = NodePath("BenchGrid")

var _slots: Array[Node] = []
var _slot_panels: Array[PanelContainer] = []
var _slot_icons: Array[ColorRect] = []
var _slot_name_labels: Array[Label] = []
var _slot_star_labels: Array[Label] = []

@onready var _grid: GridContainer = get_node_or_null(grid_path)


func _ready() -> void:
	if _grid == null:
		push_error("M2BenchUI: 未找到 BenchGrid 节点，备战席初始化失败。")
		return
	initialize_slots(max_slots, slots_per_row)


func initialize_slots(total_slots: int, columns: int) -> void:
	max_slots = maxi(total_slots, 1)
	slots_per_row = maxi(columns, 1)
	_slots.resize(max_slots)
	for i in range(max_slots):
		_slots[i] = null

	_build_slot_controls()
	_refresh_all_slot_ui()
	emit_signal("bench_changed")


func add_unit(unit: Node) -> bool:
	var slot_index: int = _first_empty_slot()
	if slot_index < 0:
		return false
	return add_unit_to_slot(unit, slot_index)


func add_unit_to_slot(unit: Node, slot_index: int, compact_after_add: bool = true) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not _is_slot_valid(slot_index):
		return false
	if _slots[slot_index] != null:
		return false

	_slots[slot_index] = unit
	_prepare_unit_for_bench(unit, slot_index)

	if compact_after_add:
		_compact_slots()
	_refresh_all_slot_ui()
	_try_star_upgrade_loop()
	emit_signal("bench_changed")
	return true


func remove_unit(unit: Node) -> bool:
	var slot_index: int = find_slot_of_unit(unit)
	if slot_index < 0:
		return false
	_slots[slot_index] = null
	_refresh_all_slot_ui()
	emit_signal("bench_changed")
	return true


func remove_unit_at(slot_index: int) -> Node:
	if not _is_slot_valid(slot_index):
		return null
	var unit: Node = _slots[slot_index]
	if unit == null:
		return null
	_slots[slot_index] = null
	_refresh_all_slot_ui()
	emit_signal("bench_changed")
	return unit


func move_unit_to_slot(unit: Node, target_slot: int) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not _is_slot_valid(target_slot):
		return false
	if _slots[target_slot] != null:
		return false

	var source_slot: int = find_slot_of_unit(unit)
	if source_slot < 0:
		return false

	_slots[source_slot] = null
	_slots[target_slot] = unit
	_prepare_unit_for_bench(unit, target_slot)
	_refresh_all_slot_ui()
	emit_signal("bench_changed")
	return true


func swap_slots(a: int, b: int) -> bool:
	if not _is_slot_valid(a) or not _is_slot_valid(b):
		return false
	if a == b:
		return true

	var tmp: Node = _slots[a]
	_slots[a] = _slots[b]
	_slots[b] = tmp

	if _slots[a] != null:
		_prepare_unit_for_bench(_slots[a], a)
	if _slots[b] != null:
		_prepare_unit_for_bench(_slots[b], b)

	_refresh_all_slot_ui()
	emit_signal("bench_changed")
	return true


func get_unit_at_slot(slot_index: int) -> Node:
	if not _is_slot_valid(slot_index):
		return null
	return _slots[slot_index]


func get_all_units() -> Array[Node]:
	var units: Array[Node] = []
	for unit in _slots:
		if unit != null and is_instance_valid(unit):
			units.append(unit)
	return units


func get_slot_count() -> int:
	return max_slots


func get_unit_count() -> int:
	var count: int = 0
	for unit in _slots:
		if unit != null and is_instance_valid(unit):
			count += 1
	return count


func find_slot_of_unit(unit: Node) -> int:
	for i in range(_slots.size()):
		if _slots[i] == unit:
			return i
	return -1


func is_screen_point_inside(screen_pos: Vector2) -> bool:
	return get_global_rect().has_point(screen_pos)


func get_slot_index_at_screen_pos(screen_pos: Vector2) -> int:
	for i in range(_slot_panels.size()):
		var panel: PanelContainer = _slot_panels[i]
		if panel == null:
			continue
		if panel.get_global_rect().has_point(screen_pos):
			return i
	return -1


func set_interactable(value: bool) -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS if value else Control.MOUSE_FILTER_IGNORE
	for panel in _slot_panels:
		if panel == null:
			continue
		panel.mouse_filter = Control.MOUSE_FILTER_PASS if value else Control.MOUSE_FILTER_IGNORE


func _build_slot_controls() -> void:
	for child in _grid.get_children():
		child.queue_free()

	_slot_panels.clear()
	_slot_icons.clear()
	_slot_name_labels.clear()
	_slot_star_labels.clear()

	_grid.columns = slots_per_row
	_grid.add_theme_constant_override("h_separation", int(slot_gap))
	_grid.add_theme_constant_override("v_separation", int(slot_gap))

	for i in range(max_slots):
		var slot_panel := PanelContainer.new()
		slot_panel.custom_minimum_size = slot_size
		slot_panel.mouse_filter = Control.MOUSE_FILTER_PASS
		slot_panel.tooltip_text = "槽位 %d" % (i + 1)

		var content := VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_theme_constant_override("separation", 1)

		var icon := ColorRect.new()
		icon.custom_minimum_size = Vector2(slot_size.x - 10.0, slot_size.x - 10.0)
		icon.color = Color(0.16, 0.19, 0.23, 0.65)

		var name_label := Label.new()
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", 11)
		name_label.text = "空"

		var star_label := Label.new()
		star_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		star_label.add_theme_font_size_override("font_size", 12)
		star_label.text = ""

		content.add_child(icon)
		content.add_child(name_label)
		content.add_child(star_label)
		slot_panel.add_child(content)
		_grid.add_child(slot_panel)

		_slot_panels.append(slot_panel)
		_slot_icons.append(icon)
		_slot_name_labels.append(name_label)
		_slot_star_labels.append(star_label)


func _refresh_all_slot_ui() -> void:
	for i in range(max_slots):
		var unit: Node = _slots[i]
		_refresh_single_slot_ui(i, unit)


func _refresh_single_slot_ui(index: int, unit: Node) -> void:
	if index < 0 or index >= _slot_panels.size():
		return

	var icon: ColorRect = _slot_icons[index]
	var name_label: Label = _slot_name_labels[index]
	var star_label: Label = _slot_star_labels[index]

	if unit == null or not is_instance_valid(unit):
		icon.color = Color(0.16, 0.19, 0.23, 0.65)
		name_label.text = "空"
		star_label.text = ""
		return

	name_label.text = str(unit.get("unit_name"))
	var star: int = int(unit.get("star_level"))
	star_label.text = "★".repeat(clampi(star, 1, 3))
	star_label.modulate = _star_to_color(star)
	icon.color = _quality_to_color(str(unit.get("quality")))


func _prepare_unit_for_bench(unit: Node, slot_index: int) -> void:
	# 备战席角色只作为数据存在，真实战场节点在部署时再显示。
	unit.call("set_on_bench_state", true, slot_index)
	if unit is CanvasItem:
		(unit as CanvasItem).visible = false


func _first_empty_slot() -> int:
	for i in range(_slots.size()):
		if _slots[i] == null:
			return i
	return -1


func _is_slot_valid(slot_index: int) -> bool:
	return slot_index >= 0 and slot_index < _slots.size()


func _compact_slots() -> void:
	var compacted: Array[Node] = []
	for unit in _slots:
		if unit != null and is_instance_valid(unit):
			compacted.append(unit)

	_slots.clear()
	_slots.resize(max_slots)
	for i in range(max_slots):
		_slots[i] = compacted[i] if i < compacted.size() else null

	for i in range(max_slots):
		var unit: Node = _slots[i]
		if unit == null:
			continue
		_prepare_unit_for_bench(unit, i)


func _try_star_upgrade_loop() -> void:
	while true:
		if not _try_star_merge_once():
			break


func _try_star_merge_once() -> bool:
	var grouped: Dictionary = {}
	for unit in get_all_units():
		var star: int = int(unit.get("star_level"))
		if star >= 3:
			continue
		var key: String = "%s:%d" % [str(unit.get("unit_id")), star]
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
		for consumed_unit in consumed:
			if consumed_unit is CanvasItem:
				(consumed_unit as CanvasItem).visible = false

		result_unit.call("set_star_level", int(result_unit.get("star_level")) + 1)
		_compact_slots()
		_refresh_all_slot_ui()
		emit_signal("unit_star_upgraded", result_unit, consumed, int(result_unit.get("star_level")))
		return true

	return false


func _quality_to_color(quality: String) -> Color:
	match quality:
		"white":
			return Color(0.78, 0.8, 0.82, 0.95)
		"green":
			return Color(0.42, 0.68, 0.42, 0.95)
		"blue":
			return Color(0.32, 0.52, 0.8, 0.95)
		"purple":
			return Color(0.54, 0.38, 0.72, 0.95)
		"orange":
			return Color(0.76, 0.48, 0.2, 0.95)
		"red":
			return Color(0.78, 0.24, 0.24, 0.95)
		_:
			return Color(0.5, 0.5, 0.5, 0.95)


func _star_to_color(star: int) -> Color:
	match star:
		1:
			return Color(0.94, 0.94, 0.94, 1.0)
		2:
			return Color(1.0, 0.86, 0.35, 1.0)
		3:
			return Color(1.0, 0.42, 0.2, 1.0)
		_:
			return Color(1, 1, 1, 1)
