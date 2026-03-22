extends Node

# M5 渲染职责拆分：MultiMesh 与棋盘自适应缩放

const SQRT3: float = 1.7320508

var _owner: Node = null


func configure(host: Node) -> void:
	_owner = host


func refresh_multimesh() -> void:
	if _owner == null:
		return
	var units: Array[Node] = []
	var ally_deployed: Dictionary = _owner.get("_ally_deployed")
	var enemy_deployed: Dictionary = _owner.get("_enemy_deployed")
	for unit in ally_deployed.values():
		if bool(_owner.call("_is_valid_unit", unit)):
			units.append(unit)
	for unit in enemy_deployed.values():
		if bool(_owner.call("_is_valid_unit", unit)):
			units.append(unit)
	var multimesh_renderer: Node = _owner.get("multimesh_renderer")
	if multimesh_renderer != null:
		multimesh_renderer.call("set_units", units)


func refit_hex_grid() -> void:
	if _owner == null:
		return
	var viewport_size: Vector2 = _owner.get_viewport().get_visible_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return
	var bottom_expanded: bool = bool(_owner.get("_bottom_expanded"))
	var bottom_reserved: float = float(_owner.get("bottom_reserved_preparation")) if bottom_expanded else float(_owner.get("bottom_reserved_collapsed"))
	var board_margin: float = float(_owner.get("board_margin"))
	var top_reserved_height: float = float(_owner.get("top_reserved_height"))
	var available_w: float = maxf(viewport_size.x - board_margin * 2.0, 220.0)
	var available_h: float = maxf(viewport_size.y - top_reserved_height - bottom_reserved - board_margin, 160.0)
	var fit_hex: float = calculate_fit_hex_size(available_w, available_h)
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return
	hex_grid.set("hex_size", fit_hex)
	var board_size: Vector2 = calculate_board_pixel_size(fit_hex)
	hex_grid.set("origin_offset", Vector2(
		board_margin + (available_w - board_size.x) * 0.5 + fit_hex * 0.8660254,
		top_reserved_height + (available_h - board_size.y) * 0.5 + fit_hex
	))
	hex_grid.call("queue_redraw")
	var deploy_overlay: Node = _owner.get("deploy_overlay")
	if deploy_overlay != null:
		deploy_overlay.call("queue_redraw")
	# 角色缩放 = 棋格自适应比例 * 配置倍率，兼顾不同分辨率显示效果。
	var unit_visual_scale_multiplier: float = float(_owner.get("unit_visual_scale_multiplier"))
	var adaptive_scale: float = clampf((fit_hex * 1.52) / 32.0, 0.42, 1.10)
	_owner.set("_unit_scale_factor", clampf(adaptive_scale * unit_visual_scale_multiplier, 0.20, 1.10))
	_owner.call("_apply_visual_to_all_units")


func calculate_fit_hex_size(available_w: float, available_h: float) -> float:
	if _owner == null:
		return 16.0
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return 16.0
	var min_hex_size: float = float(_owner.get("min_hex_size"))
	var max_hex_size: float = float(_owner.get("max_hex_size"))
	if hex_grid.has_method("get_layout_fit_hex_size"):
		var layout_fit: Variant = hex_grid.call("get_layout_fit_hex_size", available_w, available_h)
		return clampf(float(layout_fit), min_hex_size, max_hex_size)
	var grid_w: int = maxi(int(hex_grid.get("grid_width")), 1)
	var grid_h: int = maxi(int(hex_grid.get("grid_height")), 1)
	var width_coeff: float = SQRT3 * (float(grid_w - 1) + float(grid_h - 1) * 0.5) + SQRT3
	var height_coeff: float = 1.5 * float(grid_h - 1) + 2.0
	return clampf(minf(available_w / maxf(width_coeff, 1.0), available_h / maxf(height_coeff, 1.0)), min_hex_size, max_hex_size)


func calculate_board_pixel_size(hex_size: float) -> Vector2:
	if _owner == null:
		return Vector2.ZERO
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return Vector2.ZERO
	if hex_grid.has_method("get_layout_board_size"):
		var layout_size: Variant = hex_grid.call("get_layout_board_size", hex_size)
		if layout_size is Vector2:
			return layout_size
	var grid_w: int = maxi(int(hex_grid.get("grid_width")), 1)
	var grid_h: int = maxi(int(hex_grid.get("grid_height")), 1)
	var x_radius: float = hex_size * 0.8660254
	var board_w: float = hex_size * SQRT3 * (float(grid_w - 1) + float(grid_h - 1) * 0.5) + x_radius * 2.0
	var board_h: float = hex_size * 1.5 * float(grid_h - 1) + hex_size * 2.0
	return Vector2(board_w, board_h)
