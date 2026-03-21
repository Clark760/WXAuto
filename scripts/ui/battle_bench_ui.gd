extends ScrollContainer
class_name BattleBenchUI

# ===========================
# 备战席 UI（CanvasLayer）
# ===========================
# 设计目标：
# 1. 备战席完全处于 UI 坐标空间，不参与战场缩放与平移。
# 2. 负责 50 格槽位管理、显示与 3 合 1 升星逻辑。
# 3. 仅管理“角色节点引用 + UI 显示”，不直接决定战场部署规则。

signal bench_changed()
signal unit_star_upgraded(result_unit: Node, consumed_units: Array[Node], new_star: int)

@export var max_slots: int = 50
@export var slots_per_row: int = 10
@export var slot_size: Vector2 = Vector2(112, 136)
@export var slot_gap: float = 6.0
@export var grid_path: NodePath = NodePath("BenchGrid")
@export var auto_fit_columns: bool = true
@export var wheel_scroll_rows_per_notch: int = 1

var _slots: Array[Node] = []
var _slot_panels: Array[PanelContainer] = []
var _slot_icons: Array[ColorRect] = []
var _slot_name_labels: Array[Label] = []
var _slot_star_labels: Array[Label] = []
var _last_layout_size: Vector2 = Vector2(-1.0, -1.0)
var _forced_layout_width: float = -1.0

@onready var _grid: GridContainer = get_node_or_null(grid_path)


func _ready() -> void:
	if _grid == null:
		push_error("BattleBenchUI: 未找到 BenchGrid 节点，备战席初始化失败。")
		return
	initialize_slots(max_slots, slots_per_row)
	# 监听尺寸变化，保证备战区列数随面板宽度实时自适应。
	var resize_cb: Callable = Callable(self, "_on_bench_resized")
	if not is_connected("resized", resize_cb):
		connect("resized", resize_cb)
	call_deferred("refresh_adaptive_layout")


func _process(_delta: float) -> void:
	# 实时自适应兜底：
	# 某些布局链路下 Control.resized 可能触发时机滞后，
	# 因此每帧检测尺寸变化并按需重算列数，保证拖动窗口时立即生效。
	if size.is_equal_approx(_last_layout_size):
		return
	refresh_adaptive_layout()


func initialize_slots(total_slots: int, columns: int) -> void:
	max_slots = maxi(total_slots, 1)
	slots_per_row = maxi(columns, 1)
	_slots.resize(max_slots)
	for i in range(max_slots):
		_slots[i] = null

	_build_slot_controls()
	refresh_adaptive_layout()
	_refresh_all_slot_ui()
	emit_signal("bench_changed")


func set_layout_width(width: float) -> void:
	_forced_layout_width = maxf(width, 0.0)
	refresh_adaptive_layout()


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


func consume_wheel_input(button_index: int) -> bool:
	# 备战区滚轮滚动入口：
	# 1. 由上层战场脚本优先调用，阻止滚轮继续传递给地图缩放。
	# 2. 即使当前无需滚动（内容不足一屏），也返回 true，确保“地图不响应”。
	if button_index != MOUSE_BUTTON_WHEEL_UP and button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	var v_scroll: VScrollBar = get_v_scroll_bar()
	if v_scroll == null:
		return true
	var row_step: int = maxi(int(round(slot_size.y + slot_gap)), 24)
	var scroll_delta: int = row_step * maxi(wheel_scroll_rows_per_notch, 1)
	if button_index == MOUSE_BUTTON_WHEEL_UP:
		scroll_delta = -scroll_delta
	var max_scroll: int = maxi(int(ceil(v_scroll.max_value - v_scroll.page)), 0)
	scroll_vertical = clampi(scroll_vertical + scroll_delta, 0, max_scroll)
	return true


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
		slot_panel.size_flags_horizontal = 0
		slot_panel.size_flags_vertical = 0
		slot_panel.mouse_filter = Control.MOUSE_FILTER_PASS
		slot_panel.tooltip_text = "槽位 %d" % (i + 1)

		var content := VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.custom_minimum_size = slot_size
		content.add_theme_constant_override("separation", 1)

		var icon := ColorRect.new()
		# 槽位放大后，图标高度不再按宽度硬撑满，避免压缩名称与星级文本区域。
		var icon_height: float = clampf(slot_size.y * 0.55, 28.0, slot_size.x - 10.0)
		icon.custom_minimum_size = Vector2(slot_size.x - 10.0, icon_height)
		icon.color = Color(0.16, 0.19, 0.23, 0.65)

		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		name_label.add_theme_font_size_override("font_size", 22)
		name_label.text = "空"

		var star_label := Label.new()
		star_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		star_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		star_label.clip_text = true
		star_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		star_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		star_label.add_theme_font_size_override("font_size", 24)
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


