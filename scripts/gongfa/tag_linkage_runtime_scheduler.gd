extends RefCounted
class_name TagLinkageRuntimeScheduler

const DEFAULT_STAGGER_BUCKETS: int = 8

var _combat_manager: Node = null
var _watchers: Dictionary = {} # watcher_key -> Dictionary
var _watchers_by_cell: Dictionary = {} # "x,y" -> {watcher_key: true}
var _watchers_by_unit: Dictionary = {} # unit_iid -> {watcher_key: true}
var _dirty_watchers: Dictionary = {} # watcher_key -> true


func clear() -> void:
	_watchers.clear()
	_watchers_by_cell.clear()
	_watchers_by_unit.clear()
	_dirty_watchers.clear()


func bind_combat_manager(combat_manager: Node) -> void:
	if _combat_manager == combat_manager:
		return
	_disconnect_combat_signals()
	_combat_manager = combat_manager
	_connect_combat_signals()
	mark_all_dirty("combat_context_changed")


func should_evaluate(owner: Node, effect: Dictionary, context: Dictionary) -> Dictionary:
	if owner == null or not is_instance_valid(owner):
		return {
			"allowed": false,
			"dirty": false,
			"watcher_key": "",
			"reason": "invalid_owner"
		}
	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	var dirty: bool = bool(watcher.get("dirty", true)) or _dirty_watchers.has(watcher_key)
	var buckets: int = _resolve_bucket_count(effect, context)
	var physics_frame: int = int(Engine.get_physics_frames())
	var allowed: bool = dirty
	var reason: String = "dirty"
	if not allowed:
		if buckets <= 1:
			allowed = true
			reason = "always"
		else:
			var phase: int = posmod(owner.get_instance_id(), buckets)
			allowed = posmod(physics_frame, buckets) == phase
			reason = "stagger_hit" if allowed else "stagger_skip"
	return {
		"allowed": allowed,
		"dirty": dirty,
		"watcher_key": watcher_key,
		"reason": reason,
		"physics_frame": physics_frame,
		"buckets": buckets
	}


func on_evaluated(owner: Node, effect: Dictionary, context: Dictionary, result: Dictionary) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)

	var range_cells: int = maxi(int(effect.get("range", 0)), 0)
	var cells: Array[Vector2i] = _collect_scan_cells(owner, context, range_cells)
	var units_map: Dictionary = {}
	var providers_value: Variant = result.get("providers", [])
	if providers_value is Array:
		for provider_value in (providers_value as Array):
			if not (provider_value is Dictionary):
				continue
			var provider: Dictionary = provider_value as Dictionary
			var unit_id: int = int(provider.get("unit_id", -1))
			if unit_id > 0:
				units_map[unit_id] = true

	_reindex_watcher_subscriptions(watcher_key, watcher, cells, units_map)
	watcher["dirty"] = false
	watcher["last_eval_time"] = Time.get_unix_time_from_system()
	watcher["range"] = range_cells
	_watchers[watcher_key] = watcher
	_dirty_watchers.erase(watcher_key)


func get_last_case_id(owner: Node, effect: Dictionary) -> String:
	var watcher_key: String = _build_watcher_key(owner, effect)
	if not _watchers.has(watcher_key):
		return ""
	return str((_watchers[watcher_key] as Dictionary).get("last_case_id", "")).strip_edges()


func set_last_case_id(owner: Node, effect: Dictionary, case_id: String) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	watcher["last_case_id"] = case_id
	_watchers[watcher_key] = watcher


func get_stateful_buff_ids(owner: Node, effect: Dictionary) -> Array[String]:
	var watcher_key: String = _build_watcher_key(owner, effect)
	if not _watchers.has(watcher_key):
		return []
	var watcher: Dictionary = _watchers[watcher_key]
	var raw: Variant = watcher.get("stateful_buff_ids", [])
	return _normalize_string_array(raw)


func set_stateful_buff_ids(owner: Node, effect: Dictionary, buff_ids: Array[String]) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var watcher_key: String = _build_watcher_key(owner, effect)
	var watcher: Dictionary = _ensure_watcher(watcher_key, owner, effect)
	watcher["stateful_buff_ids"] = _normalize_string_array(buff_ids)
	_watchers[watcher_key] = watcher


