extends ScrollContainer
class_name BattleBenchUI

const BATTLE_BENCH_SLOT_SCENE: PackedScene = preload(
	"res://scenes/ui/battle_bench_slot.tscn"
)

# ===========================
# 备战席 UI
# ===========================
# 设计目标：
# 1. 备战席完全处于 UI 坐标空间，不参与战场缩放与平移。
# 2. 负责 50 格槽位管理、显示与 3 合 1 升星逻辑。
# 3. 只管理“角色节点引用 + UI 显示”，不直接决定战场部署规则。
# 4. 槽位可见结构统一来自子场景，不再由代码硬拼控件树。
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
var _slot_views: Array = []
var _last_layout_size: Vector2 = Vector2(-1.0, -1.0)
var _forced_layout_width: float = -1.0

@onready var _grid: GridContainer = get_node_or_null(grid_path)


# 初始化固定节点并拉起第一批槽位子场景。
func _ready() -> void:
	if _grid == null:
		push_error("BattleBenchUI: missing BenchGrid node.")
		return
	initialize_slots(max_slots, slots_per_row)
	var resize_cb: Callable = Callable(self, "_on_bench_resized")
	if not is_connected("resized", resize_cb):
		connect("resized", resize_cb)
	call_deferred("refresh_adaptive_layout")


# 运行时持续检测尺寸变化，保证窗口拖动时列数自适应立即生效。
func _process(_delta: float) -> void:
	if size.is_equal_approx(_last_layout_size):
		return
	refresh_adaptive_layout()


# 初始化槽位容器，先清状态，再重建子场景并刷新 UI。
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


# 外层可显式指定布局宽度，供底栏收展和容器联动复用。
func set_layout_width(width: float) -> void:
	_forced_layout_width = maxf(width, 0.0)
	refresh_adaptive_layout()


# 追加单位时始终落到第一个空槽位，不做自动重排。
func add_unit(unit: Node) -> bool:
	var slot_index: int = _first_empty_slot()
	if slot_index < 0:
		return false
	return add_unit_to_slot(unit, slot_index, false)


# 只允许把单位放进空槽位，放入后统一刷新和尝试升星。
func add_unit_to_slot(unit: Node, slot_index: int, _compact_after_add: bool = false) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	if not _is_slot_valid(slot_index):
		return false
	if _slots[slot_index] != null:
		return false

	_slots[slot_index] = unit
	_prepare_unit_for_bench(unit, slot_index)
	_refresh_single_slot_ui(slot_index, unit)
	_try_star_upgrade_loop()
	emit_signal("bench_changed")
	return true


# 按单位引用删除槽位内容，不做任何自动补位。
func remove_unit(unit: Node) -> bool:
	var slot_index: int = find_slot_of_unit(unit)
	if slot_index < 0:
		return false
	_slots[slot_index] = null
	_refresh_single_slot_ui(slot_index, null)
	emit_signal("bench_changed")
	return true


# 按槽位取出单位，供拖拽起手复用。
func remove_unit_at(slot_index: int) -> Node:
	if not _is_slot_valid(slot_index):
		return null
	var unit: Node = _slots[slot_index]
	if unit == null:
		return null
	_slots[slot_index] = null
	_refresh_single_slot_ui(slot_index, null)
	emit_signal("bench_changed")
	return unit


# 单位换槽只做引用搬运，不改变其他槽位顺序。
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
	_refresh_single_slot_ui(source_slot, null)
	_refresh_single_slot_ui(target_slot, unit)
	emit_signal("bench_changed")
	return true


# 槽位交换只交换引用，不触发整表重排。
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

	_refresh_single_slot_ui(a, _slots[a])
	_refresh_single_slot_ui(b, _slots[b])
	emit_signal("bench_changed")
	return true


# 读取指定槽位当前单位。
func get_unit_at_slot(slot_index: int) -> Node:
	if not _is_slot_valid(slot_index):
		return null
	return _slots[slot_index]


# 返回所有仍有效的备战席单位。
func get_all_units() -> Array[Node]:
	var units: Array[Node] = []
	for unit in _slots:
		if unit != null and is_instance_valid(unit):
			units.append(unit)
	return units


# 槽位总数对外读取入口。
func get_slot_count() -> int:
	return max_slots


# 当前备战席单位数量。
func get_unit_count() -> int:
	var count: int = 0
	for unit in _slots:
		if unit != null and is_instance_valid(unit):
			count += 1
	return count


# 通过单位引用反查所在槽位。
func find_slot_of_unit(unit: Node) -> int:
	for i in range(_slots.size()):
		if _slots[i] == unit:
			return i
	return -1


# 备战席区域命中判定，供外层输入优先级复用。
func is_screen_point_inside(screen_pos: Vector2) -> bool:
	return get_global_rect().has_point(screen_pos)


