extends RefCounted
class_name UnitAugmentTelemetryEmitter


# `summary` 是 effect facade 的唯一输出，这里只负责把结果投影成外部信号。
# `origin` / `gongfa_id` / `trigger` 是日志归因字段，不在这里重新推导。
# manager 只被当成信号发射器和私有 trigger 桥接入口，不承担任何汇总逻辑。
func emit_effect_log_events(
	manager: Node,
	registry: Variant,
	summary: Dictionary,
	default_source: Node,
	default_target: Node,
	origin: String,
	gongfa_id: String,
	trigger: String,
	extra_fields: Dictionary = {}
) -> void:
	if summary.is_empty():
		return

	# 三类事件分别投影，保持 damage/heal/buff 三套外部信号的既有契约不变。
	# 这里故意不再返回新 summary，telemetry emitter 的职责只到“发信号”为止。
	# 如果未来新增 mp/summon/hazard 专用信号，也应该继续沿用这里的单向投影模式。
	# 也就是说，这个服务永远只做“格式投影”，不回流修改任何运行时状态。
	_emit_damage_events(
		manager,
		summary.get("damage_events", []),
		default_source,
		default_target,
		origin,
		gongfa_id,
		trigger,
		extra_fields
	)
	_emit_heal_events(
		manager,
		summary.get("heal_events", []),
		default_source,
		default_target,
		origin,
		gongfa_id,
		trigger,
		extra_fields
	)
	_emit_buff_events(
		manager,
		registry,
		summary.get("buff_events", []),
		default_source,
		default_target,
		origin,
		gongfa_id,
		trigger,
		extra_fields
	)


# 伤害事件需要附带护盾吸收和免疫吸收，供战斗日志和统计面板复用。
# `default_source` / `default_target` 只在单条 event 没显式写出 source/target 时兜底。
# 单条 damage event 上如果已经带了 source/target，会优先使用事件内的真实归因。
func _emit_damage_events(
	manager: Node,
	damage_events_value: Variant,
	default_source: Node,
	default_target: Node,
	origin: String,
	gongfa_id: String,
	trigger: String,
	extra_fields: Dictionary
) -> void:
	if not (damage_events_value is Array):
		return

	# summary 里的 damage_events 已经是 effect engine 的标准化结果，这里只做 payload 投影。
	for event_value in (damage_events_value as Array):
		if not (event_value is Dictionary):
			continue

		var event_data: Dictionary = event_value as Dictionary
		var source_node: Node = event_data.get("source", default_source)
		var target_node: Node = event_data.get("target", default_target)
		# 统一先补基础身份字段，再让 extra_fields 以“显式传参优先”覆盖默认值。
		# damage payload 会保留 op/damage_type，方便日志面板区分普通伤害、反伤和特殊 damage op。
		var payload: Dictionary = {
			"origin": origin,
			"source": source_node,
			"target": target_node,
			"damage": float(event_data.get("damage", 0.0)),
			"shield_absorbed": float(event_data.get("shield_absorbed", 0.0)),
			"immune_absorbed": float(event_data.get("immune_absorbed", 0.0)),
			"damage_type": str(event_data.get("damage_type", "internal")),
			"op": str(event_data.get("op", "")),
			"gongfa_id": gongfa_id,
			"trigger": trigger
		}
		_append_actor_fields(payload, source_node, target_node, extra_fields)
		_merge_extra_fields(payload, extra_fields)
		manager.skill_effect_damage.emit(payload)


