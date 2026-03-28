extends RefCounted

# 战场世界输入支撑
# 说明：
# 1. 集中承接世界层输入分流、镜头缩放/平移、拖拽起手阈值和拖拽高亮绘制。
# 2. 这里不决定 HUD 具体展示，只把点击/hover/拖拽结果回调给 world controller。
# 3. 这样可以把 world controller 收缩成装配与委托入口，输入细节单独静态定位。
#
# 约束口径：
# 1. 输入支撑只负责输入序列和镜头状态，不负责商店、奖励或关卡推进。
# 2. 任何世界点击命中后的展示动作，仍然必须回到 world controller 再转给 presenter。
# 3. 拖拽开始、拖拽结束和拖拽目标刷新仍然走既有 drag controller，不在这里复制规则。
# 4. 这里保留准备期与战斗期的阶段判断，只服务输入可用性，不承接阶段编排。
#
# 迁移目的：
# 1. 把超长的 world controller 切成“装配入口”和“输入细节”两层。
# 2. 让后续输入冲突回归可以直接定位到这一份支撑脚本，而不是回到根控制器整文件排查。
# 3. 保持现有输入契约不变，只搬运实现细节，不放松任何 guard 口径。

var _owner: Node = null
var _scene_root: Node = null
var _refs = null
var _state = null

var _stage_preparation: int = 0
var _stage_combat: int = 1
var _click_drag_threshold: float = 8.0
var _world_zoom_min: float = 0.4
var _world_zoom_max: float = 2.5
var _world_zoom_step: float = 0.1
var _world_pan_speed: float = 540.0


# ===========================
# 装配入口
# ===========================
# 绑定 world controller、场景引用表和会话状态，后续所有输入都只从这里读写。
func initialize(
	owner: Node,
	scene_root: Node,
	refs,
	state,
	stage_preparation: int,
	stage_combat: int,
	click_drag_threshold: float,
	world_zoom_min: float,
	world_zoom_max: float,
	world_zoom_step: float,
	world_pan_speed: float
) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_stage_preparation = stage_preparation
	_stage_combat = stage_combat
	_click_drag_threshold = click_drag_threshold
	_world_zoom_min = world_zoom_min
	_world_zoom_max = world_zoom_max
	_world_zoom_step = world_zoom_step
	_world_pan_speed = world_pan_speed


# ===========================
# 顶层输入入口
# ===========================
# 根场景把 `_input` 统一转发到这里，世界输入优先级只在这一处维护。
func handle_input(event: InputEvent) -> void:
	if _state == null or _scene_root == null:
		return

	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if consume_bench_wheel_input(mouse_button):
			_scene_root.get_viewport().set_input_as_handled()
			return
		if handle_world_view_input(event):
			_scene_root.get_viewport().set_input_as_handled()
			return
		if mouse_button.button_index != MOUSE_BUTTON_LEFT:
			return

		if mouse_button.pressed:
			_handle_left_button_pressed(mouse_button)
			return
		_handle_left_button_released(mouse_button)
		return

	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		if handle_world_view_input(event):
			_scene_root.get_viewport().set_input_as_handled()
			return
		_handle_mouse_motion(motion)


# 根场景把 `_unhandled_input` 转发到这里，世界快捷键不再散回入口脚本。
func handle_unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_SPACE:
		reset_view()
		_scene_root.get_viewport().set_input_as_handled()


# ===========================
# 逐帧与绘制
# ===========================
# 逐帧驱动世界视角和 hover 检测，避免把这些状态散回根场景。
func process_world(delta: float) -> void:
	if _state == null:
		return
	update_world_pan_by_keyboard(delta)
	if _owner != null:
		_owner._update_hover(delta)
	if _state.stage == _stage_combat:
		_state.combat_elapsed += delta


# 拖拽高亮仍由根节点绘制，但几何和颜色判断统一由输入支撑给出。
func draw_overlay(canvas: Node2D) -> void:
	if canvas == null or _state == null:
		return
	if _state.dragging_unit == null or _state.drag_target_cell.x < 0:
		return
	if _refs == null or _refs.hex_grid == null:
		return

	var fill: Color = (
		Color(0.3, 0.85, 0.45, 0.24)
		if _state.drag_target_valid
		else Color(0.9, 0.26, 0.26, 0.24)
	)
	var border_color: Color = (
		Color(0.6, 1.0, 0.7, 0.9)
		if _state.drag_target_valid
		else Color(1.0, 0.48, 0.48, 0.9)
	)
	var local_points: PackedVector2Array = _refs.hex_grid.get_hex_points_local(_state.drag_target_cell)
	if local_points.size() < 3:
		return

	var screen_points := PackedVector2Array()
	for point in local_points:
		var world_local: Vector2 = _refs.hex_grid.transform * point
		screen_points.append(_refs.world_container.to_global(world_local))
	canvas.draw_colored_polygon(screen_points, fill)
	var border: PackedVector2Array = screen_points.duplicate()
	border.append(screen_points[0])
	canvas.draw_polyline(border, border_color, 2.0, true)


