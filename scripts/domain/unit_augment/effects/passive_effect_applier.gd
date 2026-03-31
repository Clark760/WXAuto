extends RefCounted
class_name UnitAugmentPassiveEffectApplier

# 被动效果仍集中在纯数据变换层。
# 只要这里不碰运行时副作用，集中 `match` 就仍然成立。


# 被动 modifier bundle 的字段口径必须稳定，避免运行时组件各自兜底。
# 这里定义的是“被动层对外契约”，后续 combat / unit 组件都按这份字段读取。
func create_empty_modifier_bundle() -> Dictionary:
	return {
		"mp_regen_add": 0.0,
		"mp_gain_on_attack": 0.0,
		"mp_gain_on_hit": 0.0,
		"hp_regen_add": 0.0,
		"damage_reduce_flat": 0.0,
		"damage_reduce_percent": 0.0,
		"damage_amp_percent": 0.0,
		"damage_amp_vs_any_debuff": 0.0,
		"damage_amp_vs_debuff_map": {},
		"dodge_bonus": 0.0,
		"crit_bonus": 0.0,
		"crit_damage_bonus": 0.0,
		"vampire": 0.0,
		"tenacity": 0.0,
		"thorns_percent": 0.0,
		"thorns_flat": 0.0,
		"shield_on_combat_start": 0.0,
		"execute_threshold": 0.0,
		"healing_amp": 0.0,
		"mp_on_kill": 0.0,
		"conditional_stats": [],
		"attack_speed_bonus": 0.0,
		"range_add": 0.0
	}


# 被动效果入口只负责遍历。
# `effects` 是配表定义，`stack_multiplier` 只影响数值折算，不改变被动 op 的语义分支。
# `modifier_bundle` 会在循环中被原地累加，因此调用方必须先传入已初始化的容器。
func apply_passive_effects(
	runtime_stats: Dictionary,
	modifier_bundle: Dictionary,
	effects: Array,
	stack_multiplier: float = 1.0
) -> void:
	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue

		var effect: Dictionary = effect_value as Dictionary
		_apply_passive_op(runtime_stats, modifier_bundle, effect, stack_multiplier)


