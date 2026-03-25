extends RefCounted
class_name GongfaBuffManager

signal buff_removed(event: Dictionary)

# ===========================
# Buff / Debuff 管理器
# ===========================
# 目标：
# 1. 维护单位身上的 Buff 生命周期（叠加、刷新、过期）。
# 2. 提供“当前生效效果列表”给 GongfaManager 参与属性重算。
# 3. 处理 tick_effects 的定时触发请求（真正执行由 EffectEngine 完成）。

var _buff_defs: Dictionary = {}      # buff_id -> buff_data
var _active_by_unit: Dictionary = {} # unit_instance_id -> Array[Dictionary]
# 战场级效果（例如 hazard_zone）：不绑定单个单位，按区域与时间驱动。
var _battlefield_effects: Array[Dictionary] = []
var _source_bound_auras: Dictionary = {} # aura_key -> Dictionary


func clear_all() -> void:
	_active_by_unit.clear()
	_battlefield_effects.clear()
	_source_bound_auras.clear()


func set_buff_definitions(buff_defs: Dictionary) -> void:
	_buff_defs = buff_defs.duplicate(true)


func apply_buff(target: Node, buff_id: String, duration: float, source: Node = null) -> bool:
	return apply_buff_with_options(target, buff_id, duration, source, {})


func apply_buff_with_options(
	target: Node,
	buff_id: String,
	duration: float,
	source: Node = null,
	options: Dictionary = {}
) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not _buff_defs.has(buff_id):
		push_warning("BuffManager: 未找到 Buff 定义 id=%s" % buff_id)
		return false

	var iid: int = target.get_instance_id()
	var unit_entries: Array = _active_by_unit.get(iid, [])
	var buff_data: Dictionary = (_buff_defs[buff_id] as Dictionary).duplicate(true)
	var source_meta: Dictionary = _build_source_meta(source)
	var source_id: int = int(source_meta.get("source_id", -1))
	var application_key: String = _normalize_application_key(options.get("application_key", ""))

	var stackable: bool = bool(buff_data.get("stackable", false))
	var max_stacks: int = maxi(int(buff_data.get("max_stacks", 1)), 1)
	var final_duration: float = duration
	if final_duration <= 0.0:
		final_duration = float(buff_data.get("default_duration", 3.0))
	# duration < 0 代表永久效果。
	if duration < 0.0:
		final_duration = -1.0

	for i in range(unit_entries.size()):
		var entry: Dictionary = unit_entries[i]
		if str(entry.get("buff_id", "")) != buff_id:
			continue
		if int(entry.get("source_id", -1)) != source_id:
			continue
		if _normalize_application_key(entry.get("application_key", "")) != application_key:
			continue

		if stackable:
			entry["stacks"] = mini(int(entry.get("stacks", 1)) + 1, max_stacks)
		else:
			entry["stacks"] = 1

		if str(buff_data.get("type", "buff")).strip_edges().to_lower() == "debuff" and final_duration > 0.0:
			final_duration = _apply_tenacity_duration_scale(target, final_duration)
		entry["remaining"] = final_duration
		entry["tick_accum"] = 0.0
		entry["source_id"] = int(source_meta.get("source_id", -1))
		entry["source_unit_id"] = str(source_meta.get("source_unit_id", "")).strip_edges()
		entry["source_name"] = str(source_meta.get("source_name", "")).strip_edges()
		entry["source_team"] = int(source_meta.get("source_team", 0))
		entry["application_key"] = application_key
		unit_entries[i] = entry
		_active_by_unit[iid] = unit_entries
		_sync_unit_runtime_meta(target, unit_entries)
		return true

	var new_entry: Dictionary = {
		"buff_id": buff_id,
		"data": buff_data,
		"stacks": 1,
		"remaining": final_duration,
		"tick_accum": 0.0,
		"source_id": int(source_meta.get("source_id", -1)),
		"source_unit_id": str(source_meta.get("source_unit_id", "")).strip_edges(),
		"source_name": str(source_meta.get("source_name", "")).strip_edges(),
		"source_team": int(source_meta.get("source_team", 0)),
		"application_key": application_key
	}
	if str(buff_data.get("type", "buff")).strip_edges().to_lower() == "debuff" and final_duration > 0.0:
		new_entry["remaining"] = _apply_tenacity_duration_scale(target, final_duration)
	unit_entries.append(new_entry)
	_active_by_unit[iid] = unit_entries
	_sync_unit_runtime_meta(target, unit_entries)
	return true