func _on_bench_resized() -> void:
	refresh_adaptive_layout()


func refresh_adaptive_layout() -> void:
	_fit_columns_to_width()
	_last_layout_size = size


func _fit_columns_to_width() -> void:
	if not auto_fit_columns:
		return
	if _grid == null or not is_instance_valid(_grid):
		return
	if size.x <= 1.0:
		return
	# 列数自适应策略（宽高双约束）：
	# 1. 保持单格尺寸稳定，避免角色卡在不同分辨率下忽大忽小。
	# 2. 宽度上限：列数不能超过当前可用宽度可容纳的数量。
	# 3. 行数下限：默认至少按 2 行目标排布，避免“无论分辨率都退化为单行”。
	var visible_width: float = _forced_layout_width if _forced_layout_width > 0.0 else size.x
	var vertical_bar: VScrollBar = get_v_scroll_bar()
	if vertical_bar != null and vertical_bar.visible:
		visible_width -= vertical_bar.size.x
	# 预留少量安全边距，优先让卡片完整换行，避免行尾只显示半张。
	var available_width: float = maxf(visible_width - slot_gap * 2.0 - 20.0, slot_size.x)
	var cell_plus_gap: float = maxf(slot_size.x + slot_gap, 1.0)
	var max_columns_by_width: int = int(floor((available_width + slot_gap) / cell_plus_gap))
	max_columns_by_width = clampi(max_columns_by_width, 1, max_slots)

	var available_height: float = maxf(size.y - 4.0, slot_size.y)
	var row_plus_gap: float = maxf(slot_size.y + slot_gap, 1.0)
	var visible_rows: int = int(floor((available_height + slot_gap) / row_plus_gap))
	visible_rows = maxi(visible_rows, 1)
	var target_rows: int = maxi(visible_rows, 2)
	var max_columns_by_target_rows: int = int(ceil(float(max_slots) / float(target_rows)))
	max_columns_by_target_rows = clampi(max_columns_by_target_rows, 1, max_slots)

	var fit_columns: int = mini(max_columns_by_width, max_columns_by_target_rows)
	if fit_columns == slots_per_row and _grid.columns == fit_columns:
		return
	slots_per_row = fit_columns
	_grid.columns = fit_columns
	_grid.custom_minimum_size.x = fit_columns * slot_size.x + maxi(fit_columns - 1, 0) * slot_gap
	_grid.queue_sort()
	update_minimum_size()


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
	var grouped_slot_indices: Dictionary = {}
	# 只按槽位顺序做升星：最靠前保留并升星，后两个删除，不做整排重排。
	for slot_index in range(_slots.size()):
		var unit: Node = _slots[slot_index]
		if unit == null or not is_instance_valid(unit):
			continue
		var star: int = int(unit.get("star_level"))
		if star >= 3:
			continue
		var key: String = "%s:%d" % [str(unit.get("unit_id")), star]
		if not grouped_slot_indices.has(key):
			grouped_slot_indices[key] = []
		(grouped_slot_indices[key] as Array).append(slot_index)

	for key in grouped_slot_indices.keys():
		var slot_group: Array = grouped_slot_indices[key]
		if slot_group.size() < 3:
			continue

		var result_slot: int = int(slot_group[0])
		var consume_slot_a: int = int(slot_group[1])
		var consume_slot_b: int = int(slot_group[2])
		var result_unit: Node = _slots[result_slot]
		var consume_a: Node = _slots[consume_slot_a]
		var consume_b: Node = _slots[consume_slot_b]
		if result_unit == null or consume_a == null or consume_b == null:
			continue

		var consumed: Array[Node] = [consume_a, consume_b]
		_slots[consume_slot_a] = null
		_slots[consume_slot_b] = null
		for consumed_unit in consumed:
			if consumed_unit is CanvasItem:
				(consumed_unit as CanvasItem).visible = false

		result_unit.call("set_star_level", int(result_unit.get("star_level")) + 1)
		_prepare_unit_for_bench(result_unit, result_slot)
		_refresh_all_slot_ui()
		emit_signal("unit_star_upgraded", result_unit, consumed, int(result_unit.get("star_level")))
		emit_signal("bench_changed")
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
