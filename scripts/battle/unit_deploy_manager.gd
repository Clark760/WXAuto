extends Node

# M5 拆分：单位部署/回收/生成模块。
# 说明：该模块持有 battlefield_runtime 作为上下文，不改外部调用接口。

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2

var _owner: Node = null


func configure(host: Node) -> void:
	_owner = host


func is_ally_deploy_zone(cell: Vector2i) -> bool:
	if _owner == null:
		return false
	var rect: Dictionary = _resolve_ally_deploy_rect()
	return (
		cell.x >= int(rect.get("x_min", 0))
		and cell.x <= int(rect.get("x_max", -1))
		and cell.y >= int(rect.get("y_min", 0))
		and cell.y <= int(rect.get("y_max", -1))
	)


func can_deploy_ally_to_cell(unit: Node, cell: Vector2i) -> bool:
	if _owner == null:
		return false
	if unit == null:
		return false
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null or not bool(hex_grid.call("is_inside_grid", cell)):
		return false
	if not is_ally_deploy_zone(cell):
		return false
	var ally_deployed: Dictionary = _owner.get("_ally_deployed")
	var unit_id: String = _get_unit_id(unit)
	if not unit_id.is_empty():
		if _has_other_unit_with_id(ally_deployed, unit_id, unit):
			return false
	var key: String = str(_owner.call("_cell_key", cell))
	if not ally_deployed.has(key):
		return true
	return ally_deployed[key] == unit


func deploy_ally_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	if _owner == null or unit == null:
		return
	if not can_deploy_ally_to_cell(unit, cell):
		return
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return
	var ally_deployed: Dictionary = _owner.get("_ally_deployed")
	var map_key: String = str(_owner.call("_cell_key", cell))
	ally_deployed[map_key] = unit
	_owner.call("_set_unit_map_cache", unit, map_key, TEAM_ALLY)
	unit.set("deployed_cell", cell)
	unit.call("set_team", TEAM_ALLY)
	unit.call("set_on_bench_state", false, -1)
	unit.set("is_in_combat", false)
	var node2d: Node2D = unit as Node2D
	if node2d != null:
		node2d.position = hex_grid.call("axial_to_world", cell)
	var canvas_item: CanvasItem = unit as CanvasItem
	if canvas_item != null:
		canvas_item.visible = true
	_owner.call("_apply_unit_visual_presentation", unit)
	unit.call("play_anim_state", 0, {})


func deploy_enemy_unit_to_cell(unit: Node, cell: Vector2i) -> void:
	if _owner == null or unit == null:
		return
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return
	var enemy_deployed: Dictionary = _owner.get("_enemy_deployed")
	var map_key: String = str(_owner.call("_cell_key", cell))
	enemy_deployed[map_key] = unit
	_owner.call("_set_unit_map_cache", unit, map_key, TEAM_ENEMY)
	unit.set("deployed_cell", cell)
	unit.call("set_team", TEAM_ENEMY)
	unit.call("set_on_bench_state", false, -1)
	unit.set("is_in_combat", false)
	var node2d: Node2D = unit as Node2D
	if node2d != null:
		node2d.position = hex_grid.call("axial_to_world", cell)
	var canvas_item: CanvasItem = unit as CanvasItem
	if canvas_item != null:
		canvas_item.visible = true
	_owner.call("_apply_unit_visual_presentation", unit)
	unit.call("play_anim_state", 0, {})


func remove_ally_mapping(unit: Node) -> void:
	if _owner == null:
		return
	var ally_deployed: Dictionary = _owner.get("_ally_deployed")
	remove_unit_from_map(ally_deployed, unit)


func spawn_enemy_wave(count: int) -> void:
	if _owner == null:
		return
	clear_enemy_wave()
	var unit_factory: Node = _owner.get("unit_factory")
	var unit_layer: Node = _owner.get("unit_layer")
	if unit_factory == null or unit_layer == null:
		return
	var unit_ids: Array = unit_factory.call("get_unit_ids")
	var cells: Array[Vector2i] = collect_enemy_spawn_cells()
	if unit_ids.is_empty() or cells.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_owner.call("_shuffle_cells", cells, rng)
	var spawn_total: int = mini(count, cells.size())
	for i in range(spawn_total):
		var unit_id: String = str(unit_ids[rng.randi_range(0, unit_ids.size() - 1)])
		var unit_node: Node = unit_factory.call("acquire_unit", unit_id, -1, unit_layer)
		if unit_node != null:
			deploy_enemy_unit_to_cell(unit_node, cells[i])


