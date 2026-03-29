extends RefCounted
class_name UnitAugmentAuraRuntime


# 管理 source-bound aura 的 enter/exit 差集。
func refresh_source_bound_aura(
	manager,
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
	if not manager._buff_defs.has(buff_id):
		return {"applied_count": 0, "applied_targets": []}

	var source_id: int = source.get_instance_id()
	var aura_record: Dictionary = manager._source_bound_auras.get(normalized_aura_key, {
		"aura_key": normalized_aura_key,
		"scope_key": normalized_scope_key,
		"source_id": source_id,
		"buff_id": buff_id,
		"application_key": normalized_aura_key,
		"target_ids": {},
		"last_refresh_token": 0
	})
	var previous_target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(false)
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

		var was_tracked: bool = previous_target_ids.has(target_iid)
		if was_tracked and manager._has_buff_instance(target, buff_id, normalized_aura_key):
			continue
		var applied: bool = manager.apply_buff_with_options(
			target,
			buff_id,
			-1.0,
			source,
			{"application_key": normalized_aura_key}
		)
		if applied:
			applied_targets.append(target)

	for previous_target_id in previous_target_ids.keys():
		var target_iid: int = int(previous_target_id)
		if next_target_ids.has(target_iid):
			continue
		var removed_target: Node = manager._find_unit_in_context(target_iid, context)
		if removed_target != null and is_instance_valid(removed_target):
			manager.remove_buff_instance(
				removed_target,
				buff_id,
				normalized_aura_key,
				"aura_condition_lost"
			)

	aura_record["scope_key"] = normalized_scope_key
	aura_record["source_id"] = source_id
	aura_record["buff_id"] = buff_id
	aura_record["application_key"] = normalized_aura_key
	aura_record["target_ids"] = next_target_ids
	aura_record["last_refresh_token"] = scope_refresh_token
	manager._set_source_bound_aura_record(normalized_aura_key, aura_record)
	return {
		"applied_count": applied_targets.size(),
		"applied_targets": applied_targets
	}


# 清掉本轮没有被刷新到的 aura 记录。
func finalize_source_bound_aura_scope(
	manager,
	scope_key: String,
	scope_refresh_token: int,
	context: Dictionary = {}
) -> int:
	var normalized_scope_key: String = scope_key.strip_edges()
	if normalized_scope_key.is_empty() or scope_refresh_token <= 0:
		return 0

	var removed_total: int = 0
	var stale_aura_keys: Array[String] = []
	var aura_keys: Array[String] = manager._get_source_bound_aura_keys_for_scope(normalized_scope_key)
	for aura_key in aura_keys:
		var aura_record: Dictionary = manager._source_bound_auras.get(aura_key, {})
		if str(aura_record.get("scope_key", "")).strip_edges() != normalized_scope_key:
			continue
		if int(aura_record.get("last_refresh_token", 0)) == scope_refresh_token:
			continue
		removed_total += _remove_source_bound_aura_record(
			manager,
			aura_key,
			aura_record,
			"aura_condition_lost",
			context
		)
		stale_aura_keys.append(aura_key)

	for aura_key in stale_aura_keys:
		manager._erase_source_bound_aura_record(aura_key)
	return removed_total


# provider 死亡时要立刻摘掉它提供出去的动态光环。
func remove_source_bound_auras_from_source(
	manager,
	source: Node,
	context: Dictionary = {}
) -> int:
	if source == null or not is_instance_valid(source):
		return 0
	var source_id: int = source.get_instance_id()
	var removed_total: int = 0
	var stale_aura_keys: Array[String] = []
	var aura_keys: Array[String] = manager._get_source_bound_aura_keys_for_source(source_id)
	for aura_key in aura_keys:
		var aura_record: Dictionary = manager._source_bound_auras.get(aura_key, {})
		if int(aura_record.get("source_id", -1)) != source_id:
			continue
		removed_total += _remove_source_bound_aura_record(
			manager,
			aura_key,
			aura_record,
			"aura_source_dead",
			context
		)
		stale_aura_keys.append(aura_key)

	for aura_key in stale_aura_keys:
		manager._erase_source_bound_aura_record(aura_key)
	return removed_total


func _remove_source_bound_aura_record(
	manager,
	aura_key: String,
	aura_record: Dictionary,
	reason: String,
	context: Dictionary
) -> int:
	var removed_total: int = 0
	var buff_id: String = str(aura_record.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return 0
	var target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(false)
	for target_id_value in target_ids.keys():
		var target_iid: int = int(target_id_value)
		var target: Node = manager._find_unit_in_context(target_iid, context)
		if target == null or not is_instance_valid(target):
			continue
		removed_total += manager.remove_buff_instance(target, buff_id, aura_key, reason)
	return removed_total