func remove_buff(target: Node, buff_id: String, reason: String = "manual") -> int:
	return _remove_buff_internal(target, buff_id, reason, "", false)


func remove_buff_instance(target: Node, buff_id: String, application_key: String, reason: String = "manual") -> int:
	var normalized_application_key: String = _normalize_application_key(application_key)
	if normalized_application_key.is_empty():
		return 0
	return _remove_buff_internal(target, buff_id, reason, normalized_application_key, true)


func _remove_buff_internal(
	target: Node,
	buff_id: String,
	reason: String,
	application_key: String,
	match_application_key: bool
) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var normalized_buff_id: String = buff_id.strip_edges()
	if normalized_buff_id.is_empty():
		return 0
	var iid: int = target.get_instance_id()
	if not _active_by_unit.has(iid):
		return 0
	var entries: Array = _active_by_unit.get(iid, [])
	var next_entries: Array = []
	var removed_count: int = 0
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("buff_id", "")).strip_edges() != normalized_buff_id:
			next_entries.append(entry)
			continue
		if match_application_key and _normalize_application_key(entry.get("application_key", "")) != application_key:
			next_entries.append(entry)
			continue
		removed_count += 1
		_on_buff_entry_removed(iid, entry, reason)
		_emit_buff_removed(iid, normalized_buff_id, int(entry.get("source_id", -1)), reason)
	if next_entries.is_empty():
		_active_by_unit.erase(iid)
	else:
		_active_by_unit[iid] = next_entries
	_sync_unit_runtime_meta(target, next_entries)
	return removed_count


