extends RefCounted

# 战场世界视图支撑
# 说明：
# 1. 集中承接镜头坐标换算、hover 命中、阶段可视表现和底栏布局。
# 2. 这里不处理商店、奖励、关卡推进，也不直接驱动 HUD 节点。
# 3. world controller 仍是唯一对外入口，这里只负责把视图态细节从超长文件里拆出来。

var _owner: Node = null
var _scene_root: Node = null
var _refs = null
var _state = null

var _stage_preparation: int = 0
var _stage_combat: int = 1
var _stage_result: int = 2
var _min_hex_size: float = 10.0
var _max_hex_size: float = 24.0
var _bottom_reserved_preparation: float = 250.0
var _bottom_tween: Tween = null

const COMBAT_COMPACT_VISUAL_UNIT_THRESHOLD: int = 120 # 高密度战斗隐藏单位标签。


# 绑定 world controller、场景引用表和会话状态，后续所有视图态都只走这里。
func initialize(
	owner: Node,
	scene_root: Node,
	refs,
	state,
	stage_preparation: int,
	stage_combat: int,
	stage_result: int,
	min_hex_size: float,
	max_hex_size: float,
	bottom_reserved_preparation: float
) -> void:
	_owner = owner
	_scene_root = scene_root
	_refs = refs
	_state = state
	_stage_preparation = stage_preparation
	_stage_combat = stage_combat
	_stage_result = stage_result
	_min_hex_size = min_hex_size
	_max_hex_size = max_hex_size
	_bottom_reserved_preparation = bottom_reserved_preparation


# world 坐标键格式只允许有一种，部署映射与缓存都走这一口径。
func cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


# 世界层只认仍然活着的节点实例，避免悬空引用继续污染状态表。
func is_valid_unit(unit: Variant) -> bool:
	if not is_instance_valid(unit):
		return false
	return (unit as Node) != null


# 给单位写入部署映射缓存，供 deploy manager 优先走 O(1) 删除路径。
func set_unit_map_cache(unit: Node, map_key: String, team_id: int) -> void:
	if not is_valid_unit(unit):
		return
	unit.set_meta("map_cell_key", map_key)
	unit.set_meta("map_team_id", team_id)


# 读取单位上的部署映射缓存 key。
func get_unit_map_key(unit: Node) -> String:
	if not is_valid_unit(unit):
		return ""
	return str(unit.get_meta("map_cell_key", ""))


# 清空单位上的部署缓存，避免下一次拖拽仍带着旧格子信息。
func clear_unit_map_cache(unit: Node) -> void:
	if not is_valid_unit(unit):
		return
	unit.remove_meta("map_cell_key")
	unit.remove_meta("map_team_id")


# 屏幕坐标转世界坐标统一走 WorldContainer 逆矩阵。
func screen_to_world(screen_pos: Vector2) -> Vector2:
	if _refs == null or _refs.world_container == null:
		return screen_pos
	return _refs.world_container.get_global_transform().affine_inverse() * screen_pos


# 从已部署友军里按碰撞半径拾取单位，用于准备期点击和拖拽起手。
func pick_deployed_ally_unit_at(world_pos: Vector2) -> Node:
	if _state == null:
		return null
	for unit in _state.ally_deployed.values():
		if is_valid_unit(unit) and is_point_on_unit(unit, world_pos):
			return unit
	return null


# hover 命中同时兼容战斗期索引查询和准备期部署映射遍历。
func pick_visible_unit_at_world(world_pos: Vector2) -> Node:
	if _state == null or _refs == null or _refs.hex_grid == null:
		return null
	var pick_radius: float = maxf(float(_refs.hex_grid.hex_size) * 0.72 * _state.unit_scale_factor, 12.0)
	if _state.stage == _stage_combat:
		if _refs.combat_manager != null and _refs.combat_manager.has_method("pick_unit_at_world"):
			var indexed_candidate: Variant = _refs.combat_manager.pick_unit_at_world(
				world_pos,
				pick_radius
			)
			if indexed_candidate is Node and is_valid_unit(indexed_candidate):
				var indexed_unit: Node = indexed_candidate as Node
				var indexed_canvas: CanvasItem = indexed_unit as CanvasItem
				if indexed_canvas != null and indexed_canvas.visible and is_point_on_unit(indexed_unit, world_pos):
					return indexed_unit
	var candidate: Node = null
	for unit in _state.ally_deployed.values():
		var ally_canvas: CanvasItem = unit as CanvasItem
		if is_valid_unit(unit) and ally_canvas != null and ally_canvas.visible and is_point_on_unit(unit, world_pos):
			candidate = unit
	for unit in _state.enemy_deployed.values():
		var enemy_canvas: CanvasItem = unit as CanvasItem
		if is_valid_unit(unit) and enemy_canvas != null and enemy_canvas.visible and is_point_on_unit(unit, world_pos):
			candidate = unit
	return candidate


