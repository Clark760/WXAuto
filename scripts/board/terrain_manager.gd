extends RefCounted
class_name TerrainManager

const DEFAULT_TICK_INTERVAL: float = 0.5
const DEFAULT_DAMAGE_TYPE: String = "internal"
const DEFAULT_TARGET_MODE: String = "enemies"
const DEFAULT_STATIC_SOURCE: Dictionary = {
	"source_id": 0,
	"source_unit_id": "environment",
	"source_name": "Environment",
	"source_team": 0
}

var _terrain_registry: Dictionary = {} # terrain_def_id -> Dictionary
var _terrain_alias_to_id: Dictionary = {} # alias -> terrain_def_id

var _terrains: Array[Dictionary] = []
var _barrier_cells_static: Dictionary = {} # int(cell_key) -> true
var _barrier_cells_dynamic: Dictionary = {} # int(cell_key) -> true
var _visual_cells_cache: Dictionary = {} # int(cell_key) -> Color
var _needs_visual_refresh: bool = true


# 载入地形定义表并建立别名索引，供运行期按 id/别名解析。
func set_terrain_registry(records: Array) -> void:
	_terrain_registry.clear()
	_terrain_alias_to_id.clear()
	for record_value in records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = (record_value as Dictionary).duplicate(true)
		var terrain_id: String = str(record.get("id", "")).strip_edges().to_lower()
		if terrain_id.is_empty():
			continue
		record["id"] = terrain_id
		record["tags"] = _normalize_tags(record.get("tags", []))
		_terrain_registry[terrain_id] = record
		_register_terrain_alias(terrain_id, terrain_id)
		if terrain_id.begins_with("terrain_") and terrain_id.length() > 8:
			_register_terrain_alias(terrain_id.substr(8), terrain_id)
		var aliases_value: Variant = record.get("aliases", [])
		if aliases_value is Array:
			for alias_value in (aliases_value as Array):
				_register_terrain_alias(str(alias_value).strip_edges().to_lower(), terrain_id)


# 清空地形实例。
# include_static=true 时清空全部；否则仅移除临时地形并保留静态地形。
func clear_all(include_static: bool = true) -> void:
	if include_static:
		_terrains.clear()
		_barrier_cells_static.clear()
		_barrier_cells_dynamic.clear()
	else:
		var kept: Array[Dictionary] = []
		for terrain_value in _terrains:
			if not (terrain_value is Dictionary):
				continue
			var terrain: Dictionary = terrain_value as Dictionary
			if bool(terrain.get("is_static", false)):
				kept.append(terrain.duplicate(true))
		_terrains = kept
		_barrier_cells_dynamic.clear()
	_visual_cells_cache.clear()
	_needs_visual_refresh = true


# 快捷清理：只移除临时地形。
func clear_temporary_terrains() -> void:
	clear_all(false)


# 快捷清理：只移除静态地形，保留临时地形实例。
func clear_static_terrains() -> void:
	var kept: Array[Dictionary] = []
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		if not bool(terrain.get("is_static", false)):
			kept.append(terrain.duplicate(true))
	_terrains = kept
	_barrier_cells_static.clear()
	_visual_cells_cache.clear()
	_needs_visual_refresh = true


# 添加一个临时地形实例（可伤害/治疗/施加 buff/阻挡）。
# 返回：是否添加成功，以及阻挡/可视缓存是否变化。
func add_terrain(config: Dictionary, source: Node, context: Dictionary = {}) -> Dictionary:
	var entry: Dictionary = _build_terrain_entry(config, source, context, false)
	if entry.is_empty():
		return {"added": false, "barrier_changed": false, "visual_changed": false}
	_terrains.append(entry)
	var rebuild: Dictionary = _rebuild_all_barrier_cells(context.get("hex_grid", null))
	_needs_visual_refresh = true
	return {
		"added": true,
		"barrier_changed": bool(rebuild.get("dynamic_changed", false)),
		"static_barrier_changed": bool(rebuild.get("static_changed", false)),
		"visual_changed": true
	}


