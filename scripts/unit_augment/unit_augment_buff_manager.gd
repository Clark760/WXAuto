extends RefCounted
class_name UnitAugmentBuffManager

signal buff_removed(event: Dictionary)

const AURA_RUNTIME_SCRIPT: Script = preload("res://scripts/unit_augment/buff/unit_augment_aura_runtime.gd")
const BATTLEFIELD_RUNTIME_SCRIPT: Script = preload(
	"res://scripts/unit_augment/buff/unit_augment_battlefield_effect_runtime.gd"
)

# 这三份状态分别对应：
# Buff 定义快照、单位实例桶、战场级 effect 和 source-bound aura 追踪表。
var _buff_defs: Dictionary = {}
var _active_by_unit: Dictionary = {}
var _battlefield_effects: Array[Dictionary] = []
var _source_bound_auras: Dictionary = {}
var _aura_runtime = AURA_RUNTIME_SCRIPT.new()
var _battlefield_runtime = BATTLEFIELD_RUNTIME_SCRIPT.new()


# clear 会同时重置普通 Buff、战场级 effect 和 source-bound aura 追踪。
# 三份状态属于同一条生命周期系统，不能只清其中一块。
func clear_all() -> void:
	_active_by_unit.clear()
	_battlefield_effects.clear()
	_source_bound_auras.clear()


# 定义快照由 registry 提供。
# 这里始终复制一份，避免外层在战斗中修改原字典导致运行时状态漂移。
func set_buff_definitions(buff_defs: Dictionary) -> void:
	_buff_defs = buff_defs.duplicate(true)


# 普通入口保持旧契约不变。
# options 级扩展仍统一收口到 `apply_buff_with_options()`。
func apply_buff(target: Node, buff_id: String, duration: float, source: Node = null) -> bool:
	return apply_buff_with_options(target, buff_id, duration, source, {})


# `application_key` 是光环实例和普通施法实例分桶的核心字段。
# 只要 bucket 相同，就刷新或叠层；bucket 不同就视为独立实例并存。
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
		push_warning("UnitAugmentBuffManager: 未找到 Buff 定义 id=%s" % buff_id)
		return false

	# Buff 定义和来源元数据都在进入运行时时快照一份。
	# 后续刷新实例只改当前桶，不回头追 live schema 或 live source。
	var unit_iid: int = target.get_instance_id()
	var unit_entries: Array = _active_by_unit.get(unit_iid, [])
	var buff_data: Dictionary = (_buff_defs[buff_id] as Dictionary).duplicate(true)
	var source_meta: Dictionary = _build_source_meta(source)
	var source_id: int = int(source_meta.get("source_id", -1))
	var application_key: String = _normalize_application_key(options.get("application_key", ""))

	var stackable: bool = bool(buff_data.get("stackable", false))
	var max_stacks: int = maxi(int(buff_data.get("max_stacks", 1)), 1)
	var final_duration: float = duration
	if final_duration <= 0.0:
		final_duration = float(buff_data.get("default_duration", 3.0))
	if duration < 0.0:
		final_duration = -1.0

	# 先尝试命中同 `(buff_id, source_id, application_key)` 的旧实例桶。
	# 命中后只刷新层数、时长和来源快照，不重复追加数组项。
	for idx in range(unit_entries.size()):
		var entry: Dictionary = unit_entries[idx]
		if str(entry.get("buff_id", "")) != buff_id:
			continue
		if int(entry.get("source_id", -1)) != source_id:
			continue
		if _normalize_application_key(entry.get("application_key", "")) != application_key:
			continue

		entry["stacks"] = mini(int(entry.get("stacks", 1)) + 1, max_stacks) if stackable else 1
		if str(buff_data.get("type", "buff")).strip_edges().to_lower() == "debuff" and final_duration > 0.0:
			final_duration = _apply_tenacity_duration_scale(target, final_duration)
		entry["remaining"] = final_duration
		entry["tick_accum"] = 0.0
		entry["source_id"] = int(source_meta.get("source_id", -1))
		entry["source_unit_id"] = str(source_meta.get("source_unit_id", "")).strip_edges()
		entry["source_name"] = str(source_meta.get("source_name", "")).strip_edges()
		entry["source_team"] = int(source_meta.get("source_team", 0))
		entry["application_key"] = application_key
		unit_entries[idx] = entry
		_active_by_unit[unit_iid] = unit_entries
		_sync_unit_runtime_meta(target, unit_entries)
		return true

	# 旧桶不存在时，才真正创建新实例。
	# `data` 保留 Buff 定义副本，供 tick/passive 查询直接读取。
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
	_active_by_unit[unit_iid] = unit_entries
	_sync_unit_runtime_meta(target, unit_entries)
	return true


