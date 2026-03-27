extends Node
class_name BattlefieldWorldController

# ===========================
# 战场世界控制器
# ===========================
# 说明：
# 1. 承接拖拽部署、镜头缩放/平移、hover、点击与棋盘自适应。
# 2. 根场景只把输入和绘制转发到这里，不再自己保存世界交互私有状态。
#
# Batch 2 职责边界：
# 1. 这里只处理世界交互，不处理商店、奖励、关卡推进或重开战场。
# 2. 这里只处理点击和 hover 的“命中判定”，不直接绘制详情或 tooltip。
# 3. 这里只处理底栏展开对棋盘的影响，不处理底栏内部控件的数据投影。
# 4. 这里只处理拖拽和部署，不处理装备卡、功法卡等 UI 卡片拖拽。
# 5. 这里只处理世界输入优先级，不处理战斗日志、商店日志或结果面板文案。
# 6. 开战和结算编排留给 coordinator，详情与 tooltip 留给 presenter。
# 7. 这样拆开后，世界职责线才能从文件结构和场景树静态定位。
#
# 输入优先级：
# 1. 备战席滚轮优先于世界缩放。
# 2. 右键平移优先于准备期拖拽阈值判断。
# 3. 拖拽中的鼠标移动优先刷新预览和落点。
# 4. 点击到可交互 UI 时，不再当作世界点击处理。
# 5. 准备期才允许友军拖拽部署。
# 6. 战斗期和结果期仍允许世界视角移动与缩放。
#
# 状态口径：
# 1. 拖拽态全部写入 session state。
# 2. 视角缩放和平移全部写入 session state。
# 3. hover 候选、延迟和 tooltip 显隐也全部写入 session state。
# 4. 底栏展开态写入 session state，供 renderer 计算棋盘可用高度。
# 5. 部署映射只读写 session state，不再落回根场景私有字段。
# 6. 单位映射缓存仍写在单位 meta 上，但统一通过 world controller / deploy manager 管。
#
# 迁移备忘：
# 1. 旧链路里世界交互主要散在 battlefield_runtime 和 battlefield_ui 两层。
# 2. 现在先把世界交互移到这里，HUD 具体表现留给后续批次。
# 3. 这意味着 Batch 2 可以先把“点击命中”与“详情展示”解耦。
# 4. presenter 当前只提供占位入口，不代表它已经完成 HUD 迁移。
# 5. 同理，coordinator 当前还没承接开战和结算，不代表世界层要代管这些流程。
# 6. 世界控制器只需要把自己的边界站稳，后续批次才能继续往前推。
# 7. 如果这里再次开始读取商店面板、奖励面板或结果面板的业务数据，就说明又偏离了。
# 8. 如果这里再次开始拼装战斗用例、关卡推进或 reload，也说明又偏离了。
# 9. 因此这里宁可多写清楚边界，也不接受“先混着跑通再说”的回退。

enum Stage { PREPARATION, COMBAT, RESULT } # 世界层只根据阶段切换交互性与布局。

const CLICK_DRAG_THRESHOLD: float = 8.0 # 点击和拖拽的分界阈值。
const INVALID_CELL: Vector2i = Vector2i(-999, -999) # 无效格哨兵值。
const TEAM_ALLY: int = 1 # 己方队伍标识。
const TEAM_ENEMY: int = 2 # 敌方队伍标识。

@export var bench_slot_count: int = 50 # 备战席槽位总数。
@export var bench_columns: int = 10 # 备战席每行列数。
@export var top_reserved_height: float = 64.0 # 顶栏保留高度。
@export var bottom_reserved_preparation: float = 250.0 # 备战期底栏保留高度。
@export var bottom_reserved_collapsed: float = 54.0 # 底栏收起时保留高度。
@export var board_margin: float = 20.0 # 棋盘安全边距。
@export var min_hex_size: float = 10.0 # 棋格最小尺寸。
@export var max_hex_size: float = 24.0 # 棋格最大尺寸。
@export var world_zoom_min: float = 0.4 # 世界缩放下限。
@export var world_zoom_max: float = 2.5 # 世界缩放上限。
@export var world_zoom_step: float = 0.1 # 鼠标滚轮单次缩放倍率。
@export var world_pan_speed: float = 540.0 # 键盘平移速度。
@export var unit_visual_scale_multiplier: float = 0.5 # 单位视觉缩放系数。

var _scene_root: Node = null # 根场景入口。
var _refs: Node = null # 场景引用表。
var _state: RefCounted = null # 会话状态表。
var _initialized: bool = false # 世界层装配是否完成。
var _signals_connected: bool = false # 世界层信号是否已收口。
var _bottom_tween: Tween = null # 底栏开合动画句柄。

var _unit_deploy_manager: Node = null # 部署规则协作者。
var _drag_controller: Node = null # 世界拖拽协作者。
var _battlefield_renderer: Node = null # 世界渲染协作者。


