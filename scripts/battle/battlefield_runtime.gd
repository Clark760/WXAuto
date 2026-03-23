extends Node2D

enum Stage { PREPARATION, COMBAT, RESULT }

const HUD_REFRESH_INTERVAL: float = 0.1
const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2
const UNIT_DEPLOY_MANAGER_SCRIPT: Script = preload("res://scripts/battle/unit_deploy_manager.gd")
const DRAG_CONTROLLER_SCRIPT: Script = preload("res://scripts/battle/drag_controller.gd")
const BATTLEFIELD_RENDERER_SCRIPT: Script = preload("res://scripts/battle/battlefield_renderer.gd")

@export var initial_bench_count: int = 30
@export var enemy_wave_size: int = 200
@export var max_auto_deploy: int = 50
@export var top_reserved_height: float = 64.0
@export var bottom_reserved_preparation: float = 250.0
@export var bottom_reserved_collapsed: float = 54.0
@export var board_margin: float = 20.0
@export var min_hex_size: float = 10.0
@export var max_hex_size: float = 24.0
@export var world_zoom_min: float = 0.4
@export var world_zoom_max: float = 2.5
@export var world_zoom_step: float = 0.1
@export var world_pan_speed: float = 540.0
@export var unit_visual_scale_multiplier: float = 0.5

@onready var world_container: Node2D = $WorldContainer
@onready var hex_grid: HexGrid = $WorldContainer/HexGrid
@onready var deploy_overlay: Node2D = $WorldContainer/HexGrid/DeployZoneOverlay
@onready var unit_layer: Node2D = $WorldContainer/UnitLayer
@onready var multimesh_renderer: Node2D = $WorldContainer/UnitLayer/UnitMultiMeshRenderer
@onready var vfx_factory: Node2D = $WorldContainer/VfxLayer/VfxFactory
@onready var unit_factory: Node = $UnitFactory
@onready var combat_manager: Node = $CombatManager
@onready var gongfa_manager: Node = _get_root_node("GongfaManager")

@onready var phase_label: Label = $HUDLayer/TopBar/TopBarContent/PhaseLabel
@onready var round_label: Label = $HUDLayer/TopBar/TopBarContent/RoundLabel
@onready var power_bar: ProgressBar = $HUDLayer/TopBar/TopBarContent/PowerBar
@onready var timer_label: Label = $HUDLayer/TopBar/TopBarContent/TimerLabel
@onready var unit_tooltip: PanelContainer = $HUDLayer/UnitTooltip
@onready var phase_transition: Control = $HUDLayer/PhaseTransition
@onready var phase_transition_text: Label = $HUDLayer/PhaseTransition/PhaseText

@onready var bottom_panel: PanelContainer = $BottomLayer/BottomPanel
@onready var bench_ui: Node = $BottomLayer/BottomPanel/RootVBox/BenchArea
@onready var toggle_button: Button = $BottomLayer/ToggleButton
@onready var drag_preview: PanelContainer = $BottomLayer/DragPreview
@onready var drag_preview_icon: ColorRect = $BottomLayer/DragPreview/PreviewVBox/Icon
@onready var drag_preview_name: Label = $BottomLayer/DragPreview/PreviewVBox/Name
@onready var drag_preview_star: Label = $BottomLayer/DragPreview/PreviewVBox/Star
@onready var debug_label: Label = $DebugLayer/DebugLabel

var _stage: int = Stage.PREPARATION
var _round_index: int = 1
var _combat_elapsed: float = 0.0
var _ally_deployed: Dictionary = {}
var _enemy_deployed: Dictionary = {}
var _unit_scale_factor: float = 1.0
var _world_zoom: float = 1.0
var _world_offset: Vector2 = Vector2.ZERO
var _is_panning: bool = false
var _bottom_expanded: bool = true
var _bottom_tween: Tween = null
var _dragging_unit: Node = null
var _drag_target_cell: Vector2i = Vector2i(-999, -999)
var _drag_target_valid: bool = false
var _hover_candidate_unit: Node = null
var _hover_hold_time: float = 0.0
var _tooltip_hide_delay: float = 0.0
var _hud_refresh_accum: float = HUD_REFRESH_INTERVAL
var _multimesh_dirty: bool = false
var _ui_dirty: bool = false
var _pending_multimesh_refresh: bool = false
var _pending_ui_refresh: bool = false
var _cached_ui_values: Dictionary = {}
var _unit_deploy_manager: Node = null
var _drag_controller: Node = null
var _battlefield_renderer: Node = null


