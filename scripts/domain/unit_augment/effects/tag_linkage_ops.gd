extends RefCounted
class_name UnitAugmentTagLinkageOps

# tag linkage 负责条件分支与 stateful 切换。
# 它可以回调 dispatcher 执行子效果，但不承担普通 effect 分发。

var _child_effect_executor: Callable


# `child_effect_executor` 由 dispatcher 注入，用于递归执行分支里的子效果。
# 这里不持有 dispatcher 实例本身，避免 tag linkage 反向依赖分发器实现细节。
func _init(child_effect_executor: Callable = Callable()) -> void:
	_child_effect_executor = child_effect_executor


# tag linkage 是独立语义分支，避免继续散落在 facade helper 里。
# `routes` 里只注册入口 op，具体分支判定继续委托给 manager。
func register_routes(routes: Dictionary) -> void:
	routes["tag_linkage_branch"] = Callable(self, "_tag_linkage_branch")


# 这里同时兼容新旧 context key，避免旧 manager 在过渡期直接断链。
# `effect` 描述 linkage 配置，`context` 则提供 gate_map 与 manager 等运行时依赖。
# 先判 gate 再取 branch result，避免 manager 在未放行时提前推进状态。
func _tag_linkage_branch(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
# 这里先判 gate，再取 branch result，顺序不能反。
	if source == null or not is_instance_valid(source):
		return

	var manager: Variant = context.get("unit_augment_manager", null)
	if manager == null or not is_instance_valid(manager):
		return

	var effect_key: String = _tag_linkage_effect_key(effect)
	var gate_allowed: bool = true
	var gate_decided: bool = false
	var gate_map_value: Variant = context.get("tag_linkage_gate_map", {})
	if gate_map_value is Dictionary:
		var gate_map: Dictionary = gate_map_value as Dictionary
		if gate_map.has(effect_key):
			gate_allowed = bool(gate_map.get(effect_key, true))
			gate_decided = true

	if not gate_decided and manager.has_method("evaluate_tag_linkage_gate"):
		var gate_result_value: Variant = manager.evaluate_tag_linkage_gate(source, effect, context)
		if gate_result_value is Dictionary:
			gate_allowed = bool((gate_result_value as Dictionary).get("allowed", true))

	if not gate_allowed:
		return
	if not manager.has_method("evaluate_tag_linkage_branch"):
		return

	var result_value: Variant = manager.evaluate_tag_linkage_branch(source, effect, context)
	if not (result_value is Dictionary):
		return

	var result: Dictionary = result_value as Dictionary
	if manager.has_method("notify_tag_linkage_evaluated"):
		manager.notify_tag_linkage_evaluated(source, effect, context, result)

	var branch_effects_value: Variant = result.get("effects", [])
	if not (branch_effects_value is Array):
		return

	var branch_effects: Array = branch_effects_value as Array
	var execution_mode: String = str(effect.get("execution_mode", "continuous")).strip_edges().to_lower()
	if execution_mode != "stateful":
		# 非 stateful 分支不保留额外状态，直接把当前命中的子效果展开执行。
		_execute_tag_linkage_child_effects(source, target, branch_effects, context, summary)
		return

	_execute_stateful_branch(source, target, effect, result, branch_effects, context, summary, manager, effect_key)


# 子效果执行通过 dispatcher 传入的 callable 递归触发，不反向依赖 dispatcher 类型。
# `branch_effects` 里的每个子效果都会共享当前 `context/summary`，保证分支效果口径一致。
func _execute_tag_linkage_child_effects(
	source: Node,
	target: Node,
	branch_effects: Array,
	context: Dictionary,
	summary: Dictionary
) -> void:
	if not _child_effect_executor.is_valid():
		return

	for child_effect_value in branch_effects:
		if not (child_effect_value is Dictionary):
			continue

		_child_effect_executor.callv([source, target, child_effect_value as Dictionary, context, summary])


# stateful 模式只在 case 切换时重挂 Buff，避免每跳都刷新永久状态。
# `manager` 持有 linkage runtime state，当前函数只负责编排“切换前清旧 Buff / 切换后挂新 Buff”。
# `effect_key` 用于把同一来源下的不同 linkage 配置隔离开，避免状态串线。
func _execute_stateful_branch(
	source: Node,
	target: Node,
	effect: Dictionary,
	result: Dictionary,
	branch_effects: Array,
	context: Dictionary,
	summary: Dictionary,
	manager: Variant,
	effect_key: String
) -> void:
	var state: Dictionary = _get_tag_linkage_state(manager, source, effect, effect_key)
	var previous_case_id: String = str(state.get("last_case_id", "")).strip_edges()
	var previous_buff_ids: Array[String] = _normalize_id_array(state.get("stateful_buff_ids", []))
	var next_case_id: String = _resolve_tag_linkage_case_id(result, branch_effects)
	var case_changed: bool = previous_case_id != next_case_id
	var next_buff_ids: Array[String] = previous_buff_ids.duplicate()

	if case_changed:
		_remove_stateful_buffs(source, previous_buff_ids, context)
		next_buff_ids.clear()
		var prepared_effects: Array[Dictionary] = _build_stateful_branch_effects(branch_effects, next_buff_ids)
		_execute_tag_linkage_child_effects(source, target, prepared_effects, context, summary)

	_set_tag_linkage_state(manager, source, effect, effect_key, next_case_id, next_buff_ids)


# stateful 分支只保留 case 对应的 Buff 声明，普通子效果仍沿用原始列表。
# `next_buff_ids` 会被原地填充，供上层写回 manager 的运行时状态。
func _build_stateful_branch_effects(branch_effects: Array, next_buff_ids: Array[String]) -> Array[Dictionary]:
	var prepared: Array[Dictionary] = []
	for child_effect_value in branch_effects:
		if not (child_effect_value is Dictionary):
			continue

		var child_effect: Dictionary = (child_effect_value as Dictionary).duplicate(true)
		var op: String = str(child_effect.get("op", "")).strip_edges()
		if op == "buff_self":
			var buff_id: String = str(child_effect.get("buff_id", "")).strip_edges()
			if not buff_id.is_empty() and not next_buff_ids.has(buff_id):
				next_buff_ids.append(buff_id)
			child_effect["duration"] = -1.0

		prepared.append(child_effect)

	return prepared


# 移除旧 stateful Buff 时仍通过 manager 暴露的兼容接口，避免直接碰旧 BuffManager。
# `buff_ids` 只接受已经标准化过的字符串 id，空串会在这里再次防御性过滤。
func _remove_stateful_buffs(source: Node, buff_ids: Array[String], context: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return

	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null or not buff_manager.has_method("remove_buff"):
		return

	for buff_id in buff_ids:
		var normalized_id: String = buff_id.strip_edges()
		if normalized_id.is_empty():
			continue
		buff_manager.remove_buff(source, normalized_id, "tag_linkage_state_switch")


# `case_id` 优先取 manager 计算结果，缺失时再退回到分支是否命中的兜底标识。
# 这里不直接把整个 effect 序列序列化成 case_id，避免状态键过长且不稳定。
func _resolve_tag_linkage_case_id(result: Dictionary, branch_effects: Array) -> String:
	var matched_value: Variant = result.get("matched_case_ids", [])
	if matched_value is Array and not (matched_value as Array).is_empty():
		return str((matched_value as Array)[0]).strip_edges()
	if not branch_effects.is_empty():
		return "__else__"
	return ""


# manager 是 linkage runtime 的唯一状态持有者，这里只读取，不在 effect 层私自缓存。
# `_effect_key` 作为兼容占位参数保留，便于后续 manager 如需按 key 取状态时直接接上。
func _get_tag_linkage_state(manager: Variant, source: Node, effect: Dictionary, _effect_key: String) -> Dictionary:
	if manager != null and is_instance_valid(manager) and manager.has_method("get_tag_linkage_state"):
		var state_value: Variant = manager.get_tag_linkage_state(source, effect)
		if state_value is Dictionary:
			return (state_value as Dictionary).duplicate(true)
	return {"last_case_id": "", "stateful_buff_ids": []}


# 写回 stateful 运行时状态时仍然统一走 manager，避免 effect 层和 manager 各存一份状态。
# `_effect_key` 同样暂时只做兼容占位，真正的状态主键仍由 manager 自己决定。
func _set_tag_linkage_state(
	manager: Variant,
	source: Node,
	effect: Dictionary,
	_effect_key: String,
	case_id: String,
	buff_ids: Array[String]
) -> void:
	var normalized_ids: Array[String] = _normalize_id_array(buff_ids)
	if manager != null and is_instance_valid(manager) and manager.has_method("set_tag_linkage_state"):
		manager.set_tag_linkage_state(source, effect, case_id, normalized_ids)


# `effect_key` 必须稳定，否则 stateful 分支会在同一技能内产生错误复用。
# 这里使用 effect 序列化签名，保证同一配表在同一来源下能稳定命中同一状态槽位。
func _tag_linkage_effect_key(effect: Dictionary) -> String:
	return var_to_str(effect)


# linkage case 配表允许混入非字符串数组项，这里统一压平成稳定的字符串 id 列表。
# 去重在这里完成，避免 manager 和 effect 层各自再做一遍标准化。
func _normalize_id_array(raw: Variant) -> Array[String]:
	var output: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for value in (raw as Array):
			var text: String = str(value).strip_edges()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			output.append(text)
	return output