# 单位碰撞半径跟随棋格和视觉缩放变化，保证不同分辨率下点选手感一致。
func is_point_on_unit(unit: Node, world_pos: Vector2) -> bool:
	if _refs == null or _refs.hex_grid == null or _state == null:
		return false
	var node2d: Node2D = unit as Node2D
	if node2d == null:
		return false
	var radius: float = maxf(float(_refs.hex_grid.hex_size) * 0.62 * _state.unit_scale_factor, 10.0)
	return node2d.position.distance_squared_to(world_pos) <= radius * radius


# MultiMesh 刷新入口统一从这里转给 renderer。
func refresh_multimesh() -> void:
	var renderer: Node = _get_battlefield_renderer()
	if renderer != null:
		renderer.refresh_multimesh()


# 棋盘自适应重新收口到 view support，world controller 不再内嵌 renderer 细节。
func refit_hex_grid() -> void:
	var renderer: Node = _get_battlefield_renderer()
	if renderer != null:
		renderer.refit_hex_grid()


# 保留给测试使用的尺寸计算包装口。
func calculate_fit_hex_size(available_w: float, available_h: float) -> float:
	var renderer: Node = _get_battlefield_renderer()
	if renderer != null:
		return float(renderer.calculate_fit_hex_size(available_w, available_h))
	return clampf(minf(available_w, available_h), _min_hex_size, _max_hex_size)


# 保留给测试使用的棋盘像素尺寸包装口。
func calculate_board_pixel_size(hex_size: float) -> Vector2:
	var renderer: Node = _get_battlefield_renderer()
	if renderer != null:
		var value: Variant = renderer.calculate_board_pixel_size(hex_size)
		if value is Vector2:
			return value
	return Vector2.ZERO


# 单位视觉状态只按“备战席/棋盘”和当前阶段切换，不承接 HUD 文案投影。
func apply_unit_visual_presentation(unit: Node) -> void:
	if not is_valid_unit(unit):
		return
	var on_bench: bool = bool(unit.get("is_on_bench"))
	var canvas_item: CanvasItem = unit as CanvasItem
	var node2d: Node2D = unit as Node2D
	if on_bench:
		if canvas_item != null:
			canvas_item.visible = false
		if node2d != null:
			node2d.scale = Vector2.ONE
		unit.set_compact_visual_mode(false)
		return
	if canvas_item != null:
		canvas_item.visible = true
	if node2d != null:
		node2d.scale = Vector2.ONE * _state.unit_scale_factor
	unit.set_compact_visual_mode(false)


# 批量刷新所有单位视觉表现，保证阶段切换和棋盘缩放后结果一致。
func apply_visual_to_all_units() -> void:
	if _refs == null or _state == null:
		return
	if _refs.bench_ui != null:
		for unit in _refs.bench_ui.get_all_units():
			apply_unit_visual_presentation(unit)
	for unit in _state.ally_deployed.values():
		apply_unit_visual_presentation(unit)
	for unit in _state.enemy_deployed.values():
		apply_unit_visual_presentation(unit)


# 棋盘尺寸变化后，所有已部署单位的位置都要重投影一次。
func refresh_deployed_positions() -> void:
	if _refs == null or _refs.hex_grid == null or _state == null:
		return
	for unit in _state.ally_deployed.values():
		var ally_node2d: Node2D = unit as Node2D
		if is_valid_unit(unit) and ally_node2d != null:
			ally_node2d.position = _refs.hex_grid.axial_to_world(unit.get("deployed_cell"))
	for unit in _state.enemy_deployed.values():
		var enemy_node2d: Node2D = unit as Node2D
		if is_valid_unit(unit) and enemy_node2d != null:
			enemy_node2d.position = _refs.hex_grid.axial_to_world(unit.get("deployed_cell"))


# hover 状态更新只回传“展示 / 清理”的投影结果，真正的 HUD 调用仍在 world controller。
func update_hover(delta: float) -> Dictionary:
	if _state == null or _scene_root == null:
		return {}
	if _state.dragging_unit != null:
		_state.tooltip_visible = false
		_state.hover_candidate_unit = null
		_state.hover_hold_time = 0.0
		_state.tooltip_hide_delay = 0.0
		return {"action": "clear"}

	var viewport: Viewport = _scene_root.get_viewport()
	if viewport == null:
		return {}
	var mouse_screen: Vector2 = viewport.get_mouse_position()
	var world_pos: Vector2 = screen_to_world(mouse_screen)
	var hovered: Node = pick_visible_unit_at_world(world_pos)
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
				return {"action": "clear"}
		return {}

	_state.tooltip_hide_delay = 0.0
	if _state.hover_hold_time >= 0.3:
		_state.tooltip_visible = true
		return {
			"action": "show",
			"unit": hovered,
			"screen_pos": mouse_screen
		}
	return {}