func _bootstrap_runtime_modules() -> void:
	# M5 拆分：将部署、拖拽、渲染职责委托给独立模块。
	if _unit_deploy_manager == null:
		_unit_deploy_manager = UNIT_DEPLOY_MANAGER_SCRIPT.new() as Node
		_unit_deploy_manager.name = "RuntimeUnitDeployManager"
		add_child(_unit_deploy_manager)
		_unit_deploy_manager.call("configure", self)
	if _drag_controller == null:
		_drag_controller = DRAG_CONTROLLER_SCRIPT.new() as Node
		_drag_controller.name = "RuntimeDragController"
		add_child(_drag_controller)
		_drag_controller.call("configure", self)
	if _battlefield_renderer == null:
		_battlefield_renderer = BATTLEFIELD_RENDERER_SCRIPT.new() as Node
		_battlefield_renderer.name = "RuntimeBattlefieldRenderer"
		add_child(_battlefield_renderer)
		_battlefield_renderer.call("configure", self)


func _ready() -> void:
	_bootstrap_runtime_modules()
	_connect_signals()
	combat_manager.call("configure_dependencies", hex_grid, vfx_factory)
	if gongfa_manager != null:
		gongfa_manager.call("bind_combat_context", combat_manager, hex_grid, vfx_factory)
	_bind_viewport_resize()
	bench_ui.initialize_slots(50, 10)
	bench_ui.set_interactable(true)
	drag_preview.visible = false
	unit_tooltip.visible = false
	_spawn_random_units_to_bench(initial_bench_count)
	_set_stage(Stage.PREPARATION)
	_on_viewport_size_changed()
	_refresh_multimesh()
	_refresh_all_ui()

func _input(event: InputEvent) -> void:
	# 鼠标交互使用 _input，避免被 ScrollContainer 等控件先消费导致拖拽失效。
	if event is InputEventMouseButton:
		var mouse_button: InputEventMouseButton = event as InputEventMouseButton
		# 备战区滚轮优先：在备战区内滚动时，劫持事件给列表滚动，禁止透传到地图缩放。
		if _consume_bench_wheel_input(mouse_button):
			get_viewport().set_input_as_handled()
			return

		# 视角控制支持全阶段，右键/滚轮处理后直接标记为已消费。
		if _handle_world_view_input(event):
			get_viewport().set_input_as_handled()
			return

		if _stage != Stage.PREPARATION:
			return

		if mouse_button.button_index == MOUSE_BUTTON_LEFT:
			var dragging_before: bool = _dragging_unit != null
			if mouse_button.pressed:
				_try_begin_drag(mouse_button.position)
			else:
				_try_end_drag(mouse_button.position)
			if dragging_before or _dragging_unit != null:
				get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion:
		if _handle_world_view_input(event):
			get_viewport().set_input_as_handled()
			return

		if _stage != Stage.PREPARATION:
			return

		if _dragging_unit != null:
			var mouse_motion: InputEventMouseMotion = event as InputEventMouseMotion
			_update_drag_preview(mouse_motion.position)
			_update_drag_target(mouse_motion.position)
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	_update_world_pan_by_keyboard(delta)
	_update_tooltip(delta)
	if _stage == Stage.COMBAT:
		_combat_elapsed += delta
	if _multimesh_dirty:
		_multimesh_dirty = false
		_refresh_multimesh()
	if _ui_dirty:
		_ui_dirty = false
		_refresh_dynamic_ui()
	_hud_refresh_accum += delta
	if _hud_refresh_accum >= HUD_REFRESH_INTERVAL:
		_hud_refresh_accum = 0.0
		_refresh_dynamic_ui()

func _draw() -> void:
	if _dragging_unit == null or _drag_target_cell.x < 0:
		return
	var fill: Color = Color(0.3, 0.85, 0.45, 0.24) if _drag_target_valid else Color(0.9, 0.26, 0.26, 0.24)
	var border_color: Color = Color(0.6, 1.0, 0.7, 0.9) if _drag_target_valid else Color(1.0, 0.48, 0.48, 0.9)
	var local_points: PackedVector2Array = hex_grid.get_hex_points_local(_drag_target_cell)
	if local_points.size() < 3:
		return
	var screen_points := PackedVector2Array()
	for p in local_points:
		var world_local: Vector2 = hex_grid.transform * p
		screen_points.append(world_container.to_global(world_local))
	draw_colored_polygon(screen_points, fill)
	var border: PackedVector2Array = screen_points.duplicate()
	border.append(screen_points[0])
	draw_polyline(border, border_color, 2.0, true)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		_handle_key_input(event as InputEventKey)
	return