# 按固定顺序装配世界控制器，避免运行时节点初始化顺序漂移。
# 先装 runtime 协作者，再写默认态，最后连信号，后续排查更容易定位责任边界。
func initialize(
	scene_root: Node,
	refs: Node,
	state: RefCounted
) -> void:
	_scene_root = scene_root
	_refs = refs
	_state = state
	_unit_deploy_manager = _refs.runtime_unit_deploy_manager
	_drag_controller = _refs.runtime_drag_controller
	_battlefield_renderer = _refs.runtime_battlefield_renderer

	_initialize_runtime_collaborators()
	_initialize_scene_defaults()
	_connect_signals()
	_bind_runtime_dependencies()
	_set_stage(Stage.PREPARATION)
	_on_viewport_size_changed()
	_apply_world_transform()
	_refresh_multimesh()
	_refresh_all_ui()
	_initialized = (
		_scene_root != null
		and _refs != null
		and _state != null
		and _refs.has_required_scene_nodes()
		and _refs.has_required_runtime_nodes()
		and _runtime_collaborators_initialized()
	)


# 返回基础初始化状态，供根场景和 smoke test 读取。
func is_initialized() -> bool:
	return _initialized


# 根场景把 `_input` 统一转发到这里，世界输入优先级只在这一处维护。
# 左键、滚轮、右键平移都在这里分流，避免旧入口脚本继续偷接输入。
func handle_input(event: InputEvent) -> void:
	if _state == null:
		return

	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if _consume_bench_wheel_input(mouse_button):
			_scene_root.get_viewport().set_input_as_handled()
			return
		if _handle_world_view_input(event):
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
		if _handle_world_view_input(event):
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
		_reset_view()
		_scene_root.get_viewport().set_input_as_handled()


# 逐帧驱动世界视角和 hover 检测，避免把这些状态放回根场景。
# combat_elapsed 也在这里累加，是因为世界层最清楚战斗期是否仍在运行视角逻辑。
func process_world(delta: float) -> void:
	if _state == null:
		return
	_update_world_pan_by_keyboard(delta)
	_update_hover(delta)
	if int(_state.stage) == Stage.COMBAT:
		_state.combat_elapsed += delta


# 拖拽高亮仍由根节点绘制，但具体几何和颜色判断由世界控制器给出。
func draw_overlay(canvas: Node2D) -> void:
	if canvas == null or _state == null:
		return
	if _state.dragging_unit == null or _state.drag_target_cell.x < 0:
		return
	var hex_grid: Node = _refs.hex_grid
	if hex_grid == null:
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
	var local_points: PackedVector2Array = hex_grid.get_hex_points_local(_state.drag_target_cell)
	if local_points.size() < 3:
		return

	var screen_points := PackedVector2Array()
	for point in local_points:
		var world_local: Vector2 = hex_grid.transform * point
		screen_points.append(_refs.world_container.to_global(world_local))
	canvas.draw_colored_polygon(screen_points, fill)
	var border: PackedVector2Array = screen_points.duplicate()
	border.append(screen_points[0])
	canvas.draw_polyline(border, border_color, 2.0, true)


# 对外暴露阶段切换入口，后续给 coordinator 复用同一世界层口径。
func set_stage(next_stage: int) -> void:
	_set_stage(next_stage)


# coordinator 在关卡切换或奖励落位后，需要显式要求世界层重算布局和单位表现。
func refresh_world_layout() -> void:
	_refit_hex_grid()
	_refresh_deployed_positions()
	_apply_visual_to_all_units()
	_refresh_multimesh()
	_refresh_all_ui()
	_request_drag_overlay_redraw(true)
# 离开结果阶段前，统一把仍存活单位恢复到待机状态，避免胜利动作残留。
func reset_all_units_to_idle() -> void:
	var all_units: Array[Node] = []
	for unit in _state.ally_deployed.values():
		if _is_valid_unit(unit):
			all_units.append(unit)
	for unit in _state.enemy_deployed.values():
		if _is_valid_unit(unit):
			all_units.append(unit)
	for unit in all_units:
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat != null:
			var combat_alive: Variant = combat.get("is_alive")
			if combat_alive is bool and not combat_alive:
				continue
		var unit_api: Variant = unit
		if unit.has_method("reset_visual_transform"):
			unit_api.reset_visual_transform()
		if unit.has_method("play_anim_state"):
			unit_api.play_anim_state(0, {})
# 所有 runtime 协作者都必须走 initialize(refs, state, delegate) 显式注入。
func _initialize_runtime_collaborators() -> void:
	if _unit_deploy_manager != null and _unit_deploy_manager.has_method("initialize"):
		_unit_deploy_manager.initialize(_refs, _state, self)
	if _drag_controller != null and _drag_controller.has_method("initialize"):
		_drag_controller.initialize(_refs, _state, self)
	if _battlefield_renderer != null and _battlefield_renderer.has_method("initialize"):
		_battlefield_renderer.initialize(_refs, _state, self)


# 新入口在这里写入世界默认态，不允许根场景重新持有这些字段。
func _initialize_scene_defaults() -> void:
	if _refs.bench_ui != null and _refs.bench_ui.has_method("initialize_slots"):
		_refs.bench_ui.initialize_slots(bench_slot_count, bench_columns)
	_state.world_zoom = 1.0
	_state.world_offset = Vector2.ZERO
	_state.is_panning = false
	_state.bottom_expanded = true
	_state.drag_target_cell = INVALID_CELL
	_state.drag_target_valid = false


