extends RefCounted
class_name TagLinkageResolver

const DEFAULT_SOURCE_TYPES: Array[String] = ["trait", "gongfa", "equipment", "terrain", "unit"]
const COMPILE_CACHE_MAX: int = 256

var _tag_to_index: Dictionary = {}
var _tag_registry_version: int = 0
var _mask_word_count: int = 0
var _compiled_cache: Dictionary = {} # cache_key -> compiled config


func configure_tag_registry(tag_to_index: Dictionary, version: int) -> void:
	var incoming: Dictionary = {}
	for key_value in tag_to_index.keys():
		var key: String = str(key_value).strip_edges().to_lower()
		if key.is_empty():
			continue
		incoming[key] = int(tag_to_index[key_value])
	var changed: bool = version != _tag_registry_version
	if not changed and incoming.size() == _tag_to_index.size():
		for key in incoming.keys():
			if not _tag_to_index.has(key) or int(_tag_to_index[key]) != int(incoming[key]):
				changed = true
				break
	else:
		changed = true
	_tag_to_index = incoming
	_tag_registry_version = maxi(version, 0)
	_mask_word_count = int(ceili(float(_tag_to_index.size()) / 64.0))
	if changed:
		_compiled_cache.clear()


func evaluate(owner: Node, config: Dictionary, context: Dictionary) -> Dictionary:
	var output: Dictionary = {
		"query_counts": {},
		"matched_case_ids": [],
		"effects": [],
		"providers": [],
		"debug": {}
	}
	if owner == null or not is_instance_valid(owner):
		return output

	var compiled: Dictionary = _get_compiled_config(config)
	var global_source_types: Array[String] = compiled.get("global_source_types", DEFAULT_SOURCE_TYPES)
	var global_team_scope: String = str(compiled.get("global_team_scope", "ally"))
	var include_self: bool = bool(config.get("include_self", true))
	var range_cells: int = maxi(int(config.get("range", 0)), 0)
	var count_mode: String = str(compiled.get("count_mode", "provider"))

	var scan_context: Dictionary = _build_scan_context(owner, context, range_cells)
	var providers: Array[Dictionary] = _collect_providers(
		owner,
		context,
		scan_context,
		range_cells,
		include_self,
		global_team_scope,
		global_source_types
	)
	output["providers"] = providers

	var query_counts: Dictionary = _count_queries(
		config.get("queries", []),
		providers,
		global_source_types,
		global_team_scope,
		count_mode,
		compiled.get("compiled_queries", [])
	)
	output["query_counts"] = query_counts

	var effects_to_execute: Array[Dictionary] = []
	var matched_case_ids: Array[String] = []
	var stop_after_first_case: bool = bool(config.get("stop_after_first_case", true))
	var cases_value: Variant = config.get("cases", [])
	if cases_value is Array:
		for case_value in (cases_value as Array):
			if not (case_value is Dictionary):
				continue
			var case_data: Dictionary = case_value as Dictionary
			if not _is_case_matched(case_data, query_counts):
				continue
			var case_id: String = str(case_data.get("id", "")).strip_edges()
			if not case_id.is_empty():
				matched_case_ids.append(case_id)
			var case_effects_value: Variant = case_data.get("effects", [])
			if case_effects_value is Array:
				for effect_value in (case_effects_value as Array):
					if effect_value is Dictionary:
						effects_to_execute.append((effect_value as Dictionary).duplicate(true))
			if stop_after_first_case:
				break

	if effects_to_execute.is_empty():
		var else_effects_value: Variant = config.get("else_effects", [])
		if else_effects_value is Array:
			for effect_value in (else_effects_value as Array):
				if effect_value is Dictionary:
					effects_to_execute.append((effect_value as Dictionary).duplicate(true))

	output["matched_case_ids"] = matched_case_ids
	output["effects"] = effects_to_execute
	var compiled_queries_value: Variant = compiled.get("compiled_queries", [])
	var compiled_query_count: int = 0
	if compiled_queries_value is Array:
		compiled_query_count = (compiled_queries_value as Array).size()
	output["debug"] = {
		"range": range_cells,
		"count_mode": count_mode,
		"team_scope": global_team_scope,
		"source_types": global_source_types,
		"compiled_query_count": compiled_query_count,
		"tag_registry_version": _tag_registry_version,
		"scan_cells": scan_context.get("cells", [])
	}
	return output


