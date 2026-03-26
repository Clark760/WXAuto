extends RefCounted
class_name UnitAugmentAuraRuntime


# 这里负责一轮光环轮询中的“进入范围即挂上实例”。
# `aura_key` 会直接作为 `application_key`，保证光环实例与普通 Buff 精确分桶。
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
	# 这组早退只做输入合法性兜底。
	# 真正的光环生命周期一旦进入运行时，就全部由 aura_key/scope_key 驱动。
	var normalized_aura_key: String = aura_key.strip_edges()
	var normalized_scope_key: String = scope_key.strip_edges()
	if source == null or not is_instance_valid(source):
		return {"applied_count": 0, "applied_targets": []}
	if normalized_aura_key.is_empty() or normalized_scope_key.is_empty():
		return {"applied_count": 0, "applied_targets": []}
	if not manager._buff_defs.has(buff_id):
		return {"applied_count": 0, "applied_targets": []}

	var source_id: int = source.get_instance_id()
	# 同一个 aura_key 会跨帧复用旧命中集。
	# 先拿到上一轮快照，后面才能精确做 enter/exit diff。
	var aura_record: Dictionary = manager._source_bound_auras.get(normalized_aura_key, {
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
		# targets 可能混入重复节点或失效节点。
		# 这里统一按 instance_id 去重，避免同一轮重复挂同一条实例。
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

		var has_instance: bool = manager._has_buff_instance(target, buff_id, normalized_aura_key)
		# 旧命中还在且实例未丢失时，不重复刷新。
		# 这样永久 aura 不会在每次轮询里重置层数或内部 tick 状态。
		if previous_target_ids.has(target_iid) and has_instance:
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
		# 上一轮命中、这轮未命中的目标要立即摘掉实例。
		# 删除走 application_key 精确定位，不会误删同 source 的普通施法 Buff。
		var target_iid: int = int(previous_target_id)
		if next_target_ids.has(target_iid):
			continue
		var removed_target: Node = manager._find_unit_in_context(target_iid, context)
		if removed_target != null and is_instance_valid(removed_target):
			manager.remove_buff_instance(removed_target, buff_id, normalized_aura_key, "aura_condition_lost")

	# 刷新 token 由外层 scope 统一递增。
	# finalize 只要发现 token 对不上，就说明这条 aura 本轮没有再被刷新命中。
	aura_record["scope_key"] = normalized_scope_key
	aura_record["source_id"] = source_id
	aura_record["buff_id"] = buff_id
	aura_record["application_key"] = normalized_aura_key
	aura_record["target_ids"] = next_target_ids
	aura_record["last_refresh_token"] = scope_refresh_token
	manager._source_bound_auras[normalized_aura_key] = aura_record
	return {
		"applied_count": applied_targets.size(),
		"applied_targets": applied_targets
	}


# finalize 用来清掉这一轮没有被刷新到的 aura 记录。
# 光环离开范围或条件失效都走这里，理由统一标成 `aura_condition_lost`。
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
	# 先记录 stale key，再统一 erase。
	# 遍历字典时直接删除容易漏项，也不利于调试时保留完整脏集。
	for aura_key_value in manager._source_bound_auras.keys():
		var aura_key: String = str(aura_key_value).strip_edges()
		var aura_record: Dictionary = manager._source_bound_auras.get(aura_key, {})
		if str(aura_record.get("scope_key", "")).strip_edges() != normalized_scope_key:
			continue
		if int(aura_record.get("last_refresh_token", 0)) == scope_refresh_token:
			continue
		removed_total += _remove_source_bound_aura_record(manager, aura_key, aura_record, "aura_condition_lost", context)
		stale_aura_keys.append(aura_key)

	for aura_key in stale_aura_keys:
		# 删除动作放在第二段统一执行。
		# 这样 finalize 可以先完整统计 removed_total，再一次性清理状态表。
		manager._source_bound_auras.erase(aura_key)
	return removed_total


# provider 死亡要即时移除它提供出去的全部动态光环。
# 这条路径不能等待下一帧的 passive_aura 轮询，否则会留下错误的一帧状态。
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
	# provider death 也沿用“先收集再统一擦除”的策略。
	# 这样同一 source 提供多条 aura 时，删除顺序仍然稳定可预测。
	for aura_key_value in manager._source_bound_auras.keys():
		var aura_key: String = str(aura_key_value).strip_edges()
		var aura_record: Dictionary = manager._source_bound_auras.get(aura_key, {})
		if int(aura_record.get("source_id", -1)) != source_id:
			continue
		removed_total += _remove_source_bound_aura_record(manager, aura_key, aura_record, "aura_source_dead", context)
		stale_aura_keys.append(aura_key)

	for aura_key in stale_aura_keys:
		manager._source_bound_auras.erase(aura_key)
	return removed_total


# 删除一条 aura 记录时，要精准按 `aura_key` 分桶清理实例。
# 这样同 source 的普通施法 Buff 不会被误删。
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
	# aura record 只保存 target_id 集，不保存节点引用。
	# 真正删实例时再按 context 查节点，避免把失效节点泄漏进运行时状态。
	var target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(true)
	for target_id_value in target_ids.keys():
		var target_iid: int = int(target_id_value)
		var target: Node = manager._find_unit_in_context(target_iid, context)
		if target == null or not is_instance_valid(target):
			continue
		removed_total += manager.remove_buff_instance(target, buff_id, aura_key, reason)
	return removed_total