# 视口、底栏和备战席信号都在 world controller 内集中连接。
func _connect_signals() -> void:
	if _signals_connected:
		return
	var viewport: Viewport = _scene_root.get_viewport()
	if viewport != null:
		var resize_cb: Callable = Callable(self, "_on_viewport_size_changed")
		if not viewport.is_connected("size_changed", resize_cb):
			viewport.connect("size_changed", resize_cb)
	if _refs.toggle_button != null:
		var toggle_cb: Callable = Callable(self, "_on_toggle_bottom_pressed")
		if not _refs.toggle_button.is_connected("pressed", toggle_cb):
			_refs.toggle_button.connect("pressed", toggle_cb)
	if _refs.bench_ui != null and _refs.bench_ui.has_signal("bench_changed"):
		var bench_cb: Callable = Callable(self, "_on_bench_changed")
		if not _refs.bench_ui.is_connected("bench_changed", bench_cb):
			_refs.bench_ui.connect("bench_changed", bench_cb)
	_signals_connected = true


# 世界层只绑定战斗运行时依赖，不在这里承接开战和结算编排。
func _bind_runtime_dependencies() -> void:
	if _refs.combat_manager != null and _refs.combat_manager.has_method("configure_dependencies"):
		_refs.combat_manager.configure_dependencies(_refs.hex_grid, _refs.vfx_factory)
	if _refs.unit_augment_manager != null and _refs.unit_augment_manager.has_method("bind_combat_context"):
		_refs.unit_augment_manager.bind_combat_context(
			_refs.combat_manager,
			_refs.hex_grid,
			_refs.vfx_factory
		)


# 左键按下时只记录准备期世界输入来源，点击和拖拽在这里分流。
# 这里只记来源，不立即启动拖拽，能让点击和拖拽共享同一阈值判断。
func _handle_left_button_pressed(mouse_button: InputEventMouseButton) -> void:
	_state.left_click_pending = true
	_state.left_press_pos = mouse_button.position
	_state.bench_press_slot = -1
	_state.world_press_unit = null
	_state.world_press_cell = INVALID_CELL

	if int(_state.stage) != Stage.PREPARATION:
		return
	if _refs.bench_ui != null and _refs.bench_ui.is_screen_point_inside(mouse_button.position):
		var slot: int = _refs.bench_ui.get_slot_index_at_screen_pos(mouse_button.position)
		if slot >= 0 and _refs.bench_ui.get_unit_at_slot(slot) != null:
			_state.bench_press_slot = slot
			_state.bench_press_pos = mouse_button.position
			_scene_root.get_viewport().set_input_as_handled()
			return

	var world_pos_press: Vector2 = _screen_to_world(mouse_button.position)
	var world_unit: Node = _pick_deployed_ally_unit_at(world_pos_press)
	if world_unit != null:
		_state.world_press_unit = world_unit
		_state.world_press_pos = mouse_button.position
		_state.world_press_cell = world_unit.get("deployed_cell")
		_scene_root.get_viewport().set_input_as_handled()


# 左键释放时统一结算拖拽、棋盘点击和备战席点击的后续动作。
# 先处理拖拽再处理点击，避免一次释放同时触发拖放和详情点击。
func _handle_left_button_released(mouse_button: InputEventMouseButton) -> void:
	if int(_state.stage) == Stage.PREPARATION and _state.dragging_unit != null:
		_try_end_drag(mouse_button.position)
		_reset_press_state()
		_scene_root.get_viewport().set_input_as_handled()
		return

	if int(_state.stage) == Stage.PREPARATION and _state.bench_press_slot >= 0 and _state.dragging_unit == null:
		var slot_index: int = _state.bench_press_slot
		var click_like_bench: bool = mouse_button.position.distance_to(_state.bench_press_pos) <= CLICK_DRAG_THRESHOLD
		_reset_press_state()
		if click_like_bench:
			_notify_bench_slot_clicked(slot_index)
			_scene_root.get_viewport().set_input_as_handled()
		return

	if int(_state.stage) == Stage.PREPARATION and _state.world_press_unit != null and _state.dragging_unit == null:
		var clicked_unit: Node = _state.world_press_unit
		var click_like_world: bool = mouse_button.position.distance_to(_state.world_press_pos) <= CLICK_DRAG_THRESHOLD
		_state.world_press_unit = null
		_state.world_press_cell = INVALID_CELL
		_state.left_click_pending = false
		if click_like_world and _is_valid_unit(clicked_unit):
			_notify_world_unit_clicked(clicked_unit, mouse_button.position)
			_scene_root.get_viewport().set_input_as_handled()
		return

	var click_like: bool = (
		_state.left_click_pending
		and mouse_button.position.distance_to(_state.left_press_pos) <= CLICK_DRAG_THRESHOLD
	)
	_state.left_click_pending = false
	if click_like and _state.dragging_unit == null:
		_try_notify_click(mouse_button.position)