# 通过子场景全局矩形反查当前屏幕点命中的槽位。
func get_slot_index_at_screen_pos(screen_pos: Vector2) -> int:
	for i in range(_slot_views.size()):
		var slot_view = _slot_views[i]
		if slot_view == null:
			continue
		if slot_view.get_global_rect().has_point(screen_pos):
			return i
	return -1


# 交互开关统一下发到根容器和全部槽位子场景。
func set_interactable(value: bool) -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS if value else Control.MOUSE_FILTER_IGNORE
	for slot_view in _slot_views:
		if slot_view == null:
			continue
		slot_view.set_interactable(value)


# 备战区滚轮输入优先消费，避免事件继续传给世界缩放。
func consume_wheel_input(button_index: int) -> bool:
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


# 批量实例化槽位子场景，固定结构来自 scenes/ui，不再手写控件树。
func _build_slot_controls() -> void:
	for child in _grid.get_children():
		child.queue_free()

	_slot_views.clear()
	_grid.columns = slots_per_row
	_grid.add_theme_constant_override("h_separation", int(slot_gap))
	_grid.add_theme_constant_override("v_separation", int(slot_gap))

	for i in range(max_slots):
		var slot_view = BATTLE_BENCH_SLOT_SCENE.instantiate()
		slot_view.configure_slot(i, slot_size, mouse_filter != Control.MOUSE_FILTER_IGNORE)
		_grid.add_child(slot_view)
		_slot_views.append(slot_view)


# resized 信号统一只触发布局刷新。
func _on_bench_resized() -> void:
	refresh_adaptive_layout()


# 每次尺寸变化后都重新计算列数并缓存最后尺寸。
func refresh_adaptive_layout() -> void:
	_fit_columns_to_width()
	_last_layout_size = size


# 列数自适应策略同时考虑可用宽度和目标行数，不让槽位退化成单行超长列表。
func _fit_columns_to_width() -> void:
	if not auto_fit_columns:
		return
	if _grid == null or not is_instance_valid(_grid):
		return
	if size.x <= 1.0:
		return

	var visible_width: float = _forced_layout_width if _forced_layout_width > 0.0 else size.x
	var vertical_bar: VScrollBar = get_v_scroll_bar()
	if vertical_bar != null and vertical_bar.visible:
		visible_width -= vertical_bar.size.x
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


# 批量刷新全部槽位显示。
func _refresh_all_slot_ui() -> void:
	for i in range(max_slots):
		_refresh_single_slot_ui(i, _slots[i])


# 单槽位刷新只把颜色、名称和星级投影到槽位子场景。
func _refresh_single_slot_ui(index: int, unit: Node) -> void:
	if index < 0 or index >= _slot_views.size():
		return
	var slot_view = _slot_views[index]
	if slot_view == null:
		return

	if unit == null or not is_instance_valid(unit):
		slot_view.apply_empty_state()
		return

	var star: int = int(unit.get("star_level"))
	slot_view.apply_unit_state(
		str(unit.get("unit_name")),
		star,
		_quality_to_color(str(unit.get("quality"))),
		_star_to_color(star)
	)


# 备战席单位只作为数据引用存在，真实战场节点在部署时再显示。
func _prepare_unit_for_bench(unit: Node, slot_index: int) -> void:
	unit.call("set_on_bench_state", true, slot_index)
	if unit is CanvasItem:
		(unit as CanvasItem).visible = false


# 返回第一个空槽位索引，满时返回 -1。
func _first_empty_slot() -> int:
	for i in range(_slots.size()):
		if _slots[i] == null:
			return i
	return -1


# 槽位索引合法性检查统一收口。
func _is_slot_valid(slot_index: int) -> bool:
	return slot_index >= 0 and slot_index < _slots.size()


# 历史接口保留，但按当前规则不做任何自动紧缩。
func _compact_slots() -> void:
	return


# 升星循环一直执行到当前已无新合成为止。
func _try_star_upgrade_loop() -> bool:
	var merged_any: bool = false
	while true:
		if not _try_star_merge_once():
			break
		merged_any = true
	return merged_any


# 只按槽位顺序做 3 合 1：保留最前一个，消耗后两个，不做整表重排。
func _try_star_merge_once() -> bool:
	var grouped_slot_indices: Dictionary = {}
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
		_refresh_single_slot_ui(result_slot, result_unit)
		_refresh_single_slot_ui(consume_slot_a, null)
		_refresh_single_slot_ui(consume_slot_b, null)
		emit_signal("unit_star_upgraded", result_unit, consumed, int(result_unit.get("star_level")))
		return true

	return false


# 品质色统一收口，避免槽位视图自己维护颜色表。
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
		_:
			return Color(0.5, 0.5, 0.5, 0.95)


# 星级颜色统一收口，保证备战席和其他投影口径一致。
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
