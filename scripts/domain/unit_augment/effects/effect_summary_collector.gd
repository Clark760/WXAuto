extends RefCounted
class_name UnitAugmentEffectSummaryCollector

# summary collector 只维护结算摘要和事件归档。
# 任何 effect 判定都不应写回这里。


# 统一初始化主动效果结算摘要，避免各个 op service 各自补字段。
# 这里同时初始化 total 字段和 event 列表，保证日志、统计和测试读到同一份结构。
func create_empty_summary() -> Dictionary:
	return {
		"damage_total": 0.0,
		"heal_total": 0.0,
		"mp_total": 0.0,
		"summon_total": 0,
		"hazard_total": 0,
		"buff_applied": 0,
		"debuff_applied": 0,
		"damage_events": [],
		"heal_events": [],
		"mp_events": [],
		"buff_events": []
	}


# 伤害事件除了最终伤害，还要保留护盾吸收和免疫吸收信息。
# `runtime_gateway` 持有最近一次伤害的吸收元数据，这里负责把它消费并写回 summary。
# `summary` 只保留可回放结果，不反向驱动运行时逻辑。
func append_damage_event(
	summary: Dictionary,
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	damage: float,
	damage_type: String,
	op: String
) -> void:
	var shield_absorbed: float = 0.0
	var immune_absorbed: float = 0.0

	if runtime_gateway != null and runtime_gateway.has_method("get_last_damage_meta"):
		# 护盾吸收和免疫吸收来自 gateway 缓存，不从事件调用方重复传参。
		var damage_meta: Variant = runtime_gateway.get_last_damage_meta()
		if damage_meta is Dictionary:
			shield_absorbed = float((damage_meta as Dictionary).get("shield_absorbed", 0.0))
			immune_absorbed = float((damage_meta as Dictionary).get("immune_absorbed", 0.0))

	if damage <= 0.0 and shield_absorbed <= 0.0 and immune_absorbed <= 0.0:
		return

	var damage_events: Array = summary.get("damage_events", [])
	damage_events.append({
		"source": source,
		"target": target,
		"damage": damage,
		"shield_absorbed": shield_absorbed,
		"immune_absorbed": immune_absorbed,
		"damage_type": damage_type,
		"op": op
	})
	summary["damage_events"] = damage_events

	# 元数据只对应最近一次伤害，写完事件后立即清空，避免串到下一次结算。
	if runtime_gateway != null and runtime_gateway.has_method("clear_last_damage_meta"):
		runtime_gateway.clear_last_damage_meta()


# Buff/Debuff 事件只记录可回放所需的公共字段。
# `duration` 会原样写入事件，便于区分普通 Buff 与 `-1` 的长期光环实例。
# `summary` 只记录实际生效结果。
func append_buff_event(
	summary: Dictionary,
	source: Node,
	target: Node,
	buff_id: String,
	duration: float,
	op: String
) -> void:
	if buff_id.strip_edges().is_empty():
		return

	var buff_events: Array = summary.get("buff_events", [])
	# Buff 事件保留 source/target，方便后续日志和测试按来源实例断言。
	buff_events.append({
		"source": source,
		"target": target,
		"buff_id": buff_id,
		"duration": duration,
		"op": op
	})
	summary["buff_events"] = buff_events


# 治疗事件只在实际回复量大于 0 时写入，避免噪音。
# 这里不记录理论治疗量，防止吸收、满血溢出等情况污染日志。
# `summary` 只记录实际生效结果。
func append_heal_event(
	summary: Dictionary,
	source: Node,
	target: Node,
	heal: float,
	op: String
) -> void:
	if heal <= 0.0:
		return

	var heal_events: Array = summary.get("heal_events", [])
	heal_events.append({
		"source": source,
		"target": target,
		"heal": heal,
		"op": op
	})
	summary["heal_events"] = heal_events


# MP 事件沿用与伤害/治疗相同的汇总口径。
# 主动回蓝和吸蓝都会落到这里，后续可通过 `op` 区分来源。
# `summary` 只记录实际生效结果。
func append_mp_event(
	summary: Dictionary,
	source: Node,
	target: Node,
	mp: float,
	op: String
) -> void:
	if mp <= 0.0:
		return

	var mp_events: Array = summary.get("mp_events", [])
	# MP 事件单独建列表，避免和治疗事件混在一起后失去资源类型语义。
	mp_events.append({
		"source": source,
		"target": target,
		"mp": mp,
		"op": op
	})
	summary["mp_events"] = mp_events