func clear_enemy_wave() -> void:
	if _owner == null:
		return
	var unit_factory: Node = _owner.get("unit_factory")
	var enemy_deployed: Dictionary = _owner.get("_enemy_deployed")
	for enemy in enemy_deployed.values():
		if bool(_owner.call("_is_valid_unit", enemy)):
			_owner.call("_clear_unit_map_cache", enemy)
			if unit_factory != null:
				unit_factory.call("release_unit", enemy)
	enemy_deployed.clear()


func auto_deploy_from_bench(limit: int) -> void:
	if _owner == null:
		return
	var bench_ui: Node = _owner.get("bench_ui")
	if bench_ui == null:
		return
	var ally_deployed: Dictionary = _owner.get("_ally_deployed")
	var deploy_cells: Array[Vector2i] = collect_ally_spawn_cells()
	var deployed_count: int = 0
	for cell in deploy_cells:
		if deployed_count >= limit:
			break
		var bench_units: Array = bench_ui.call("get_all_units")
		if bench_units.is_empty():
			break
		if ally_deployed.has(str(_owner.call("_cell_key", cell))):
			continue
		var unit: Node = null
		for idx in range(bench_units.size() - 1, -1, -1):
			var candidate: Node = bench_units[idx] as Node
			if candidate == null:
				continue
			if not can_deploy_ally_to_cell(candidate, cell):
				continue
			unit = candidate
			break
		if unit == null:
			continue
		bench_ui.call("remove_unit", unit)
		deploy_ally_unit_to_cell(unit, cell)
		deployed_count += 1


func collect_ally_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if _owner == null:
		return cells
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return cells
	var rect: Dictionary = _resolve_ally_deploy_rect()
	var x_min: int = int(rect.get("x_min", 0))
	var x_max: int = int(rect.get("x_max", -1))
	var y_min: int = int(rect.get("y_min", 0))
	var y_max: int = int(rect.get("y_max", -1))
	for r in range(y_min, y_max + 1):
		for q in range(x_min, x_max + 1):
			cells.append(Vector2i(q, r))
	return cells


func collect_enemy_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if _owner == null:
		return cells
	var hex_grid: Node = _owner.get("hex_grid")
	if hex_grid == null:
		return cells
	var rect: Dictionary = _resolve_ally_deploy_rect()
	var x_min: int = int(rect.get("x_min", 0))
	var x_max: int = int(rect.get("x_max", -1))
	var y_min: int = int(rect.get("y_min", 0))
	var y_max: int = int(rect.get("y_max", -1))
	var width: int = int(hex_grid.get("grid_width"))
	var height: int = int(hex_grid.get("grid_height"))
	for r in range(height):
		for q in range(width):
			if q >= x_min and q <= x_max and r >= y_min and r <= y_max:
				continue
			cells.append(Vector2i(q, r))
	return cells


func _resolve_ally_deploy_rect() -> Dictionary:
	var default_rect: Dictionary = _build_default_deploy_rect()
	if _owner == null:
		return default_rect
	var rect_source: Dictionary = {}
	if _owner_has_property("_current_deploy_zone"):
		var stage_rect_value: Variant = _owner.get("_current_deploy_zone")
		if stage_rect_value is Dictionary:
			rect_source = (stage_rect_value as Dictionary).duplicate(true)
	if rect_source.is_empty():
		var overlay: Node = _owner.get("deploy_overlay")
		if overlay != null:
			rect_source = {
				"x_min": int(overlay.get("deploy_x_min")),
				"x_max": int(overlay.get("deploy_x_max")),
				"y_min": int(overlay.get("deploy_y_min")),
				"y_max": int(overlay.get("deploy_y_max"))
			}
	return _sanitize_deploy_rect(rect_source, default_rect)


