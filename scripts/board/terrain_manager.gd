extends RefCounted
class_name TerrainManager

# ===========================
# 临时地形管理器（M5）
# ===========================
# 职责：
# 1. 维护 create_terrain 生成的临时地形生命周期；
# 2. 在逻辑帧按地形类型结算伤害/治疗/状态；
# 3. 维护 barrier 阻挡格并通知战斗层重建流场。

const TERRAIN_COLOR_BY_TYPE: Dictionary = {
	"fire": Color(0.96, 0.44, 0.2, 0.34),
	"ice": Color(0.45, 0.75, 0.98, 0.32),
	"poison": Color(0.52, 0.84, 0.44, 0.34),
	"heal": Color(0.45, 0.9, 0.56, 0.34),
	"barrier": Color(0.75, 0.9, 1.0, 0.42),
	"slow": Color(0.66, 0.54, 0.34, 0.34),
	"amp_damage": Color(0.92, 0.28, 0.28, 0.34)
}

const DEFAULT_DPS_BY_TYPE: Dictionary = {
	"fire": 25.0,
	"poison": 12.0,
	"burn_ground": 20.0
}

const DEFAULT_HEAL_PER_SECOND: float = 22.0
const DEFAULT_TICK_INTERVAL: float = 0.5

var _terrains: Array[Dictionary] = []
var _barrier_cells: Dictionary = {} # int(cell_key) -> true
var _visual_cells_cache: Dictionary = {} # int(cell_key) -> Color
var _needs_visual_refresh: bool = true


func clear_all() -> void:
	_terrains.clear()
	_barrier_cells.clear()
	_visual_cells_cache.clear()
	_needs_visual_refresh = true


func add_terrain(config: Dictionary, source: Node, context: Dictionary = {}) -> Dictionary:
	var entry: Dictionary = _build_terrain_entry(config, source, context)
	if entry.is_empty():
		return {"added": false, "barrier_changed": false, "visual_changed": false}
	_terrains.append(entry)
	var barrier_changed: bool = false
	if str(entry.get("terrain_type", "")) == "barrier":
		barrier_changed = _rebuild_barrier_cells(context.get("hex_grid", null))
	_needs_visual_refresh = true
	return {
		"added": true,
		"barrier_changed": barrier_changed,
		"visual_changed": true
	}


func tick(delta: float, context: Dictionary) -> Dictionary:
	if _terrains.is_empty():
		return {
			"barrier_changed": false,
			"visual_changed": false
		}

	var next_terrains: Array[Dictionary] = []
	var barrier_changed: bool = false
	var visual_changed: bool = false
	var hex_grid: Node = context.get("hex_grid", null)

	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = (terrain_value as Dictionary).duplicate(true)
		var previous_remaining: float = float(terrain.get("remaining", 0.0))
		var remaining: float = previous_remaining
		if remaining >= 0.0:
			remaining -= delta
			terrain["remaining"] = remaining
		var expired: bool = previous_remaining >= 0.0 and remaining <= 0.0
		if expired:
			visual_changed = true
			continue

		var terrain_type: String = str(terrain.get("terrain_type", "")).strip_edges().to_lower()
		if terrain_type != "barrier":
			var tick_interval: float = maxf(float(terrain.get("tick_interval", DEFAULT_TICK_INTERVAL)), 0.05)
			var tick_accum: float = float(terrain.get("tick_accum", 0.0)) + delta
			while tick_accum >= tick_interval:
				tick_accum -= tick_interval
				_apply_terrain_tick(terrain, tick_interval, context)
			terrain["tick_accum"] = tick_accum

		next_terrains.append(terrain)
	_terrains = next_terrains
	if _has_barrier_terrain():
		barrier_changed = _rebuild_barrier_cells(hex_grid)
	else:
		if not _barrier_cells.is_empty():
			_barrier_cells.clear()
			barrier_changed = true
	_needs_visual_refresh = _needs_visual_refresh or visual_changed or barrier_changed
	return {
		"barrier_changed": barrier_changed,
		"visual_changed": _needs_visual_refresh
	}


func get_barrier_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for key_value in _barrier_cells.keys():
		cells.append(_cell_from_int_key(int(key_value)))
	return cells


func get_visual_cells(hex_grid: Node) -> Dictionary:
	if _needs_visual_refresh:
		_visual_cells_cache = _build_visual_cells(hex_grid)
		_needs_visual_refresh = false
	return _visual_cells_cache.duplicate(true)


