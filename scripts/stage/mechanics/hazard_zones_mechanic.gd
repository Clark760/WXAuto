extends "res://scripts/stage/mechanics/base_mechanic.gd"
class_name HazardZonesMechanic

# ===========================
# 机制：天地为炉（移动危险区）
# ===========================
# 说明：
# 1. 危险区会周期重定位，重定位后先 warning 再生效；
# 2. 生效后对范围内全体单位持续造成环境伤害；
# 3. 视觉先用轻量 Polygon2D 标记，便于调试关卡。

var _elapsed: float = 0.0
var _next_reposition_at: float = 0.0
var _hazards: Array[Dictionary] = [] # {center, active_at, visuals}
var _visual_root: Node2D = null
var _rng := RandomNumberGenerator.new()


func setup(mechanic_config: Dictionary, mechanic_context: Dictionary) -> void:
	super.setup(mechanic_config, mechanic_context)
	_rng.randomize()
	_elapsed = 0.0
	_hazards.clear()
	_setup_visual_root()

	var move_interval: float = maxf(float(config.get("move_interval_seconds", 8.0)), 1.0)
	_next_reposition_at = move_interval
	_roll_hazard_positions(true)


func cleanup() -> void:
	super.cleanup()
	_clear_visuals()
	_hazards.clear()


func tick(delta: float, _runtime_context: Dictionary) -> void:
	if not is_active:
		return
	var boss: Node = _get_primary_boss_unit()
	if boss == null or not _is_unit_alive(boss):
		return

	_elapsed += delta
	var move_interval: float = maxf(float(config.get("move_interval_seconds", 8.0)), 1.0)
	if _elapsed >= _next_reposition_at:
		_roll_hazard_positions(true)
		_next_reposition_at += move_interval

	_update_visual_state()
	_apply_hazard_damage(delta)


func _apply_hazard_damage(delta: float) -> void:
	var combat_manager: Node = _get_combat_manager()
	if combat_manager == null or not is_instance_valid(combat_manager):
		return
	if not combat_manager.has_method("get_alive_units"):
		return
	if not combat_manager.has_method("get_unit_cell_of"):
		return
	if not combat_manager.has_method("apply_environment_damage"):
		return

	var damage_per_second: float = maxf(float(config.get("damage_per_second", 20.0)), 0.0)
	if damage_per_second <= 0.0:
		return
	var radius_cells: int = maxi(int(config.get("radius_cells", 2)), 0)
	var damage_per_tick: float = damage_per_second * delta
	if damage_per_tick <= 0.0:
		return

	var units_value: Variant = combat_manager.call("get_alive_units", 0)
	if not (units_value is Array):
		return
	var units: Array = units_value

	for hazard in _hazards:
		var active_at: float = float(hazard.get("active_at", 0.0))
		if _elapsed < active_at:
			continue
		var center: Vector2i = hazard.get("center", Vector2i(-1, -1))
		if center.x < 0:
			continue
		for unit_value in units:
			if not (unit_value is Node):
				continue
			var unit: Node = unit_value
			var cell_value: Variant = combat_manager.call("get_unit_cell_of", unit)
			if not (cell_value is Vector2i):
				continue
			var cell: Vector2i = cell_value as Vector2i
			if cell.x < 0:
				continue
			if _hex_distance(center, cell) > radius_cells:
				continue
			combat_manager.call("apply_environment_damage", unit, damage_per_tick, null, "internal")


func _roll_hazard_positions(with_warning: bool) -> void:
	var count: int = maxi(int(config.get("count", 2)), 1)
	var warning_seconds: float = maxf(float(config.get("warning_seconds", 1.5)), 0.0)
	_hazards.clear()
	for _i in range(count):
		var center: Vector2i = _pick_random_cell()
		if center.x < 0:
			continue
		var active_at: float = _elapsed + (warning_seconds if with_warning else 0.0)
		_hazards.append({
			"center": center,
			"active_at": active_at,
			"visuals": []
		})
	_rebuild_hazard_visuals()
	_append_log("战场危险区发生位移。")


func _pick_random_cell() -> Vector2i:
	var hex_grid: Node = _get_hex_grid()
	if hex_grid == null or not is_instance_valid(hex_grid):
		return Vector2i(-1, -1)
	var width: int = maxi(int(hex_grid.get("grid_width")), 1)
	var height: int = maxi(int(hex_grid.get("grid_height")), 1)
	var x: int = _rng.randi_range(0, width - 1)
	var y: int = _rng.randi_range(0, height - 1)
	return Vector2i(x, y)


func _setup_visual_root() -> void:
	var hex_grid: Node = _get_hex_grid()
	if hex_grid == null or not is_instance_valid(hex_grid):
		return
	if _visual_root != null and is_instance_valid(_visual_root):
		return
	_visual_root = Node2D.new()
	_visual_root.name = "HazardZoneVisuals"
	hex_grid.add_child(_visual_root)


func _clear_visuals() -> void:
	if _visual_root == null or not is_instance_valid(_visual_root):
		return
	_visual_root.queue_free()
	_visual_root = null


func _rebuild_hazard_visuals() -> void:
	if _visual_root == null or not is_instance_valid(_visual_root):
		return
	for child in _visual_root.get_children():
		child.queue_free()

	var hex_grid: Node = _get_hex_grid()
	if hex_grid == null:
		return
	var radius_cells: int = maxi(int(config.get("radius_cells", 2)), 0)
	for idx in range(_hazards.size()):
		var hazard: Dictionary = _hazards[idx]
		var center: Vector2i = hazard.get("center", Vector2i(-1, -1))
		var visuals: Array = []
		for cell in _collect_cells_in_radius(center, radius_cells):
			var poly := Polygon2D.new()
			var points_value: Variant = hex_grid.call("get_hex_points_local", cell)
			if not (points_value is PackedVector2Array):
				poly.queue_free()
				continue
			poly.polygon = points_value
			poly.color = Color(1.0, 0.32, 0.2, 0.18)
			poly.z_index = -1
			_visual_root.add_child(poly)
			visuals.append(poly)
		hazard["visuals"] = visuals
		_hazards[idx] = hazard


func _update_visual_state() -> void:
	for idx in range(_hazards.size()):
		var hazard: Dictionary = _hazards[idx]
		var active_at: float = float(hazard.get("active_at", 0.0))
		var is_active_zone: bool = _elapsed >= active_at
		var visuals_value: Variant = hazard.get("visuals", [])
		if not (visuals_value is Array):
			continue
		for node_value in visuals_value:
			var poly: Polygon2D = node_value as Polygon2D
			if poly == null or not is_instance_valid(poly):
				continue
			poly.color = Color(1.0, 0.35, 0.22, 0.28) if is_active_zone else Color(1.0, 0.92, 0.35, 0.18)


func _collect_cells_in_radius(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if center.x < 0:
		return out
	var hex_grid: Node = _get_hex_grid()
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	var queue: Array[Vector2i] = [center]
	var visited: Dictionary = {_cell_key(center): true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance(center, cell) > radius:
			continue
		out.append(cell)
		var neighbors_value: Variant = hex_grid.call("get_neighbor_cells", cell)
		if not (neighbors_value is Array):
			continue
		for neighbor_value in neighbors_value:
			if not (neighbor_value is Vector2i):
				continue
			var neighbor: Vector2i = neighbor_value as Vector2i
			var key: String = _cell_key(neighbor)
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


func _hex_distance(a: Vector2i, b: Vector2i) -> int:
	var hex_grid: Node = _get_hex_grid()
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]

