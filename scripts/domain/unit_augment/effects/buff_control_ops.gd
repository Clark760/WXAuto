extends RefCounted
class_name UnitAugmentBuffControlOps

# Buff control 只负责状态附着入口与摘要记录。
# 长期生命周期仍由 BuffManager 和光环跟踪维护。

var _summary_collector: Variant
var _query_service: Variant


# `summary_collector` 负责附着结果归档，`query_service` 负责目标筛选。
# 这层不直接持有 BuffManager，所有运行时落地都经由 gateway。
# 因此这里可以解释效果语义，但不能直接决定具体的 BuffManager 调用细节。
func _init(
	summary_collector: Variant,
	query_service: Variant
) -> void:
	_summary_collector = summary_collector
	_query_service = query_service


# Buff、Debuff 与净化/驱散共享同一类生命周期语义。
# `routes` 只建立公开 op 到 handler 的映射，不在注册阶段偷做任何兼容判断。
func register_routes(routes: Dictionary) -> void:
	routes["buff_self"] = Callable(self, "_buff_self")
	routes["buff_allies_aoe"] = Callable(self, "_buff_allies_aoe")
	routes["debuff_target"] = Callable(self, "_debuff_target")
	routes["buff_target"] = Callable(self, "_buff_target")
	routes["debuff_aoe"] = Callable(self, "_debuff_aoe")
	routes["cleanse_self"] = Callable(self, "_cleanse_self")
	routes["cleanse_ally"] = Callable(self, "_cleanse_ally")
	routes["steal_buff"] = Callable(self, "_steal_buff")
	routes["dispel_target"] = Callable(self, "_dispel_target")
	routes["mark_target"] = Callable(self, "_mark_target")