func _build_terrain_entry(config: Dictionary, source: Node, context: Dictionary) -> Dictionary:
	if config.is_empty():
		return {}
	var hex_grid: Node = context.get("hex_grid", null)
	if hex_grid == null or not is_instance_valid(hex_grid):
		return {}

	var center_cell: Vector2i = Vector2i(-1, -1)
	var center_cell_value: Variant = config.get("center_cell", null)
	if center_cell_value is Vector2i:
		center_cell = center_cell_value as Vector2i
	elif source != null and is_instance_valid(source):
		var source_node: Node2D = source as Node2D
		if source_node != null and hex_grid.has_method("world_to_axial"):
			center_cell = hex_grid.call("world_to_axial", source_node.position)
	if center_cell.x < 0 or not bool(hex_grid.call("is_inside_grid", center_cell)):
		return {}

	var terrain_type: String = str(config.get("terrain_type", "fire")).strip_edges().to_lower()
	var radius: int = maxi(int(config.get("radius", 1)), 0)
	var duration: float = float(config.get("duration", 0.0))
	if duration <= 0.0:
		return {}
	var source_id: int = -1
	var source_team: int = 0
	var source_unit_id: String = str(config.get("source_unit_id", "")).strip_edges()
	var source_name: String = str(config.get("source_name", "")).strip_edges()
	if source != null and is_instance_valid(source):
		source_id = source.get_instance_id()
		source_team = int(source.get("team_id"))
		source_unit_id = str(source.get("unit_id"))
		source_name = str(source.get("unit_name"))

	var target_mode: String = str(config.get("target_mode", "")).strip_edges().to_lower()
	if target_mode.is_empty():
		target_mode = _default_target_mode_for_terrain(terrain_type)
	var debuff_id: String = str(config.get("debuff_id", "")).strip_edges()
	if debuff_id.is_empty():
		debuff_id = _default_debuff_for_terrain(terrain_type)
	var buff_id: String = str(config.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		buff_id = _default_buff_for_terrain(terrain_type)

	return {
		"terrain_id": str(config.get("terrain_id", "terrain_%d" % Time.get_ticks_msec())).strip_edges(),
		"terrain_type": terrain_type,
		"center_cell": center_cell,
		"radius": radius,
		"remaining": duration,
		"tick_interval": maxf(float(config.get("tick_interval", DEFAULT_TICK_INTERVAL)), 0.05),
		"tick_accum": 0.0,
		"source_id": source_id,
		"source_team": source_team,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"target_mode": target_mode,
		"damage_per_second": maxf(float(config.get("damage_per_second", config.get("dps", _default_dps_for_terrain(terrain_type)))), 0.0),
		"heal_per_second": maxf(float(config.get("heal_per_second", DEFAULT_HEAL_PER_SECOND)), 0.0),
		"debuff_id": debuff_id,
		"buff_id": buff_id
	}


func _apply_terrain_tick(terrain: Dictionary, tick_seconds: float, context: Dictionary) -> void:
	var terrain_type: String = str(terrain.get("terrain_type", "")).strip_edges().to_lower()
	if terrain_type.is_empty():
		return
	var targets: Array[Node] = _collect_targets_in_terrain(terrain, context)
	if targets.is_empty():
		return

	var combat_manager: Node = context.get("combat_manager", null)
	var gongfa_manager: Node = context.get("gongfa_manager", null)
	var source_node: Node = _resolve_source_node(terrain, context)
	var source_fallback: Dictionary = _build_source_fallback_from_terrain(terrain)

	match terrain_type:
		"fire", "burn_ground":
			var fire_damage: float = float(terrain.get("damage_per_second", _default_dps_for_terrain(terrain_type))) * tick_seconds
			if combat_manager != null and combat_manager.has_method("apply_environment_damage") and fire_damage > 0.0:
				for unit in targets:
					combat_manager.call("apply_environment_damage", unit, fire_damage, source_node, "internal", source_fallback)
		"poison":
			var poison_damage: float = float(terrain.get("damage_per_second", _default_dps_for_terrain("poison"))) * tick_seconds
			if poison_damage > 0.0 and combat_manager != null and combat_manager.has_method("apply_environment_damage"):
				for poisoned in targets:
					combat_manager.call("apply_environment_damage", poisoned, poison_damage, source_node, "internal", source_fallback)
			if gongfa_manager != null and gongfa_manager.has_method("apply_runtime_buff"):
				var poison_id: String = str(terrain.get("debuff_id", "tangmen_poison")).strip_edges()
				for poisoned2 in targets:
					gongfa_manager.call("apply_runtime_buff", poisoned2, poison_id, 1.2, source_node, "terrain")
		"ice", "slow":
			if gongfa_manager != null and gongfa_manager.has_method("apply_runtime_buff"):
				var slow_id: String = str(terrain.get("debuff_id", "debuff_slow")).strip_edges()
				for slowed in targets:
					gongfa_manager.call("apply_runtime_buff", slowed, slow_id, 1.0, source_node, "terrain")
		"heal":
			var heal_value: float = float(terrain.get("heal_per_second", DEFAULT_HEAL_PER_SECOND)) * tick_seconds
			if heal_value <= 0.0:
				return
			for ally in targets:
				var combat: Node = ally.get_node_or_null("Components/UnitCombat")
				if combat != null and combat.has_method("restore_hp"):
					combat.call("restore_hp", heal_value)
		"amp_damage":
			if gongfa_manager != null and gongfa_manager.has_method("apply_runtime_buff"):
				var amp_buff_id: String = str(terrain.get("buff_id", "buff_terrain_amp_damage")).strip_edges()
				for ally_amp in targets:
					gongfa_manager.call("apply_runtime_buff", ally_amp, amp_buff_id, 1.0, source_node, "terrain")
		_:
			# 未定义行为的地形类型保留扩展点，默认不做结算。
			return


func _collect_targets_in_terrain(terrain: Dictionary, context: Dictionary) -> Array[Node]:
	var output: Array[Node] = []
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return output
	var combat_manager: Node = context.get("combat_manager", null)
	var hex_grid: Node = context.get("hex_grid", null)
	if hex_grid == null or not is_instance_valid(hex_grid):
		return output
	var center_cell: Vector2i = terrain.get("center_cell", Vector2i(-1, -1))
	if center_cell.x < 0:
		return output
	var radius: int = maxi(int(terrain.get("radius", 0)), 0)
	var source_team: int = int(terrain.get("source_team", 0))
	var target_mode: String = str(terrain.get("target_mode", "enemies")).strip_edges().to_lower()
	for unit_value in (all_units_value as Array):
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null or not bool(combat.get("is_alive")):
			continue
		var team_id: int = int(unit.get("team_id"))
		if target_mode == "allies" and source_team != 0 and team_id != source_team:
			continue
		if target_mode == "enemies" and source_team != 0 and team_id == source_team:
			continue
		var unit_cell: Vector2i = Vector2i(-1, -1)
		if combat_manager != null and combat_manager.has_method("get_unit_cell_of"):
			var cell_value: Variant = combat_manager.call("get_unit_cell_of", unit)
			if cell_value is Vector2i:
				unit_cell = cell_value as Vector2i
		if unit_cell.x < 0 and hex_grid.has_method("world_to_axial"):
			var unit_node2d: Node2D = unit as Node2D
			if unit_node2d != null:
				unit_cell = hex_grid.call("world_to_axial", unit_node2d.position)
		if unit_cell.x < 0:
			continue
		var dist: int = _hex_distance_cells(center_cell, unit_cell, hex_grid)
		if dist > radius:
			continue
		output.append(unit)
	return output


func _rebuild_barrier_cells(hex_grid: Node) -> bool:
	var next_cells: Dictionary = {}
	for terrain in _terrains:
		if not (terrain is Dictionary):
			continue
		var terrain_type: String = str((terrain as Dictionary).get("terrain_type", "")).strip_edges().to_lower()
		if terrain_type != "barrier":
			continue
		var center_cell: Vector2i = (terrain as Dictionary).get("center_cell", Vector2i(-1, -1))
		var radius: int = maxi(int((terrain as Dictionary).get("radius", 0)), 0)
		var cells: Array[Vector2i] = _collect_cells_in_radius(hex_grid, center_cell, radius)
		for cell in cells:
			next_cells[_cell_key_int(cell)] = true
	var changed: bool = next_cells.size() != _barrier_cells.size()
	if not changed:
		for key in next_cells.keys():
			if not _barrier_cells.has(key):
				changed = true
				break
	_barrier_cells = next_cells
	if changed:
		_needs_visual_refresh = true
	return changed


func _build_visual_cells(hex_grid: Node) -> Dictionary:
	var cells_colors: Dictionary = {}
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		var terrain_type: String = str(terrain.get("terrain_type", "")).strip_edges().to_lower()
		var center_cell: Vector2i = terrain.get("center_cell", Vector2i(-1, -1))
		var radius: int = maxi(int(terrain.get("radius", 0)), 0)
		var color: Color = TERRAIN_COLOR_BY_TYPE.get(terrain_type, Color(0.8, 0.8, 0.8, 0.25))
		for cell in _collect_cells_in_radius(hex_grid, center_cell, radius):
			var key: int = _cell_key_int(cell)
			if cells_colors.has(key):
				var current: Color = cells_colors[key] as Color
				cells_colors[key] = current.lerp(color, 0.5)
			else:
				cells_colors[key] = color
	return cells_colors


func _collect_cells_in_radius(hex_grid: Node, center_cell: Vector2i, radius_cells: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	if center_cell.x < 0 or center_cell.y < 0:
		return out
	if not bool(hex_grid.call("is_inside_grid", center_cell)):
		return out
	var queue: Array[Vector2i] = [center_cell]
	var visited: Dictionary = {_cell_key_int(center_cell): true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance_cells(center_cell, cell, hex_grid) > radius_cells:
			continue
		out.append(cell)
		var neighbors_value: Variant = hex_grid.call("get_neighbor_cells", cell)
		if not (neighbors_value is Array):
			continue
		for neighbor_value in (neighbors_value as Array):
			if not (neighbor_value is Vector2i):
				continue
			var neighbor: Vector2i = neighbor_value as Vector2i
			if not bool(hex_grid.call("is_inside_grid", neighbor)):
				continue
			var key: int = _cell_key_int(neighbor)
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


func _resolve_source_node(terrain: Dictionary, context: Dictionary) -> Node:
	var source_id: int = int(terrain.get("source_id", -1))
	if source_id <= 0:
		return null
	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager != null and combat_manager.has_method("get_unit_by_instance_id"):
		var resolved: Variant = combat_manager.call("get_unit_by_instance_id", source_id)
		if resolved is Node:
			return resolved as Node
	var all_units_value: Variant = context.get("all_units", [])
	if all_units_value is Array:
		for unit_value in (all_units_value as Array):
			if unit_value is Node and (unit_value as Node).get_instance_id() == source_id:
				return unit_value as Node
	return null


func _build_source_fallback_from_terrain(terrain: Dictionary) -> Dictionary:
	var source_id: int = int(terrain.get("source_id", -1))
	var source_unit_id: String = str(terrain.get("source_unit_id", "")).strip_edges()
	var source_name: String = str(terrain.get("source_name", "")).strip_edges()
	var source_team: int = int(terrain.get("source_team", 0))
	if source_unit_id.is_empty() and source_id > 0:
		source_unit_id = "iid_%d" % source_id
	if source_name.is_empty() and not source_unit_id.is_empty():
		source_name = source_unit_id
	if source_id <= 0 and source_unit_id.is_empty() and source_name.is_empty() and source_team == 0:
		return {}
	return {
		"source_id": source_id,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"source_team": source_team
	}


func _has_barrier_terrain() -> bool:
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		if str((terrain_value as Dictionary).get("terrain_type", "")).strip_edges().to_lower() == "barrier":
			return true
	return false


func _default_target_mode_for_terrain(terrain_type: String) -> String:
	match terrain_type:
		"heal", "amp_damage":
			return "allies"
		"barrier":
			return "none"
		_:
			return "enemies"


func _default_debuff_for_terrain(terrain_type: String) -> String:
	match terrain_type:
		"poison":
			return "tangmen_poison"
		"ice", "slow":
			return "debuff_slow"
		_:
			return ""


func _default_buff_for_terrain(terrain_type: String) -> String:
	if terrain_type == "amp_damage":
		return "buff_terrain_amp_damage"
	return ""


func _default_dps_for_terrain(terrain_type: String) -> float:
	if DEFAULT_DPS_BY_TYPE.has(terrain_type):
		return float(DEFAULT_DPS_BY_TYPE[terrain_type])
	return 0.0


func _hex_distance_cells(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2


func _cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


func _cell_from_int_key(int_key: int) -> Vector2i:
	var x_raw: int = (int_key >> 16) & 0xFFFF
	var y_raw: int = int_key & 0xFFFF
	if x_raw > 0x7FFF:
		x_raw -= 0x10000
	if y_raw > 0x7FFF:
		y_raw -= 0x10000
	return Vector2i(x_raw, y_raw)