# 按地形定义与格子列表创建静态地形（通常用于障碍或预置地块）。
func add_static_terrain(terrain_ref: String, cells: Array, context: Dictionary = {}, extra_config: Dictionary = {}) -> Dictionary:
	var terrain_key: String = terrain_ref.strip_edges().to_lower()
	if terrain_key.is_empty():
		return {"added": false, "added_count": 0, "barrier_changed": false, "visual_changed": false}
	var static_cells: Array[Vector2i] = _parse_cells(cells, context.get("hex_grid", null))
	if static_cells.is_empty():
		return {"added": false, "added_count": 0, "barrier_changed": false, "visual_changed": false}

	var config: Dictionary = extra_config.duplicate(true)
	config["terrain_ref_id"] = terrain_key
	config["terrain_id"] = "%s_static_%d" % [terrain_key, Time.get_ticks_msec()]
	config["cells"] = static_cells
	config["is_static"] = true
	config["duration"] = -1.0
	if not config.has("source_fallback"):
		config["source_fallback"] = DEFAULT_STATIC_SOURCE.duplicate(true)

	var entry: Dictionary = _build_terrain_entry(config, null, context, true)
	if entry.is_empty():
		return {"added": false, "added_count": 0, "barrier_changed": false, "visual_changed": false}

	_terrains.append(entry)
	var rebuild: Dictionary = _rebuild_all_barrier_cells(context.get("hex_grid", null))
	_needs_visual_refresh = true
	return {
		"added": true,
		"added_count": 1,
		"barrier_changed": bool(rebuild.get("static_changed", false)),
		"visual_changed": true
	}


# 推进所有地形的持续时间与效果逻辑，并在必要时重建阻挡与可视缓存。
func tick(delta: float, context: Dictionary) -> Dictionary:
	if _terrains.is_empty():
		return {
			"barrier_changed": false,
			"static_barrier_changed": false,
			"visual_changed": false
		}

	var next_terrains: Array[Dictionary] = []
	var visual_changed: bool = false
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = (terrain_value as Dictionary).duplicate(true)
		var current_targets: Array[Node] = _collect_targets_in_terrain(terrain, context)
		var is_static: bool = bool(terrain.get("is_static", false))
		if not is_static:
			var previous_remaining: float = float(terrain.get("remaining", 0.0))
			var remaining: float = previous_remaining - delta
			terrain["remaining"] = remaining
			if previous_remaining >= 0.0 and remaining <= 0.0:
				_execute_terrain_phase_effects(terrain, current_targets, "expire", context)
				visual_changed = true
				continue
		_apply_terrain_enter_exit_effects(terrain, current_targets, context)
		var tick_interval: float = maxf(float(terrain.get("tick_interval", DEFAULT_TICK_INTERVAL)), 0.05)
		var tick_accum: float = float(terrain.get("tick_accum", 0.0)) + delta
		while tick_accum >= tick_interval:
			tick_accum -= tick_interval
			_apply_terrain_tick(terrain, current_targets, context)
		terrain["tick_accum"] = tick_accum
		terrain["occupied_iids"] = _build_target_iid_map(current_targets)
		next_terrains.append(terrain)

	_terrains = next_terrains
	var rebuild: Dictionary = _rebuild_all_barrier_cells(context.get("hex_grid", null))
	_needs_visual_refresh = _needs_visual_refresh \
		or visual_changed \
		or bool(rebuild.get("static_changed", false)) \
		or bool(rebuild.get("dynamic_changed", false))
	return {
		"barrier_changed": bool(rebuild.get("dynamic_changed", false)),
		"static_barrier_changed": bool(rebuild.get("static_changed", false)),
		"visual_changed": _needs_visual_refresh
	}


# 获取阻挡格列表；scope 支持 all/static/dynamic(temporary)。
func get_barrier_cells(scope: String = "all") -> Array[Vector2i]:
	var mode: String = scope.strip_edges().to_lower()
	var merged: Dictionary = {}
	match mode:
		"static":
			merged = _barrier_cells_static
		"dynamic", "temporary":
			merged = _barrier_cells_dynamic
		_:
			merged = _barrier_cells_static.duplicate(true)
			for key_value in _barrier_cells_dynamic.keys():
				merged[int(key_value)] = true
	var cells: Array[Vector2i] = []
	for key_value in merged.keys():
		cells.append(_cell_from_int_key(int(key_value)))
	return cells