func _build_default_deploy_rect() -> Dictionary:
	var width: int = 1
	var height: int = 1
	if _owner != null:
		var hex_grid: Node = _owner.get("hex_grid")
		if hex_grid != null:
			width = maxi(int(hex_grid.get("grid_width")), 1)
			height = maxi(int(hex_grid.get("grid_height")), 1)
	var ally_width: int = maxi(width / 2, 1)
	return {
		"x_min": 0,
		"x_max": ally_width - 1,
		"y_min": 0,
		"y_max": height - 1
	}


func _sanitize_deploy_rect(source: Dictionary, fallback: Dictionary) -> Dictionary:
	var width: int = 1
	var height: int = 1
	if _owner != null:
		var hex_grid: Node = _owner.get("hex_grid")
		if hex_grid != null:
			width = maxi(int(hex_grid.get("grid_width")), 1)
			height = maxi(int(hex_grid.get("grid_height")), 1)
	var x_min: int = clampi(int(source.get("x_min", int(fallback.get("x_min", 0)))), 0, width - 1)
	var x_max: int = clampi(int(source.get("x_max", int(fallback.get("x_max", width - 1)))), 0, width - 1)
	var y_min: int = clampi(int(source.get("y_min", int(fallback.get("y_min", 0)))), 0, height - 1)
	var y_max: int = clampi(int(source.get("y_max", int(fallback.get("y_max", height - 1)))), 0, height - 1)
	if x_min > x_max:
		var swap_x: int = x_min
		x_min = x_max
		x_max = swap_x
	if y_min > y_max:
		var swap_y: int = y_min
		y_min = y_max
		y_max = swap_y
	return {
		"x_min": x_min,
		"x_max": x_max,
		"y_min": y_min,
		"y_max": y_max
	}


func _owner_has_property(property_name: String) -> bool:
	if _owner == null:
		return false
	var properties: Array = _owner.get_property_list()
	for property_value in properties:
		if not (property_value is Dictionary):
			continue
		var property_info: Dictionary = property_value as Dictionary
		if str(property_info.get("name", "")) == property_name:
			return true
	return false


func _get_unit_id(unit: Node) -> String:
	if unit == null:
		return ""
	return str(unit.get("unit_id")).strip_edges()


func _has_other_unit_with_id(target_map: Dictionary, unit_id: String, except_unit: Node) -> bool:
	if unit_id.is_empty():
		return false
	for other in target_map.values():
		if other == null:
			continue
		if other == except_unit:
			continue
		if _get_unit_id(other) == unit_id:
			return true
	return false


func collect_units_from_map(map_value: Dictionary) -> Array[Node]:
	var units: Array[Node] = []
	if _owner == null:
		return units
	for unit in map_value.values():
		if bool(_owner.call("_is_valid_unit", unit)):
			units.append(unit)
	return units


func remove_unit_from_map(target_map: Dictionary, unit: Node) -> void:
	if _owner == null:
		return
	# 优先走 O(1) 路径：用 deployed_cell 直接构造 key。
	if bool(_owner.call("_is_valid_unit", unit)):
		var cell: Vector2i = unit.get("deployed_cell")
		if cell.x > -900:
			var key: String = str(_owner.call("_cell_key", cell))
			if target_map.has(key) and target_map[key] == unit:
				target_map.erase(key)
				_owner.call("_clear_unit_map_cache", unit)
				return
	# 兜底：deployed_cell 不可信时回退遍历。
	var remove_key: String = ""
	for key2 in target_map.keys():
		if target_map[key2] == unit:
			remove_key = str(key2)
			break
	if not remove_key.is_empty():
		target_map.erase(remove_key)
		_owner.call("_clear_unit_map_cache", unit)


func remove_unit_from_map_cached(target_map: Dictionary, unit: Node) -> void:
	if _owner == null:
		return
	if not bool(_owner.call("_is_valid_unit", unit)):
		return
	var remove_key: String = str(_owner.call("_get_unit_map_key", unit))
	if not remove_key.is_empty() and target_map.get(remove_key, null) == unit:
		target_map.erase(remove_key)
		_owner.call("_clear_unit_map_cache", unit)
		return
	for key in target_map.keys():
		if target_map[key] == unit:
			target_map.erase(key)
			_owner.call("_clear_unit_map_cache", unit)
			return