# 治疗事件不携带护盾吸收，但仍需要完整 source/target 身份字段。
# 这里沿用伤害事件同一套 actor 字段填充逻辑，保证 UI 口径一致。
# heal payload 的字段名保持旧契约，避免日志面板和测试断言一起改。
func _emit_heal_events(
	manager: Node,
	heal_events_value: Variant,
	default_source: Node,
	default_target: Node,
	origin: String,
	gongfa_id: String,
	trigger: String,
	extra_fields: Dictionary
) -> void:
	if not (heal_events_value is Array):
		return

	# 治疗事件与伤害事件共享同一套 actor 字段拼装，减少 UI 侧分支判断。
	for heal_value in (heal_events_value as Array):
		if not (heal_value is Dictionary):
			continue

		var heal_data: Dictionary = heal_value as Dictionary
		var source_node: Node = heal_data.get("source", default_source)
		var target_node: Node = heal_data.get("target", default_target)
		# heal payload 结构故意比 damage 简单，只保留治疗统计真正需要的字段。
		var payload: Dictionary = {
			"origin": origin,
			"source": source_node,
			"target": target_node,
			"heal": float(heal_data.get("heal", 0.0)),
			"op": str(heal_data.get("op", "")),
			"gongfa_id": gongfa_id,
			"trigger": trigger
		}
		_append_actor_fields(payload, source_node, target_node, extra_fields)
		_merge_extra_fields(payload, extra_fields)
		manager.skill_effect_heal.emit(payload)


# Buff 事件除了广播 buff_event，还要给 debuff 命中补一个 on_debuff_applied 触发源。
# `event_type` 在这里固定写成 apply，tick/remove 由其他运行时入口负责生成。
# registry 只在这里参与一次，用来判断 buff 定义到底是 buff 还是 debuff。
func _emit_buff_events(
	manager: Node,
	registry: Variant,
	buff_events_value: Variant,
	default_source: Node,
	default_target: Node,
	origin: String,
	gongfa_id: String,
	trigger: String,
	extra_fields: Dictionary
) -> void:
	if not (buff_events_value is Array):
		return

	# Buff apply 日志与 debuff 触发派生共用同一份 payload，避免两边口径漂移。
	for buff_value in (buff_events_value as Array):
		if not (buff_value is Dictionary):
			continue

		var buff_data: Dictionary = buff_value as Dictionary
		var source_node: Node = buff_data.get("source", default_source)
		var target_node: Node = buff_data.get("target", default_target)
		# buff payload 的 duration 直接取 summary 值，不在 telemetry 再推断无限时长或 tick 时长。
		var payload: Dictionary = {
			"origin": origin,
			"source": source_node,
			"target": target_node,
			"buff_id": str(buff_data.get("buff_id", "")),
			"duration": float(buff_data.get("duration", 0.0)),
			"op": str(buff_data.get("op", "")),
			"gongfa_id": gongfa_id,
			"trigger": trigger,
			"event_type": "apply"
		}
		_append_actor_fields(payload, source_node, target_node, extra_fields)
		_merge_extra_fields(payload, extra_fields)
		manager.buff_event.emit(payload)
		_emit_debuff_trigger_if_needed(
			manager,
			registry,
			payload,
			source_node,
			target_node
		)


# source/target 的 id、名称和阵营字段统一由这个 helper 填充，避免三套复制。
# 这个 helper 只管身份字段，不负责附加业务字段。
# `extra_fields` 里的 fallback 值主要服务环境伤害、地形和 buff tick 这类无真实节点来源。
func _append_actor_fields(
	payload: Dictionary,
	source_node: Node,
	target_node: Node,
	extra_fields: Dictionary
) -> void:
	payload["source_id"] = _resolve_node_id(source_node, extra_fields, "source_id")
	payload["target_id"] = _resolve_node_id(target_node, extra_fields, "target_id")
	# 名称和 unit_id 都优先读真实节点；extra_fields 只在无节点来源时兜底。
	payload["source_unit_id"] = _resolve_node_text(
		source_node,
		"unit_id",
		extra_fields,
		"source_unit_id"
	)
	payload["source_name"] = _resolve_node_text(
		source_node,
		"unit_name",
		extra_fields,
		"source_name"
	)
	payload["target_unit_id"] = _resolve_node_text(
		target_node,
		"unit_id",
		extra_fields,
		"target_unit_id"
	)
	payload["target_name"] = _resolve_node_text(
		target_node,
		"unit_name",
		extra_fields,
		"target_name"
	)
	payload["source_team"] = _resolve_node_int(source_node, "team_id", extra_fields, "source_team")
	payload["target_team"] = _resolve_node_int(target_node, "team_id", extra_fields, "target_team")