# ===========================
# 镜头与视图输入
# ===========================
# 视角缩放和平移的输入优先级高于准备期拖拽，是世界层的统一入口。
func handle_world_view_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP and mouse_button.pressed:
			zoom_at(mouse_button.position, 1.0 + _world_zoom_step)
			return true
		if mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN and mouse_button.pressed:
			zoom_at(mouse_button.position, 1.0 - _world_zoom_step)
			return true
		if mouse_button.button_index == MOUSE_BUTTON_RIGHT:
			_state.is_panning = mouse_button.pressed
			return true
	if event is InputEventMouseMotion and _state.is_panning:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		pan(motion.relative)
		return true
	return false


# 备战席滚轮要先消费，避免同一滚轮事件同时触发棋盘缩放。
func consume_bench_wheel_input(mouse_button: InputEventMouseButton) -> bool:
	if mouse_button == null or not mouse_button.pressed:
		return false
	if mouse_button.button_index != MOUSE_BUTTON_WHEEL_UP and mouse_button.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if _refs == null or _refs.bench_ui == null or not is_instance_valid(_refs.bench_ui):
		return false

	var inside_bench: bool = false
	if _refs.bench_ui.has_method("is_screen_point_inside"):
		inside_bench = bool(_refs.bench_ui.is_screen_point_inside(mouse_button.position))
	if not inside_bench and _refs.bottom_panel != null:
		var bottom_panel: Control = _refs.bottom_panel as Control
		if bottom_panel != null and bottom_panel.visible:
			inside_bench = bottom_panel.get_global_rect().has_point(mouse_button.position)
	if not inside_bench:
		return false
	if _refs.bench_ui.has_method("consume_wheel_input"):
		return bool(_refs.bench_ui.consume_wheel_input(mouse_button.button_index))
	return true


# 键盘平移沿用旧战场 WASD 口径，但状态统一写入 session state。
func update_world_pan_by_keyboard(delta: float) -> void:
	var direction: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_A):
		direction.x += 1.0
	if Input.is_key_pressed(KEY_D):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_W):
		direction.y += 1.0
	if Input.is_key_pressed(KEY_S):
		direction.y -= 1.0
	if direction.is_zero_approx():
		return
	pan(direction.normalized() * _world_pan_speed * delta)


# 世界变换只作用于 WorldContainer，禁止对子节点分别做位移和缩放。
func apply_world_transform() -> void:
	if _refs == null or _state == null:
		return
	_refs.world_container.position = _state.world_offset
	_refs.world_container.scale = Vector2.ONE * _state.world_zoom
	if _state.dragging_unit != null:
		var overlay_canvas: CanvasItem = _scene_root as CanvasItem
		if overlay_canvas != null:
			overlay_canvas.queue_redraw()


# 以鼠标位置为锚点缩放，保持缩放前后的光标落点稳定。
func zoom_at(screen_pos: Vector2, factor: float) -> void:
	if _state == null:
		return
	var old_zoom: float = _state.world_zoom
	var next_zoom: float = clampf(old_zoom * factor, _world_zoom_min, _world_zoom_max)
	if is_equal_approx(next_zoom, old_zoom):
		return
	var world_point: Vector2 = (screen_pos - _state.world_offset) / maxf(old_zoom, 0.0001)
	_state.world_zoom = next_zoom
	_state.world_offset = screen_pos - world_point * _state.world_zoom
	apply_world_transform()


# 平移直接累加世界偏移，并立即刷新 WorldContainer 变换。
func pan(relative: Vector2) -> void:
	if _state == null:
		return
	_state.world_offset += relative
	apply_world_transform()


# 重置视角时统一恢复缩放、偏移和右键平移状态。
func reset_view() -> void:
	if _state == null:
		return
	_state.world_zoom = 1.0
	_state.world_offset = Vector2.ZERO
	_state.is_panning = false
	apply_world_transform()