func _collect_providers(
	owner: Node,
	context: Dictionary,
	scan_context: Dictionary,
	range_cells: int,
	include_self: bool,
	global_team_scope: String,
	global_source_types: Array[String]
) -> Array[Dictionary]:
	var providers: Array[Dictionary] = []
	providers.append_array(
		_collect_unit_providers(
			owner,
			context,
			range_cells,
			include_self,
			global_team_scope,
			global_source_types
		)
	)
	providers.append_array(
		_collect_terrain_providers(
			scan_context,
			context,
			global_source_types
		)
	)
	return providers


func _collect_unit_providers(
	owner: Node,
	context: Dictionary,
	range_cells: int,
	include_self: bool,
	global_team_scope: String,
	global_source_types: Array[String]
) -> Array[Dictionary]:
	var providers: Array[Dictionary] = []
	var candidates: Array[Node] = _extract_units(context.get("all_units", []))
	if include_self and not candidates.has(owner):
		candidates.append(owner)

	for unit in candidates:
		if unit == null or not is_instance_valid(unit):
			continue
		if not _is_live_unit(unit):
			continue

		var is_self: bool = unit == owner
		if is_self and not include_self:
			continue
		if range_cells <= 0 and not is_self:
			continue
		if range_cells > 0 and not _is_unit_within_range(owner, unit, context, range_cells):
			continue

		var relation: String = _resolve_team_relation(owner, unit)

		var iid: int = unit.get_instance_id()
		if global_source_types.has("unit"):
			var unit_tags: Array[String] = _normalize_tags(_node_prop(unit, "tags", []))
			if not unit_tags.is_empty():
				providers.append({
					"key": "unit:%d" % iid,
					"source_type": "unit",
					"tags": unit_tags,
					"tag_mask": _build_mask_from_tags(unit_tags),
					"unit_id": iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})

		if global_source_types.has("trait"):
			for trait_entry in _extract_trait_tag_entries(unit):
				var trait_tags: Array[String] = trait_entry.get("tags", [])
				if trait_tags.is_empty():
					continue
				var trait_id: String = str(trait_entry.get("id", "trait")).strip_edges()
				var trait_idx: int = int(trait_entry.get("index", 0))
				providers.append({
					"key": "trait:%d:%s:%d" % [iid, trait_id, trait_idx],
					"source_type": "trait",
					"tags": trait_tags,
					"tag_mask": _build_mask_from_tags(trait_tags),
					"unit_id": iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})

		if global_source_types.has("gongfa"):
			for gongfa_id in _get_unit_runtime_gongfa_ids(context, unit):
				var gongfa_tags: Array[String] = _get_gongfa_tags(context, gongfa_id)
				if gongfa_tags.is_empty():
					continue
				providers.append({
					"key": "gongfa:%d:%s" % [iid, gongfa_id],
					"source_type": "gongfa",
					"tags": gongfa_tags,
					"tag_mask": _build_mask_from_tags(gongfa_tags),
					"unit_id": iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})

		if global_source_types.has("equipment"):
			for equip_id in _get_unit_runtime_equip_ids(context, unit):
				var equip_tags: Array[String] = _get_equipment_tags(context, equip_id)
				if equip_tags.is_empty():
					continue
				providers.append({
					"key": "equipment:%d:%s" % [iid, equip_id],
					"source_type": "equipment",
					"tags": equip_tags,
					"tag_mask": _build_mask_from_tags(equip_tags),
					"unit_id": iid,
					"is_self": is_self,
					"is_self_cell": false,
					"team_relation": relation
				})
	return providers


