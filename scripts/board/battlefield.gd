extends Node2D

# ===========================
# 战场管理（M1 角色核心原型）
# ===========================
# M1 目标对齐：
# 1. 从 JSON 加载角色并放入备战席。
# 2. 支持拖拽角色部署到六边形网格。
# 3. 支持从战场拖回备战席。
# 4. 支持备战席 3 合 1 升星。
# 5. 更新 MultiMesh 批量渲染验证同屏渲染路径。

@export var initial_bench_count: int = 14

@onready var hex_grid: Node2D = $HexGrid
@onready var unit_layer: Node2D = $UnitLayer
@onready var bench: Node2D = $Bench
@onready var unit_factory: Node = $UnitFactory
@onready var multimesh_renderer: Node2D = $UnitMultiMeshRenderer
@onready var info_label: Label = $CanvasLayer/InfoLabel
@onready var tip_label: Label = $CanvasLayer/TipLabel

var _deployed_units: Dictionary = {} # "q,r" -> unit
var _dragging_unit: Node = null
var _drag_from_bench: bool = false
var _drag_origin_cell: Vector2i = Vector2i(-999, -999)


func _ready() -> void:
	_connect_signals()
	_set_preparation_phase()
	_spawn_initial_bench_units()
	_refresh_info()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		_handle_key_input(event as InputEventKey)
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)