# 获取地形着色缓存；当标记为脏时会先重建再返回副本。
func get_visual_cells(hex_grid: Node) -> Dictionary:
	if _needs_visual_refresh:
		_visual_cells_cache = _build_visual_cells(hex_grid)
		_needs_visual_refresh = false
	return _visual_cells_cache.duplicate(true)


func get_terrain_tags_at_cell(cell: Vector2i, scope: String = "all", hex_grid: Node = null) -> Array[String]:
	var merged: Array[String] = []
	if cell.x < 0 or cell.y < 0:
		return merged
	var seen: Dictionary = {}
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		if not _should_include_terrain_by_scope(terrain, scope):
			continue
		var contains_cell: bool = false
		for terrain_cell in _get_effective_cells_for_terrain(terrain, hex_grid):
			if terrain_cell == cell:
				contains_cell = true
				break
		if not contains_cell:
			continue
		var tags_value: Variant = terrain.get("tags", [])
		if not (tags_value is Array):
			continue
		for tag_value in (tags_value as Array):
			var normalized: String = str(tag_value).strip_edges().to_lower()
			if normalized.is_empty():
				continue
			if seen.has(normalized):
				continue
			seen[normalized] = true
			merged.append(normalized)
	return merged


func cell_has_terrain_tag(cell: Vector2i, tag: String, scope: String = "all", hex_grid: Node = null) -> bool:
	var target: String = tag.strip_edges().to_lower()
	if target.is_empty():
		return false
	var tags: Array[String] = get_terrain_tags_at_cell(cell, scope, hex_grid)
	return tags.has(target)


# 将输入配置标准化为可运行的地形实例结构。
func _build_terrain_entry(config: Dictionary, source: Node, context: Dictionary, force_static: bool) -> Dictionary:
	if config.is_empty():
		return {}

	var hex_grid: Node = context.get("hex_grid", null)
	var resolved: Dictionary = _resolve_terrain_definition(config)
	var terrain_def_id: String = str(resolved.get("terrain_def_id", "")).strip_edges().to_lower()
	var terrain_def: Dictionary = {}
	if resolved.get("definition", null) is Dictionary:
		terrain_def = (resolved.get("definition", {}) as Dictionary).duplicate(true)

	var explicit_cells: Array[Vector2i] = _parse_cells(config.get("cells", []), hex_grid)
	var center_cell: Vector2i = _extract_center_cell(config, source, hex_grid)
	if explicit_cells.is_empty() and center_cell.x < 0:
		return {}
	if center_cell.x < 0 and not explicit_cells.is_empty():
		center_cell = explicit_cells[0]

	var is_static: bool = force_static or bool(config.get("is_static", false))
	var remaining: float = -1.0
	if not is_static:
		remaining = float(config.get("duration", terrain_def.get("duration", 0.0)))
		if config.has("remaining"):
			remaining = float(config.get("remaining", remaining))
		if remaining <= 0.0:
			return {}

	var source_payload: Dictionary = _extract_source_payload(config, source, is_static)

	var terrain_instance_id: String = str(config.get("terrain_id", "")).strip_edges()
	if terrain_instance_id.is_empty():
		var short_name: String = _terrain_short_name(terrain_def_id, config)
		terrain_instance_id = "terrain_%d_%s" % [Time.get_ticks_msec(), short_name]

	var terrain_type: String = str(config.get("terrain_type", "")).strip_edges().to_lower()
	if terrain_type.is_empty():
		terrain_type = _terrain_short_name(terrain_def_id, terrain_def)

	var radius_default: int = 0 if not explicit_cells.is_empty() else 1
	var radius: int = maxi(int(config.get("radius", terrain_def.get("radius", radius_default))), 0)
	var tick_interval: float = maxf(float(config.get("tick_interval", terrain_def.get("tick_interval", DEFAULT_TICK_INTERVAL))), 0.05)
	var target_mode: String = _resolve_target_mode(config, terrain_def)
	var damage_type: String = str(config.get("damage_type", terrain_def.get("damage_type", DEFAULT_DAMAGE_TYPE))).strip_edges().to_lower()
	if damage_type.is_empty():
		damage_type = DEFAULT_DAMAGE_TYPE

	var effects_on_enter: Array[Dictionary] = _resolve_terrain_effects(config, terrain_def, "effects_on_enter")
	var effects_on_tick: Array[Dictionary] = _resolve_terrain_effects(config, terrain_def, "effects_on_tick")
	var effects_on_exit: Array[Dictionary] = _resolve_terrain_effects(config, terrain_def, "effects_on_exit")
	var effects_on_expire: Array[Dictionary] = _resolve_terrain_effects(config, terrain_def, "effects_on_expire")
	var is_barrier: bool = bool(config.get("is_barrier", terrain_def.get("is_barrier", false)))
	if not is_barrier and str(terrain_def.get("type", "")).strip_edges().to_lower() == "obstacle":
		is_barrier = true

	var color: Color = _parse_color(
		config.get("color", terrain_def.get("color", "")),
		Color(0.8, 0.8, 0.8, 0.25)
	)
	var terrain_tags: Array[String] = _resolve_terrain_tags(config, terrain_def)

	return {
		"terrain_id": terrain_instance_id,
		"terrain_def_id": terrain_def_id,
		"terrain_type": terrain_type,
		"terrain_name": str(terrain_def.get("name", terrain_def_id)),
		"terrain_class": str(terrain_def.get("type", "hazard")).strip_edges().to_lower(),
		"is_static": is_static,
		"is_barrier": is_barrier,
		"cells": explicit_cells,
		"center_cell": center_cell,
		"radius": radius,
		"remaining": remaining,
		"tick_interval": tick_interval,
		"tick_accum": 0.0,
		"target_mode": target_mode,
		"damage_type": damage_type,
		"vfx_on_tick": str(config.get("vfx_on_tick", terrain_def.get("vfx_on_tick", ""))).strip_edges(),
		"effects_on_enter": effects_on_enter,
		"effects_on_tick": effects_on_tick,
		"effects_on_exit": effects_on_exit,
		"effects_on_expire": effects_on_expire,
		"occupied_iids": {},
		"source_id": int(source_payload.get("source_id", -1)),
		"source_team": int(source_payload.get("source_team", 0)),
		"source_unit_id": str(source_payload.get("source_unit_id", "")),
		"source_name": str(source_payload.get("source_name", "")),
		"tags": terrain_tags,
		"color": color
	}