# 鼠标移动既要处理拖拽阈值，也要处理拖拽中的预览与目标刷新。
# bench/world 两类起手都走同一阈值，保证玩家感受到的拖拽手感一致。
func _handle_mouse_motion(motion: InputEventMouseMotion) -> void:
	if _state.left_click_pending and motion.position.distance_to(_state.left_press_pos) > CLICK_DRAG_THRESHOLD:
		_state.left_click_pending = false

	if _state.bench_press_slot >= 0 and int(_state.stage) == Stage.PREPARATION and _state.dragging_unit == null:
		if motion.position.distance_to(_state.bench_press_pos) > CLICK_DRAG_THRESHOLD:
			var bench_unit: Node = _refs.bench_ui.remove_unit_at(_state.bench_press_slot)
			var origin_slot: int = _state.bench_press_slot
			_state.bench_press_slot = -1
			if bench_unit != null:
				_begin_drag(bench_unit, "bench", origin_slot, INVALID_CELL, motion.position)
				_scene_root.get_viewport().set_input_as_handled()
		return

	if _state.world_press_unit != null and int(_state.stage) == Stage.PREPARATION and _state.dragging_unit == null:
		if motion.position.distance_to(_state.world_press_pos) > CLICK_DRAG_THRESHOLD:
			var pressed_unit: Node = _state.world_press_unit
			var origin_cell: Vector2i = _state.world_press_cell
			_state.world_press_unit = null
			_state.world_press_cell = INVALID_CELL
			if _is_valid_unit(pressed_unit):
				_remove_ally_mapping(pressed_unit)
				_begin_drag(pressed_unit, "battlefield", -1, origin_cell, motion.position)
				_scene_root.get_viewport().set_input_as_handled()
		return

	if int(_state.stage) == Stage.PREPARATION and _state.dragging_unit != null:
		_update_drag_preview(motion.position)
		_update_drag_target(motion.position)
		_scene_root.get_viewport().set_input_as_handled()


# 视角缩放和平移的输入优先级高于准备期拖拽，是世界层的统一入口。
# 右键平移在任意阶段都可用，所以不能把这套逻辑藏在 preparation 分支里。
func _handle_world_view_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP and mouse_button.pressed:
			_zoom_at(mouse_button.position, 1.0 + world_zoom_step)
			return true
		if mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN and mouse_button.pressed:
			_zoom_at(mouse_button.position, 1.0 - world_zoom_step)
			return true
		if mouse_button.button_index == MOUSE_BUTTON_RIGHT:
			_state.is_panning = mouse_button.pressed
			return true
	if event is InputEventMouseMotion and _state.is_panning:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_pan(motion.relative)
		return true
	return false


# 备战席滚轮要先消费，避免同一滚轮事件同时触发棋盘缩放。
func _consume_bench_wheel_input(mouse_button: InputEventMouseButton) -> bool:
	if mouse_button == null or not mouse_button.pressed:
		return false
	if mouse_button.button_index != MOUSE_BUTTON_WHEEL_UP and mouse_button.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if _refs.bench_ui == null or not is_instance_valid(_refs.bench_ui):
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
func _update_world_pan_by_keyboard(delta: float) -> void:
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
	_pan(direction.normalized() * world_pan_speed * delta)


# 世界变换只作用于 WorldContainer，禁止对子节点分别做位移和缩放。
func _apply_world_transform() -> void:
	_refs.world_container.position = _state.world_offset
	_refs.world_container.scale = Vector2.ONE * _state.world_zoom
	if _state.dragging_unit != null:
		_scene_root.queue_redraw()


# 以鼠标位置为锚点缩放，保持缩放前后的光标落点稳定。
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var old_zoom: float = _state.world_zoom
	var next_zoom: float = clampf(old_zoom * factor, world_zoom_min, world_zoom_max)
	if is_equal_approx(next_zoom, old_zoom):
		return
	var world_point: Vector2 = (screen_pos - _state.world_offset) / maxf(old_zoom, 0.0001)
	_state.world_zoom = next_zoom
	_state.world_offset = screen_pos - world_point * _state.world_zoom
	_apply_world_transform()


# 平移直接累加世界偏移，并立即刷新 WorldContainer 变换。
func _pan(relative: Vector2) -> void:
	_state.world_offset += relative
	_apply_world_transform()


# 重置视角时统一恢复缩放、偏移和右键平移状态。
func _reset_view() -> void:
	_state.world_zoom = 1.0
	_state.world_offset = Vector2.ZERO
	_state.is_panning = false
	_apply_world_transform()