# remove_buff 仍按 `(buff_id, source_id)` 桶语义删除。
# 只有 `remove_buff_instance` 才会继续精确到 `application_key`。
func remove_buff(target: Node, buff_id: String, reason: String = "manual") -> int:
	return _remove_buff_internal(target, buff_id, reason, "", false)


# `application_key` 是实例级删除的唯一精确定位键。
# 光环退出范围或 provider 死亡都必须走这条路径，不能误删普通施法桶。
func remove_buff_instance(target: Node, buff_id: String, application_key: String, reason: String = "manual") -> int:
	var normalized_application_key: String = _normalize_application_key(application_key)
	if normalized_application_key.is_empty():
		return 0
	return _remove_buff_internal(target, buff_id, reason, normalized_application_key, true)


# 内部删除逻辑统一收口在这里。
# `match_application_key` 为真时，删除只影响目标实例，不会影响同 source 的普通 Buff。
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
	var unit_iid: int = target.get_instance_id()
	if not _active_by_unit.has(unit_iid):
		return 0

	var entries: Array = _active_by_unit.get(unit_iid, [])
	var next_entries: Array = []
	var removed_count: int = 0
	# 删除过程只重建目标单位自己的实例列表。
	# aura 目标集同步和 buff_removed 事件都在删除瞬间完成，避免残留脏状态。
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
		_on_buff_entry_removed(unit_iid, entry, reason)
		_emit_buff_removed(unit_iid, normalized_buff_id, int(entry.get("source_id", -1)), reason)

	if next_entries.is_empty():
		_active_by_unit.erase(unit_iid)
		_clear_unit_runtime_meta(target)
	else:
		_active_by_unit[unit_iid] = next_entries
		_sync_unit_runtime_meta(target, next_entries)
	return removed_count