# 执行单次地形 tick：对当前地形内目标执行 effects_on_tick。
func _apply_terrain_tick(terrain: Dictionary, targets: Array[Node], context: Dictionary) -> void:
	_execute_terrain_phase_effects(terrain, targets, "tick", context)


func _apply_terrain_enter_exit_effects(terrain: Dictionary, current_targets: Array[Node], context: Dictionary) -> void:
	var previous_map: Dictionary = {}
	var previous_value: Variant = terrain.get("occupied_iids", {})
	if previous_value is Dictionary:
		previous_map = (previous_value as Dictionary).duplicate(true)
	var current_map: Dictionary = _build_target_iid_map(current_targets)
	var enter_targets: Array[Node] = []
	for target in current_targets:
		if target == null or not is_instance_valid(target):
			continue
		var iid: int = target.get_instance_id()
		if previous_map.has(iid):
			continue
		enter_targets.append(target)
	var exit_targets: Array[Node] = []
	for iid_value in previous_map.keys():
		var iid: int = int(iid_value)
		if current_map.has(iid):
			continue
		var unit: Node = _resolve_unit_by_instance_id(iid, context)
		if unit == null or not is_instance_valid(unit):
			continue
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null or not bool(combat.get("is_alive")):
			continue
		exit_targets.append(unit)
	_execute_terrain_phase_effects(terrain, enter_targets, "enter", context)
	_execute_terrain_phase_effects(terrain, exit_targets, "exit", context)