func _handle_key_input(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return

	# F3: 回到 M0 主场景，便于快速对照验证。
	if event.keycode == KEY_F3:
		var event_bus: Node = _get_root_node("EventBus")
		if event_bus != null:
			event_bus.call("emit_scene_change_requested", "res://scenes/main/main.tscn")

	# F4: 重新补充一批角色到备战席，快速压力测试拖拽和升星。
	if event.keycode == KEY_F4:
		_spawn_random_units_to_bench(6)
		_refresh_info()


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	var world_pos: Vector2 = get_global_mouse_position()

	if event.pressed:
		_try_begin_drag(world_pos)
	else:
		_try_end_drag(world_pos)


func _handle_mouse_motion(_event: InputEventMouseMotion) -> void:
	if _dragging_unit == null:
		return
	_dragging_unit.call("update_drag", get_global_mouse_position())


func _try_begin_drag(world_pos: Vector2) -> void:
	if _dragging_unit != null:
		return

	var bench_unit: Node = bench.call("pick_unit_at_world", world_pos)
	if bench_unit != null:
		if bool(bench.call("remove_unit", bench_unit)):
			_dragging_unit = bench_unit
			_drag_from_bench = true
			_drag_origin_cell = Vector2i(-999, -999)
			_dragging_unit.call("begin_drag")
			_refresh_info()
		return

	var deployed_unit: Node = _pick_deployed_unit_at(world_pos)
	if deployed_unit != null:
		_dragging_unit = deployed_unit
		_drag_from_bench = false
		_drag_origin_cell = deployed_unit.get("deployed_cell")
		_remove_deployed_mapping(deployed_unit)
		_dragging_unit.call("begin_drag")
		_refresh_multimesh()
		_refresh_info()


func _try_end_drag(world_pos: Vector2) -> void:
	if _dragging_unit == null:
		return

	_dragging_unit.call("end_drag", world_pos)

	var drop_cell: Vector2i = hex_grid.call("world_to_axial", world_pos)
	if _can_deploy_to_cell(drop_cell):
		_deploy_unit_to_cell(_dragging_unit, drop_cell)
		_clear_drag_state()
		_refresh_info()
		return

	# 非法落点时：
	# - 来自备战席：尝试放回备战席（满了则原地保留并提示）。
	# - 来自战场：优先回备战席；若失败，退回原战场格。
	var put_back_ok: bool = bool(bench.call("add_unit", _dragging_unit))
	if not put_back_ok and not _drag_from_bench and _drag_origin_cell.x > -900:
		_deploy_unit_to_cell(_dragging_unit, _drag_origin_cell)

	_clear_drag_state()
	_refresh_info()


func _deploy_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	var cell_key: String = _cell_key(cell)
	if _deployed_units.has(cell_key):
		return

	_deployed_units[cell_key] = unit
	unit.set("deployed_cell", cell)
	unit.call("set_on_bench_state", false, -1)
	unit.global_position = hex_grid.call("axial_to_world", cell)
	unit.call("play_anim_state", 0, {}) # IDLE
	_refresh_multimesh()


func _remove_deployed_mapping(unit: Node) -> void:
	var target_key: String = ""
	for cell_key in _deployed_units.keys():
		if _deployed_units[cell_key] == unit:
			target_key = str(cell_key)
			break
	if not target_key.is_empty():
		_deployed_units.erase(target_key)


func _pick_deployed_unit_at(world_pos: Vector2) -> Node:
	for unit in _deployed_units.values():
		if unit == null:
			continue
		if bool(unit.call("contains_point", world_pos)):
			return unit
	return null


func _can_deploy_to_cell(cell: Vector2i) -> bool:
	if not bool(hex_grid.call("is_inside_grid", cell)):
		return false
	return not _deployed_units.has(_cell_key(cell))


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


func _clear_drag_state() -> void:
	_dragging_unit = null
	_drag_from_bench = false
	_drag_origin_cell = Vector2i(-999, -999)


func _spawn_initial_bench_units() -> void:
	_spawn_random_units_to_bench(initial_bench_count)


func _spawn_random_units_to_bench(count: int) -> void:
	var unit_ids: Array[String] = unit_factory.call("get_unit_ids")
	if unit_ids.is_empty():
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for i in range(count):
		var idx: int = rng.randi_range(0, unit_ids.size() - 1)
		var unit_id: String = unit_ids[idx]
		var unit_node: Node = unit_factory.call("acquire_unit", unit_id, -1, unit_layer)
		if unit_node == null:
			continue

		var added: bool = bool(bench.call("add_unit", unit_node))
		if not added:
			unit_factory.call("release_unit", unit_node)
			break


func _connect_signals() -> void:
	var cb_upgrade: Callable = Callable(self, "_on_unit_star_upgraded")
	if not bench.is_connected("unit_star_upgraded", cb_upgrade):
		bench.connect("unit_star_upgraded", cb_upgrade)

	var cb_bench_changed: Callable = Callable(self, "_on_bench_changed")
	if not bench.is_connected("bench_changed", cb_bench_changed):
		bench.connect("bench_changed", cb_bench_changed)


func _on_unit_star_upgraded(result_unit: Node, consumed_units: Array[Node], _new_star: int) -> void:
	# 合成时的被消耗单位回收到对象池，避免无意义销毁。
	for consumed in consumed_units:
		unit_factory.call("release_unit", consumed)
	result_unit.call("play_anim_state", 3, {}) # SKILL 动画作为合成反馈
	_refresh_info()


func _on_bench_changed() -> void:
	_refresh_info()


func _refresh_multimesh() -> void:
	var deployed_list: Array[Node] = []
	for unit in _deployed_units.values():
		if unit != null:
			deployed_list.append(unit)
	multimesh_renderer.call("set_units", deployed_list)


func _refresh_info() -> void:
	var bench_units_variant: Variant = bench.call("get_all_units")
	var bench_count: int = 0
	if bench_units_variant is Array:
		bench_count = (bench_units_variant as Array).size()
	var bench_capacity: int = int(bench.get("max_slots"))
	var deployed_count: int = _deployed_units.size()
	var phase_name: String = "PREPARATION"

	var game_manager: Node = _get_root_node("GameManager")
	if game_manager != null:
		phase_name = str(game_manager.call("get_phase_name", int(game_manager.get("current_phase"))))

	var lines: Array[String] = []
	lines.append("M1 角色核心系统验证场景")
	lines.append("当前阶段: %s" % phase_name)
	lines.append("备战席人数: %d / %d" % [bench_count, bench_capacity])
	lines.append("已部署人数: %d" % deployed_count)
	lines.append("提示：同名同星 3 个会自动升星")

	info_label.text = "\n".join(lines)
	tip_label.text = "操作：鼠标左键拖拽部署/回收 | F4补充随机角色 | F3返回主场景"


func _set_preparation_phase() -> void:
	var game_manager: Node = _get_root_node("GameManager")
	if game_manager != null:
		# GamePhase 枚举定义在 GameManager 内部，M1 直接使用已约定值：
		# BOOT=0, MAIN_MENU=1, PREPARATION=2
		game_manager.call("set_phase", 2)


func _get_root_node(node_name: String) -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(node_name)