# ===========================
# 点击与拖拽分流
# ===========================
# 左键按下时只记录准备期世界输入来源，点击和拖拽在这里分流。
func _handle_left_button_pressed(mouse_button: InputEventMouseButton) -> void:
	_state.left_click_pending = true
	_state.left_press_pos = mouse_button.position
	_state.bench_press_slot = -1
	_state.world_press_unit = null
	_state.world_press_cell = Vector2i(-999, -999)

	if _state.stage != _stage_preparation:
		return
	if _refs.bench_ui != null and _refs.bench_ui.is_screen_point_inside(mouse_button.position):
		var slot: int = _refs.bench_ui.get_slot_index_at_screen_pos(mouse_button.position)
		if slot >= 0 and _refs.bench_ui.get_unit_at_slot(slot) != null:
			_state.bench_press_slot = slot
			_state.bench_press_pos = mouse_button.position
			_scene_root.get_viewport().set_input_as_handled()
			return

	var world_pos_press: Vector2 = _owner._screen_to_world(mouse_button.position)
	var world_unit: Node = _owner._pick_deployed_ally_unit_at(world_pos_press)
	if world_unit != null:
		_state.world_press_unit = world_unit
		_state.world_press_pos = mouse_button.position
		_state.world_press_cell = world_unit.get("deployed_cell")
		_scene_root.get_viewport().set_input_as_handled()


# 左键释放时统一结算拖拽、棋盘点击和备战席点击的后续动作。
func _handle_left_button_released(mouse_button: InputEventMouseButton) -> void:
	if _state.stage == _stage_preparation and _state.dragging_unit != null:
		_owner._try_end_drag(mouse_button.position)
		_owner._reset_press_state()
		_scene_root.get_viewport().set_input_as_handled()
		return

	if _state.stage == _stage_preparation and _state.bench_press_slot >= 0 and _state.dragging_unit == null:
		var slot_index: int = _state.bench_press_slot
		var click_like_bench: bool = (
			mouse_button.position.distance_to(_state.bench_press_pos) <= _click_drag_threshold
		)
		_owner._reset_press_state()
		if click_like_bench:
			_owner._notify_bench_slot_clicked(slot_index)
			_scene_root.get_viewport().set_input_as_handled()
		return

	if _state.stage == _stage_preparation and _state.world_press_unit != null and _state.dragging_unit == null:
		var clicked_unit: Node = _state.world_press_unit
		var click_like_world: bool = (
			mouse_button.position.distance_to(_state.world_press_pos) <= _click_drag_threshold
		)
		_state.world_press_unit = null
		_state.world_press_cell = Vector2i(-999, -999)
		_state.left_click_pending = false
		if click_like_world and _owner._is_valid_unit(clicked_unit):
			_owner._notify_world_unit_clicked(clicked_unit, mouse_button.position)
			_scene_root.get_viewport().set_input_as_handled()
		return

	var click_like: bool = (
		_state.left_click_pending
		and mouse_button.position.distance_to(_state.left_press_pos) <= _click_drag_threshold
	)
	_state.left_click_pending = false
	if click_like and _state.dragging_unit == null:
		_owner._try_notify_click(mouse_button.position)


# 鼠标移动既要处理拖拽阈值，也要处理拖拽中的预览与目标刷新。
func _handle_mouse_motion(motion: InputEventMouseMotion) -> void:
	if _state.left_click_pending and motion.position.distance_to(_state.left_press_pos) > _click_drag_threshold:
		_state.left_click_pending = false

	if _state.bench_press_slot >= 0 and _state.stage == _stage_preparation and _state.dragging_unit == null:
		if motion.position.distance_to(_state.bench_press_pos) > _click_drag_threshold:
			var bench_unit: Node = _refs.bench_ui.remove_unit_at(_state.bench_press_slot)
			var origin_slot: int = _state.bench_press_slot
			_state.bench_press_slot = -1
			if bench_unit != null:
				_owner._begin_drag(bench_unit, "bench", origin_slot, Vector2i(-999, -999), motion.position)
				_scene_root.get_viewport().set_input_as_handled()
		return

	if _state.world_press_unit != null and _state.stage == _stage_preparation and _state.dragging_unit == null:
		if motion.position.distance_to(_state.world_press_pos) > _click_drag_threshold:
			var pressed_unit: Node = _state.world_press_unit
			var origin_cell: Vector2i = _state.world_press_cell
			_state.world_press_unit = null
			_state.world_press_cell = Vector2i(-999, -999)
			if _owner._is_valid_unit(pressed_unit):
				_owner._remove_ally_mapping(pressed_unit)
				_owner._begin_drag(pressed_unit, "battlefield", -1, origin_cell, motion.position)
				_scene_root.get_viewport().set_input_as_handled()
		return

	if _state.stage == _stage_preparation and _state.dragging_unit != null:
		_owner._update_drag_preview(motion.position)
		_owner._update_drag_target(motion.position)
		_scene_root.get_viewport().set_input_as_handled()