# 阶段切换在世界层只处理交互性和视觉状态，不处理战斗编排。
func set_stage(next_stage: int) -> void:
	if _state == null:
		return
	_state.stage = next_stage
	if _refs != null and _refs.bench_ui != null and _refs.bench_ui.has_method("set_interactable"):
		_refs.bench_ui.set_interactable(next_stage == _stage_preparation)
	if _refs != null and _refs.deploy_overlay != null:
		_refs.deploy_overlay.visible = next_stage == _stage_preparation
	set_bottom_expanded(next_stage != _stage_combat, next_stage != _stage_preparation)
	apply_visual_to_all_units()
	refit_hex_grid()
	refresh_deployed_positions()


# 底栏展开态直接影响棋盘可用高度，因此固定由 view support 统一维护。
func set_bottom_expanded(expanded: bool, animate: bool) -> void:
	if _state == null:
		return
	_state.bottom_expanded = expanded
	if _refs == null or _refs.bottom_panel == null or _scene_root == null:
		return
	var viewport_size: Vector2 = _scene_root.get_viewport().get_visible_rect().size
	var height: float = _bottom_reserved_preparation if expanded else 42.0
	var target_left: float = 12.0
	var target_right: float = -12.0
	var target_top: float = -height - 8.0
	var target_bottom: float = -8.0
	if _bottom_tween != null:
		_bottom_tween.kill()
		_bottom_tween = null
	if animate and _owner != null:
		_bottom_tween = _owner.create_tween()
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


# 视口变化后同步底栏、棋盘和拖拽高亮，避免分辨率切换后错位。
func on_viewport_size_changed() -> void:
	if _state == null:
		return
	set_bottom_expanded(_state.bottom_expanded, false)
	if _refs != null and _refs.bench_ui != null and _refs.bench_ui.has_method("refresh_adaptive_layout"):
		_refs.bench_ui.call_deferred("refresh_adaptive_layout")
	refit_hex_grid()
	refresh_deployed_positions()
	request_drag_overlay_redraw()


# 底栏切换按钮只改变世界布局，不掺入任何 HUD 业务逻辑。
func on_toggle_bottom_pressed() -> void:
	if _state == null:
		return
	set_bottom_expanded(not _state.bottom_expanded, true)
	refit_hex_grid()
	refresh_deployed_positions()


# 拖拽高亮需要重绘时，只允许请求可绘制的根场景节点 queue_redraw。
func request_drag_overlay_redraw(force: bool = false) -> void:
	if _scene_root == null or _state == null:
		return
	if force or _state.dragging_unit != null or _state.drag_target_cell.x >= 0:
		var overlay_canvas: CanvasItem = _scene_root as CanvasItem
		if overlay_canvas != null:
			overlay_canvas.queue_redraw()


# 世界调试态先整理成快照，再由 HUD 决定如何投影。
func build_world_debug_snapshot() -> Dictionary:
	if _state == null:
		return {}
	var bench_count: int = 0
	if _refs != null and _refs.bench_ui != null and _refs.bench_ui.has_method("get_unit_count"):
		bench_count = int(_refs.bench_ui.get_unit_count())
	var stage_name: String = "PREPARATION"
	if _state.stage == _stage_combat:
		stage_name = "COMBAT"
	elif _state.stage == _stage_result:
		stage_name = "RESULT"
	return {
		"stage_name": stage_name,
		"bench_count": bench_count,
		"ally_count": _state.ally_deployed.size(),
		"enemy_count": _state.enemy_deployed.size()
	}


# 统一从 refs 读取 renderer，避免 world controller 同时维护第二份来源。
func _get_battlefield_renderer() -> Node:
	if _refs == null:
		return null
	return _refs.runtime_battlefield_renderer


# 高密度战斗下优先压掉随单位移动的标签层，给核心战斗逻辑和位移留预算。
func _should_use_compact_combat_visuals() -> bool:
	if _state == null or _state.stage != _stage_combat:
		return false
	return (_state.ally_deployed.size() + _state.enemy_deployed.size()) >= COMBAT_COMPACT_VISUAL_UNIT_THRESHOLD