func _execute_terrain_phase_effects(terrain: Dictionary, targets: Array[Node], phase: String, context: Dictionary) -> void:
	if targets.is_empty():
		return
	var effects: Array[Dictionary] = _get_terrain_phase_effects(terrain, phase)
	if effects.is_empty():
		return
	var gongfa_manager: Node = context.get("gongfa_manager", null)
	if gongfa_manager == null or not is_instance_valid(gongfa_manager):
		return
	if not gongfa_manager.has_method("execute_external_effects"):
		return
	var source_node: Node = _resolve_source_node(terrain, context)
	var source_fallback: Dictionary = _build_source_fallback_from_terrain(terrain)
	var extra_fields: Dictionary = {
		"terrain_id": str(terrain.get("terrain_id", "")),
		"terrain_def_id": str(terrain.get("terrain_def_id", "")),
		"terrain_type": str(terrain.get("terrain_type", "")),
		"terrain_phase": phase,
		"is_environment": true
	}
	if source_node == null and not source_fallback.is_empty():
		extra_fields["source_id"] = int(source_fallback.get("source_id", -1))
		extra_fields["source_unit_id"] = str(source_fallback.get("source_unit_id", ""))
		extra_fields["source_name"] = str(source_fallback.get("source_name", ""))
		extra_fields["source_team"] = int(source_fallback.get("source_team", 0))
	var origin: String = "terrain_%s" % phase
	for target in targets:
		if target == null or not is_instance_valid(target):
			continue
		var effect_context: Dictionary = context.duplicate(false)
		effect_context["terrain"] = terrain
		effect_context["terrain_phase"] = phase
		effect_context["is_environment"] = true
		gongfa_manager.call("execute_external_effects", source_node, target, effects, effect_context, {
			"origin": origin,
			"trigger": origin,
			"extra_fields": extra_fields
		})


func _get_terrain_phase_effects(terrain: Dictionary, phase: String) -> Array[Dictionary]:
	var key: String = "effects_on_tick"
	match phase:
		"enter":
			key = "effects_on_enter"
		"exit":
			key = "effects_on_exit"
		"expire":
			key = "effects_on_expire"
	var effects_value: Variant = terrain.get(key, [])
	return _normalize_effect_rows(effects_value)


# 收集当前地形生效范围内的有效目标单位。
func _collect_targets_in_terrain(terrain: Dictionary, context: Dictionary) -> Array[Node]:
	var output: Array[Node] = []
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return output
	var hex_grid: Node = context.get("hex_grid", null)
	var combat_manager: Node = context.get("combat_manager", null)
	var target_mode: String = str(terrain.get("target_mode", DEFAULT_TARGET_MODE)).strip_edges().to_lower()
	if target_mode == "none":
		return output

	var area_cells: Array[Vector2i] = _get_effective_cells_for_terrain(terrain, hex_grid)
	if area_cells.is_empty():
		return output
	var area_map: Dictionary = {}
	for cell in area_cells:
		area_map[_cell_key_int(cell)] = true

	var source_team: int = int(terrain.get("source_team", 0))
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
		if unit_cell.x < 0 and hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
			var node2d: Node2D = unit as Node2D
			if node2d != null:
				unit_cell = hex_grid.call("world_to_axial", node2d.position)
		if unit_cell.x < 0:
			continue
		if not area_map.has(_cell_key_int(unit_cell)):
			continue
		output.append(unit)
	return output


# 依据现存地形重建静态/动态阻挡格，并返回是否发生变化。
func _rebuild_all_barrier_cells(hex_grid: Node) -> Dictionary:
	var next_static: Dictionary = {}
	var next_dynamic: Dictionary = {}
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		if not bool(terrain.get("is_barrier", false)):
			continue
		var target_map: Dictionary = next_static if bool(terrain.get("is_static", false)) else next_dynamic
		for cell in _get_effective_cells_for_terrain(terrain, hex_grid):
			target_map[_cell_key_int(cell)] = true

	var static_changed: bool = _dict_keys_changed(_barrier_cells_static, next_static)
	var dynamic_changed: bool = _dict_keys_changed(_barrier_cells_dynamic, next_dynamic)
	_barrier_cells_static = next_static
	_barrier_cells_dynamic = next_dynamic
	return {
		"static_changed": static_changed,
		"dynamic_changed": dynamic_changed
	}


# 汇总所有地形颜色，构建“格子 -> 叠加颜色”的可视映射。
func _build_visual_cells(hex_grid: Node) -> Dictionary:
	var cells_colors: Dictionary = {}
	for terrain_value in _terrains:
		if not (terrain_value is Dictionary):
			continue
		var terrain: Dictionary = terrain_value as Dictionary
		var color: Color = _parse_color(terrain.get("color", Color(0.8, 0.8, 0.8, 0.25)), Color(0.8, 0.8, 0.8, 0.25))
		for cell in _get_effective_cells_for_terrain(terrain, hex_grid):
			var key: int = _cell_key_int(cell)
			if cells_colors.has(key):
				var current: Color = cells_colors[key] as Color
				cells_colors[key] = current.lerp(color, clampf(color.a, 0.15, 0.75))
			else:
				cells_colors[key] = color
	return cells_colors