func _collect_terrain_providers(
	scan_context: Dictionary,
	context: Dictionary,
	global_source_types: Array[String]
) -> Array[Dictionary]:
	var providers: Array[Dictionary] = []
	if not global_source_types.has("terrain"):
		return providers
	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return providers
	if not combat_manager.has_method("get_terrain_tags_at_cell"):
		return providers
	var origin_cell: Vector2i = scan_context.get("origin_cell", Vector2i(-1, -1))
	var cells: Array[Vector2i] = scan_context.get("cells", [])
	for cell in cells:
		var tags_value: Variant = combat_manager.call("get_terrain_tags_at_cell", cell, "all")
		var terrain_tags: Array[String] = _normalize_tags(tags_value)
		if terrain_tags.is_empty():
			continue
		providers.append({
			"key": "terrain:%d,%d" % [cell.x, cell.y],
			"source_type": "terrain",
			"tags": terrain_tags,
			"tag_mask": _build_mask_from_tags(terrain_tags),
			"unit_id": -1,
			"is_self": false,
			"is_self_cell": cell == origin_cell and origin_cell.x >= 0,
			"team_relation": "neutral"
		})
	return providers


func _count_queries(
	queries_value: Variant,
	providers: Array[Dictionary],
	global_source_types: Array[String],
	global_team_scope: String,
	count_mode: String,
	compiled_queries: Variant = []
) -> Dictionary:
	var query_counts: Dictionary = {}
	var query_items: Array = _resolve_query_items(queries_value, global_source_types, global_team_scope, compiled_queries)
	for query_value in query_items:
		if not (query_value is Dictionary):
			continue
		var query: Dictionary = query_value as Dictionary
		var query_id: String = str(query.get("id", "")).strip_edges()
		if query_id.is_empty():
			continue
		var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
		if query_type != "forbid_tags":
			query_type = "match_tags"
		var query_tags: Array[String] = query.get("tags", [])
		var query_exclude_tags: Array[String] = query.get("exclude_tags", [])
		if query_type == "forbid_tags":
			if query_exclude_tags.is_empty():
				query_counts[query_id] = 0
				continue
		elif query_tags.is_empty():
			query_counts[query_id] = 0
			continue
		var query_source_types: Array[String] = query.get("source_types", global_source_types)
		var query_team_scope: String = str(query.get("team_scope", global_team_scope))
		var origin_scope: String = str(query.get("origin_scope", "all")).strip_edges().to_lower()
		var provider_seen: Dictionary = {}
		var unit_seen: Dictionary = {}
		var count: int = 0
		for provider in providers:
			var source_type: String = str(provider.get("source_type", "")).strip_edges().to_lower()
			if source_type.is_empty() or not query_source_types.has(source_type):
				continue

			var is_self_provider: bool = bool(provider.get("is_self", false)) or bool(provider.get("is_self_cell", false))
			if origin_scope == "self" and not is_self_provider:
				continue
			if origin_scope == "nearby" and is_self_provider:
				continue

			if source_type != "terrain":
				var relation: String = str(provider.get("team_relation", "neutral")).strip_edges().to_lower()
				if not _team_scope_accepts(query_team_scope, relation):
					continue

			if not _provider_matches_query(provider, query):
				continue

			match count_mode:
				"occurrence":
					count += 1
				"unit":
					var unit_id: int = int(provider.get("unit_id", -1))
					if unit_id > 0:
						if unit_seen.has(unit_id):
							continue
						unit_seen[unit_id] = true
						count += 1
					else:
						var key_for_terrain: String = str(provider.get("key", "")).strip_edges()
						if key_for_terrain.is_empty() or provider_seen.has(key_for_terrain):
							continue
						provider_seen[key_for_terrain] = true
						count += 1
				_:
					var provider_key: String = str(provider.get("key", "")).strip_edges()
					if provider_key.is_empty() or provider_seen.has(provider_key):
						continue
					provider_seen[provider_key] = true
					count += 1

		query_counts[query_id] = count
	return query_counts


