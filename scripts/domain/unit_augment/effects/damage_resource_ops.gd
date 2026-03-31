extends RefCounted
class_name UnitAugmentDamageResourceOps

# damage/resource op 只结算资源数值并写入 summary。
# 目标查询和运行时副作用分别交给 query service 与 gateway。

var _summary_collector: Variant
var _query_service: Variant


# `summary_collector` 统一维护 total/event 双写口径。
# `query_service` 统一负责范围、距离和兜底目标查询。
# 这一层只解释数值语义，不直接保存 combat/buff 旧对象引用。
func _init(
	summary_collector: Variant,
	query_service: Variant
) -> void:
	_summary_collector = summary_collector
	_query_service = query_service


# 伤害、治疗、MP 属于同一类资源结算，统一挂在这一组。
# `routes` 只注册公开 op 名称，不在这里塞任何 effect 判定逻辑。
func register_routes(routes: Dictionary) -> void:
	routes["damage_target"] = Callable(self, "_damage_target")
	routes["damage_aoe"] = Callable(self, "_damage_aoe")
	routes["heal_self"] = Callable(self, "_heal_self")
	routes["heal_self_percent"] = Callable(self, "_heal_self_percent")
	routes["heal_allies_aoe"] = Callable(self, "_heal_allies_aoe")
	routes["heal_target_flat"] = Callable(self, "_heal_target_flat")
	routes["mp_regen_add"] = Callable(self, "_mp_regen_add")
	routes["damage_target_scaling"] = Callable(self, "_damage_target_scaling")
	routes["damage_if_debuffed"] = Callable(self, "_damage_if_debuffed")
	routes["damage_chain"] = Callable(self, "_damage_chain")
	routes["damage_cone"] = Callable(self, "_damage_cone")
	routes["heal_lowest_ally"] = Callable(self, "_heal_lowest_ally")
	routes["heal_percent_missing_hp"] = Callable(self, "_heal_percent_missing_hp")
	routes["shield_allies_aoe"] = Callable(self, "_shield_allies_aoe")
	routes["shield_self"] = Callable(self, "_shield_self")
	routes["immunity_self"] = Callable(self, "_immunity_self")
	routes["damage_if_marked"] = Callable(self, "_damage_if_marked")
	routes["execute_target"] = Callable(self, "_execute_target")
	routes["drain_mp"] = Callable(self, "_drain_mp")
	routes["aoe_percent_hp_damage"] = Callable(self, "_aoe_percent_hp_damage")
	routes["damage_amp_percent"] = Callable(self, "_damage_amp_percent")


# 单体伤害是最基础的主动效果口径。
# `effect.value` 是基础伤害，`multiplier` 只在这一层做简单乘算，不额外引入条件判定。
# `summary` 记录的是 `deal_damage` 返回的实际伤害，而不是理论输入值。
func _damage_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	# 单体伤害是所有伤害 op 的基线实现。
	# 其他复杂伤害最终都应回到同一套记账口径。
	var damage_value: float = float(effect.get("value", 0.0))
	var multiplier: float = float(effect.get("multiplier", 1.0))
	var damage_type: String = str(effect.get("damage_type", "internal"))
	var dealt: float = runtime_gateway.deal_damage(source, target, damage_value * multiplier, damage_type)
	_add_damage(summary, source, target, dealt, damage_type, "damage_target", runtime_gateway)


# 范围伤害依赖统一的敌军查询，而不是每个 op 自己扫 `all_units`。
# `effect.radius` 会先被换算成世界距离，`source` 的当前位置就是 AOE 中心。
# `summary` 逐目标累计实际命中结果，不在这里先做总伤害预估。
func _damage_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var radius_world: float = _query_service.cells_to_world_distance(float(effect.get("radius", 2.0)), context)
	var base_damage: float = float(effect.get("value", 0.0))
	var damage_type: String = str(effect.get("damage_type", "internal"))
	var center: Vector2 = _query_service.node_pos(source)

	for enemy in _query_service.collect_enemy_units_in_radius(source, center, radius_world, context):
		# AOE 每个目标单独走一次旧伤害入口，便于护盾吸收和事件日志逐目标记录。
		var dealt: float = runtime_gateway.deal_damage(source, enemy, base_damage, damage_type)
		_add_damage(summary, source, enemy, dealt, damage_type, "damage_aoe", runtime_gateway)