# 计算地形实际作用格：优先显式 cells，其次 center+radius。
func _get_effective_cells_for_terrain(terrain: Dictionary, hex_grid: Node) -> Array[Vector2i]:
	var cells_value: Variant = terrain.get("cells", [])
	var explicit_cells: Array[Vector2i] = _parse_cells(cells_value, hex_grid)
	if not explicit_cells.is_empty():
		return explicit_cells
	var center_cell: Vector2i = terrain.get("center_cell", Vector2i(-1, -1))
	var radius: int = maxi(int(terrain.get("radius", 0)), 0)
	return _collect_cells_in_radius(hex_grid, center_cell, radius)


# 在六角网格上按半径收集格子（BFS），用于圆形范围地形。
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


# 通过 source_id 反查施放者节点；优先 combat_manager，回退 all_units。
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


# 从地形实例提取来源快照，用于施放者节点失效时的归属兜底。
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


# 汇总来源信息：优先 source 节点，再读配置与 fallback，必要时注入静态默认来源。
func _extract_source_payload(config: Dictionary, source: Node, use_static_default: bool) -> Dictionary:
	var source_id: int = -1
	var source_team: int = 0
	var source_unit_id: String = ""
	var source_name: String = ""
	if source != null and is_instance_valid(source):
		source_id = source.get_instance_id()
		source_team = int(_safe_node_prop(source, "team_id", 0))
		source_unit_id = str(_safe_node_prop(source, "unit_id", ""))
		source_name = str(_safe_node_prop(source, "unit_name", ""))
	if source_id <= 0:
		source_id = int(config.get("source_id", source_id))
	if source_unit_id.is_empty():
		source_unit_id = str(config.get("source_unit_id", source_unit_id)).strip_edges()
	if source_name.is_empty():
		source_name = str(config.get("source_name", source_name)).strip_edges()
	if source_team == 0:
		source_team = int(config.get("source_team", source_team))

	var source_fallback_value: Variant = config.get("source_fallback", {})
	if source_fallback_value is Dictionary:
		var fallback: Dictionary = source_fallback_value as Dictionary
		if source_id <= 0:
			source_id = int(fallback.get("source_id", source_id))
		if source_unit_id.is_empty():
			source_unit_id = str(fallback.get("source_unit_id", source_unit_id)).strip_edges()
		if source_name.is_empty():
			source_name = str(fallback.get("source_name", source_name)).strip_edges()
		if source_team == 0:
			source_team = int(fallback.get("source_team", source_team))

	if use_static_default and source_id <= 0 and source_unit_id.is_empty() and source_name.is_empty() and source_team == 0:
		source_id = int(DEFAULT_STATIC_SOURCE.get("source_id", 0))
		source_unit_id = str(DEFAULT_STATIC_SOURCE.get("source_unit_id", "environment"))
		source_name = str(DEFAULT_STATIC_SOURCE.get("source_name", "Environment"))
		source_team = int(DEFAULT_STATIC_SOURCE.get("source_team", 0))

	return {
		"source_id": source_id,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"source_team": source_team
	}


# 按 terrain_ref_id / terrain_id / terrain_type 解析地形定义与标准 id。
func _resolve_terrain_definition(config: Dictionary) -> Dictionary:
	var candidates: Array[String] = []
	var terrain_ref: String = str(config.get("terrain_ref_id", "")).strip_edges().to_lower()
	if not terrain_ref.is_empty():
		candidates.append(terrain_ref)
	var terrain_id: String = str(config.get("terrain_id", "")).strip_edges().to_lower()
	if not terrain_id.is_empty():
		candidates.append(terrain_id)
	var terrain_type: String = str(config.get("terrain_type", "")).strip_edges().to_lower()
	if not terrain_type.is_empty():
		candidates.append(terrain_type)
		if terrain_type.begins_with("terrain_") and terrain_type.length() > 8:
			candidates.append(terrain_type.substr(8))
	for candidate in candidates:
		var resolved_id: String = _resolve_terrain_id_alias(candidate)
		if resolved_id.is_empty():
			continue
		return {
			"terrain_def_id": resolved_id,
			"definition": (_terrain_registry[resolved_id] as Dictionary).duplicate(true)
		}
	return {}