func _handle_key_input(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	if event.keycode == KEY_F8:
		debug_label.text = "F8 被 Godot 调试器占用。"
		return
	if event.keycode == KEY_F3:
		var event_bus: Node = _get_root_node("EventBus")
		if event_bus != null:
			event_bus.call("emit_scene_change_requested", "res://scenes/main/main.tscn")
		return
	if event.keycode == KEY_F4 and _stage == Stage.PREPARATION:
		_spawn_random_units_to_bench(8)
		_refresh_all_ui()
		return
	if event.keycode == KEY_F6 and _stage == Stage.PREPARATION:
		_start_combat()
		return
	if event.keycode == KEY_F7:
		var event_bus_reload: Node = _get_root_node("EventBus")
		if event_bus_reload != null:
			event_bus_reload.call("emit_scene_change_requested", "res://scenes/battle/battlefield.tscn")
		return
	if event.keycode == KEY_SPACE:
		_reset_view()

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
			_is_panning = mouse_button.pressed
			return true
	if event is InputEventMouseMotion and _is_panning:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_pan(motion.relative)
		return true
	return false


func _consume_bench_wheel_input(mouse_button: InputEventMouseButton) -> bool:
	if mouse_button == null:
		return false
	if not mouse_button.pressed:
		return false
	if mouse_button.button_index != MOUSE_BUTTON_WHEEL_UP and mouse_button.button_index != MOUSE_BUTTON_WHEEL_DOWN:
		return false
	if not _bottom_expanded:
		return false
	if bench_ui == null or not is_instance_valid(bench_ui):
		return false
	if not bench_ui.has_method("is_screen_point_inside"):
		return false
	if not bool(bench_ui.call("is_screen_point_inside", mouse_button.position)):
		return false
	# 优先调用备战区脚本提供的滚轮消费接口。
	if bench_ui.has_method("consume_wheel_input"):
		return bool(bench_ui.call("consume_wheel_input", mouse_button.button_index))
	# 兜底：即使未实现滚动接口，也消费事件以阻止地图响应。
	return true

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

func _apply_world_transform() -> void:
	# 视角统一入口：只修改 WorldContainer，禁止对子节点分别做缩放/平移。
	world_container.position = _world_offset
	world_container.scale = Vector2.ONE * _world_zoom
	if _dragging_unit != null:
		queue_redraw()

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# 以鼠标位置为锚点缩放，避免“缩放后画面跳动”。
	var old_zoom: float = _world_zoom
	var next_zoom: float = clampf(old_zoom * factor, world_zoom_min, world_zoom_max)
	if is_equal_approx(next_zoom, old_zoom):
		return
	var world_point: Vector2 = (screen_pos - _world_offset) / maxf(old_zoom, 0.0001)
	_world_zoom = next_zoom
	_world_offset = screen_pos - world_point * _world_zoom
	_apply_world_transform()

func _pan(relative: Vector2) -> void:
	_world_offset += relative
	_apply_world_transform()

func _reset_view() -> void:
	_world_zoom = 1.0
	_world_offset = Vector2.ZERO
	_is_panning = false
	_apply_world_transform()

func _try_begin_drag(screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.call("try_begin_drag", screen_pos)

func _begin_drag(unit: Node, origin_kind: String, origin_slot: int, origin_cell: Vector2i, screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.call("begin_drag", unit, origin_kind, origin_slot, origin_cell, screen_pos)

func _try_end_drag(screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.call("try_end_drag", screen_pos)

func _finish_drag() -> void:
	if _drag_controller != null:
		_drag_controller.call("finish_drag")

func _update_drag_preview(screen_pos: Vector2) -> void:
	drag_preview.position = screen_pos + Vector2(14.0, 14.0)

func _update_drag_target(screen_pos: Vector2) -> void:
	if _drag_controller != null:
		_drag_controller.call("update_drag_target", screen_pos)

func _update_drag_preview_data(unit: Node) -> void:
	drag_preview_name.text = str(unit.get("unit_name"))
	var star: int = int(unit.get("star_level"))
	drag_preview_star.text = "★".repeat(clampi(star, 1, 3))
	drag_preview_star.modulate = _star_color(star)
	drag_preview_icon.color = _quality_color(str(unit.get("quality")))

func _get_drop_target(screen_mouse: Vector2) -> Dictionary:
	if _drag_controller != null:
		return _drag_controller.call("get_drop_target", screen_mouse)
	return {"type": "invalid"}

func _drop_to_bench_slot(unit: Node, slot_index: int) -> bool:
	if _drag_controller != null:
		return bool(_drag_controller.call("drop_to_bench_slot", unit, slot_index))
	return false

func _restore_drag_origin() -> void:
	if _drag_controller != null:
		_drag_controller.call("restore_drag_origin")


func _get_drag_origin_kind() -> String:
	if _drag_controller != null:
		return str(_drag_controller.call("get_drag_origin_kind"))
	return ""


func _pick_deployed_ally_unit_at(world_pos: Vector2) -> Node:
	for unit in _ally_deployed.values():
		if _is_valid_unit(unit) and _is_point_on_unit(unit, world_pos):
			return unit
	return null

func _is_point_on_unit(unit: Node, world_pos: Vector2) -> bool:
	var node2d: Node2D = unit as Node2D
	if node2d == null:
		return false
	var radius: float = maxf(float(hex_grid.hex_size) * 0.62 * _unit_scale_factor, 10.0)
	return node2d.position.distance_squared_to(world_pos) <= radius * radius

func _can_deploy_ally_to_cell(unit: Node, cell: Vector2i) -> bool:
	if _unit_deploy_manager != null:
		return bool(_unit_deploy_manager.call("can_deploy_ally_to_cell", unit, cell))
	return false

func _is_ally_deploy_zone(cell: Vector2i) -> bool:
	if _unit_deploy_manager != null:
		return bool(_unit_deploy_manager.call("is_ally_deploy_zone", cell))
	return false

func _deploy_ally_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("deploy_ally_unit_to_cell", unit, cell)

func _deploy_enemy_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("deploy_enemy_unit_to_cell", unit, cell)

func _remove_ally_mapping(unit: Node) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("remove_ally_mapping", unit)

func _spawn_random_units_to_bench(count: int) -> void:
	var unit_ids: Array[String] = unit_factory.call("get_unit_ids")
	if unit_ids.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(count):
		var unit_id: String = unit_ids[rng.randi_range(0, unit_ids.size() - 1)]
		var unit_node: Node = unit_factory.call("acquire_unit", unit_id, -1, unit_layer)
		if unit_node == null:
			continue
		_clear_unit_map_cache(unit_node)
		unit_node.call("set_team", 1)
		unit_node.call("set_on_bench_state", true, -1)
		unit_node.set("is_in_combat", false)
		if not bench_ui.add_unit(unit_node):
			unit_factory.call("release_unit", unit_node)
			break
	_apply_visual_to_all_units()

func _start_combat() -> void:
	if bool(combat_manager.call("is_battle_running")):
		return
	if _ally_deployed.is_empty():
		_auto_deploy_from_bench(max_auto_deploy)
	_spawn_enemy_wave(enemy_wave_size)

	var ally_units: Array[Node] = _collect_units_from_map(_ally_deployed)
	var enemy_units: Array[Node] = _collect_units_from_map(_enemy_deployed)
	if ally_units.is_empty() or enemy_units.is_empty():
		debug_label.text = "无法开始战斗：己方与敌方都必须至少有 1 名角色。"
		return

	_combat_elapsed = 0.0
	if gongfa_manager != null:
		# 功法系统接入点：必须先 prepare，再 start_battle，
		# 否则 CombatManager 的 battle_started 信号会先于触发器注册发出。
		gongfa_manager.call("prepare_battle", ally_units, enemy_units, hex_grid, vfx_factory, combat_manager)

	var started: bool = bool(combat_manager.call("start_battle", ally_units, enemy_units))
	if not started:
		debug_label.text = "CombatManager 启动失败。"
		return
	for unit in ally_units:
		unit.call("enter_combat")
	for unit in enemy_units:
		unit.call("enter_combat")

	_set_stage(Stage.COMBAT)
	# 注意：_set_stage 内部已调用 _refresh_all_ui() 和 _apply_visual_to_all_units()，
	# 不再重复调用 _refresh_multimesh() / _refresh_all_ui()。

func _spawn_enemy_wave(count: int) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("spawn_enemy_wave", count)

func _clear_enemy_wave() -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("clear_enemy_wave")

func _auto_deploy_from_bench(limit: int) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("auto_deploy_from_bench", limit)

func _collect_ally_spawn_cells() -> Array[Vector2i]:
	if _unit_deploy_manager != null:
		return _unit_deploy_manager.call("collect_ally_spawn_cells")
	return []

func _collect_enemy_spawn_cells() -> Array[Vector2i]:
	if _unit_deploy_manager != null:
		return _unit_deploy_manager.call("collect_enemy_spawn_cells")
	return []

func _collect_units_from_map(map_value: Dictionary) -> Array[Node]:
	if _unit_deploy_manager != null:
		return _unit_deploy_manager.call("collect_units_from_map", map_value)
	return []

func _apply_unit_visual_presentation(unit: Node) -> void:
	if not _is_valid_unit(unit):
		return
	var on_bench: bool = bool(unit.get("is_on_bench"))
	if on_bench:
		(unit as CanvasItem).visible = false
		(unit as Node2D).scale = Vector2.ONE
		unit.call("set_compact_visual_mode", false)
		return
	(unit as CanvasItem).visible = true
	(unit as Node2D).scale = Vector2.ONE * _unit_scale_factor
	unit.call("set_compact_visual_mode", _should_use_compact_unit_labels_for_stage(_stage))


func _should_use_compact_unit_labels_for_stage(stage_value: int) -> bool:
	# 仅交锋阶段使用紧凑标签；结算阶段需要显示姓名/星级用于胜利展示。
	return stage_value == Stage.COMBAT

func _apply_visual_to_all_units() -> void:
	for unit in bench_ui.get_all_units():
		_apply_unit_visual_presentation(unit)
	for unit in _ally_deployed.values():
		_apply_unit_visual_presentation(unit)
	for unit in _enemy_deployed.values():
		_apply_unit_visual_presentation(unit)

func _refresh_deployed_positions() -> void:
	for unit in _ally_deployed.values():
		if _is_valid_unit(unit):
			(unit as Node2D).position = hex_grid.axial_to_world(unit.get("deployed_cell"))
	for unit in _enemy_deployed.values():
		if _is_valid_unit(unit):
			(unit as Node2D).position = hex_grid.axial_to_world(unit.get("deployed_cell"))

func _refresh_multimesh() -> void:
	if _battlefield_renderer != null:
		_battlefield_renderer.call("refresh_multimesh")

func _update_tooltip(delta: float) -> void:
	# Tooltip 采用“悬停 0.3s 显示 + 离开 0.15s 隐藏”的节奏，减少抖动。
	if _dragging_unit != null:
		unit_tooltip.visible = false
		_hover_candidate_unit = null
		_hover_hold_time = 0.0
		_tooltip_hide_delay = 0.0
		return
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()
	var world_pos: Vector2 = _screen_to_world(mouse_screen)
	var hovered: Node = _pick_visible_unit_at_world(world_pos)
	if hovered == _hover_candidate_unit:
		_hover_hold_time += delta
	else:
		_hover_candidate_unit = hovered
		_hover_hold_time = 0.0
	if hovered == null:
		if unit_tooltip.visible:
			_tooltip_hide_delay += delta
			if _tooltip_hide_delay >= 0.15:
				unit_tooltip.visible = false
		return
	_tooltip_hide_delay = 0.0
	if _hover_hold_time >= 0.3:
		_show_tooltip_for_unit(hovered, mouse_screen)

func _pick_visible_unit_at_world(world_pos: Vector2) -> Node:
	var pick_radius: float = maxf(float(hex_grid.hex_size) * 0.72 * _unit_scale_factor, 12.0)
	if _stage == Stage.COMBAT and combat_manager != null and combat_manager.has_method("pick_unit_at_world"):
		var indexed_candidate: Variant = combat_manager.call("pick_unit_at_world", world_pos, pick_radius)
		if indexed_candidate is Node and _is_valid_unit(indexed_candidate):
			var indexed_unit: Node = indexed_candidate as Node
			if indexed_unit is CanvasItem and (indexed_unit as CanvasItem).visible and _is_point_on_unit(indexed_unit, world_pos):
				return indexed_unit
	var candidate: Node = null
	for unit in _ally_deployed.values():
		if _is_valid_unit(unit) and (unit as CanvasItem).visible and _is_point_on_unit(unit, world_pos):
			candidate = unit
	for unit in _enemy_deployed.values():
		if _is_valid_unit(unit) and (unit as CanvasItem).visible and _is_point_on_unit(unit, world_pos):
			candidate = unit
	return candidate

func _show_tooltip_for_unit(unit: Node, screen_pos: Vector2) -> void:
	var header_name: Label = unit_tooltip.get_node_or_null("TooltipVBox/HeaderRow/HeaderName") as Label
	var hp_bar: ProgressBar = unit_tooltip.get_node_or_null("TooltipVBox/HPRow/HPBarRich") as ProgressBar
	var mp_bar: ProgressBar = unit_tooltip.get_node_or_null("TooltipVBox/MPRow/MPBarRich") as ProgressBar
	var hp_text: Label = unit_tooltip.get_node_or_null("TooltipVBox/HPRow/HPText") as Label
	var mp_text: Label = unit_tooltip.get_node_or_null("TooltipVBox/MPRow/MPText") as Label
	if header_name != null:
		header_name.text = "%s %s" % [str(unit.get("unit_name")), "★".repeat(int(unit.get("star_level")))]

	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null:
		var max_hp: float = maxf(float(combat.get("max_hp")), 1.0)
		var max_mp: float = maxf(float(combat.get("max_mp")), 1.0)
		var current_hp: float = float(combat.get("current_hp"))
		var current_mp: float = float(combat.get("current_mp"))
		if hp_bar != null:
			hp_bar.value = clampf(current_hp / max_hp * 100.0, 0.0, 100.0)
		if mp_bar != null:
			mp_bar.value = clampf(current_mp / max_mp * 100.0, 0.0, 100.0)
		if hp_text != null:
			hp_text.text = "%d/%d" % [int(round(current_hp)), int(round(max_hp))]
		if mp_text != null:
			mp_text.text = "%d/%d" % [int(round(current_mp)), int(round(max_mp))]
	else:
		if hp_bar != null:
			hp_bar.value = 100.0
		if mp_bar != null:
			mp_bar.value = 0.0
		if hp_text != null:
			hp_text.text = "100/100"
		if mp_text != null:
			mp_text.text = "0/100"

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var desired: Vector2 = screen_pos + Vector2(16.0, 16.0)
	var tooltip_size: Vector2 = unit_tooltip.size
	if desired.x + tooltip_size.x > viewport_size.x - 8.0:
		desired.x = screen_pos.x - tooltip_size.x - 16.0
	if desired.y + tooltip_size.y > viewport_size.y - 8.0:
		desired.y = screen_pos.y - tooltip_size.y - 16.0
	desired.x = clampf(desired.x, 8.0, viewport_size.x - tooltip_size.x - 8.0)
	desired.y = clampf(desired.y, 8.0, viewport_size.y - tooltip_size.y - 8.0)
	unit_tooltip.position = desired
	unit_tooltip.visible = true

func _set_stage(next_stage: int) -> void:
	# 阶段驱动 UI：布阵可操作，交锋/结算自动切只读或收起。
	_stage = next_stage
	match _stage:
		Stage.PREPARATION:
			phase_label.text = "布阵期"
			phase_label.modulate = Color(0.67, 0.84, 1.0, 1.0)
			bench_ui.set_interactable(true)
			deploy_overlay.visible = true
			_set_bottom_expanded(true, false)
			_play_phase_transition("布阵开始")
		Stage.COMBAT:
			phase_label.text = "交锋期"
			phase_label.modulate = Color(1.0, 0.6, 0.55, 1.0)
			bench_ui.set_interactable(false)
			deploy_overlay.visible = false
			_set_bottom_expanded(false, true)
			_play_phase_transition("交锋开始")
		Stage.RESULT:
			phase_label.text = "结算期"
			phase_label.modulate = Color(1.0, 0.86, 0.5, 1.0)
			bench_ui.set_interactable(false)
			deploy_overlay.visible = false
			_set_bottom_expanded(true, true)
			_play_phase_transition("战斗结束")
	_apply_visual_to_all_units()
	_refit_hex_grid()
	# 阶段切换会触发布局变化（尤其底栏收起/展开），必须同步刷新单位格子坐标。
	_refresh_deployed_positions()
	_refresh_all_ui()

func _set_bottom_expanded(expanded: bool, animate: bool) -> void:
	_bottom_expanded = expanded
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var width: float = maxf(viewport_size.x - 24.0, 320.0)
	var height: float = bottom_reserved_preparation if expanded else 42.0
	var y: float = viewport_size.y - height - 8.0
	bottom_panel.size = Vector2(width, height)
	if _bottom_tween != null:
		_bottom_tween.kill()
		_bottom_tween = null
	if animate:
		_bottom_tween = create_tween()
		_bottom_tween.tween_property(bottom_panel, "position", Vector2(12.0, y), 0.28).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		_bottom_tween.parallel().tween_property(bottom_panel, "size", Vector2(width, height), 0.28).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		bottom_panel.position = Vector2(12.0, y)
	toggle_button.text = "▼" if expanded else "▲"
	toggle_button.position = Vector2(viewport_size.x * 0.5 - 24.0, viewport_size.y - 34.0)
	# 通知备战席刷新自适应列数，确保底栏尺寸变化后行列立即重排。
	if bench_ui != null and is_instance_valid(bench_ui) and bench_ui.has_method("refresh_adaptive_layout"):
		bench_ui.call_deferred("refresh_adaptive_layout")

func _play_phase_transition(text: String) -> void:
	phase_transition_text.text = text
	phase_transition.visible = true
	phase_transition.modulate = Color(1, 1, 1, 0)
	var tween: Tween = create_tween()
	tween.tween_property(phase_transition, "modulate:a", 1.0, 0.16)
	tween.tween_interval(0.18)
	tween.tween_property(phase_transition, "modulate:a", 0.0, 0.24)
	tween.finished.connect(func() -> void: phase_transition.visible = false)

func _refresh_dynamic_ui() -> void:
	_refresh_dynamic_ui_incremental()

func _refresh_all_ui() -> void:
	_hud_refresh_accum = 0.0
	_refresh_dynamic_ui()

func _bind_viewport_resize() -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var cb: Callable = Callable(self, "_on_viewport_size_changed")
	if not viewport.is_connected("size_changed", cb):
		viewport.connect("size_changed", cb)

func _on_viewport_size_changed() -> void:
	_set_bottom_expanded(_bottom_expanded, false)
	if bench_ui != null and is_instance_valid(bench_ui) and bench_ui.has_method("refresh_adaptive_layout"):
		bench_ui.call_deferred("refresh_adaptive_layout")
	_refit_hex_grid()
	_refresh_deployed_positions()
	_request_drag_overlay_redraw()

func _refit_hex_grid() -> void:
	if _battlefield_renderer != null:
		_battlefield_renderer.call("refit_hex_grid")

func _calculate_fit_hex_size(available_w: float, available_h: float) -> float:
	if _battlefield_renderer != null:
		return float(_battlefield_renderer.call("calculate_fit_hex_size", available_w, available_h))
	return clampf(minf(available_w, available_h), min_hex_size, max_hex_size)

func _calculate_board_pixel_size(hex_size: float) -> Vector2:
	if _battlefield_renderer != null:
		var value: Variant = _battlefield_renderer.call("calculate_board_pixel_size", hex_size)
		if value is Vector2:
			return value
	return Vector2.ZERO

func _on_bench_changed() -> void:
	if _stage != Stage.PREPARATION:
		debug_label.text = "交锋/结算阶段备战席仅可查看，拖拽已禁用。"
	_refresh_all_ui()

func _on_unit_star_upgraded(result_unit: Node, consumed_units: Array[Node], _new_star: int) -> void:
	for consumed in consumed_units:
		if _is_valid_unit(consumed):
			unit_factory.call("release_unit", consumed)
	if _is_valid_unit(result_unit):
		result_unit.call("play_anim_state", 3, {})
	_refresh_all_ui()

func _on_damage_resolved(_event: Dictionary) -> void:
	pass

func _on_unit_died(dead_unit: Node, _killer: Node, team_id: int) -> void:
	if team_id == 1:
		_remove_unit_from_map(_ally_deployed, dead_unit)
	else:
		_remove_unit_from_map(_enemy_deployed, dead_unit)
	if _is_valid_unit(dead_unit) and dead_unit is CanvasItem:
		(dead_unit as CanvasItem).visible = false
	# 延迟合并：避免同帧多次死亡导致重复全量刷新。
	_multimesh_dirty = true
	_ui_dirty = true

func _on_battle_ended(winner_team: int, _summary: Dictionary) -> void:
	# M4 规则：结算 = 暂停。这里只切阶段标记与最小 HUD，不触发棋盘重排。
	# 注意：不能走 _set_stage(Stage.RESULT)，否则会调用：
	# _apply_visual_to_all_units() / _refit_hex_grid() / _refresh_deployed_positions()
	# 从而导致单位缩放重算、位置重排和结算瞬间闪跳。
	_stage = Stage.RESULT
	phase_label.text = "结算期"
	phase_label.modulate = Color(1.0, 0.86, 0.5, 1.0)
	bench_ui.set_interactable(false)
	deploy_overlay.visible = false
	_play_phase_transition("战斗结束")
	# 仅刷新 HUD 文案/数值，不触发任何布局与单位视觉重算。
	_refresh_dynamic_ui()
	if winner_team == 1:
		debug_label.text = "战斗结束：己方胜利。F7 重开"
	elif winner_team == 2:
		debug_label.text = "战斗结束：敌方胜利。F7 重开"
	else:
		debug_label.text = "战斗结束：平局。F7 重开"

func _remove_unit_from_map(target_map: Dictionary, unit: Node) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("remove_unit_from_map", target_map, unit)

func _refresh_dynamic_ui_incremental() -> void:
	var ally_alive: int = int(combat_manager.call("get_alive_count", TEAM_ALLY)) if _stage != Stage.PREPARATION else _ally_deployed.size()
	var enemy_alive: int = int(combat_manager.call("get_alive_count", TEAM_ENEMY)) if _stage != Stage.PREPARATION else _enemy_deployed.size()
	var bench_count: int = bench_ui.get_unit_count()
	_set_label_text_if_changed(round_label, "round_label", "第 %d 回合" % _round_index)
	var render_fps: int = int(Engine.get_frames_per_second())
	var timer_text: String = "%.1fs | %d fps" % [_combat_elapsed, render_fps] if _stage == Stage.COMBAT else "-- | %d fps" % render_fps
	_set_label_text_if_changed(timer_label, "timer_label", timer_text)
	var total_power: int = maxi(ally_alive + enemy_alive, 1)
	_set_progress_value_if_changed(power_bar, "power_bar_value", float(ally_alive) / float(total_power) * 100.0)
	_set_control_tooltip_if_changed(power_bar, "power_bar_tooltip", "己方 %d / 敌方 %d" % [ally_alive, enemy_alive])
	var stage_name: String = "PREPARATION"
	if _stage == Stage.COMBAT:
		stage_name = "COMBAT"
	elif _stage == Stage.RESULT:
		stage_name = "RESULT"
	_set_label_text_if_changed(debug_label, "debug_label", "阶段:%s  备战:%d  己方:%d  敌方:%d  渲染fps:%d  逻辑fps:%.1f" % [
		stage_name,
		bench_count,
		_ally_deployed.size(),
		_enemy_deployed.size(),
		render_fps,
		float(combat_manager.get("logic_fps"))
	])

func _remove_unit_from_map_cached(target_map: Dictionary, unit: Node) -> void:
	if _unit_deploy_manager != null:
		_unit_deploy_manager.call("remove_unit_from_map_cached", target_map, unit)

func _set_unit_map_cache(unit: Node, map_key: String, team_id: int) -> void:
	if not _is_valid_unit(unit):
		return
	unit.set_meta("map_cell_key", map_key)
	unit.set_meta("map_team_id", team_id)

func _get_unit_map_key(unit: Node) -> String:
	if not _is_valid_unit(unit):
		return ""
	return str(unit.get_meta("map_cell_key", ""))

func _clear_unit_map_cache(unit: Node) -> void:
	if not _is_valid_unit(unit):
		return
	unit.remove_meta("map_cell_key")
	unit.remove_meta("map_team_id")

func _mark_runtime_refresh(multimesh_dirty: bool, ui_dirty: bool) -> void:
	_pending_multimesh_refresh = _pending_multimesh_refresh or multimesh_dirty
	_pending_ui_refresh = _pending_ui_refresh or ui_dirty

func _flush_pending_runtime_refreshes(allow_ui_refresh: bool) -> void:
	if _pending_multimesh_refresh:
		_refresh_multimesh()
		_pending_multimesh_refresh = false
	if allow_ui_refresh and _pending_ui_refresh:
		_pending_ui_refresh = false

func _request_drag_overlay_redraw(force: bool = false) -> void:
	if force or _dragging_unit != null or _drag_target_cell.x >= 0:
		queue_redraw()

func _set_label_text_if_changed(label: Label, cache_key: String, next_text: String) -> void:
	if label == null:
		return
	if str(_cached_ui_values.get(cache_key, "")) == next_text:
		return
	_cached_ui_values[cache_key] = next_text
	label.text = next_text

func _set_progress_value_if_changed(progress_bar: ProgressBar, cache_key: String, next_value: float) -> void:
	if progress_bar == null:
		return
	var cached_value: float = float(_cached_ui_values.get(cache_key, -INF))
	if is_equal_approx(cached_value, next_value):
		return
	_cached_ui_values[cache_key] = next_value
	progress_bar.value = next_value

func _set_control_tooltip_if_changed(control: Control, cache_key: String, next_text: String) -> void:
	if control == null:
		return
	if str(_cached_ui_values.get(cache_key, "")) == next_text:
		return
	_cached_ui_values[cache_key] = next_text
	control.tooltip_text = next_text

func _connect_signals() -> void:
	var cb_bench: Callable = Callable(self, "_on_bench_changed")
	if not bench_ui.is_connected("bench_changed", cb_bench):
		bench_ui.connect("bench_changed", cb_bench)
	var cb_star: Callable = Callable(self, "_on_unit_star_upgraded")
	if not bench_ui.is_connected("unit_star_upgraded", cb_star):
		bench_ui.connect("unit_star_upgraded", cb_star)
	var cb_damage: Callable = Callable(self, "_on_damage_resolved")
	if not combat_manager.is_connected("damage_resolved", cb_damage):
		combat_manager.connect("damage_resolved", cb_damage)
	var cb_dead: Callable = Callable(self, "_on_unit_died")
	if not combat_manager.is_connected("unit_died", cb_dead):
		combat_manager.connect("unit_died", cb_dead)
	var cb_end: Callable = Callable(self, "_on_battle_ended")
	if not combat_manager.is_connected("battle_ended", cb_end):
		combat_manager.connect("battle_ended", cb_end)
	var cb_toggle: Callable = Callable(self, "_on_toggle_bottom_pressed")
	if not toggle_button.is_connected("pressed", cb_toggle):
		toggle_button.connect("pressed", cb_toggle)

func _on_toggle_bottom_pressed() -> void:
	_set_bottom_expanded(not _bottom_expanded, true)
	_refit_hex_grid()
	_refresh_deployed_positions()

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return world_container.get_global_transform().affine_inverse() * screen_pos

func _shuffle_cells(cells: Array[Vector2i], rng: RandomNumberGenerator) -> void:
	for i in range(cells.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var temp: Vector2i = cells[i]
		cells[i] = cells[j]
		cells[j] = temp

func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]

func _is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null

func _get_root_node(node_name: String) -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null
	var tree: SceneTree = main_loop as SceneTree
	return tree.root.get_node_or_null(node_name) if tree.root != null else null

func _quality_color(quality: String) -> Color:
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

func _star_color(star: int) -> Color:
	match star:
		1:
			return Color(0.94, 0.94, 0.94, 1.0)
		2:
			return Color(1.0, 0.86, 0.35, 1.0)
		3:
			return Color(1.0, 0.42, 0.2, 1.0)
		_:
			return Color(1, 1, 1, 1)