# 单位移除时必须把身上的所有实例和 aura 记录都清掉。
# 这里统一走 `unit_removed` reason，保持现有触发器和日志口径不变。
func remove_all_for_unit(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	var unit_iid: int = target.get_instance_id()
	var entries: Array = _active_by_unit.get(unit_iid, [])
	# 这里逐条发移除事件，而不是直接粗暴清空。
	# 这样日志、触发器和测试仍能观察到每个 buff 实例的退出原因。
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_id: String = str(entry.get("buff_id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		_on_buff_entry_removed(unit_iid, entry, "unit_removed")
		_emit_buff_removed(unit_iid, buff_id, int(entry.get("source_id", -1)), "unit_removed")
	_active_by_unit.erase(unit_iid)
	_clear_unit_runtime_meta(target)


# passive effects 继续返回按层数放大的 effect 列表。
# `stat_add` 一类纯 modifier 仍由 effect engine 被动汇总阶段继续消费。
func collect_passive_effects_for_unit(target: Node) -> Array[Dictionary]:
	var effects: Array[Dictionary] = []
	if target == null or not is_instance_valid(target):
		return effects
	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	# passive 查询只读当前快照。
	# `value` 会按 stacks 放大，但行为型 op 仍留给 effect runtime 处理。
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
			if scaled.has("value"):
				scaled["value"] = float(scaled.get("value", 0.0)) * float(stacks)
			effects.append(scaled)
	return effects


# 详情面板只关心当前有哪些唯一 buff_id 正在生效。
# 这里继续按 buff_id 去重，不把 instance bucket 泄漏给 UI。
func get_active_buff_ids_for_unit(target: Node) -> Array[String]:
	var ids: Array[String] = []
	if target == null or not is_instance_valid(target):
		return ids
	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	var seen: Dictionary = {}
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var buff_id: String = str((entry_value as Dictionary).get("buff_id", "")).strip_edges()
		if buff_id.is_empty() or seen.has(buff_id):
			continue
		seen[buff_id] = true
		ids.append(buff_id)
	return ids


# `has_buff` 只看 buff_id 级存在性，不区分 source/application bucket。
# 这条查询会被触发器条件和部分 UI 状态直接使用。
func has_buff(target: Node, buff_id: String) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var normalized: String = buff_id.strip_edges()
	if normalized.is_empty():
		return false
	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	# has_buff 只回答“是否存在这个 buff_id”。
	# source_id 和 application_key 都故意不参与这个高层查询。
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		if str((entry_value as Dictionary).get("buff_id", "")).strip_edges() == normalized:
			return true
	return false


# debuff 查询保留原先的“空 id 表示任意 debuff”语义。
# 它会被 cleanse、条件触发和部分效果分支反复调用。
func has_debuff(target: Node, debuff_id: String = "") -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var normalized: String = debuff_id.strip_edges()
	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	# 空 debuff_id 表示“任意 debuff 即可”。
	# 指定 id 时才继续按 buff_id 精确过滤。
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_data: Dictionary = entry.get("data", {})
		if str(buff_data.get("type", "buff")).strip_edges().to_lower() != "debuff":
			continue
		if normalized.is_empty() or str(entry.get("buff_id", "")).strip_edges() == normalized:
			return true
	return false


# cleanse 只清 debuff，不影响普通 buff。
# reason 固定为 `cleanse`，保持现有移除事件和触发器口径稳定。
func cleanse_debuffs(target: Node) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var unit_iid: int = target.get_instance_id()
	if not _active_by_unit.has(unit_iid):
		return 0

	var entries: Array = _active_by_unit.get(unit_iid, [])
	var next_entries: Array = []
	var removed: int = 0
	# cleanse 只过滤 debuff。
	# 普通 buff 原样回写，保持实例桶顺序和 application_key 不变。
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_type: String = str((entry.get("data", {}) as Dictionary).get("type", "buff")).strip_edges().to_lower()
		if buff_type != "debuff":
			next_entries.append(entry)
			continue
		removed += 1
		_on_buff_entry_removed(unit_iid, entry, "cleanse")
		_emit_buff_removed(unit_iid, str(entry.get("buff_id", "")).strip_edges(), int(entry.get("source_id", -1)), "cleanse")

	if next_entries.is_empty():
		_active_by_unit.erase(unit_iid)
		_clear_unit_runtime_meta(target)
	else:
		_active_by_unit[unit_iid] = next_entries
		_sync_unit_runtime_meta(target, next_entries)
	return removed


# dispel 只驱散 buff 桶，不处理 debuff。
# 随机策略保持旧行为，避免这轮收口同时改变驱散结果分布。
func dispel_buffs(target: Node, count: int) -> int:
	if target == null or not is_instance_valid(target):
		return 0
	var max_remove: int = maxi(count, 0)
	if max_remove <= 0:
		return 0

	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	if entries.is_empty():
		return 0
	var buff_candidates: Array[int] = []
	for idx in range(entries.size()):
		if not (entries[idx] is Dictionary):
			continue
		var entry: Dictionary = entries[idx]
		var buff_type: String = str((entry.get("data", {}) as Dictionary).get("type", "buff")).strip_edges().to_lower()
		if buff_type == "buff":
			buff_candidates.append(idx)
	if buff_candidates.is_empty():
		return 0

	buff_candidates.shuffle()
	var remove_index_set: Dictionary = {}
	# 先抽样，再按索引重建数组。
	# 这样不会因为边遍历边删除而破坏随机结果。
	for pick in range(mini(max_remove, buff_candidates.size())):
		remove_index_set[int(buff_candidates[pick])] = true

	var next_entries: Array = []
	var removed: int = 0
	for idx in range(entries.size()):
		var entry_value: Variant = entries[idx]
		if not (entry_value is Dictionary):
			continue
		var entry2: Dictionary = entry_value
		if not remove_index_set.has(idx):
			next_entries.append(entry2)
			continue
		removed += 1
		var removed_buff_id: String = str(entry2.get("buff_id", "")).strip_edges()
		var removed_source_id: int = int(entry2.get("source_id", -1))
		_on_buff_entry_removed(target.get_instance_id(), entry2, "dispel")
		_emit_buff_removed(
			target.get_instance_id(),
			removed_buff_id,
			removed_source_id,
			"dispel"
		)

	if next_entries.is_empty():
		_active_by_unit.erase(target.get_instance_id())
		_clear_unit_runtime_meta(target)
	else:
		_active_by_unit[target.get_instance_id()] = next_entries
		_sync_unit_runtime_meta(target, next_entries)
	return removed


# steal 仍按旧逻辑从目标身上随机挑可偷的 buff 桶。
# 新实现只把状态持有位置从旧 delegate 挪到当前 manager，不改玩法语义。
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
		var buff_type: String = str((entry.get("data", {}) as Dictionary).get("type", "buff")).strip_edges().to_lower()
		if buff_type == "buff":
			candidate_indices.append(idx)
	if candidate_indices.is_empty():
		return 0

	candidate_indices.shuffle()
	var selected_index_set: Dictionary = {}
	# steal 和 dispel 共享同一套“先抽样再重建”的稳定策略。
	# receiver 只重挂 buff_id 与时长，不复制旧实例的 application_key。
	for pick in range(mini(max_steal, candidate_indices.size())):
		selected_index_set[int(candidate_indices[pick])] = true

	var next_entries: Array = []
	var stolen_count: int = 0
	for idx in range(entries.size()):
		var entry_value: Variant = entries[idx]
		if not (entry_value is Dictionary):
			continue
		var entry2: Dictionary = entry_value
		if not selected_index_set.has(idx):
			next_entries.append(entry2)
			continue
		stolen_count += 1
		var buff_id: String = str(entry2.get("buff_id", "")).strip_edges()
		var remaining: float = float(entry2.get("remaining", 0.0))
		var duration: float = remaining
		if duration == 0.0:
			duration = float((entry2.get("data", {}) as Dictionary).get("default_duration", 3.0))
		apply_buff(receiver, buff_id, duration, source)
		_on_buff_entry_removed(source_iid, entry2, "stolen")
		_emit_buff_removed(source_iid, buff_id, int(entry2.get("source_id", -1)), "stolen")

	if next_entries.is_empty():
		_active_by_unit.erase(source_iid)
		_clear_unit_runtime_meta(source_target)
	else:
		_active_by_unit[source_iid] = next_entries
		_sync_unit_runtime_meta(source_target, next_entries)
	return stolen_count


# source-bound aura 的 enter/exit 和 source death 清理都交给专用 runtime。
# manager 这里只保留稳定入口，不再把整个 diff 逻辑塞回同一个文件。
func refresh_source_bound_aura(
	source: Node,
	buff_id: String,
	aura_key: String,
	scope_key: String,
	scope_refresh_token: int,
	targets: Array,
	context: Dictionary = {}
) -> Dictionary:
	return _aura_runtime.refresh_source_bound_aura(
		self,
		source,
		buff_id,
		aura_key,
		scope_key,
		scope_refresh_token,
		targets,
		context
	)


# finalize 仍按原契约返回删除的 aura 实例数。
# battle runtime 会在一轮 passive_aura 结束后显式调用它做差集清理。
func finalize_source_bound_aura_scope(scope_key: String, scope_refresh_token: int, context: Dictionary = {}) -> int:
	return _aura_runtime.finalize_source_bound_aura_scope(self, scope_key, scope_refresh_token, context)


# provider 死亡即时清理继续沿用独立入口。
# combat event bridge 通过这条方法把 dead source 的 aura 快速摘掉。
func remove_source_bound_auras_from_source(source: Node, context: Dictionary = {}) -> int:
	return _aura_runtime.remove_source_bound_auras_from_source(self, source, context)


# battlefield effect 与 tick 请求生成统一由 runtime 子服务处理。
# manager 只继续暴露原来的对外方法名，避免 battle runtime 感知内部拆分。
func tick(delta: float, context: Dictionary = {}) -> Dictionary:
	return _battlefield_runtime.tick(self, delta, context)


# 战场级效果和普通 buff 共用同一套来源元数据口径。
# 新实现不再经旧 delegate 转发，而是直接写入当前运行时数组。
func add_battlefield_effect(effect_config: Dictionary, source: Node = null) -> bool:
	return _battlefield_runtime.add_battlefield_effect(self, effect_config, source)


# context 中的 `all_units` 是 aura 和 tick 清理找目标节点的统一入口。
# 这里保持纯查找语义，不附带任何创建或 fallback 装配。
func _find_unit_in_context(unit_iid: int, context: Dictionary) -> Node:
	var all_units_value: Variant = context.get("all_units", [])
	if not (all_units_value is Array):
		return null
	# 这里只做线性查找，不在缺失时偷偷创建或缓存节点。
	# 这样 aura/tick 清理始终只操作外层明确交进来的活体上下文。
	for unit_value in (all_units_value as Array):
		if not (unit_value is Node):
			continue
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.get_instance_id() == unit_iid:
			return unit
	return null


# 运行时 meta 继续只保留去重后的 buff/debuff id 列表。
# UI 和条件查询只关心“当前有哪些状态”，不应感知 instance bucket 细节。
func _sync_unit_runtime_meta(target: Node, entries: Array) -> void:
	if target == null or not is_instance_valid(target):
		return
	var buff_ids: Array[String] = []
	var debuff_ids: Array[String] = []
	var buff_seen: Dictionary = {}
	var debuff_seen: Dictionary = {}
	# UI 侧只关心“当前有哪些 buff_id/debuff_id 正在生效”。
	# 这里显式去重，避免 instance bucket 细节泄漏到展示层。
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var buff_id: String = str(entry.get("buff_id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		var buff_type: String = str((entry.get("data", {}) as Dictionary).get("type", "buff")).strip_edges().to_lower()
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


# 单位不再持有任何实例时，需要把 meta 一次清干净。
# 不能只把数组置空，否则某些 UI 和条件判断会把空数组误当成“仍然有状态键”。
func _clear_unit_runtime_meta(target: Node) -> void:
	if target == null or not is_instance_valid(target):
		return
	target.remove_meta("active_buff_ids")
	target.remove_meta("active_debuff_ids")
	target.remove_meta("has_debuff")
	target.remove_meta("has_buff")


# tenacity 只影响 debuff 正时长。
# duration < 0 的永久状态不做缩放，避免 source-bound aura 被错误缩短。
func _apply_tenacity_duration_scale(target: Node, duration: float) -> float:
	if target == null or not is_instance_valid(target):
		return duration
	var combat: Variant = target.get_node_or_null("Components/UnitCombat")
	if combat == null or not combat.has_method("get_external_modifiers"):
		return duration
	# tenacity 读取的是外部修正快照。
	# 这里只改 debuff 正时长，不改变永久 aura 或其它实例桶语义。
	var modifiers_value: Variant = combat.get_external_modifiers()
	if not (modifiers_value is Dictionary):
		return duration
	var tenacity: float = clampf(float((modifiers_value as Dictionary).get("tenacity", 0.0)), 0.0, 0.9)
	return maxf(duration * (1.0 - tenacity), 0.1)


# buff_removed 是外部统一消费的事件。
# reason 和 source_id 都继续保持旧字段名，避免 trigger/runtime 日志回归。
func _emit_buff_removed(target_id: int, buff_id: String, source_id: int, reason: String) -> void:
	buff_removed.emit({
		"target_id": target_id,
		"buff_id": buff_id,
		"source_id": source_id,
		"reason": reason
	})


# source 元数据统一在挂 Buff 时快照一份。
# 后续 tick 和日志都只读这份快照，不再回头追 live source 节点。
func _build_source_meta(source: Node) -> Dictionary:
	# live source 只在挂载瞬间读取一次。
	# 之后即使 source 死亡或名称变化，旧事件也继续按快照口径上报。
	return {
		"source_id": source.get_instance_id() if source != null and is_instance_valid(source) else -1,
		"source_unit_id": str(source.get("unit_id")) if source != null and is_instance_valid(source) else "",
		"source_name": str(source.get("unit_name")) if source != null and is_instance_valid(source) else "",
		"source_team": int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	}


# application_key 在整个 Buff 运行时里统一按字符串处理。
# 普通施法实例缺省为空串，光环实例则用 aura_key 或其他逻辑来源键。
func _normalize_application_key(value: Variant) -> String:
	return str(value).strip_edges()


# 这条查询只服务于 aura runtime 的实例级存在性判定。
# 它必须精确到 `application_key`，否则光环轮询会把普通 Buff 误判成自己的实例。
func _has_buff_instance(target: Node, buff_id: String, application_key: String) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var normalized_buff_id: String = buff_id.strip_edges()
	var normalized_application_key: String = _normalize_application_key(application_key)
	if normalized_buff_id.is_empty() or normalized_application_key.is_empty():
		return false
	var entries: Array = _active_by_unit.get(target.get_instance_id(), [])
	# 这里必须同时命中 buff_id 和 application_key。
	# 只看 buff_id 会把普通施法实例误判成光环实例仍然存在。
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


# 当某条带 `application_key` 的实例被移除时，要同步回写 aura_record 的 target 集。
# 这样 provider death 和 finalize scope 的差集清理才能保持同一份真实命中集。
func _on_buff_entry_removed(target_id: int, entry: Dictionary, _reason: String) -> void:
	var application_key: String = _normalize_application_key(entry.get("application_key", ""))
	if application_key.is_empty():
		return
	# 普通施法实例的 application_key 为空，不会进入 aura 追踪表。
	# 只有 source-bound aura 的实例会回写 target 命中集。
	if not _source_bound_auras.has(application_key):
		return
	var aura_record: Dictionary = _source_bound_auras.get(application_key, {})
	var target_ids: Dictionary = (aura_record.get("target_ids", {}) as Dictionary).duplicate(true)
	target_ids.erase(target_id)
	aura_record["target_ids"] = target_ids
	_source_bound_auras[application_key] = aura_record


# 这里的 alive 判定只服务于 battlefield effect 目标筛选。
# 没有战斗组件的目标不会参与战场级 tick，避免把无效节点拉进效果循环。
func _is_unit_alive_node(unit: Node) -> bool:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	return bool(combat.get("is_alive"))