# 被动 op 仍然保持集中匹配，因为它本身是纯属性变换逻辑。
# `effect` 只提供配置值，不允许在这个函数里读取场景节点或写运行时副作用。
# 纯数据变换集中在这里，便于后续继续拆成更细的 stat 组而不改变外部契约。
func _apply_passive_op(
	runtime_stats: Dictionary,
	modifier_bundle: Dictionary,
	effect: Dictionary,
	stack_multiplier: float
) -> void:
	var op: String = str(effect.get("op", "")).strip_edges()
	if op.is_empty():
		return

	match op:
		"stat_add":
			# 基础属性加法直接改 runtime_stats，供后续运行时属性重算使用。
			var stat_key: String = str(effect.get("stat", "")).strip_edges()
			if stat_key.is_empty():
				return

			var value: float = float(effect.get("value", 0.0)) * stack_multiplier
			runtime_stats[stat_key] = float(runtime_stats.get(stat_key, 0.0)) + value

		"stat_percent":
			# 百分比类被动直接在当前快照上乘算，保持旧效果的即时叠乘语义。
			var percent_key: String = str(effect.get("stat", "")).strip_edges()
			if percent_key.is_empty():
				return

			var ratio: float = 1.0 + float(effect.get("value", 0.0)) * stack_multiplier
			runtime_stats[percent_key] = float(runtime_stats.get(percent_key, 0.0)) * ratio

		"mp_regen_add":
			# 以下 modifier 统一进入 bundle，由战斗组件在结算时消费。
			_add_modifier(modifier_bundle, "mp_regen_add", float(effect.get("value", 0.0)) * stack_multiplier)

		"mp_gain_on_attack":
			_add_modifier(modifier_bundle, "mp_gain_on_attack", float(effect.get("value", 0.0)) * stack_multiplier)

		"mp_gain_on_hit":
			_add_modifier(modifier_bundle, "mp_gain_on_hit", float(effect.get("value", 0.0)) * stack_multiplier)

		"hp_regen_add":
			_add_modifier(modifier_bundle, "hp_regen_add", float(effect.get("value", 0.0)) * stack_multiplier)

		"damage_reduce_flat":
			_add_modifier(modifier_bundle, "damage_reduce_flat", float(effect.get("value", 0.0)) * stack_multiplier)

		"damage_reduce_percent":
			_add_modifier(modifier_bundle, "damage_reduce_percent", float(effect.get("value", 0.0)) * stack_multiplier)

		"dodge_bonus":
			_add_modifier(modifier_bundle, "dodge_bonus", float(effect.get("value", 0.0)) * stack_multiplier)

		"crit_bonus":
			_add_modifier(modifier_bundle, "crit_bonus", float(effect.get("value", 0.0)) * stack_multiplier)

		"crit_damage_bonus":
			_add_modifier(modifier_bundle, "crit_damage_bonus", float(effect.get("value", 0.0)) * stack_multiplier)

		"attack_speed_bonus":
			# 攻速、射程这类战斗外显属性也统一挂在 bundle，避免直接改 runtime_stats 后丢失来源。
			_add_modifier(modifier_bundle, "attack_speed_bonus", float(effect.get("value", 0.0)) * stack_multiplier)

		"range_add":
			_add_modifier(modifier_bundle, "range_add", float(effect.get("value", 0.0)) * stack_multiplier)

		"vampire":
			_add_modifier(modifier_bundle, "vampire", float(effect.get("value", 0.0)) * stack_multiplier)

		"damage_amp_percent":
			# 增伤、吸血、韧性等战斗修正都延后到战斗结算阶段再读取。
			_add_modifier(modifier_bundle, "damage_amp_percent", float(effect.get("value", 0.0)) * stack_multiplier)

		"damage_amp_vs_debuffed":
			# 指定 Debuff 的增伤单独记到 map，任意 Debuff 增伤则进入聚合字段。
			var amp_value: float = float(effect.get("value", 0.0)) * stack_multiplier
			var require_debuff: String = str(effect.get("require_debuff", "")).strip_edges()
			if require_debuff.is_empty():
				_add_modifier(modifier_bundle, "damage_amp_vs_any_debuff", amp_value)
			else:
				var amp_map: Dictionary = modifier_bundle.get("damage_amp_vs_debuff_map", {})
				amp_map[require_debuff] = float(amp_map.get(require_debuff, 0.0)) + amp_value
				modifier_bundle["damage_amp_vs_debuff_map"] = amp_map

		"tenacity":
			_add_modifier(modifier_bundle, "tenacity", float(effect.get("value", 0.0)) * stack_multiplier)

		"thorns_percent":
			_add_modifier(modifier_bundle, "thorns_percent", float(effect.get("value", 0.0)) * stack_multiplier)

		"thorns_flat":
			_add_modifier(modifier_bundle, "thorns_flat", float(effect.get("value", 0.0)) * stack_multiplier)

		"shield_on_combat_start":
			# 开场护盾、斩杀线、治疗增幅等特殊字段都保持独立键，避免和基础属性混算。
			_add_modifier(modifier_bundle, "shield_on_combat_start", float(effect.get("value", 0.0)) * stack_multiplier)

		"execute_threshold":
			_add_modifier(modifier_bundle, "execute_threshold", float(effect.get("value", 0.0)) * stack_multiplier)

		"healing_amp":
			_add_modifier(modifier_bundle, "healing_amp", float(effect.get("value", 0.0)) * stack_multiplier)

		"mp_on_kill":
			_add_modifier(modifier_bundle, "mp_on_kill", float(effect.get("value", 0.0)) * stack_multiplier)

		"conditional_stat":
			# 条件属性延迟到运行时条件满足时再解释，因此这里只把声明保存在 bundle 中。
			# effect 层不提前求值，避免把战斗中才知道的条件提前固化到静态数值里。
			var conditional_entries: Array = modifier_bundle.get("conditional_stats", [])
			conditional_entries.append({
				"stat": str(effect.get("stat", "")).strip_edges(),
				"value": float(effect.get("value", 0.0)) * stack_multiplier,
				"condition": str(effect.get("condition", "")).strip_edges().to_lower(),
				"threshold": float(effect.get("threshold", 0.0))
			})
			modifier_bundle["conditional_stats"] = conditional_entries

		_:
			# 被动未实现时只告警不抛错，保持旧配表在迁移期的容错行为。
			push_warning("UnitAugmentEffectEngine: 未实现的被动 op=%s" % op)


# `key` 对应 modifier bundle 字段名，`value` 是已经换算好的增量。
# 所有 bundle 累加都收口在这里，避免不同被动分支出现不同的默认值策略。
func _add_modifier(modifier_bundle: Dictionary, key: String, value: float) -> void:
	# 默认缺省值统一按 0 处理，避免某个调用点先读后写时忘了初始化。
	# 即使 value 为 0 也允许落库，保证字段集合在调试时保持完整。
	modifier_bundle[key] = float(modifier_bundle.get(key, 0.0)) + value