func _is_case_matched(case_data: Dictionary, query_counts: Dictionary) -> bool:
	var all_conditions_value: Variant = case_data.get("all", [])
	var any_conditions_value: Variant = case_data.get("any", [])
	var all_ok: bool = _match_conditions(all_conditions_value, query_counts, true)
	if not all_ok:
		return false
	if any_conditions_value is Array and not (any_conditions_value as Array).is_empty():
		return _match_conditions(any_conditions_value, query_counts, false)
	return true


func _match_conditions(conditions_value: Variant, query_counts: Dictionary, require_all: bool) -> bool:
	if not (conditions_value is Array):
		return require_all
	var conditions: Array = conditions_value as Array
	if conditions.is_empty():
		return require_all
	if require_all:
		for cond_value in conditions:
			if not _is_single_condition_met(cond_value, query_counts):
				return false
		return true
	for cond_value in conditions:
		if _is_single_condition_met(cond_value, query_counts):
			return true
	return false


func _is_single_condition_met(condition_value: Variant, query_counts: Dictionary) -> bool:
	if not (condition_value is Dictionary):
		return false
	var condition: Dictionary = condition_value as Dictionary
	var query_id: String = str(condition.get("query_id", "")).strip_edges()
	if query_id.is_empty():
		return false
	var count: int = int(query_counts.get(query_id, 0))
	var min_count: int = maxi(int(condition.get("min_count", condition.get("min", 0))), 0)
	var max_count: int = int(condition.get("max_count", condition.get("max", -1)))
	if count < min_count:
		return false
	if max_count >= 0 and count > max_count:
		return false
	return true


func _build_scan_context(owner: Node, context: Dictionary, range_cells: int) -> Dictionary:
	var origin_cell: Vector2i = _resolve_unit_cell(owner, context)
	var cells: Array[Vector2i] = []
	if origin_cell.x < 0 or origin_cell.y < 0:
		return {"origin_cell": origin_cell, "cells": cells}
	if range_cells <= 0:
		cells.append(origin_cell)
		return {"origin_cell": origin_cell, "cells": cells}
	var hex_grid: Node = context.get("hex_grid", null)
	cells = _collect_cells_in_radius(hex_grid, origin_cell, range_cells)
	if cells.is_empty():
		cells.append(origin_cell)
	return {"origin_cell": origin_cell, "cells": cells}


func _resolve_unit_cell(unit: Node, context: Dictionary) -> Vector2i:
	if unit == null or not is_instance_valid(unit):
		return Vector2i(-1, -1)
	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of"):
		var cell_value: Variant = combat_manager.call("get_unit_cell_of", unit)
		if cell_value is Vector2i:
			var cell_from_combat: Vector2i = cell_value as Vector2i
			if cell_from_combat.x >= 0 and cell_from_combat.y >= 0:
				return cell_from_combat
	var hex_grid: Node = context.get("hex_grid", null)
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
		var n2d: Node2D = unit as Node2D
		if n2d != null:
			var cell_value_hex: Variant = hex_grid.call("world_to_axial", n2d.position)
			if cell_value_hex is Vector2i:
				return cell_value_hex as Vector2i
	return Vector2i(-1, -1)