# 解析目标模式并做安全兜底（all/enemies/allies/none）。
func _resolve_target_mode(config: Dictionary, terrain_def: Dictionary) -> String:
	var target_mode: String = str(config.get("target_mode", "")).strip_edges().to_lower()
	if target_mode.is_empty():
		target_mode = str(terrain_def.get("target_mode", "")).strip_edges().to_lower()
	if target_mode.is_empty():
		var terrain_class: String = str(terrain_def.get("type", "hazard")).strip_edges().to_lower()
		match terrain_class:
			"beneficial":
				target_mode = "allies"
			"obstacle":
				target_mode = "none"
			_:
				target_mode = DEFAULT_TARGET_MODE
	if target_mode != "all" and target_mode != "allies" and target_mode != "none":
		target_mode = DEFAULT_TARGET_MODE
	return target_mode


func _resolve_terrain_effects(config: Dictionary, terrain_def: Dictionary, key: String) -> Array[Dictionary]:
	if config.has(key):
		return _normalize_effect_rows(config.get(key, []))
	return _normalize_effect_rows(terrain_def.get(key, []))


func _resolve_terrain_tags(config: Dictionary, terrain_def: Dictionary) -> Array[String]:
	if config.has("tags"):
		return _normalize_tags(config.get("tags", []))
	return _normalize_tags(terrain_def.get("tags", []))


func _normalize_effect_rows(value: Variant) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if not (value is Array):
		return output
	for effect_value in (value as Array):
		if effect_value is Dictionary:
			output.append((effect_value as Dictionary).duplicate(true))
	return output


func _build_target_iid_map(targets: Array[Node]) -> Dictionary:
	var out: Dictionary = {}
	for target in targets:
		if target == null or not is_instance_valid(target):
			continue
		out[target.get_instance_id()] = true
	return out


func _resolve_unit_by_instance_id(instance_id: int, context: Dictionary) -> Node:
	if instance_id <= 0:
		return null
	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_by_instance_id"):
		var result: Variant = combat_manager.call("get_unit_by_instance_id", instance_id)
		if result is Node:
			return result as Node
	var all_units_value: Variant = context.get("all_units", [])
	if all_units_value is Array:
		for unit_value in (all_units_value as Array):
			if not (unit_value is Node):
				continue
			var unit: Node = unit_value as Node
			if unit == null or not is_instance_valid(unit):
				continue
			if unit.get_instance_id() == instance_id:
				return unit
	return null


# 解析中心格：优先配置，其次从 source 世界坐标反推。
func _extract_center_cell(config: Dictionary, source: Node, hex_grid: Node) -> Vector2i:
	var center_cell: Vector2i = _to_cell(config.get("center_cell", config.get("cell", null)))
	if center_cell.x >= 0:
		return center_cell
	if source != null and is_instance_valid(source):
		if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
			var source_node: Node2D = source as Node2D
			if source_node != null:
				center_cell = hex_grid.call("world_to_axial", source_node.position)
	return center_cell


# 解析多种 cells 输入格式，并去重/越界过滤。
func _parse_cells(value: Variant, hex_grid: Node) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var input: Array = []
	if value is Array:
		input = value as Array
	elif value is Vector2i:
		input = [value]
	else:
		return cells
	var seen: Dictionary = {}
	for raw in input:
		var cell: Vector2i = _to_cell(raw)
		if cell.x < 0 or cell.y < 0:
			continue
		if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("is_inside_grid"):
			if not bool(hex_grid.call("is_inside_grid", cell)):
				continue
		var key: int = _cell_key_int(cell)
		if seen.has(key):
			continue
		seen[key] = true
		cells.append(cell)
	return cells