# 对 drag controller 的入口封装留在这里，根场景不直接碰 runtime 节点。
func _try_begin_drag(screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.try_begin_drag(screen_pos)


# 这里统一把拖拽开始请求下发给 runtime drag controller。
func _begin_drag(
	unit: Node,
	origin_kind: String,
	origin_slot: int,
	origin_cell: Vector2i,
	screen_pos: Vector2
) -> void:
	if _drag_controller != null:
		_drag_controller.begin_drag(unit, origin_kind, origin_slot, origin_cell, screen_pos)


# 鼠标释放后的拖拽结束也统一走 drag controller，避免落点逻辑重复。
func _try_end_drag(screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.try_end_drag(screen_pos)


# 保留 finish 包装口，方便后续批次从 world controller 统一收口拖拽结束。
func _finish_drag() -> void:
	if _drag_controller != null:
		_drag_controller.finish_drag()


# 拖拽预览位置仍由 world controller 决定，但具体 UI 节点写入交给 HUD。
func _update_drag_preview(screen_pos: Vector2) -> void:
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("update_drag_preview_position"):
		hud_presenter.update_drag_preview_position(screen_pos)


# 拖拽预览显隐统一交给 HUD facade，世界层只声明状态变化。
func _set_drag_preview_visible(visible: bool) -> void:
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("set_drag_preview_visible"):
		hud_presenter.set_drag_preview_visible(visible)


# 拖拽目标刷新统一交给 drag controller，避免 world controller 自己重写判定。
func _update_drag_target(screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.update_drag_target(screen_pos)


# 拖拽预览卡数据现在统一由 HUD facade 投影，world controller 只提供单位快照。
func _update_drag_preview_data(unit: Node) -> void:
	if unit == null:
		return
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("set_drag_preview_unit"):
		hud_presenter.set_drag_preview_unit(unit)


# 保留获取落点的统一包装口，方便后续测试和批次迁移共用。
func _get_drop_target(screen_mouse: Vector2) -> Dictionary:
	if _drag_controller != null:
		return _drag_controller.get_drop_target(screen_mouse)
	return {"type": "invalid"}


# 备战席落位包装口保留在 world controller，避免根场景重新长出落位逻辑。
func _drop_to_bench_slot(unit: Node, slot_index: int) -> bool:
	if _drag_controller != null:
		return bool(_drag_controller.drop_to_bench_slot(unit, slot_index))
	return false


# 还原拖拽来源也通过包装口暴露，后续批次可在这里加监控或校验。
func _restore_drag_origin() -> void:
	if _drag_controller != null:
		_drag_controller.restore_drag_origin()


# 对外暴露拖拽来源类型，供世界层区分棋盘拖起和备战席拖起。
func _get_drag_origin_kind() -> String:
	if _drag_controller != null:
		return str(_drag_controller.get_drag_origin_kind())
	return ""


# 从已部署友军里按碰撞半径拾取单位，用于准备期棋盘点击和拖拽。
func _pick_deployed_ally_unit_at(world_pos: Vector2) -> Node:
	for unit in _state.ally_deployed.values():
		if _is_valid_unit(unit) and _is_point_on_unit(unit, world_pos):
			return unit
	return null


# hover 检测既兼容战斗期索引查询，也兼容准备期直接遍历部署映射。
func _pick_visible_unit_at_world(world_pos: Vector2) -> Node:
	var pick_radius: float = maxf(float(_refs.hex_grid.hex_size) * 0.72 * _state.unit_scale_factor, 12.0)
	if int(_state.stage) == Stage.COMBAT:
		if _refs.combat_manager != null and _refs.combat_manager.has_method("pick_unit_at_world"):
			var indexed_candidate: Variant = _refs.combat_manager.pick_unit_at_world(
				world_pos,
				pick_radius
			)
			if indexed_candidate is Node and _is_valid_unit(indexed_candidate):
				var indexed_unit: Node = indexed_candidate as Node
				if (
					indexed_unit is CanvasItem
					and (indexed_unit as CanvasItem).visible
					and _is_point_on_unit(indexed_unit, world_pos)
				):
					return indexed_unit
	var candidate: Node = null
	for unit in _state.ally_deployed.values():
		if _is_valid_unit(unit) and (unit as CanvasItem).visible and _is_point_on_unit(unit, world_pos):
			candidate = unit
	for unit in _state.enemy_deployed.values():
		if _is_valid_unit(unit) and (unit as CanvasItem).visible and _is_point_on_unit(unit, world_pos):
			candidate = unit
	return candidate


# 单位碰撞半径跟随棋格缩放变化，保证不同分辨率下点击手感一致。
func _is_point_on_unit(unit: Node, world_pos: Vector2) -> bool:
	var node2d: Node2D = unit as Node2D
	if node2d == null:
		return false
	var radius: float = maxf(float(_refs.hex_grid.hex_size) * 0.62 * _state.unit_scale_factor, 10.0)
	return node2d.position.distance_squared_to(world_pos) <= radius * radius


# 友军部署校验统一委托给 unit_deploy_manager，world controller 不复制规则。
func _can_deploy_ally_to_cell(unit: Node, cell: Vector2i) -> bool:
	if _unit_deploy_manager != null:
		return bool(_unit_deploy_manager.can_deploy_ally_to_cell(unit, cell))
	return false


# 部署区判定同样只走 unit_deploy_manager，避免两处维护部署矩形规则。
func _is_ally_deploy_zone(cell: Vector2i) -> bool:
	if _unit_deploy_manager != null:
		return bool(_unit_deploy_manager.is_ally_deploy_zone(cell))
	return false


# 友军落位包装口保留在 world controller，供拖拽和后续测试共用。
func _deploy_ally_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.deploy_ally_unit_to_cell(unit, cell)


# 敌军落位包装口留给后续敌军生成与回放逻辑复用。
func _deploy_enemy_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.deploy_enemy_unit_to_cell(unit, cell)


# 当棋盘单位被拖起时，需要先从映射里摘掉原位置。
func _remove_ally_mapping(unit: Node) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.remove_ally_mapping(unit)


# MultiMesh 刷新入口统一放在这里，根场景不直接碰渲染协作者。
func _refresh_multimesh() -> void:
	if _battlefield_renderer != null:
		_battlefield_renderer.refresh_multimesh()


# world 变化后的 HUD 投影只通过 presenter 收口，避免世界层继续写 UI 节点。
func _refresh_all_ui() -> void:
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("sync_world_debug_status"):
		hud_presenter.sync_world_debug_status(_build_world_debug_snapshot())
	if hud_presenter != null and hud_presenter.has_method("refresh_after_world_change"):
		hud_presenter.refresh_after_world_change()


# 棋盘自适应仍由 renderer 负责，world controller 只保留统一入口。
func _refit_hex_grid() -> void:
	if _battlefield_renderer != null:
		_battlefield_renderer.refit_hex_grid()


# 这里保留尺寸计算包装口，便于后续测试直接校验 renderer 输出。
func _calculate_fit_hex_size(available_w: float, available_h: float) -> float:
	if _battlefield_renderer != null:
		return float(_battlefield_renderer.calculate_fit_hex_size(available_w, available_h))
	return clampf(minf(available_w, available_h), min_hex_size, max_hex_size)


# 这里保留棋盘像素尺寸包装口，方便后续世界回归测试复用。
func _calculate_board_pixel_size(hex_size: float) -> Vector2:
	if _battlefield_renderer != null:
		var value: Variant = _battlefield_renderer.calculate_board_pixel_size(hex_size)
		if value is Vector2:
			return value
	return Vector2.ZERO


# 单位视觉状态只按“备战席/棋盘”和当前阶段切换，不承接 HUD 投影。
func _apply_unit_visual_presentation(unit: Node) -> void:
	if not _is_valid_unit(unit):
		return
	var on_bench: bool = bool(unit.get("is_on_bench"))
	if on_bench:
		(unit as CanvasItem).visible = false
		(unit as Node2D).scale = Vector2.ONE
		unit.set_compact_visual_mode(false)
		return
	(unit as CanvasItem).visible = true
	(unit as Node2D).scale = Vector2.ONE * _state.unit_scale_factor
	unit.set_compact_visual_mode(int(_state.stage) == Stage.COMBAT)


# 批量刷新所有单位视觉表现，保证缩放或阶段变化后表现一致。
func _apply_visual_to_all_units() -> void:
	if _refs.bench_ui != null:
		for unit in _refs.bench_ui.get_all_units():
			_apply_unit_visual_presentation(unit)
	for unit in _state.ally_deployed.values():
		_apply_unit_visual_presentation(unit)
	for unit in _state.enemy_deployed.values():
		_apply_unit_visual_presentation(unit)


# 棋盘格大小或布局变化后，需要重算所有已部署单位的世界坐标。
func _refresh_deployed_positions() -> void:
	for unit in _state.ally_deployed.values():
		if _is_valid_unit(unit):
			(unit as Node2D).position = _refs.hex_grid.axial_to_world(unit.get("deployed_cell"))
	for unit in _state.enemy_deployed.values():
		if _is_valid_unit(unit):
			(unit as Node2D).position = _refs.hex_grid.axial_to_world(unit.get("deployed_cell"))


# hover 采用悬停延迟显示口径，防止鼠标划过单位时 tooltip 抖动。
func _update_hover(delta: float) -> void:
	if _state.dragging_unit != null:
		_state.tooltip_visible = false
		_state.hover_candidate_unit = null
		_state.hover_hold_time = 0.0
		_state.tooltip_hide_delay = 0.0
		_notify_hover_cleared()
		return

	var mouse_screen: Vector2 = _scene_root.get_viewport().get_mouse_position()
	var world_pos: Vector2 = _screen_to_world(mouse_screen)
	var hovered: Node = _pick_visible_unit_at_world(world_pos)
	if hovered == _state.hover_candidate_unit:
		_state.hover_hold_time += delta
	else:
		_state.hover_candidate_unit = hovered
		_state.hover_hold_time = 0.0
	if hovered == null:
		if _state.tooltip_visible:
			_state.tooltip_hide_delay += delta
			if _state.tooltip_hide_delay >= 0.15:
				_state.tooltip_visible = false
				_notify_hover_cleared()
		return

	_state.tooltip_hide_delay = 0.0
	if _state.hover_hold_time >= 0.3:
		_state.tooltip_visible = true
		_notify_hover_unit(hovered, mouse_screen)


# 阶段切换在世界层只处理交互性和布局，不处理战斗编排与面板内容。
func _set_stage(next_stage: int) -> void:
	_state.stage = next_stage
	if _refs.bench_ui != null and _refs.bench_ui.has_method("set_interactable"):
		_refs.bench_ui.set_interactable(next_stage == Stage.PREPARATION)
	if _refs.deploy_overlay != null:
		_refs.deploy_overlay.visible = next_stage == Stage.PREPARATION
	_set_bottom_expanded(next_stage != Stage.COMBAT, next_stage != Stage.PREPARATION)
	_apply_visual_to_all_units()
	_refit_hex_grid()
	_refresh_deployed_positions()
	_refresh_all_ui()


# 底栏展开态会直接影响棋盘可用高度，因此必须由世界层统一控制。
func _set_bottom_expanded(expanded: bool, animate: bool) -> void:
	_state.bottom_expanded = expanded
	if _refs.bottom_panel == null:
		return
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	var height: float = bottom_reserved_preparation if expanded else 42.0
	var target_left: float = 12.0
	var target_right: float = -12.0
	var target_top: float = -height - 8.0
	var target_bottom: float = -8.0
	if _bottom_tween != null:
		_bottom_tween.kill()
		_bottom_tween = null
	if animate:
		_bottom_tween = create_tween()
		_bottom_tween.tween_property(
			_refs.bottom_panel,
			"offset_left",
			target_left,
			0.28
		).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_bottom_tween.parallel().tween_property(
			_refs.bottom_panel,
			"offset_right",
			target_right,
			0.28
		).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_bottom_tween.parallel().tween_property(
			_refs.bottom_panel,
			"offset_top",
			target_top,
			0.28
		).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_bottom_tween.parallel().tween_property(
			_refs.bottom_panel,
			"offset_bottom",
			target_bottom,
			0.28
		).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		_refs.bottom_panel.offset_left = target_left
		_refs.bottom_panel.offset_right = target_right
		_refs.bottom_panel.offset_top = target_top
		_refs.bottom_panel.offset_bottom = target_bottom
	if _refs.toggle_button != null:
		_refs.toggle_button.text = "▼" if expanded else "▲"
		_refs.toggle_button.position = Vector2(viewport_size.x * 0.5 - 24.0, viewport_size.y - 34.0)
	if _refs.bench_ui != null and _refs.bench_ui.has_method("refresh_adaptive_layout"):
		_refs.bench_ui.call_deferred("refresh_adaptive_layout")


# 视口变化后要同步底栏、棋盘和拖拽高亮，避免分辨率切换后错位。
func _on_viewport_size_changed() -> void:
	_set_bottom_expanded(_state.bottom_expanded, false)
	if _refs.bench_ui != null and _refs.bench_ui.has_method("refresh_adaptive_layout"):
		_refs.bench_ui.call_deferred("refresh_adaptive_layout")
	_refit_hex_grid()
	_refresh_deployed_positions()
	_request_drag_overlay_redraw()


# 底栏切换按钮只改变世界布局，不在这里掺入任何 HUD 业务逻辑。
func _on_toggle_bottom_pressed() -> void:
	_set_bottom_expanded(not _state.bottom_expanded, true)
	_refit_hex_grid()
	_refresh_deployed_positions()


# 备战席变化后做最小刷新，确保调试文案与 hover 数据不陈旧。
func _on_bench_changed() -> void:
	_refresh_all_ui()


# 拖拽高亮需要重绘时，只允许通过这里请求根节点 queue_redraw。
func _request_drag_overlay_redraw(force: bool = false) -> void:
	if force or _state.dragging_unit != null or _state.drag_target_cell.x >= 0:
		_scene_root.queue_redraw()


# 屏幕坐标转世界坐标统一走 WorldContainer 逆矩阵，避免多处自算偏移。
func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return _refs.world_container.get_global_transform().affine_inverse() * screen_pos


# 单元格洗牌逻辑收在世界层，供自动部署和敌军落位共用。
func _shuffle_cells(cells: Array[Vector2i], rng: RandomNumberGenerator) -> void:
	for index in range(cells.size() - 1, 0, -1):
		var swap_index: int = rng.randi_range(0, index)
		var temp: Vector2i = cells[index]
		cells[index] = cells[swap_index]
		cells[swap_index] = temp


# 统一 cell key 格式，避免部署映射在不同调用点写出不同字符串口径。
func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


# 只认仍然活着的实例化节点，避免悬空引用继续留在部署映射里。
func _is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null


# 给单位节点写入映射缓存，后续删除时可以优先走 O(1) 路径。
func _set_unit_map_cache(unit: Node, map_key: String, team_id: int) -> void:
	if not _is_valid_unit(unit):
		return
	unit.set_meta("map_cell_key", map_key)
	unit.set_meta("map_team_id", team_id)


# 读取映射缓存 key，供 deploy manager 删除映射时做快速命中。
func _get_unit_map_key(unit: Node) -> String:
	if not _is_valid_unit(unit):
		return ""
	return str(unit.get_meta("map_cell_key", ""))


# 清空单位上的映射缓存，避免旧格子信息带到下一次部署。
func _clear_unit_map_cache(unit: Node) -> void:
	if not _is_valid_unit(unit):
		return
	unit.remove_meta("map_cell_key")
	unit.remove_meta("map_team_id")


# 非拖拽点击只尝试做“世界单位点选”，不会在这里直接操作详情面板。
func _try_notify_click(screen_pos: Vector2) -> void:
	if _is_point_over_interactive_ui(screen_pos):
		return
	var world_pos: Vector2 = _screen_to_world(screen_pos)
	var clicked_unit: Node = _pick_visible_unit_at_world(world_pos)
	if clicked_unit != null and _is_valid_unit(clicked_unit):
		_notify_world_unit_clicked(clicked_unit, screen_pos)
		_scene_root.get_viewport().set_input_as_handled()


# 点击到可交互 UI 时，不允许把事件继续当作世界点击处理。
func _is_point_over_interactive_ui(screen_pos: Vector2) -> bool:
	var viewport: Viewport = _scene_root.get_viewport()
	if viewport == null:
		return false
	var hovered: Control = viewport.gui_get_hovered_control()
	if hovered == null or not hovered.visible:
		return false
	var current: Control = hovered
	while current != null:
		if current.mouse_filter != Control.MOUSE_FILTER_IGNORE and current.get_global_rect().has_point(screen_pos):
			return true
		current = current.get_parent() as Control
	return false


# 备战席点击只做事件转发，真正详情打开逻辑留给 HUD presenter。
func _notify_bench_slot_clicked(slot_index: int) -> void:
	if _refs.bench_ui == null:
		return
	var bench_unit: Node = _refs.bench_ui.get_unit_at_slot(slot_index)
	if bench_unit == null or not _is_valid_unit(bench_unit):
		return
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("handle_bench_unit_click"):
		hud_presenter.handle_bench_unit_click(slot_index, bench_unit)


# 世界单位点击同样只做转发，保证点击职责线停在 world controller。
func _notify_world_unit_clicked(unit: Node, screen_pos: Vector2) -> void:
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("handle_world_unit_click"):
		hud_presenter.handle_world_unit_click(unit, screen_pos)


# hover 命中后只通知 presenter，不在 world controller 内部直接绘制 tooltip。
func _notify_hover_unit(unit: Node, screen_pos: Vector2) -> void:
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("update_hovered_unit"):
		hud_presenter.update_hovered_unit(unit, screen_pos)


# hover 丢失时统一从这里通知 presenter 清理状态。
func _notify_hover_cleared() -> void:
	var hud_presenter: Node = _get_hud_presenter()
	if hud_presenter != null and hud_presenter.has_method("clear_hovered_unit"):
		hud_presenter.clear_hovered_unit()


# world controller 只保留“拖拽落到回收区”的显式包装口，真正出售逻辑仍在 coordinator。
func _try_sell_dragging_unit() -> bool:
	var coordinator: Node = _get_coordinator()
	if coordinator != null and coordinator.has_method("try_sell_dragging_unit"):
		return bool(coordinator.try_sell_dragging_unit())
	return false


# 点击/拖拽分流结束后要统一清理按下阶段的世界输入瞬态。
func _reset_press_state() -> void:
	_state.bench_press_slot = -1
	_state.world_press_unit = null
	_state.world_press_cell = INVALID_CELL
	_state.left_click_pending = false


# 世界调试态先整理成快照，再交给 HUD facade 决定怎么投影。
func _build_world_debug_snapshot() -> Dictionary:
	var bench_count: int = 0
	if _refs.bench_ui != null and _refs.bench_ui.has_method("get_unit_count"):
		bench_count = int(_refs.bench_ui.get_unit_count())
	var stage_name: String = "PREPARATION"
	if int(_state.stage) == Stage.COMBAT:
		stage_name = "COMBAT"
	elif int(_state.stage) == Stage.RESULT:
		stage_name = "RESULT"
	return {
		"stage_name": stage_name,
		"bench_count": bench_count,
		"ally_count": _state.ally_deployed.size(),
		"enemy_count": _state.enemy_deployed.size()
	}


# 通过根场景 getter 读取 presenter，避免 world controller 直接写死子节点路径。
func _get_hud_presenter() -> Node:
	if _scene_root == null or not _scene_root.has_method("get_hud_presenter"):
		return null
	return _scene_root.get_hud_presenter()


# 通过根场景 getter 读取 coordinator，避免 world controller 直接依赖节点路径。
func _get_coordinator() -> Node:
	if _scene_root == null or not _scene_root.has_method("get_coordinator"):
		return null
	return _scene_root.get_coordinator()


# 运行时协作者必须全部完成 initialize，Batch 2 才允许宣称 world ready。
func _runtime_collaborators_initialized() -> bool:
	return (
		_unit_deploy_manager != null
		and _unit_deploy_manager.has_method("is_initialized")
		and _unit_deploy_manager.is_initialized()
		and _drag_controller != null
		and _drag_controller.has_method("is_initialized")
		and _drag_controller.is_initialized()
	and _battlefield_renderer != null
	and _battlefield_renderer.has_method("is_initialized")
	and _battlefield_renderer.is_initialized()
	)