func _collect_cells_in_radius(hex_grid: Node, center_cell: Vector2i, radius_cells: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	if not hex_grid.has_method("is_inside_grid") or not hex_grid.has_method("get_neighbor_cells"):
		return out
	if not bool(hex_grid.call("is_inside_grid", center_cell)):
		return out
	var queue: Array[Vector2i] = [center_cell]
	var visited: Dictionary = {"%d,%d" % [center_cell.x, center_cell.y]: true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance(center_cell, cell, hex_grid) > radius_cells:
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
			var key: String = "%d,%d" % [neighbor.x, neighbor.y]
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


func _is_unit_within_range(owner: Node, unit: Node, context: Dictionary, range_cells: int) -> bool:
	if owner == unit:
		return true
	if range_cells <= 0:
		return false
	var owner_cell: Vector2i = _resolve_unit_cell(owner, context)
	var unit_cell: Vector2i = _resolve_unit_cell(unit, context)
	if owner_cell.x >= 0 and unit_cell.x >= 0:
		var hex_grid: Node = context.get("hex_grid", null)
		return _hex_distance(owner_cell, unit_cell, hex_grid) <= range_cells

	var owner_pos: Vector2 = _node_pos(owner)
	var unit_pos: Vector2 = _node_pos(unit)
	if owner_pos == Vector2.ZERO and unit_pos == Vector2.ZERO:
		return false
	var max_world: float = _cells_to_world_distance(float(range_cells), context)
	return owner_pos.distance_squared_to(unit_pos) <= max_world * max_world


func _resolve_team_relation(owner: Node, unit: Node) -> String:
	if owner == null or not is_instance_valid(owner):
		return "neutral"
	if unit == null or not is_instance_valid(unit):
		return "neutral"
	var owner_team: int = int(owner.get("team_id"))
	var unit_team: int = int(unit.get("team_id"))
	if owner_team == 0 or unit_team == 0:
		return "neutral"
	if owner_team == unit_team:
		return "ally"
	return "enemy"


func _team_scope_accepts(scope: String, relation: String) -> bool:
	match scope:
		"enemy":
			return relation == "enemy"
		"all":
			return true
		_:
			return relation == "ally"


func _resolve_query_items(
	queries_value: Variant,
	global_source_types: Array[String],
	global_team_scope: String,
	compiled_queries: Variant
) -> Array:
	var query_items: Array = []
	if compiled_queries is Array and not (compiled_queries as Array).is_empty():
		return (compiled_queries as Array).duplicate(true)
	if not (queries_value is Array):
		return query_items
	for query_idx in range((queries_value as Array).size()):
		var query_value: Variant = (queries_value as Array)[query_idx]
		if not (query_value is Dictionary):
			continue
		query_items.append(_compile_single_query(query_value as Dictionary, query_idx, global_source_types, global_team_scope))
	return query_items


func _provider_matches_query(provider: Dictionary, query: Dictionary) -> bool:
	var provider_tags: Array[String] = provider.get("tags", [])
	if provider_tags.is_empty():
		return false
	var provider_mask: PackedInt64Array = provider.get("tag_mask", PackedInt64Array())
	var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
	if query_type != "forbid_tags":
		query_type = "match_tags"

	var query_tag_match: String = str(query.get("tag_match", "any")).strip_edges().to_lower()
	if query_tag_match != "all":
		query_tag_match = "any"
	var query_exclude_match: String = str(query.get("exclude_match", "any")).strip_edges().to_lower()
	if query_exclude_match != "all":
		query_exclude_match = "any"

	var include_ok: bool = true
	if query_type == "match_tags":
		include_ok = _provider_matches_compiled_tags(
			provider_tags,
			provider_mask,
			query.get("tag_mask", PackedInt64Array()),
			query.get("indexed_tags", []),
			query.get("fallback_tags", []),
			query.get("tags", []),
			query_tag_match
		)
		if not include_ok:
			return false

	var exclude_hit: bool = _provider_matches_compiled_tags(
		provider_tags,
		provider_mask,
		query.get("exclude_tag_mask", PackedInt64Array()),
		query.get("exclude_indexed_tags", []),
		query.get("exclude_fallback_tags", []),
		query.get("exclude_tags", []),
		query_exclude_match
	)
	if query_type == "forbid_tags":
		return exclude_hit
	return not exclude_hit


func _provider_matches_compiled_tags(
	provider_tags: Array[String],
	provider_mask: PackedInt64Array,
	compiled_mask_value: Variant,
	indexed_tags_value: Variant,
	fallback_tags_value: Variant,
	raw_tags_value: Variant,
	tag_match: String
) -> bool:
	var query_mask: PackedInt64Array = PackedInt64Array()
	if compiled_mask_value is PackedInt64Array:
		query_mask = compiled_mask_value
	var indexed_tags: Array[String] = []
	if indexed_tags_value is Array:
		for tag in (indexed_tags_value as Array):
			indexed_tags.append(str(tag))
	var fallback_tags: Array[String] = []
	if fallback_tags_value is Array:
		for tag in (fallback_tags_value as Array):
			fallback_tags.append(str(tag))
	var raw_tags: Array[String] = []
	if raw_tags_value is Array:
		for tag in (raw_tags_value as Array):
			raw_tags.append(str(tag))
	if raw_tags.is_empty():
		return false
	if tag_match == "all":
		if not _mask_matches_all(provider_mask, query_mask):
			return false
		for tag in fallback_tags:
			if not provider_tags.has(tag):
				return false
		return true
	if _mask_matches_any(provider_mask, query_mask):
		return true
	for tag in fallback_tags:
		if provider_tags.has(tag):
			return true
	if not indexed_tags.is_empty():
		return false
	return _provider_matches_tags(provider_tags, raw_tags, "any")


func _provider_matches_tags(provider_tags: Array[String], query_tags: Array[String], tag_match: String) -> bool:
	if provider_tags.is_empty() or query_tags.is_empty():
		return false
	if tag_match == "all":
		for tag in query_tags:
			if not provider_tags.has(tag):
				return false
		return true
	for tag in query_tags:
		if provider_tags.has(tag):
			return true
	return false


func _extract_trait_tag_entries(unit: Node) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if unit == null or not is_instance_valid(unit):
		return out
	var traits_value: Variant = unit.get("traits")
	if not (traits_value is Array):
		return out
	var traits: Array = traits_value as Array
	for idx in range(traits.size()):
		var trait_value: Variant = traits[idx]
		if not (trait_value is Dictionary):
			continue
		var trait_data: Dictionary = trait_value as Dictionary
		var trait_tags: Array[String] = _normalize_tags(trait_data.get("tags", []))
		if trait_tags.is_empty():
			continue
		var trait_id: String = str(trait_data.get("id", "trait_%d" % idx)).strip_edges()
		if trait_id.is_empty():
			trait_id = "trait_%d" % idx
		out.append({
			"id": trait_id,
			"index": idx,
			"tags": trait_tags
		})
	return out


func _get_unit_runtime_gongfa_ids(context: Dictionary, unit: Node) -> Array[String]:
	var manager: Node = context.get("gongfa_manager", null)
	if manager != null and is_instance_valid(manager) and manager.has_method("get_unit_runtime_gongfa_ids"):
		return _normalize_ids(manager.call("get_unit_runtime_gongfa_ids", unit))
	return _normalize_ids(unit.get("runtime_equipped_gongfa_ids"))


func _get_unit_runtime_equip_ids(context: Dictionary, unit: Node) -> Array[String]:
	var manager: Node = context.get("gongfa_manager", null)
	if manager != null and is_instance_valid(manager) and manager.has_method("get_unit_runtime_equip_ids"):
		return _normalize_ids(manager.call("get_unit_runtime_equip_ids", unit))
	return _normalize_ids(unit.get("runtime_equipped_equip_ids"))


func _get_gongfa_tags(context: Dictionary, gongfa_id: String) -> Array[String]:
	var manager: Node = context.get("gongfa_manager", null)
	if manager != null and is_instance_valid(manager):
		if manager.has_method("get_gongfa_tags"):
			return _normalize_tags(manager.call("get_gongfa_tags", gongfa_id))
		if manager.has_method("get_gongfa_data"):
			var data_value: Variant = manager.call("get_gongfa_data", gongfa_id)
			if data_value is Dictionary:
				return _normalize_tags((data_value as Dictionary).get("tags", []))
	return []


func _get_equipment_tags(context: Dictionary, equip_id: String) -> Array[String]:
	var manager: Node = context.get("gongfa_manager", null)
	if manager != null and is_instance_valid(manager):
		if manager.has_method("get_equipment_tags"):
			return _normalize_tags(manager.call("get_equipment_tags", equip_id))
		if manager.has_method("get_equipment_data"):
			var data_value: Variant = manager.call("get_equipment_data", equip_id)
			if data_value is Dictionary:
				return _normalize_tags((data_value as Dictionary).get("tags", []))
	return []


func _extract_units(value: Variant) -> Array[Node]:
	var out: Array[Node] = []
	if value is Array:
		for unit_value in (value as Array):
			if unit_value is Node:
				out.append(unit_value as Node)
	return out


func _normalize_ids(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for item in (value as Array):
			var text: String = str(item).strip_edges()
			if text.is_empty():
				continue
			if seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


func _get_compiled_config(config: Dictionary) -> Dictionary:
	var cache_key: String = "%d|%s" % [_tag_registry_version, var_to_str(config)]
	if _compiled_cache.has(cache_key):
		return (_compiled_cache[cache_key] as Dictionary).duplicate(true)
	var compiled: Dictionary = _compile_config(config)
	if _compiled_cache.size() >= COMPILE_CACHE_MAX:
		_compiled_cache.clear()
	compiled["cache_key"] = cache_key
	compiled["tag_registry_version"] = _tag_registry_version
	_compiled_cache[cache_key] = compiled.duplicate(true)
	return compiled


func _compile_config(config: Dictionary) -> Dictionary:
	var global_source_types: Array[String] = _normalize_source_types(config.get("source_types", DEFAULT_SOURCE_TYPES))
	var global_team_scope: String = _normalize_team_scope(str(config.get("team_scope", "ally")))
	var count_mode: String = _normalize_count_mode(str(config.get("count_mode", "provider")))
	var compiled_queries: Array = []
	var queries_value: Variant = config.get("queries", [])
	if queries_value is Array:
		for query_idx in range((queries_value as Array).size()):
			var query_value: Variant = (queries_value as Array)[query_idx]
			if not (query_value is Dictionary):
				continue
			compiled_queries.append(_compile_single_query(query_value as Dictionary, query_idx, global_source_types, global_team_scope))
	return {
		"global_source_types": global_source_types,
		"global_team_scope": global_team_scope,
		"count_mode": count_mode,
		"compiled_queries": compiled_queries
	}


func _compile_single_query(query: Dictionary, query_idx: int, global_source_types: Array[String], global_team_scope: String) -> Dictionary:
	var query_id: String = str(query.get("id", "q_%d" % query_idx)).strip_edges()
	if query_id.is_empty():
		query_id = "q_%d" % query_idx
	var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
	if query_type != "forbid_tags":
		query_type = "match_tags"
	var query_tags: Array[String] = _normalize_tags(query.get("tags", []))
	var query_tag_match: String = str(query.get("tag_match", "any")).strip_edges().to_lower()
	if query_tag_match != "all":
		query_tag_match = "any"
	var query_exclude_tags: Array[String] = _normalize_tags(query.get("exclude_tags", []))
	var query_exclude_match: String = str(query.get("exclude_match", "any")).strip_edges().to_lower()
	if query_exclude_match != "all":
		query_exclude_match = "any"
	var query_source_types: Array[String] = global_source_types
	if query.has("source_types"):
		query_source_types = _normalize_source_types(query.get("source_types", global_source_types))
	var query_team_scope: String = global_team_scope
	if query.has("team_scope"):
		query_team_scope = _normalize_team_scope(str(query.get("team_scope", global_team_scope)))
	var origin_scope: String = str(query.get("origin_scope", "all")).strip_edges().to_lower()
	if origin_scope != "self" and origin_scope != "nearby":
		origin_scope = "all"
	var indexed_tags: Array[String] = []
	var fallback_tags: Array[String] = []
	for tag in query_tags:
		if _tag_to_index.has(tag):
			indexed_tags.append(tag)
		else:
			fallback_tags.append(tag)
	var exclude_indexed_tags: Array[String] = []
	var exclude_fallback_tags: Array[String] = []
	for tag in query_exclude_tags:
		if _tag_to_index.has(tag):
			exclude_indexed_tags.append(tag)
		else:
			exclude_fallback_tags.append(tag)
	return {
		"id": query_id,
		"query_type": query_type,
		"tags": query_tags,
		"indexed_tags": indexed_tags,
		"fallback_tags": fallback_tags,
		"tag_mask": _build_mask_from_tags(indexed_tags),
		"tag_match": query_tag_match,
		"exclude_tags": query_exclude_tags,
		"exclude_indexed_tags": exclude_indexed_tags,
		"exclude_fallback_tags": exclude_fallback_tags,
		"exclude_tag_mask": _build_mask_from_tags(exclude_indexed_tags),
		"exclude_match": query_exclude_match,
		"source_types": query_source_types,
		"team_scope": query_team_scope,
		"origin_scope": origin_scope
	}


func _build_mask_from_tags(tags: Array[String]) -> PackedInt64Array:
	var mask: PackedInt64Array = _create_empty_mask()
	if mask.is_empty():
		return mask
	for tag in tags:
		if not _tag_to_index.has(tag):
			continue
		var index: int = int(_tag_to_index[tag])
		if index < 0:
			continue
		var word: int = index >> 6
		var bit: int = index & 63
		if word < 0 or word >= mask.size():
			continue
		mask[word] = int(mask[word]) | (1 << bit)
	return mask


func _create_empty_mask() -> PackedInt64Array:
	var word_count: int = maxi(_mask_word_count, 0)
	var mask: PackedInt64Array = PackedInt64Array()
	if word_count <= 0:
		return mask
	mask.resize(word_count)
	for i in range(word_count):
		mask[i] = 0
	return mask


func _mask_matches_any(provider_mask: PackedInt64Array, query_mask: PackedInt64Array) -> bool:
	if provider_mask.is_empty() or query_mask.is_empty():
		return false
	var count: int = mini(provider_mask.size(), query_mask.size())
	for idx in range(count):
		if (int(provider_mask[idx]) & int(query_mask[idx])) != 0:
			return true
	return false


func _mask_matches_all(provider_mask: PackedInt64Array, query_mask: PackedInt64Array) -> bool:
	if query_mask.is_empty():
		return true
	if provider_mask.is_empty():
		return false
	if provider_mask.size() < query_mask.size():
		return false
	for idx in range(query_mask.size()):
		var qword: int = int(query_mask[idx])
		if qword == 0:
			continue
		if (int(provider_mask[idx]) & qword) != qword:
			return false
	return true


func _normalize_source_types(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for item in (value as Array):
			var key: String = str(item).strip_edges().to_lower()
			if key.is_empty():
				continue
			if key != "trait" and key != "gongfa" and key != "equipment" and key != "terrain" and key != "unit":
				continue
			if seen.has(key):
				continue
			seen[key] = true
			out.append(key)
	if out.is_empty():
		return DEFAULT_SOURCE_TYPES.duplicate()
	return out


func _normalize_tags(value: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if value is Array:
		for item in (value as Array):
			var text: String = str(item).strip_edges().to_lower()
			if text.is_empty():
				continue
			if seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


func _normalize_team_scope(raw_scope: String) -> String:
	var scope: String = raw_scope.strip_edges().to_lower()
	if scope == "enemy":
		return "enemy"
	if scope == "all":
		return "all"
	return "ally"


func _normalize_count_mode(raw_mode: String) -> String:
	var mode: String = raw_mode.strip_edges().to_lower()
	if mode == "occurrence":
		return "occurrence"
	if mode == "unit":
		return "unit"
	return "provider"


func _is_live_unit(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return true
	return bool(combat.get("is_alive"))


func _hex_distance(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


func _cells_to_world_distance(cells: float, context: Dictionary) -> float:
	var hex_size: float = float(context.get("hex_size", 26.0))
	return maxf(cells, 0.0) * maxf(hex_size, 1.0) * 1.2


func _node_pos(node: Node) -> Vector2:
	if node == null or not is_instance_valid(node):
		return Vector2.ZERO
	var node2d: Node2D = node as Node2D
	if node2d == null:
		return Vector2.ZERO
	return node2d.position


func _node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value