# extra_fields 属于调用方自定义字段，最后覆盖基础字段以保留显式传参优先级。
# 这一步必须放在最后，避免前面的默认字段把外层显式值盖掉。
# telemetry emitter 不筛字段名，调用方要自己保证 extra_fields 的契约稳定。
func _merge_extra_fields(payload: Dictionary, extra_fields: Dictionary) -> void:
	# 调用方显式传入的字段拥有最终优先级，因此这里不做白名单过滤。
	for key in extra_fields.keys():
		payload[key] = extra_fields[key]


# 只有 debuff 类型的 Buff 才需要派生 on_debuff_applied 事件。
# 这里故意不直接读 payload.event_type，因为是否是 debuff 只由配表类型决定。
# 触发派发给 target_node，是因为“被挂上 debuff 的单位”才是条件判断主体。
func _emit_debuff_trigger_if_needed(
	manager: Node,
	registry: Variant,
	payload: Dictionary,
	source_node: Node,
	target_node: Node
) -> void:
	var buff_id: String = str(payload.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return
	if registry == null or not registry.has_buff(buff_id):
		return

	var buff_def: Dictionary = registry.get_buff(buff_id)
	var buff_type: String = str(buff_def.get("type", "buff")).strip_edges().to_lower()
	if buff_type != "debuff":
		return
	if target_node == null or not is_instance_valid(target_node):
		return

	# 派生 trigger 时只透传最小必要字段，额外日志字段仍留在 buff_event payload 中。
	manager._fire_trigger_for_unit(target_node, "on_debuff_applied", {
		"target": target_node,
		"source": source_node,
		"debuff_id": buff_id
	})


# id 字段优先读取真实节点，缺失时才回落到调用方传入的 fallback。
# 环境伤害和地形效果通常会走 fallback 分支。
# 这里统一回 int，避免后面日志系统混进字符串 id。
func _resolve_node_id(node: Node, extra_fields: Dictionary, fallback_key: String) -> int:
	if node != null and is_instance_valid(node):
		# 实际节点存在时，总是以当前实例 id 为准，避免外部缓存旧 id。
		return node.get_instance_id()
	return int(extra_fields.get(fallback_key, -1))


# 文本字段统一走节点属性读取，避免日志和 tooltip 各自拼接默认值。
# `fallback_key` 用来承接 terrain / environment 这类没有真实节点的来源。
# 这里不做额外格式化，展示侧如果需要本地化或占位文案应在 UI 层处理。
func _resolve_node_text(
	node: Node,
	prop_name: String,
	extra_fields: Dictionary,
	fallback_key: String
) -> String:
	if node != null and is_instance_valid(node):
		# 展示字段直接走节点属性，便于日志与面板共享统一命名来源。
		return str(node.get(prop_name))
	return str(extra_fields.get(fallback_key, ""))


# 阵营字段默认回落到 0，表示环境伤害或未知来源。
# 调用方若显式传了 source_team / target_team，会在这里被优先读取。
# 用 0 作为未知值，能让日志与统计层稳定区分“环境来源”与正常阵营单位。
func _resolve_node_int(
	node: Node,
	prop_name: String,
	extra_fields: Dictionary,
	fallback_key: String
) -> int:
	if node != null and is_instance_valid(node):
		# 阵营字段同样优先读运行时节点，避免外层传入的旧值覆盖实时阵营状态。
		return int(node.get(prop_name))
	return int(extra_fields.get(fallback_key, 0))