# 将 Vector2i / [x,y] / {x,y} 统一转换为格坐标。
func _to_cell(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value as Vector2i
	if value is Array:
		var arr: Array = value as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	if value is Dictionary:
		var dict: Dictionary = value as Dictionary
		return Vector2i(int(dict.get("x", -1)), int(dict.get("y", -1)))
	return Vector2i(-1, -1)


# 注册地形别名到标准 terrain_id 的映射。
func _register_terrain_alias(alias: String, terrain_id: String) -> void:
	if alias.is_empty():
		return
	if terrain_id.is_empty():
		return
	_terrain_alias_to_id[alias] = terrain_id


# 把任意别名解析为标准 terrain_id（含 terrain_ 前缀互转）。
func _resolve_terrain_id_alias(alias: String) -> String:
	var key: String = alias.strip_edges().to_lower()
	if key.is_empty():
		return ""
	if _terrain_registry.has(key):
		return key
	if _terrain_alias_to_id.has(key):
		return str(_terrain_alias_to_id[key])
	if key.begins_with("terrain_") and key.length() > 8:
		var short_key: String = key.substr(8)
		if _terrain_alias_to_id.has(short_key):
			return str(_terrain_alias_to_id[short_key])
	elif _terrain_alias_to_id.has("terrain_%s" % key):
		return str(_terrain_alias_to_id["terrain_%s" % key])
	return ""


# 生成短名称，用于自动拼接运行期 terrain_id。
func _terrain_short_name(terrain_def_id: String, source: Dictionary) -> String:
	if not terrain_def_id.is_empty():
		if terrain_def_id.begins_with("terrain_") and terrain_def_id.length() > 8:
			return terrain_def_id.substr(8)
		return terrain_def_id
	var terrain_type: String = str(source.get("terrain_type", "")).strip_edges().to_lower()
	if not terrain_type.is_empty():
		if terrain_type.begins_with("terrain_") and terrain_type.length() > 8:
			return terrain_type.substr(8)
		return terrain_type
	return "custom"


func _should_include_terrain_by_scope(terrain: Dictionary, scope: String) -> bool:
	var mode: String = scope.strip_edges().to_lower()
	if mode == "static":
		return bool(terrain.get("is_static", false))
	if mode == "dynamic" or mode == "temporary":
		return not bool(terrain.get("is_static", false))
	return true


func _normalize_tags(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for tag_value in (value as Array):
			var normalized: String = str(tag_value).strip_edges().to_lower()
			if normalized.is_empty():
				continue
			if seen.has(normalized):
				continue
			seen[normalized] = true
			out.append(normalized)
	return out


# 比较两个字典的 key 集是否发生变化（用于判断是否需要刷新）。
func _dict_keys_changed(before: Dictionary, after: Dictionary) -> bool:
	if before.size() != after.size():
		return true
	for key in before.keys():
		if not after.has(key):
			return true
	return false


# 安全读取节点属性；节点无效或值为空时返回 fallback。
func _safe_node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value


# 解析颜色输入（Color / 字符串 / 字典）并夹取到合法范围。
func _parse_color(value: Variant, fallback: Color) -> Color:
	if value is Color:
		return value as Color
	if value is String:
		return Color.from_string(str(value), fallback)
	if value is Dictionary:
		var data: Dictionary = value as Dictionary
		return Color(
			clampf(float(data.get("r", fallback.r)), 0.0, 1.0),
			clampf(float(data.get("g", fallback.g)), 0.0, 1.0),
			clampf(float(data.get("b", fallback.b)), 0.0, 1.0),
			clampf(float(data.get("a", fallback.a)), 0.0, 1.0)
		)
	return fallback


# 计算六角格距离；优先调用 hex_grid，缺失时使用轴坐标公式。
func _hex_distance_cells(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


# 将格坐标编码为 int key，便于字典高速索引。
func _cell_key_int(cell: Vector2i) -> int:
	return ((cell.x & 0xFFFF) << 16) | (cell.y & 0xFFFF)


# 把 int key 还原为 Vector2i 格坐标。
func _cell_from_int_key(int_key: int) -> Vector2i:
	var x_raw: int = (int_key >> 16) & 0xFFFF
	var y_raw: int = int_key & 0xFFFF
	if x_raw > 0x7FFF:
		x_raw -= 0x10000
	if y_raw > 0x7FFF:
		y_raw -= 0x10000
	return Vector2i(x_raw, y_raw)