func remove_all_for_unit(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_id: String = str(entry.get("buff_id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		_on_buff_entry_removed(iid, entry, "unit_removed")
		_emit_buff_removed(iid, buff_id, int(entry.get("source_id", -1)), "unit_removed")
	_active_by_unit.erase(iid)
	_clear_unit_runtime_meta(target)


func collect_passive_effects_for_unit(target: Node) -> Array[Dictionary]:
	var effects: Array[Dictionary] = []
	if target == null or not is_instance_valid(target):
		return effects

	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_data: Dictionary = entry.get("data", {})
		var stacks: int = maxi(int(entry.get("stacks", 1)), 1)
		var raw_effects: Variant = buff_data.get("effects", [])
		if not (raw_effects is Array):
			continue
		for effect_value in raw_effects:
			if not (effect_value is Dictionary):
				continue
			var scaled: Dictionary = (effect_value as Dictionary).duplicate(true)
			# 简化约定：有 value 字段的效果按层数线性放大。
			if scaled.has("value"):
				scaled["value"] = float(scaled.get("value", 0.0)) * float(stacks)
			effects.append(scaled)

	return effects


func get_active_buff_ids_for_unit(target: Node) -> Array[String]:
	var ids: Array[String] = []
	if target == null or not is_instance_valid(target):
		return ids
	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	var seen: Dictionary = {}
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var buff_id: String = str((entry_value as Dictionary).get("buff_id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		if seen.has(buff_id):
			continue
		seen[buff_id] = true
		ids.append(buff_id)
	return ids


func has_buff(target: Node, buff_id: String) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var normalized: String = buff_id.strip_edges()
	if normalized.is_empty():
		return false
	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		if str((entry_value as Dictionary).get("buff_id", "")).strip_edges() == normalized:
			return true
	return false


func has_debuff(target: Node, debuff_id: String = "") -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var normalized: String = debuff_id.strip_edges()
	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_data: Dictionary = entry.get("data", {})
		if str(buff_data.get("type", "buff")).strip_edges().to_lower() != "debuff":
			continue
		if normalized.is_empty():
			return true
		if str(entry.get("buff_id", "")).strip_edges() == normalized:
			return true
	return false


func cleanse_debuffs(target: Node) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var iid: int = target.get_instance_id()
	if not _active_by_unit.has(iid):
		return 0
	var entries: Array = _active_by_unit.get(iid, [])
	var next_entries: Array = []
	var removed: int = 0
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_data: Dictionary = entry.get("data", {})
		var buff_type: String = str(buff_data.get("type", "buff")).strip_edges().to_lower()
		if buff_type != "debuff":
			next_entries.append(entry)
			continue
		removed += 1
		_on_buff_entry_removed(iid, entry, "cleanse")
		_emit_buff_removed(iid, str(entry.get("buff_id", "")).strip_edges(), int(entry.get("source_id", -1)), "cleanse")
	if next_entries.is_empty():
		_active_by_unit.erase(iid)
	else:
		_active_by_unit[iid] = next_entries
	_sync_unit_runtime_meta(target, next_entries)
	if next_entries.is_empty():
		_clear_unit_runtime_meta(target)
	return removed


func dispel_buffs(target: Node, count: int) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var max_remove: int = maxi(count, 0)
	if max_remove <= 0:
		return 0
	var iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(iid, [])
	if entries.is_empty():
		return 0
	var buff_candidates: Array[int] = []
	for idx in range(entries.size()):
		if not (entries[idx] is Dictionary):
			continue
		var entry: Dictionary = entries[idx]
		var buff_data: Dictionary = entry.get("data", {})
		if str(buff_data.get("type", "buff")).strip_edges().to_lower() == "buff":
			buff_candidates.append(idx)
	if buff_candidates.is_empty():
		return 0
	buff_candidates.shuffle()
	var remove_index_set: Dictionary = {}
	for pick in range(mini(max_remove, buff_candidates.size())):
		remove_index_set[int(buff_candidates[pick])] = true
	var next_entries: Array = []
	var removed: int = 0
	for idx2 in range(entries.size()):
		var entry_value2: Variant = entries[idx2]
		if not (entry_value2 is Dictionary):
			continue
		var entry2: Dictionary = entry_value2
		if not remove_index_set.has(idx2):
			next_entries.append(entry2)
			continue
		removed += 1
		_on_buff_entry_removed(iid, entry2, "dispel")
		_emit_buff_removed(iid, str(entry2.get("buff_id", "")).strip_edges(), int(entry2.get("source_id", -1)), "dispel")
	if next_entries.is_empty():
		_active_by_unit.erase(iid)
	else:
		_active_by_unit[iid] = next_entries
	_sync_unit_runtime_meta(target, next_entries)
	if next_entries.is_empty():
		_clear_unit_runtime_meta(target)
	return removed


func steal_buffs(source_target: Node, receiver: Node, count: int, source: Node = null) -> int:
	if source_target == null or not is_instance_valid(source_target):
		return 0
	if receiver == null or not is_instance_valid(receiver):
		return 0
	var max_steal: int = maxi(count, 0)
	if max_steal <= 0:
		return 0
	var source_iid: int = source_target.get_instance_id()
	var entries: Array = _active_by_unit.get(source_iid, [])
	if entries.is_empty():
		return 0
	var candidate_indices: Array[int] = []
	for idx in range(entries.size()):
		if not (entries[idx] is Dictionary):
			continue
		var entry: Dictionary = entries[idx]
		var buff_data: Dictionary = entry.get("data", {})
		if str(buff_data.get("type", "buff")).strip_edges().to_lower() == "buff":
			candidate_indices.append(idx)
	if candidate_indices.is_empty():
		return 0
	candidate_indices.shuffle()
	var selected_index_set: Dictionary = {}
	for pick in range(mini(max_steal, candidate_indices.size())):
		selected_index_set[int(candidate_indices[pick])] = true
	var next_entries: Array = []
	var stolen_count: int = 0
	for idx2 in range(entries.size()):
		var entry_value2: Variant = entries[idx2]
		if not (entry_value2 is Dictionary):
			continue
		var entry2: Dictionary = entry_value2
		if not selected_index_set.has(idx2):
			next_entries.append(entry2)
			continue
		stolen_count += 1
		var buff_id: String = str(entry2.get("buff_id", "")).strip_edges()
		var remaining: float = float(entry2.get("remaining", 0.0))
		var duration: float = remaining if remaining != 0.0 else float((entry2.get("data", {}) as Dictionary).get("default_duration", 3.0))
		apply_buff(receiver, buff_id, duration, source)
		_on_buff_entry_removed(source_iid, entry2, "stolen")
		_emit_buff_removed(source_iid, buff_id, int(entry2.get("source_id", -1)), "stolen")
	if next_entries.is_empty():
		_active_by_unit.erase(source_iid)
	else:
		_active_by_unit[source_iid] = next_entries
	_sync_unit_runtime_meta(source_target, next_entries)
	if next_entries.is_empty():
		_clear_unit_runtime_meta(source_target)
	return stolen_count


func add_battlefield_effect(effect_config: Dictionary, source: Node = null) -> bool:
	if effect_config.is_empty():
		return false
	var center_cell_value: Variant = effect_config.get("center_cell", Vector2i(-1, -1))
	if not (center_cell_value is Vector2i):
		return false
	var center_cell: Vector2i = center_cell_value as Vector2i
	if center_cell.x < 0 or center_cell.y < 0:
		return false
	var tick_effects_value: Variant = effect_config.get("tick_effects", [])
	if not (tick_effects_value is Array) or (tick_effects_value as Array).is_empty():
		return false
	var source_id: int = int(effect_config.get("source_id", -1))
	if source_id <= 0 and source != null and is_instance_valid(source):
		source_id = source.get_instance_id()
	var source_unit_id: String = str(effect_config.get("source_unit_id", "")).strip_edges()
	if source_unit_id.is_empty() and source != null and is_instance_valid(source):
		source_unit_id = str(source.get("unit_id"))
	var source_name: String = str(effect_config.get("source_name", "")).strip_edges()
	if source_name.is_empty() and source != null and is_instance_valid(source):
		source_name = str(source.get("unit_name"))
	var source_team: int = int(effect_config.get("source_team", 0))
	if source_team == 0 and source != null and is_instance_valid(source):
		source_team = int(source.get("team_id"))
	var duration: float = float(effect_config.get("duration", 0.0))
	if duration < 0.0:
		duration = -1.0
	var tick_interval: float = maxf(float(effect_config.get("tick_interval", 0.5)), 0.05)
	var warning_seconds: float = maxf(float(effect_config.get("warning_seconds", 0.0)), 0.0)
	_battlefield_effects.append({
		"effect_id": str(effect_config.get("effect_id", "battlefield_effect")).strip_edges(),
		"source_id": source_id,
		"source_unit_id": source_unit_id,
		"source_name": source_name,
		"source_team": source_team,
		"center_cell": center_cell,
		"radius_cells": maxi(int(effect_config.get("radius_cells", 1)), 0),
		"target_mode": str(effect_config.get("target_mode", "enemies")).strip_edges().to_lower(),
		"remaining": duration,
		"tick_interval": tick_interval,
		"tick_accum": 0.0,
		"warning_remaining": warning_seconds,
		"tick_effects": (tick_effects_value as Array).duplicate(true)
	})
	return true


func refresh_source_bound_aura(
	source: Node,
	buff_id: String,
	aura_key: String,
	scope_key: String,
	scope_refresh_token: int,
	targets: Array,
	context: Dictionary = {}
) -> Dictionary:
	var normalized_aura_key: String = aura_key.strip_edges()
	var normalized_scope_key: String = scope_key.strip_edges()
	if source == null or not is_instance_valid(source):
		return {"applied_count": 0, "applied_targets": []}
	if normalized_aura_key.is_empty() or normalized_scope_key.is_empty():
		return {"applied_count": 0, "applied_targets": []}
	if not _buff_defs.has(buff_id):
		return {"applied_count": 0, "applied_targets": []}

	var source_id: int = source.get_instance_id()
	var aura_record: Dictionary = _source_bound_auras.get(normalized_aura_key, {
		"aura_key": normalized_aura_key,
		"scope_key": normalized_scope_key,
		"source_id": source_id,
		"buff_id": buff_id,
		"application_key": normalized_aura_key,
		"target_ids": {},
		"last_refresh_token": 0
	})
	var previous_target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(true)
	var next_target_ids: Dictionary = {}
	var applied_targets: Array[Node] = []
	var seen_target_ids: Dictionary = {}

	for target_value in targets:
		if not (target_value is Node):
			continue
		var target: Node = target_value as Node
		if target == null or not is_instance_valid(target):
			continue
		var target_iid: int = target.get_instance_id()
		if seen_target_ids.has(target_iid):
			continue
		seen_target_ids[target_iid] = true
		next_target_ids[target_iid] = true
		var has_instance: bool = _has_buff_instance(target, buff_id, normalized_aura_key)
		if previous_target_ids.has(target_iid) and has_instance:
			continue
		if apply_buff_with_options(target, buff_id, -1.0, source, {"application_key": normalized_aura_key}):
			applied_targets.append(target)

	for previous_target_id in previous_target_ids.keys():
		var target_iid: int = int(previous_target_id)
		if next_target_ids.has(target_iid):
			continue
		var removed_target: Node = _find_unit_in_context(target_iid, context)
		if removed_target != null and is_instance_valid(removed_target):
			remove_buff_instance(removed_target, buff_id, normalized_aura_key, "aura_condition_lost")

	aura_record["scope_key"] = normalized_scope_key
	aura_record["source_id"] = source_id
	aura_record["buff_id"] = buff_id
	aura_record["application_key"] = normalized_aura_key
	aura_record["target_ids"] = next_target_ids
	aura_record["last_refresh_token"] = scope_refresh_token
	_source_bound_auras[normalized_aura_key] = aura_record

	return {
		"applied_count": applied_targets.size(),
		"applied_targets": applied_targets
	}


func finalize_source_bound_aura_scope(scope_key: String, scope_refresh_token: int, context: Dictionary = {}) -> int:
	var normalized_scope_key: String = scope_key.strip_edges()
	if normalized_scope_key.is_empty() or scope_refresh_token <= 0:
		return 0
	var removed_total: int = 0
	var stale_aura_keys: Array[String] = []
	for aura_key_value in _source_bound_auras.keys():
		var aura_key: String = str(aura_key_value).strip_edges()
		var aura_record: Dictionary = _source_bound_auras.get(aura_key, {})
		if str(aura_record.get("scope_key", "")).strip_edges() != normalized_scope_key:
			continue
		if int(aura_record.get("last_refresh_token", 0)) == scope_refresh_token:
			continue
		removed_total += _remove_source_bound_aura_record(aura_key, aura_record, "aura_condition_lost", context)
		stale_aura_keys.append(aura_key)
	for aura_key in stale_aura_keys:
		_source_bound_auras.erase(aura_key)
	return removed_total


func remove_source_bound_auras_from_source(source: Node, context: Dictionary = {}) -> int:
	if source == null or not is_instance_valid(source):
		return 0
	var source_id: int = source.get_instance_id()
	var removed_total: int = 0
	var stale_aura_keys: Array[String] = []
	for aura_key_value in _source_bound_auras.keys():
		var aura_key: String = str(aura_key_value).strip_edges()
		var aura_record: Dictionary = _source_bound_auras.get(aura_key, {})
		if int(aura_record.get("source_id", -1)) != source_id:
			continue
		removed_total += _remove_source_bound_aura_record(aura_key, aura_record, "aura_source_dead", context)
		stale_aura_keys.append(aura_key)
	for aura_key in stale_aura_keys:
		_source_bound_auras.erase(aura_key)
	return removed_total


func tick(delta: float, context: Dictionary = {}) -> Dictionary:
	# 返回值包含两类信息：
	# 1) tick_requests：到点需要触发的周期效果。
	# 2) changed_unit_ids：Buff 状态变化，需要重算属性的单位。
	var changed_units: Dictionary = {}
	var tick_requests: Array[Dictionary] = []

	for key in _active_by_unit.keys():
		var iid: int = int(key)
		var entries: Array = _active_by_unit.get(iid, [])
		var next_entries: Array = []

		for entry_value in entries:
			if not (entry_value is Dictionary):
				continue
			var entry: Dictionary = (entry_value as Dictionary).duplicate(true)
			var buff_data: Dictionary = entry.get("data", {})

			var previous_remaining: float = float(entry.get("remaining", 0.0))
			var remaining: float = previous_remaining
			if remaining >= 0.0:
				remaining -= delta
				entry["remaining"] = remaining

			var tick_interval: float = float(buff_data.get("tick_interval", 0.0))
			var tick_effects: Variant = buff_data.get("tick_effects", [])
			if tick_interval > 0.0 and tick_effects is Array and not (tick_effects as Array).is_empty():
				var tick_accum: float = float(entry.get("tick_accum", 0.0)) + delta
				while tick_accum >= tick_interval:
					tick_accum -= tick_interval
					tick_requests.append({
						"source_id": int(entry.get("source_id", -1)),
						"source_unit_id": str(entry.get("source_unit_id", "")).strip_edges(),
						"source_name": str(entry.get("source_name", "")).strip_edges(),
						"source_team": int(entry.get("source_team", 0)),
						"target_id": iid,
						"buff_id": str(entry.get("buff_id", "")).strip_edges(),
						"effects": (tick_effects as Array).duplicate(true)
					})
				entry["tick_accum"] = tick_accum

			var expired: bool = false
			if previous_remaining >= 0.0 and remaining <= 0.0:
				expired = true

			if expired:
				var expired_buff_id: String = str(entry.get("buff_id", "")).strip_edges()
				if not expired_buff_id.is_empty():
					_on_buff_entry_removed(iid, entry, "expired")
					_emit_buff_removed(iid, expired_buff_id, int(entry.get("source_id", -1)), "expired")
				changed_units[iid] = true
				continue

			next_entries.append(entry)
		_active_by_unit[iid] = next_entries
		var unit_node: Node = _find_unit_in_context(iid, context)
		if unit_node != null and is_instance_valid(unit_node):
			_sync_unit_runtime_meta(unit_node, next_entries)
		if next_entries.size() != entries.size():
			changed_units[iid] = true
		if next_entries.is_empty():
			_active_by_unit.erase(iid)
			if unit_node != null and is_instance_valid(unit_node):
				_clear_unit_runtime_meta(unit_node)

	var next_battlefield_effects: Array[Dictionary] = []
	for effect_value in _battlefield_effects:
		if not (effect_value is Dictionary):
			continue
		var effect_entry: Dictionary = (effect_value as Dictionary).duplicate(true)
		var previous_remaining_bf: float = float(effect_entry.get("remaining", 0.0))
		var remaining_bf: float = previous_remaining_bf
		if remaining_bf >= 0.0:
			remaining_bf -= delta
			effect_entry["remaining"] = remaining_bf

		var warning_remaining: float = float(effect_entry.get("warning_remaining", 0.0))
		if warning_remaining > 0.0:
			warning_remaining = maxf(warning_remaining - delta, 0.0)
			effect_entry["warning_remaining"] = warning_remaining

		var expired_bf: bool = previous_remaining_bf >= 0.0 and remaining_bf <= 0.0
		if expired_bf:
			continue

		if warning_remaining <= 0.0:
			var tick_interval_bf: float = maxf(float(effect_entry.get("tick_interval", 0.5)), 0.05)
			var tick_accum_bf: float = float(effect_entry.get("tick_accum", 0.0)) + delta
			while tick_accum_bf >= tick_interval_bf:
				tick_accum_bf -= tick_interval_bf
				var target_ids: Array[int] = _collect_battlefield_target_ids(effect_entry, context)
				var tick_effects: Array = effect_entry.get("tick_effects", [])
				for target_iid in target_ids:
					tick_requests.append({
						"source_id": int(effect_entry.get("source_id", -1)),
						"source_unit_id": str(effect_entry.get("source_unit_id", "")).strip_edges(),
						"source_name": str(effect_entry.get("source_name", "")).strip_edges(),
						"source_team": int(effect_entry.get("source_team", 0)),
						"target_id": int(target_iid),
						"buff_id": str(effect_entry.get("effect_id", "battlefield_effect")).strip_edges(),
						"effects": tick_effects.duplicate(true),
						"event_type": "battlefield_tick"
					})
			effect_entry["tick_accum"] = tick_accum_bf
		next_battlefield_effects.append(effect_entry)
	_battlefield_effects = next_battlefield_effects

	var changed_unit_ids: Array[int] = []
	for changed_id in changed_units.keys():
		changed_unit_ids.append(int(changed_id))

	return {
		"changed_unit_ids": changed_unit_ids,
		"tick_requests": tick_requests
	}


func _find_unit_in_context(iid: int, context: Dictionary) -> Node:
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return null
	for unit_value in (all_units_value as Array):
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.get_instance_id() == iid:
			return unit
	return null


func _sync_unit_runtime_meta(target: Node, entries: Array) -> void:
	if target == null or not is_instance_valid(target):
		return
	var buff_ids: Array[String] = []
	var debuff_ids: Array[String] = []
	var buff_seen: Dictionary = {}
	var debuff_seen: Dictionary = {}
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_id: String = str(entry.get("buff_id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		var buff_data: Dictionary = entry.get("data", {})
		var buff_type: String = str(buff_data.get("type", "buff")).strip_edges().to_lower()
		if buff_type == "debuff":
			if debuff_seen.has(buff_id):
				continue
			debuff_seen[buff_id] = true
			debuff_ids.append(buff_id)
		else:
			if buff_seen.has(buff_id):
				continue
			buff_seen[buff_id] = true
			buff_ids.append(buff_id)
	target.set_meta("active_buff_ids", buff_ids)
	target.set_meta("active_debuff_ids", debuff_ids)
	target.set_meta("has_debuff", not debuff_ids.is_empty())
	target.set_meta("has_buff", not buff_ids.is_empty())


func _clear_unit_runtime_meta(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	target.remove_meta("active_buff_ids")
	target.remove_meta("active_debuff_ids")
	target.remove_meta("has_debuff")
	target.remove_meta("has_buff")


func _apply_tenacity_duration_scale(target: Node, duration: float) -> float:
	if target == null or not is_instance_valid(target):
		return duration
	var combat: Node = target.get_node_or_null("Components/UnitCombat")
	if combat == null or not combat.has_method("get_external_modifiers"):
		return duration
	var modifiers_value: Variant = combat.call("get_external_modifiers")
	if not (modifiers_value is Dictionary):
		return duration
	var tenacity: float = clampf(float((modifiers_value as Dictionary).get("tenacity", 0.0)), 0.0, 0.9)
	return maxf(duration * (1.0 - tenacity), 0.1)


func _emit_buff_removed(target_id: int, buff_id: String, source_id: int, reason: String) -> void:
	buff_removed.emit({
		"target_id": target_id,
		"buff_id": buff_id,
		"source_id": source_id,
		"reason": reason
	})


func _collect_battlefield_target_ids(effect_entry: Dictionary, context: Dictionary) -> Array[int]:
	var output: Array[int] = []
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return output
	var center_value: Variant = effect_entry.get("center_cell", Vector2i(-1, -1))
	if not (center_value is Vector2i):
		return output
	var center_cell: Vector2i = center_value as Vector2i
	var radius_cells: int = maxi(int(effect_entry.get("radius_cells", 0)), 0)
	var source_team: int = int(effect_entry.get("source_team", 0))
	var target_mode: String = str(effect_entry.get("target_mode", "enemies")).strip_edges().to_lower()
	var combat_manager: Node = context.get("combat_manager", null)
	var hex_grid: Node = context.get("hex_grid", null)
	for unit_value in (all_units_value as Array):
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if not _is_unit_alive_node(unit):
			continue
		var team_id: int = int(unit.get("team_id"))
		if target_mode == "allies" and source_team != 0 and team_id != source_team:
			continue
		if target_mode == "enemies" and source_team != 0 and team_id == source_team:
			continue
		var unit_cell: Vector2i = _resolve_unit_cell(unit, combat_manager, hex_grid)
		if unit_cell.x < 0:
			continue
		if _hex_distance_cells(center_cell, unit_cell, hex_grid) > radius_cells:
			continue
		output.append(unit.get_instance_id())
	return output


func _resolve_unit_cell(unit: Node, combat_manager: Node, hex_grid: Node) -> Vector2i:
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of"):
		var cell_value: Variant = combat_manager.call("get_unit_cell_of", unit)
		if cell_value is Vector2i:
			return cell_value as Vector2i
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
		var node2d: Node2D = unit as Node2D
		if node2d != null:
			return hex_grid.call("world_to_axial", node2d.position)
	return Vector2i(-1, -1)


func _hex_distance_cells(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


func _is_unit_alive_node(unit: Node) -> bool:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _build_source_meta(source: Node) -> Dictionary:
	return {
		"source_id": source.get_instance_id() if source != null and is_instance_valid(source) else -1,
		"source_unit_id": str(source.get("unit_id")) if source != null and is_instance_valid(source) else "",
		"source_name": str(source.get("unit_name")) if source != null and is_instance_valid(source) else "",
		"source_team": int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	}


func _normalize_application_key(value: Variant) -> String:
	return str(value).strip_edges()


func _has_buff_instance(target: Node, buff_id: String, application_key: String) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var normalized_buff_id: String = buff_id.strip_edges()
	var normalized_application_key: String = _normalize_application_key(application_key)
	if normalized_buff_id.is_empty() or normalized_application_key.is_empty():
		return false
	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("buff_id", "")).strip_edges() != normalized_buff_id:
			continue
		if _normalize_application_key(entry.get("application_key", "")) != normalized_application_key:
			continue
		return true
	return false


func _remove_source_bound_aura_record(
	aura_key: String,
	aura_record: Dictionary,
	reason: String,
	context: Dictionary
) -> int:
	var removed_total: int = 0
	var buff_id: String = str(aura_record.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return 0
	var target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(true)
	for target_id_value in target_ids.keys():
		var target_iid: int = int(target_id_value)
		var target: Node = _find_unit_in_context(target_iid, context)
		if target == null or not is_instance_valid(target):
			continue
		removed_total += remove_buff_instance(target, buff_id, aura_key, reason)
	return removed_total


func _on_buff_entry_removed(target_id: int, entry: Dictionary, _reason: String) -> void:
	var application_key: String = _normalize_application_key(entry.get("application_key", ""))
	if application_key.is_empty():
		return
	if not _source_bound_auras.has(application_key):
		return
	var aura_record: Dictionary = _source_bound_auras.get(application_key, {})
	var target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(true)
	target_ids.erase(target_id)
	aura_record["target_ids"] = target_ids
	_source_bound_auras[application_key] = aura_record
