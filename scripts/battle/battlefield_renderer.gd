extends Node

# 战场渲染协作者
# 说明：
# 1. 只负责 MultiMesh 刷新、棋盘自适应尺寸与单位缩放。
# 2. Phase 2 中不再依赖 owner.call(...)，改为显式读取 refs/state/delegate。
# 3. 这里不负责 HUD 布局，也不负责结果面板或商店面板的避让。
# 4. 这里不负责战斗结算，只负责把当前世界态投影到棋盘视觉上。
#
# 渲染约束：
# 1. 棋盘尺寸只从视口、底栏展开态和导出参数推导。
# 2. MultiMesh 数据只从 ally_deployed / enemy_deployed 读取。
# 3. 单位缩放倍率要回写到 state.unit_scale_factor。
# 4. deploy_overlay 与 hex_grid 的 queue_redraw 必须保持同一时机。
# 5. 新旧入口兼容只体现在 refs/state 字段读取，不再回到 host.call。
# 6. renderer 是世界协作者，不应直接抓取 HUD presenter 或 coordinator。
# 7. renderer 的所有配置都从 delegate 导出参数读取，避免复制配置。
#
# 迁移备忘：
# 1. 旧战场链路里棋盘自适应先在 runtime，后在 ui 覆写过一次。
# 2. Phase 2 先把基础棋盘适配能力收到 renderer，后续再由 presenter 提供 UI 避让输入。
# 3. 这意味着当前 renderer 只看底栏，不主动看库存、商店或结果面板。
# 4. 真正的“按面板矩形避让棋盘”留到 Batch 3 的 HUD 迁移阶段处理。
# 5. 但即便如此，棋盘尺寸、原点和单位缩放口径也应该先稳定下来。
# 6. 这样世界交互和 HUD 投影才能分别演进，不会再次缠成继承链。
# 7. MultiMesh 刷新也必须停留在这个协作者，避免 world controller 重新拼单位数组。
# 8. 如果将来替换成别的渲染策略，也只需要替换这个协作者。
# 9. 这正是 Phase 2 要求“世界交互职责线可静态定位”的一部分。
# 10. renderer 不参与开战、结算、奖励，也不参与详情或 tooltip 的任何展示。
# 11. renderer 只负责“给定世界状态时，棋盘应该怎么摆、单位应该怎么缩放”。
# 12. 任何新的渲染诊断信息，也应该在这里提供，而不是回到根场景。

const SQRT3: float = 1.7320508

var _refs = null
var _state = null
var _delegate = null
var _initialized: bool = false


# ===========================
# 装配与刷新入口
# ===========================
# 显式绑定渲染协作者需要的场景引用、状态和世界控制器委托。
func initialize(refs, state, delegate) -> void:
	_refs = refs
	_state = state
	_delegate = delegate
	_initialized = (
		_refs != null
		and _state != null
		and _delegate != null
		and _get_ref("hex_grid") != null
		and _get_ref("multimesh_renderer") != null
		and _get_ref("deploy_overlay") != null
	)


# 对外暴露初始化状态，供 Batch 2 烟测和 world controller 校验。
func is_initialized() -> bool:
	return _initialized


# ===========================
# 棋盘刷新与尺寸计算
# ===========================
# 根据当前部署映射重建 MultiMesh 数据，减少棋盘上的节点绘制开销。
func refresh_multimesh() -> void:
	var units: Array[Node] = []
	var ally_deployed: Dictionary = _read_state("ally_deployed", {})
	var enemy_deployed: Dictionary = _read_state("enemy_deployed", {})
	for unit in ally_deployed.values():
		if _delegate._is_valid_unit(unit):
			units.append(unit)
	for unit in enemy_deployed.values():
		if _delegate._is_valid_unit(unit):
			units.append(unit)

	var multimesh_renderer = _get_ref("multimesh_renderer")
	if multimesh_renderer != null:
		multimesh_renderer.set_units(units)


# 依据视口尺寸和底栏占位重算棋盘尺寸、原点偏移与单位缩放倍率。
func refit_hex_grid() -> void:
	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return

	var viewport: Viewport = _delegate.get_viewport()
	if viewport == null:
		return
	var viewport_size: Vector2 = viewport.get_visible_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return

	var bottom_expanded: bool = bool(_read_state("bottom_expanded", true))
	var bottom_reserved: float = (
		float(_get_value(_delegate, "bottom_reserved_preparation", 250.0))
		if bottom_expanded
		else float(_get_value(_delegate, "bottom_reserved_collapsed", 54.0))
	)
	var board_margin: float = float(_get_value(_delegate, "board_margin", 20.0))
	var top_reserved_height: float = float(_get_value(_delegate, "top_reserved_height", 64.0))
	var available_w: float = maxf(viewport_size.x - board_margin * 2.0, 220.0)
	var available_h: float = maxf(
		viewport_size.y - top_reserved_height - bottom_reserved - board_margin,
		160.0
	)
	var fit_hex: float = calculate_fit_hex_size(available_w, available_h)
	hex_grid.set("hex_size", fit_hex)

	var board_size: Vector2 = calculate_board_pixel_size(fit_hex)
	hex_grid.set("origin_offset", Vector2(
		board_margin + (available_w - board_size.x) * 0.5 + fit_hex * 0.8660254,
		top_reserved_height + (available_h - board_size.y) * 0.5 + fit_hex
	))
	hex_grid.queue_redraw()

	var deploy_overlay = _get_ref("deploy_overlay")
	if deploy_overlay != null:
		deploy_overlay.queue_redraw()

	# 单位缩放统一跟随棋格尺寸变化，避免不同分辨率下形体失真。
	var unit_visual_scale_multiplier: float = float(
		_get_value(_delegate, "unit_visual_scale_multiplier", 0.5)
	)
	var adaptive_scale: float = clampf((fit_hex * 1.52) / 32.0, 0.42, 1.10)
	_write_state(
		"unit_scale_factor",
		clampf(adaptive_scale * unit_visual_scale_multiplier, 0.20, 1.10)
	)
	_delegate._apply_visual_to_all_units()