# 自疗和目标治疗本质一样，只是目标解析不同。
# `effect.value` 在这里按固定治疗量解释，不做百分比换算。
# `source` 作为治疗来源传给 gateway，用于复用治疗放大等旧 modifier 逻辑。
func _heal_self(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var healed: float = runtime_gateway.heal_unit(source, float(effect.get("value", 0.0)), source)
	_add_heal(summary, source, source, healed, "heal_self")


# 百分比自疗用当前最大生命做基数，避免把受伤量语义混进这个入口。
# `effect.value` 在这里表示治疗比例，而不是固定数值。
# 这样配置一眼就能看出它依赖的是上限生命，而不是缺失生命。
func _heal_self_percent(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var max_hp: float = _query_service.get_combat_value(source, "max_hp")
	var ratio: float = float(effect.get("value", 0.0))
	var healed: float = runtime_gateway.heal_unit(source, max_hp * ratio, source)
	_add_heal(summary, source, source, healed, "heal_self_percent")


# 范围治疗仍然走统一的友军查询，`exclude_self` 用于兼容光环类治疗配置。
# `effect.value` 解释为每个目标的固定治疗量，而不是在所有目标之间平摊。
# summary 只记录实际治疗量，不记录理论治疗量。
func _heal_allies_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var heal_radius: float = _query_service.cells_to_world_distance(float(effect.get("radius", 3.0)), context)
	var heal_amount: float = float(effect.get("value", 0.0))
	var heal_center: Vector2 = _query_service.node_pos(source)
	var exclude_self: bool = bool(effect.get("exclude_self", false))

	for ally in _query_service.collect_ally_units_in_radius(source, heal_center, heal_radius, context, exclude_self):
		# 治疗量按目标逐个结算，避免把溢出治疗量平均分摊到群体事件里。
		var healed: float = runtime_gateway.heal_unit(ally, heal_amount, source)
		_add_heal(summary, source, ally, healed, "heal_allies_aoe")


# 单体治疗允许 `target` 为空时回退到 `source`，避免旧配置因为缺目标直接失效。
# 这类“单体或自己”的兜底语义统一收口在 `_resolve_target_or_source`。
func _heal_target_flat(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var heal_target: Node = _resolve_target_or_source(source, target)
	var healed: float = runtime_gateway.heal_unit(heal_target, float(effect.get("value", 0.0)), source)
	_add_heal(summary, source, heal_target, healed, "heal_target_flat")


# 回蓝入口沿用与治疗相同的“目标为空则回退施法者”语义。
# `summary.mp_total` 记录的是实际回蓝量，便于和吸蓝等入口统一比较。
func _mp_regen_add(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var mp_target: Node = _resolve_target_or_source(source, target)
	var restored_mp: float = runtime_gateway.restore_mp_unit(mp_target, float(effect.get("value", 0.0)))
	_add_mp(summary, source, mp_target, restored_mp, "mp_regen_add")


# scaling 伤害依赖 query service 统一读取 runtime/combat 数值。
# `scale_source` 和 `scale_stat` 一起决定取值来源，避免各个 scaling op 自己拆分口径。
# `effect.value` 是固定底数，`scale_ratio` 只负责附加缩放部分。
func _damage_target_scaling(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var scale_base: float = float(effect.get("value", 0.0))
	var scale_stat: String = str(effect.get("scale_stat", "max_hp")).strip_edges().to_lower()
	var scale_ratio: float = float(effect.get("scale_ratio", 0.0))
	var scale_source_pref: String = str(effect.get("scale_source", "auto")).strip_edges().to_lower()
	var scale_node: Node = source

	# 血量类缩放默认更偏向 target，其余属性默认从 source 取值，保持旧配表习惯。
	if scale_source_pref == "target":
		scale_node = target
	elif (scale_stat == "max_hp" or scale_stat == "current_hp") and target != null and is_instance_valid(target):
		scale_node = target

	var scale_value: float = _query_service.resolve_scale_stat_value(scale_node, scale_stat)
	# 缩放值在这里先折算成最终伤害，再统一交给旧伤害入口处理吸收与减伤。
	var scaled_damage: float = maxf(scale_base + scale_value * scale_ratio, 0.0)
	var damage_type: String = str(effect.get("damage_type", "internal"))
	var dealt: float = runtime_gateway.deal_damage(source, target, scaled_damage, damage_type)
	_add_damage(summary, source, target, dealt, damage_type, "damage_target_scaling", runtime_gateway)


# 条件伤害只改变最终伤害倍率，不改变 Debuff 判定入口。
# `require_debuff` 为空时等价于“目标身上有任意 Debuff”。
# Debuff 判定统一委托给 query service，避免数值层自己猜目标状态来源。
func _damage_if_debuffed(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var damage_value: float = float(effect.get("value", 0.0))
	var bonus_multiplier: float = maxf(float(effect.get("bonus_multiplier", 1.0)), 0.0)
	var require_debuff: String = str(effect.get("require_debuff", "")).strip_edges()
	if _query_service.target_has_debuff(target, require_debuff):
		damage_value *= bonus_multiplier

	# 条件成立与否只影响伤害数值，不改变后续事件的 damage_type 与 op 归类。
	var damage_type: String = str(effect.get("damage_type", "internal"))
	var dealt: float = runtime_gateway.deal_damage(source, target, damage_value, damage_type)
	_add_damage(summary, source, target, dealt, damage_type, "damage_if_debuffed", runtime_gateway)


# 链伤沿用“最近未命中敌军”规则，行为口径保持不变。
# `chain_count` 表示额外跳转次数，首个命中目标仍然在本函数内统一结算。
# `visited` 由当前函数维护，保证整条链上的去重口径一致。
func _damage_chain(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	# 链伤的关键是“命中过的目标不再重复命中”。
	# `visited` 集合因此必须留在这一层统一维护。
	var base_damage: float = float(effect.get("value", 0.0))
	var chain_count: int = maxi(int(effect.get("chain_count", effect.get("jumps", 0))), 0)
	var chain_radius_cells: float = float(effect.get("radius", 3.0))
	var decay_ratio: float = clampf(float(effect.get("decay", 0.0)), 0.0, 0.95)
	var damage_type: String = str(effect.get("damage_type", "internal"))
	var visited: Dictionary = {}
	var current_target: Node = target

	if current_target == null or not is_instance_valid(current_target):
		# 没有显式主目标时，从 source 周围先捞一个最近敌人作为第一跳。
		current_target = _query_service.pick_nearest_enemy_unit(
			source,
			context,
			_query_service.node_pos(source),
			INF,
			visited
		)

	for hop in range(chain_count + 1):
		if current_target == null or not is_instance_valid(current_target):
			break

		# 每跳都按衰减公式重新计算本跳伤害，避免把第一跳数值误复用到整条链。
		var hop_damage: float = base_damage * pow(1.0 - decay_ratio, float(hop))
		var dealt: float = runtime_gateway.deal_damage(source, current_target, hop_damage, damage_type)
		_add_damage(summary, source, current_target, dealt, damage_type, "damage_chain", runtime_gateway)

		visited[current_target.get_instance_id()] = true
		if hop >= chain_count:
			break

		current_target = _query_service.pick_nearest_enemy_unit(
			source,
			context,
			_query_service.node_pos(current_target),
			_query_service.cells_to_world_distance(chain_radius_cells, context),
			visited
		)


# 扇形伤害用 `source -> target` 的方向确定正前方，`target` 为空时回退到默认朝向。
# `effect.angle/range` 共同决定命中扇区，目标筛选仍然先从范围敌军里取候选。
func _damage_cone(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var cone_damage: float = float(effect.get("value", 0.0))
	var damage_type: String = str(effect.get("damage_type", "internal"))
	var angle_deg: float = clampf(float(effect.get("angle", effect.get("angle_deg", 60.0))), 1.0, 180.0)
	var range_world: float = _query_service.cells_to_world_distance(
		float(effect.get("range", effect.get("radius", 2.0))),
		context
	)
	var origin: Vector2 = _query_service.node_pos(source)
	var direction: Vector2 = Vector2.RIGHT
	if target != null and is_instance_valid(target):
		direction = (_query_service.node_pos(target) - origin).normalized()

	if direction.is_zero_approx():
		direction = Vector2.RIGHT

	var half_cos: float = cos(deg_to_rad(angle_deg * 0.5))
	for enemy in _query_service.collect_enemy_units_in_radius(source, origin, range_world, context):
		# 扇形判定仍从范围候选里筛，避免直接全图遍历再做角度过滤。
		var offset: Vector2 = _query_service.node_pos(enemy) - origin
		if offset.is_zero_approx():
			continue
		if direction.dot(offset.normalized()) < half_cos:
			continue

		var dealt: float = runtime_gateway.deal_damage(source, enemy, cone_damage, damage_type)
		_add_damage(summary, source, enemy, dealt, damage_type, "damage_cone", runtime_gateway)


# 最低血量治疗只负责选目标，不负责额外过滤 Buff 或职业条件。
# 目标选择统一基于血量比例，避免高上限单位被优先治疗。
func _heal_lowest_ally(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var lowest_ally: Node = _query_service.find_lowest_hp_ally(source, context)
	if lowest_ally == null or not is_instance_valid(lowest_ally):
		return

	var healed: float = runtime_gateway.heal_unit(lowest_ally, float(effect.get("value", 0.0)), source)
	_add_heal(summary, source, lowest_ally, healed, "heal_lowest_ally")


# 缺失生命百分比治疗先算缺口，再把 `effect.value` 当成缺口倍率。
# `effect.value = 1` 表示补满当前缺口，`0.5` 表示只补一半缺口。
func _heal_percent_missing_hp(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var heal_target: Node = _resolve_target_or_source(source, target)
	var missing_ratio: float = clampf(float(effect.get("value", effect.get("ratio", 0.0))), 0.0, 5.0)
	var missing_hp: float = maxf(
		_query_service.get_combat_value(heal_target, "max_hp") - _query_service.get_combat_value(heal_target, "current_hp"),
		0.0
	)
	var healed: float = runtime_gateway.heal_unit(heal_target, missing_hp * missing_ratio, source)
	_add_heal(summary, source, heal_target, healed, "heal_percent_missing_hp")


# 群体护盾继续沿用“加盾 + 可选挂 Buff”的历史行为。
# `effect.duration` 只决定附带 Buff 时长，不影响即时加盾本身的生效。
# 护盾本体通过 combat 组件结算，附带 Buff 只负责表现层和后续条件判断。
func _shield_allies_aoe(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var shield_radius: float = _query_service.cells_to_world_distance(float(effect.get("radius", 3.0)), context)
	var shield_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
	var exclude_self: bool = bool(effect.get("exclude_self", false))

	for ally in _query_service.collect_ally_units_in_radius(
		source,
		_query_service.node_pos(source),
		shield_radius,
		context,
		exclude_self
	):
		var ally_combat = ally.get_node_or_null("Components/UnitCombat")
		if ally_combat == null:
			continue
		# 护盾本体和附带 Buff 分两步结算，这样没有 Buff 定义时也能先吃到即时护盾。
		if ally_combat.has_method("add_shield"):
			ally_combat.add_shield(shield_value)

		var duration: float = float(effect.get("duration", 0.0))
		if duration <= 0.0:
			continue

		var buff_id: String = str(
			effect.get("shield_buff_id", effect.get("buff_id", "buff_qi_shield"))
		).strip_edges()
		var buff_effect: Dictionary = {
			"buff_id": buff_id,
			"duration": duration
		}
		if runtime_gateway.apply_buff_op(source, ally, buff_effect, context):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_summary_collector.append_buff_event(
				summary,
				source,
				ally,
				buff_id,
				duration,
				"shield_allies_aoe"
			)


# 自身护盾同时兼容护盾 Buff 和免疫 Buff，两者都需要回写到 summary。
# `shield_buff_id` 和 `immunity_buff_id` 分别绑定两类状态，方便旧 UI 与清理逻辑区分。
func _shield_self(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	# 护盾虽然会附带 Buff，但本质上仍然在改变资源承受能力。
	# 因此它仍然先归在资源结算组，而不是 Buff 生命周期组。
	var shield_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
	if shield_value <= 0.0:
		return

	var combat = source.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return
	if combat.has_method("add_shield"):
		combat.add_shield(shield_value)

	var shield_buff_id: String = str(effect.get("shield_buff_id", effect.get("buff_id", "buff_qi_shield"))).strip_edges()
	var shield_duration: float = float(effect.get("duration", -1.0))
	if not shield_buff_id.is_empty():
		# 护盾 Buff id 会写回 meta，供旧护盾清理逻辑按来源找到对应状态。
		var shield_effect: Dictionary = {
			"buff_id": shield_buff_id,
			"duration": shield_duration
		}
		if runtime_gateway.apply_buff_op(source, source, shield_effect, context):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_summary_collector.append_buff_event(summary, source, source, shield_buff_id, shield_duration, "shield_self")
			source.set_meta("shield_bound_buff_id", shield_buff_id)

	var immunity_buff_id: String = str(effect.get("immunity_buff_id", "")).strip_edges()
	if immunity_buff_id.is_empty():
		return

	var immunity_duration: float = float(effect.get("immunity_duration", shield_duration))
	var immunity_effect: Dictionary = {
		"buff_id": immunity_buff_id,
		"duration": immunity_duration
	}
	if runtime_gateway.apply_buff_op(source, source, immunity_effect, context):
		# 纯免疫入口仍按 Buff 事件记账，便于 UI 和测试和 shield_self 的附带免疫保持一致。
		summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
		_summary_collector.append_buff_event(
			summary,
			source,
			source,
			immunity_buff_id,
			immunity_duration,
			"shield_self"
		)
		source.set_meta("shield_immunity_buff_id", immunity_buff_id)


# 纯免疫入口只负责挂免疫 Buff，不负责加盾。
# `effect.buff_id` 是这个入口必填的运行时标识，缺失时直接告警并跳过。
func _immunity_self(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	var duration: float = float(effect.get("duration", 0.0))
	if buff_id.is_empty():
		push_warning("UnitAugmentEffectEngine: immunity_self missing buff_id, skipped.")
		return

	var immunity_effect: Dictionary = {
		"buff_id": buff_id,
		"duration": duration
	}
	if runtime_gateway.apply_buff_op(source, source, immunity_effect, context):
		summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
		_summary_collector.append_buff_event(summary, source, source, buff_id, duration, "immunity_self")


# 标记者伤害先走 mark 判定，再统一回到普通伤害记账口径。
# `effect.mark_id` 与 mark 效果写入的标识必须一致，否则条件增伤会永远 miss。
func _damage_if_marked(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var mark_id: String = str(effect.get("mark_id", "")).strip_edges()
	var damage_value: float = float(effect.get("value", 0.0))
	if runtime_gateway.target_has_mark(target, mark_id, context):
		# mark 命中后只调整伤害值，不改变后续伤害事件的 op 名称。
		damage_value *= maxf(float(effect.get("bonus_multiplier", 1.0)), 0.0)

	var damage_type: String = str(effect.get("damage_type", "internal"))
	var dealt: float = runtime_gateway.deal_damage(source, target, damage_value, damage_type)
	_add_damage(summary, source, target, dealt, damage_type, "damage_if_marked", runtime_gateway)


# 斩杀只在目标生命比例低于阈值时触发，阈值本身不写回任何状态。
# `hp_threshold` 比较的是当前生命比例，执行成功后仍然按普通伤害事件记账。
func _execute_target(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	var hp_threshold: float = clampf(
		float(effect.get("hp_threshold", effect.get("threshold", 0.15))),
		0.0,
		0.95
	)
	if _query_service.get_hp_ratio(target) > hp_threshold:
		return

	# 斩杀入口本质仍是一次普通伤害，只是前面多了一层血线门槛判定。
	var execute_damage: float = maxf(float(effect.get("value", effect.get("damage", 0.0))), 0.0)
	var damage_type: String = str(effect.get("damage_type", "external"))
	var dealt: float = runtime_gateway.deal_damage(source, target, execute_damage, damage_type)
	_add_damage(summary, source, target, dealt, damage_type, "execute_target", runtime_gateway)


# 吸蓝需要同时扣目标和回施法者，因此必须在一个原子入口里完成。
# `summary` 记录的是施法者实际获得的 MP，不额外记录目标损失的理论值。
func _drain_mp(
	_runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	_context: Dictionary,
	summary: Dictionary
) -> void:
	# 吸蓝需要同时改目标 MP 和来源 MP，因此必须在同一入口里完成。
	var drain_target: Node = target if target != null and is_instance_valid(target) else null
	if drain_target == null:
		return

	var target_combat = drain_target.get_node_or_null("Components/UnitCombat")
	var source_combat = source.get_node_or_null("Components/UnitCombat") if source != null else null
	if target_combat == null or source_combat == null:
		return

	var drain_amount: float = maxf(float(effect.get("value", 0.0)), 0.0)
	var before_mp: float = float(target_combat.get("current_mp"))
	target_combat.add_mp(-drain_amount)
	var after_mp: float = float(target_combat.get("current_mp"))
	# 回给 source 的 MP 只按目标真实损失值计算，防止超扣造成凭空回蓝。
	var drained: float = maxf(before_mp - after_mp, 0.0)
	source_combat.add_mp(drained)
	_add_mp(summary, source, source, drained, "drain_mp")


# 百分比生命范围伤害按目标最大生命取值，不读当前生命，避免被残血放大两次。
# `effect.percent` 明确是上限生命比例，和 execute 一类当前血线判断分开。
func _aoe_percent_hp_damage(
	runtime_gateway: Variant,
	source: Node,
	_target: Node,
	effect: Dictionary,
	context: Dictionary,
	summary: Dictionary
) -> void:
	var aoe_radius: float = _query_service.cells_to_world_distance(float(effect.get("radius", 2.0)), context)
	var percent: float = clampf(float(effect.get("percent", effect.get("ratio", 0.05))), 0.0, 1.0)
	var cap: float = maxf(float(effect.get("cap", -1.0)), -1.0)
	var damage_type: String = str(effect.get("damage_type", "internal"))

	for enemy in _query_service.collect_enemy_units_in_radius(
		source,
		_query_service.node_pos(source),
		aoe_radius,
		context
	):
		# 百分比生命伤害先取目标最大生命，确保不同血线下伤害基数稳定。
		var enemy_max_hp: float = _query_service.get_combat_value(enemy, "max_hp")
		var percent_damage: float = maxf(enemy_max_hp * percent, 0.0)
		if cap >= 0.0:
			percent_damage = minf(percent_damage, cap)
		var dealt: float = runtime_gateway.deal_damage(source, enemy, percent_damage, damage_type)
		_add_damage(summary, source, enemy, dealt, damage_type, "aoe_percent_hp_damage", runtime_gateway)


func _damage_amp_percent(
	runtime_gateway: Variant,
	source: Node,
	target: Node,
	effect: Dictionary,
	context: Dictionary,
	_summary: Dictionary
) -> void:
	runtime_gateway.apply_damage_amp_percent(source, target, effect, context)


# 统一把累计值和事件写入逻辑收口，避免分支里漏字段。
# `damage_type` 和 `op` 都要进入事件明细，否则日志和统计面板会失去来源信息。
# `runtime_gateway` 在这里提供最近一次伤害的吸收元数据，供 summary collector 记账。
func _add_damage(
	summary: Dictionary,
	source: Node,
	target: Node,
	damage: float,
	damage_type: String,
	op: String,
	runtime_gateway: Variant
) -> void:
	# 伤害总量和伤害事件必须同步更新，否则 UI 日志与统计面板会分叉。
	summary["damage_total"] = float(summary.get("damage_total", 0.0)) + damage
	_summary_collector.append_damage_event(summary, runtime_gateway, source, target, damage, damage_type, op)


# 治疗统计继续沿用“累计值 + 事件”双写规则，保证回放和日志口径一致。
# 这里不关心治疗来源是自疗、单体疗还是复活回血，来源细分交给 `op`。
func _add_heal(summary: Dictionary, source: Node, target: Node, heal: float, op: String) -> void:
	# 治疗沿用与伤害一致的“累计值 + 事件”双写模式。
	summary["heal_total"] = float(summary.get("heal_total", 0.0)) + heal
	_summary_collector.append_heal_event(summary, source, target, heal, op)


# MP 统计也保留事件明细，避免后续无法区分“自然回复”和“主动吸蓝/回蓝”。
# 主动资源类效果统一走这个入口，避免有的效果只加总量不留事件。
func _add_mp(summary: Dictionary, source: Node, target: Node, amount: float, op: String) -> void:
	# MP 统计同样保持统一入口，避免某些 op 只改总量不记事件。
	summary["mp_total"] = float(summary.get("mp_total", 0.0)) + amount
	_summary_collector.append_mp_event(summary, source, target, amount, op)


# 目标为空时回退 `source`，是主动效果层最常见的兜底目标语义。
# 这个函数只做目标回退，不额外校验敌我或存活状态。
func _resolve_target_or_source(source: Node, target: Node) -> Node:
	if target != null and is_instance_valid(target):
		return target
	# 缺目标时统一回退到 source，供 heal/mp 等“单体或自身”入口复用。
	return source