# 自身 Buff 是最简单的附着入口。
# `source` 同时扮演施法者和目标，便于统一复用普通 Buff 落地逻辑。
# `summary` 只在真正附着成功后累加，避免把失败尝试记成已生效。
func _buff_self(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
# 自身附着是最直接的入口，也是最常见的普通 Buff 起点。
	if not runtime_gateway.apply_buff_op(source, source, effect, context):
		return

	# 只有真正写入成功后才记一条自身 Buff 事件，避免日志里出现空命中。
	summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
	_summary_collector.append_buff_event(
		summary,
		source,
		source,
		str(effect.get("buff_id", "")),
		float(effect.get("duration", 0.0)),
		"buff_self"
	)


# 光环类 Buff 在这里统一判定 `binding_mode`，避免分发器知道生命周期细节。
# `effect.radius/exclude_self/binding_mode` 决定目标集与生命周期，`context` 提供 aura 刷新作用域。
# 普通范围 Buff 和 source_bound_aura 在这里分叉，但最终都复用同一份 summary 口径。
func _buff_allies_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var buff_radius: float = _query_service.cells_to_world_distance(float(effect.get("radius", 3.0)), context)
	var exclude_self: bool = bool(effect.get("exclude_self", false))
	var allies: Array[Node] = _query_service.collect_ally_units_in_radius(
		source,
		_query_service.node_pos(source),
		buff_radius,
		context,
		exclude_self
	)

	if runtime_gateway.is_source_bound_aura_binding(effect):
		# 动态光环只刷新命中集合，不在这一层手写 enter/exit 生命周期。
		_apply_source_bound_aura(
			summary,
			runtime_gateway,
			source,
			effect,
			allies,
			context,
			true,
			"buff_allies_aoe"
		)
		return

	for ally in allies:
		# 普通范围 Buff 逐目标落地，保证每个目标的失败都不会中断其他目标。
		if not runtime_gateway.apply_buff_op(source, ally, effect, context):
			continue

		summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
		_summary_collector.append_buff_event(
			summary,
			source,
			ally,
			str(effect.get("buff_id", "")),
			float(effect.get("duration", 0.0)),
			"buff_allies_aoe"
		)


# 单体 Debuff 只负责把状态附着到目标，不在这里处理持续刷新或移除时机。
# `effect.buff_id/duration` 决定附着内容，目标解析已经在 dispatcher 阶段完成。
# summary 归到 `debuff_applied`，方便与正面 Buff 的附着统计分离。
func _debuff_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
# 目标 Debuff 沿用与 Buff 相同的附着入口，只是 summary 归到 debuff。
	if not runtime_gateway.apply_buff_op(source, target, effect, context):
		return

	summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
	_summary_collector.append_buff_event(
		summary,
		source,
		target,
		str(effect.get("buff_id", "")),
		float(effect.get("duration", 0.0)),
		"debuff_target"
	)


# 单体 Buff 与单体 Debuff 共用同一套运行时附着入口，只是 summary 归类不同。
# 这里不再额外查询目标，避免单体效果在 domain 层私自改变上层传入的目标语义。
func _buff_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	if not runtime_gateway.apply_buff_op(source, target, effect, context):
		return

	# 单体正面 Buff 和单体负面 Buff 共享同一落地逻辑，差别只留在统计字段与 op 名称上。
	summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
	_summary_collector.append_buff_event(
		summary,
		source,
		target,
		str(effect.get("buff_id", "")),
		float(effect.get("duration", 0.0)),
		"buff_target"
	)


# 范围 Debuff 的目标筛选统一走 query service，避免不同 op 各自扫描单位列表。
# 如果开启 `source_bound_aura`，这里只发起刷新，不直接长期维护目标集。
# `effect.radius` 仍按世界距离换算后的友敌查询解释，而不是格子半径。
func _debuff_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var debuff_radius: float = _query_service.cells_to_world_distance(float(effect.get("radius", 3.0)), context)
	var enemies: Array[Node] = _query_service.collect_enemy_units_in_radius(
		source,
		_query_service.node_pos(source),
		debuff_radius,
		context
	)

	if runtime_gateway.is_source_bound_aura_binding(effect):
		# Debuff 光环与 Buff 光环共享同一刷新机制，只是 summary 字段不同。
		_apply_source_bound_aura(
			summary,
			runtime_gateway,
			source,
			effect,
			enemies,
			context,
			false,
			"debuff_aoe"
		)
		return

	for enemy in enemies:
		# 非光环型范围 Debuff 继续按一次性附着处理，不维护后续离场清理。
		if not runtime_gateway.apply_buff_op(source, enemy, effect, context):
			continue

		summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
		_summary_collector.append_buff_event(
			summary,
			source,
			enemy,
			str(effect.get("buff_id", "")),
			float(effect.get("duration", 0.0)),
			"debuff_aoe"
		)


# 净化/驱散类效果继续直接复用现有 BuffManager 能力。
# 自净化不改 summary，因为它是状态移除而不是新的附着结果。
# `context.buff_manager` 是真正的运行时入口，这里只负责触发，不生成伪“附着成功”记录。
func _cleanse_self(
	_runtime_gateway: Variant,
	source: Node,
	_target: Node,
	_effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager != null and buff_manager.has_method("cleanse_debuffs"):
		buff_manager.cleanse_debuffs(source)


# 友方净化默认挑选当前最低血量队友，避免额外引入新的目标选择规则。
# `query_service` 负责目标选择，净化本身仍交给 BuffManager 执行。
func _cleanse_ally(
	_runtime_gateway: Variant,
	source: Node,
	_target: Node,
	_effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null or not buff_manager.has_method("cleanse_debuffs"):
		return

	# 目标选择和净化执行分离，便于后续替换成别的选友军策略而不碰净化逻辑。
	var ally_to_cleanse: Node = _query_service.find_lowest_hp_ally(source, context)
	if ally_to_cleanse != null and is_instance_valid(ally_to_cleanse):
		buff_manager.cleanse_debuffs(ally_to_cleanse)


# 偷取 Buff 仍沿用旧 BuffManager 入口，这里只负责把 effect 配置翻译成参数。
# `effect.count` 只表示尝试窃取的层数或条目数，不代表一定成功偷到对应数量。
func _steal_buff(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager != null and buff_manager.has_method("steal_buffs"):
		# 这里沿用旧接口参数顺序：先目标、后接收者、最后来源上下文。
		buff_manager.steal_buffs(target, source, maxi(int(effect.get("count", 1)), 1), source)


# 驱散只负责移除目标身上的正面 Buff，不在 effect 层补额外判定。
# 这里不写 summary，是因为驱散属于移除行为，不属于新的 Buff 命中事件。
func _dispel_target(
	_runtime_gateway: Variant,
	_source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager != null and buff_manager.has_method("dispel_buffs"):
		buff_manager.dispel_buffs(target, maxi(int(effect.get("count", 1)), 1))


# mark 会优先尝试走 Buff 语义，这样后续驱散和条件判定都能复用同一套状态来源。
# `effect.mark_id` 是条件判定和事件日志看到的统一标识，不能在这里悄悄换名。
# mark 成功后按 Debuff 口径记账，便于和 `damage_if_marked` 这类效果对齐。
func _mark_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	if not runtime_gateway.apply_mark_target_op(source, target, effect, context):
		return

	# mark 沿用 Debuff 统计字段，方便与带条件的增伤/斩杀效果统一读取。
	summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
	_summary_collector.append_buff_event(
		summary,
		source,
		target,
		str(effect.get("mark_id", "")),
		float(effect.get("duration", 0.0)),
		"mark_target"
	)


# 光环刷新结果由 BuffManager 返回新增目标列表，事件汇总只记录新增命中。
# `is_buff` 只用于决定 summary 字段名，真正的 aura 生命周期仍由 runtime gateway 和 BuffManager 维护。
# `targets` 是本轮命中的完整快照，而不是“只新增的目标列表”。
func _apply_source_bound_aura(
	summary: Dictionary,
	runtime_gateway: Variant,
	source: Node,
	effect: Dictionary,
	targets: Array[Node],
	context: Dictionary,
	is_buff: bool,
	op: String
) -> void:
	var aura_result: Dictionary = runtime_gateway.execute_source_bound_aura_op(source, effect, targets, context)
	# `applied_count` 只统计新进入光环的目标，已在范围内持续存在的目标不会重复累计。
	var applied_count: int = int(aura_result.get("applied_count", 0))
	var key: String = "buff_applied" if is_buff else "debuff_applied"
	summary[key] = int(summary.get(key, 0)) + applied_count

	var applied_targets_value: Variant = aura_result.get("applied_targets", [])
	if not (applied_targets_value is Array):
		return

	# BuffManager 返回的目标列表只包含本轮新进入光环的单位。
	for target_value in (applied_targets_value as Array):
		# 光环事件统一记成永久时长，方便日志和测试一眼区分它不是普通定时 Buff。
		if not (target_value is Node):
			continue

		var target: Node = target_value as Node
		_summary_collector.append_buff_event(summary, source, target, str(effect.get("buff_id", "")), -1.0, op)