# 这里开始是一组纯计算辅助函数，避免世界控制器自己写几何公式。
# 计算在当前可用矩形内能完整容纳棋盘的最佳 hex_size。
func calculate_fit_hex_size(available_w: float, available_h: float) -> float:
	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return 16.0

	var min_hex_size: float = float(_get_value(_delegate, "min_hex_size", 10.0))
	var max_hex_size: float = float(_get_value(_delegate, "max_hex_size", 24.0))
	if hex_grid.has_method("get_layout_fit_hex_size"):
		var layout_fit: Variant = hex_grid.get_layout_fit_hex_size(available_w, available_h)
		return clampf(float(layout_fit), min_hex_size, max_hex_size)

	var grid_w: int = maxi(int(hex_grid.get("grid_width")), 1)
	var grid_h: int = maxi(int(hex_grid.get("grid_height")), 1)
	var width_coeff: float = SQRT3 * (float(grid_w - 1) + float(grid_h - 1) * 0.5) + SQRT3
	var height_coeff: float = 1.5 * float(grid_h - 1) + 2.0
	return clampf(
		minf(
			available_w / maxf(width_coeff, 1.0),
			available_h / maxf(height_coeff, 1.0)
		),
		min_hex_size,
		max_hex_size
	)


# 把 hex_size 转成棋盘像素尺寸，供 origin_offset 计算居中位置。
func calculate_board_pixel_size(hex_size: float) -> Vector2:
	var hex_grid = _get_ref("hex_grid")
	if hex_grid == null:
		return Vector2.ZERO
	if hex_grid.has_method("get_layout_board_size"):
		var layout_size: Variant = hex_grid.get_layout_board_size(hex_size)
		if layout_size is Vector2:
			return layout_size

	var grid_w: int = maxi(int(hex_grid.get("grid_width")), 1)
	var grid_h: int = maxi(int(hex_grid.get("grid_height")), 1)
	var x_radius: float = hex_size * 0.8660254
	var board_w: float = hex_size * SQRT3 * (float(grid_w - 1) + float(grid_h - 1) * 0.5) + x_radius * 2.0
	var board_h: float = hex_size * 1.5 * float(grid_h - 1) + hex_size * 2.0
	return Vector2(board_w, board_h)


# ===========================
# 新旧入口兼容读取
# ===========================
# refs 读取兼容新入口 refs 节点与旧 runtime 直接注入对象。
func _get_ref(key: String, default_value = null):
	if _refs == null:
		return default_value
	if _refs is Dictionary:
		return (_refs as Dictionary).get(key, default_value)
	var value: Variant = _refs.get(key)
	if value == null:
		return default_value
	return value


# state 读取统一兼容新字段名和旧 runtime 下划线字段名。
func _read_state(key: String, default_value = null):
	if _state == null:
		return default_value
	var keys: Array[String] = [key, "_%s" % key]
	if _state is Dictionary:
		var dict_state: Dictionary = _state as Dictionary
		for current_key in keys:
			if dict_state.has(current_key):
				return dict_state[current_key]
		return default_value
	for current_key in keys:
		if _has_property(_state, current_key):
			return _state.get(current_key)
	return default_value


# 渲染协作者只通过这里修改状态，避免分散 set 逻辑。
func _write_state(key: String, value) -> void:
	if _state == null:
		return
	var keys: Array[String] = [key, "_%s" % key]
	if _state is Dictionary:
		var dict_state: Dictionary = _state as Dictionary
		dict_state[keys[0]] = value
		return
	for current_key in keys:
		if _has_property(_state, current_key):
			_state.set(current_key, value)
			return
	_state.set(keys[0], value)


# 统一读取 delegate 上的导出配置，避免把配置镜像到 refs 或 state。
func _get_value(source, key: String, default_value):
	if source == null:
		return default_value
	if source is Dictionary:
		return (source as Dictionary).get(key, default_value)
	if _has_property(source, key):
		var value: Variant = source.get(key)
		if value != null:
			return value
	return default_value


# 通过属性表判断字段是否存在，保证兼容新旧入口对象结构。
func _has_property(target, property_name: String) -> bool:
	if target == null or not (target is Object):
		return false
	var properties: Array = (target as Object).get_property_list()
	for property_value in properties:
		if not (property_value is Dictionary):
			continue
		var property_info: Dictionary = property_value as Dictionary
		if str(property_info.get("name", "")) == property_name:
			return true
	return false