func notify_unit_tags_changed(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	_mark_watchers_dirty_by_unit_id(iid)
	mark_owner_dirty(unit)
	var cell: Vector2i = _resolve_unit_cell(unit, {})
	if cell.x >= 0 and cell.y >= 0:
		_mark_watchers_dirty_by_cell(cell)


func mark_owner_dirty(owner: Node) -> void:
	if owner == null or not is_instance_valid(owner):
		return
	var iid: int = owner.get_instance_id()
	for watcher_key in _watchers.keys():
		var watcher: Dictionary = _watchers[watcher_key] as Dictionary
		if int(watcher.get("owner_id", -1)) != iid:
			continue
		_mark_watcher_dirty(str(watcher_key))


func mark_all_dirty(_reason: String = "") -> void:
	for watcher_key in _watchers.keys():
		_mark_watcher_dirty(str(watcher_key))


func _connect_combat_signals() -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	_try_connect_signal("unit_cell_changed", "_on_unit_cell_changed")
	_try_connect_signal("unit_spawned", "_on_unit_spawned")
	_try_connect_signal("unit_died", "_on_unit_died")
	_try_connect_signal("terrain_changed", "_on_terrain_changed")


func _disconnect_combat_signals() -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	_try_disconnect_signal("unit_cell_changed", "_on_unit_cell_changed")
	_try_disconnect_signal("unit_spawned", "_on_unit_spawned")
	_try_disconnect_signal("unit_died", "_on_unit_died")
	_try_disconnect_signal("terrain_changed", "_on_terrain_changed")


func _try_connect_signal(signal_name: String, callback_name: String) -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	if not _combat_manager.has_signal(signal_name):
		return
	var cb: Callable = Callable(self, callback_name)
	if not _combat_manager.is_connected(signal_name, cb):
		_combat_manager.connect(signal_name, cb)


func _try_disconnect_signal(signal_name: String, callback_name: String) -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	if not _combat_manager.has_signal(signal_name):
		return
	var cb: Callable = Callable(self, callback_name)
	if _combat_manager.is_connected(signal_name, cb):
		_combat_manager.disconnect(signal_name, cb)


func _on_unit_cell_changed(unit: Node, from_cell: Vector2i, to_cell: Vector2i) -> void:
	if unit != null and is_instance_valid(unit):
		_mark_watchers_dirty_by_unit_id(unit.get_instance_id())
	if from_cell.x >= 0 and from_cell.y >= 0:
		_mark_watchers_dirty_by_cell(from_cell)
	if to_cell.x >= 0 and to_cell.y >= 0:
		_mark_watchers_dirty_by_cell(to_cell)


func _on_unit_spawned(unit: Node, _team_id: int) -> void:
	if unit == null or not is_instance_valid(unit):
		mark_all_dirty("unit_spawned")
		return
	var cell: Vector2i = _resolve_unit_cell(unit, {})
	if cell.x >= 0 and cell.y >= 0:
		_mark_watchers_dirty_by_cell(cell)
	_mark_watchers_dirty_by_unit_id(unit.get_instance_id())


func _on_unit_died(unit: Node, _killer: Node, _team_id: int) -> void:
	if unit == null or not is_instance_valid(unit):
		mark_all_dirty("unit_died")
		return
	var iid: int = unit.get_instance_id()
	var cell: Vector2i = _resolve_unit_cell(unit, {})
	_mark_watchers_dirty_by_unit_id(iid)
	if cell.x >= 0 and cell.y >= 0:
		_mark_watchers_dirty_by_cell(cell)


func _on_terrain_changed(changed_cells: Array, _reason: String) -> void:
	if changed_cells.is_empty():
		mark_all_dirty("terrain_changed_all")
		return
	for cell_value in changed_cells:
		if not (cell_value is Vector2i):
			continue
		_mark_watchers_dirty_by_cell(cell_value as Vector2i)


func _resolve_bucket_count(effect: Dictionary, context: Dictionary) -> int:
	var local_buckets: int = int(effect.get("stagger_buckets", 0))
	if local_buckets > 0:
		return maxi(local_buckets, 1)
	var global_buckets: int = int(context.get("tag_linkage_stagger_buckets", DEFAULT_STAGGER_BUCKETS))
	return maxi(global_buckets, 1)


func _ensure_watcher(watcher_key: String, owner: Node, effect: Dictionary) -> Dictionary:
	if _watchers.has(watcher_key):
		return _watchers[watcher_key] as Dictionary
	var watcher: Dictionary = {
		"watcher_key": watcher_key,
		"owner_id": owner.get_instance_id(),
		"effect_signature": _build_effect_signature(effect),
		"dirty": true,
		"last_case_id": "",
		"stateful_buff_ids": [],
		"range": maxi(int(effect.get("range", 0)), 0),
		"subscribed_cells": {},
		"subscribed_units": {},
		"last_eval_time": 0.0
	}
	_watchers[watcher_key] = watcher
	_dirty_watchers[watcher_key] = true
	return watcher


func _reindex_watcher_subscriptions(
	watcher_key: String,
	watcher: Dictionary,
	cells: Array[Vector2i],
	units_map: Dictionary
) -> void:
	var old_cells: Dictionary = watcher.get("subscribed_cells", {})
	var old_units: Dictionary = watcher.get("subscribed_units", {})
	for cell_key in old_cells.keys():
		_unsubscribe_cell(str(cell_key), watcher_key)
	for unit_key in old_units.keys():
		_unsubscribe_unit(int(unit_key), watcher_key)

	var next_cells: Dictionary = {}
	for cell in cells:
		var key: String = _cell_key(cell)
		next_cells[key] = true
		_subscribe_cell(key, watcher_key)

	var next_units: Dictionary = {}
	for unit_key in units_map.keys():
		var iid: int = int(unit_key)
		next_units[iid] = true
		_subscribe_unit(iid, watcher_key)

	watcher["subscribed_cells"] = next_cells
	watcher["subscribed_units"] = next_units


func _subscribe_cell(cell_key: String, watcher_key: String) -> void:
	var slot: Dictionary = _watchers_by_cell.get(cell_key, {})
	slot[watcher_key] = true
	_watchers_by_cell[cell_key] = slot


func _unsubscribe_cell(cell_key: String, watcher_key: String) -> void:
	if not _watchers_by_cell.has(cell_key):
		return
	var slot: Dictionary = _watchers_by_cell[cell_key]
	slot.erase(watcher_key)
	if slot.is_empty():
		_watchers_by_cell.erase(cell_key)
	else:
		_watchers_by_cell[cell_key] = slot


func _subscribe_unit(unit_iid: int, watcher_key: String) -> void:
	var slot: Dictionary = _watchers_by_unit.get(unit_iid, {})
	slot[watcher_key] = true
	_watchers_by_unit[unit_iid] = slot


func _unsubscribe_unit(unit_iid: int, watcher_key: String) -> void:
	if not _watchers_by_unit.has(unit_iid):
		return
	var slot: Dictionary = _watchers_by_unit[unit_iid]
	slot.erase(watcher_key)
	if slot.is_empty():
		_watchers_by_unit.erase(unit_iid)
	else:
		_watchers_by_unit[unit_iid] = slot


func _mark_watchers_dirty_by_cell(cell: Vector2i) -> void:
	var key: String = _cell_key(cell)
	if not _watchers_by_cell.has(key):
		return
	var slot: Dictionary = _watchers_by_cell[key]
	for watcher_key in slot.keys():
		_mark_watcher_dirty(str(watcher_key))


func _mark_watchers_dirty_by_unit_id(unit_iid: int) -> void:
	if not _watchers_by_unit.has(unit_iid):
		return
	var slot: Dictionary = _watchers_by_unit[unit_iid]
	for watcher_key in slot.keys():
		_mark_watcher_dirty(str(watcher_key))


func _mark_watcher_dirty(watcher_key: String) -> void:
	if not _watchers.has(watcher_key):
		return
	var watcher: Dictionary = _watchers[watcher_key]
	watcher["dirty"] = true
	_watchers[watcher_key] = watcher
	_dirty_watchers[watcher_key] = true


func _collect_scan_cells(owner: Node, context: Dictionary, range_cells: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var origin: Vector2i = _resolve_unit_cell(owner, context)
	if origin.x < 0 or origin.y < 0:
		return out
	if range_cells <= 0:
		out.append(origin)
		return out
	var hex_grid: Node = context.get("hex_grid", null)
	if hex_grid == null or not is_instance_valid(hex_grid):
		out.append(origin)
		return out
	if not hex_grid.has_method("is_inside_grid") or not hex_grid.has_method("get_neighbor_cells"):
		out.append(origin)
		return out
	if not bool(hex_grid.call("is_inside_grid", origin)):
		out.append(origin)
		return out
	var queue: Array[Vector2i] = [origin]
	var visited: Dictionary = {_cell_key(origin): true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance(origin, cell, hex_grid) > range_cells:
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
			var key: String = _cell_key(neighbor)
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


func _resolve_unit_cell(unit: Node, context: Dictionary) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)
	var combat_manager: Node = context.get("combat_manager", _combat_manager)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of"):
		var cell_value: Variant = combat_manager.call("get_unit_cell_of", unit)
		if cell_value is Vector2i:
			var cell: Vector2i = cell_value as Vector2i
			if cell.x >= 0 and cell.y >= 0:
				return cell
	var hex_grid: Node = context.get("hex_grid", null)
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
		var n2d: Node2D = unit as Node2D
		if n2d != null:
			var axial_value: Variant = hex_grid.call("world_to_axial", n2d.position)
			if axial_value is Vector2i:
				return axial_value as Vector2i
	return Vector2i(-1, -1)


func _hex_distance(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


func _build_watcher_key(owner: Node, effect: Dictionary) -> String:
	if owner == null or not is_instance_valid(owner):
		return ""
	return "%d|%s" % [owner.get_instance_id(), _build_effect_signature(effect)]


func _build_effect_signature(effect: Dictionary) -> String:
	return var_to_str(effect)


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


func _normalize_string_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for value in (raw as Array):
			var text: String = str(value).strip_edges()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out
