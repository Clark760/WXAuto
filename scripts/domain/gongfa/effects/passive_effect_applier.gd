extends RefCounted
class_name PassiveEffectApplier


func create_empty_modifier_bundle() -> Dictionary:
	return {
		"mp_regen_add": 0.0,
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


func _apply_passive_op(runtime_stats: Dictionary, modifier_bundle: Dictionary, effect: Dictionary, stack_multiplier: float) -> void:
	var op: String = str(effect.get("op", "")).strip_edges()
	if op.is_empty():
		return

	match op:
		"stat_add":
			var stat_key: String = str(effect.get("stat", "")).strip_edges()
			if stat_key.is_empty():
				return
			var value: float = float(effect.get("value", 0.0)) * stack_multiplier
			runtime_stats[stat_key] = float(runtime_stats.get(stat_key, 0.0)) + value

		"stat_percent":
			var stat_key_p: String = str(effect.get("stat", "")).strip_edges()
			if stat_key_p.is_empty():
				return
			var ratio: float = 1.0 + float(effect.get("value", 0.0)) * stack_multiplier
			runtime_stats[stat_key_p] = float(runtime_stats.get(stat_key_p, 0.0)) * ratio

		"mp_regen_add":
			_add_modifier(modifier_bundle, "mp_regen_add", float(effect.get("value", 0.0)) * stack_multiplier)

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
			_add_modifier(modifier_bundle, "attack_speed_bonus", float(effect.get("value", 0.0)) * stack_multiplier)

		"range_add":
			_add_modifier(modifier_bundle, "range_add", float(effect.get("value", 0.0)) * stack_multiplier)

		"vampire":
			_add_modifier(modifier_bundle, "vampire", float(effect.get("value", 0.0)) * stack_multiplier)

		"damage_amp_percent":
			_add_modifier(modifier_bundle, "damage_amp_percent", float(effect.get("value", 0.0)) * stack_multiplier)

		"damage_amp_vs_debuffed":
			var vs_value: float = float(effect.get("value", 0.0)) * stack_multiplier
			var require_debuff: String = str(effect.get("require_debuff", "")).strip_edges()
			if require_debuff.is_empty():
				_add_modifier(modifier_bundle, "damage_amp_vs_any_debuff", vs_value)
			else:
				var amp_map: Dictionary = modifier_bundle.get("damage_amp_vs_debuff_map", {})
				amp_map[require_debuff] = float(amp_map.get(require_debuff, 0.0)) + vs_value
				modifier_bundle["damage_amp_vs_debuff_map"] = amp_map

		"tenacity":
			_add_modifier(modifier_bundle, "tenacity", float(effect.get("value", 0.0)) * stack_multiplier)

		"thorns_percent":
			_add_modifier(modifier_bundle, "thorns_percent", float(effect.get("value", 0.0)) * stack_multiplier)

		"thorns_flat":
			_add_modifier(modifier_bundle, "thorns_flat", float(effect.get("value", 0.0)) * stack_multiplier)

		"shield_on_combat_start":
			_add_modifier(modifier_bundle, "shield_on_combat_start", float(effect.get("value", 0.0)) * stack_multiplier)

		"execute_threshold":
			_add_modifier(modifier_bundle, "execute_threshold", float(effect.get("value", 0.0)) * stack_multiplier)

		"healing_amp":
			_add_modifier(modifier_bundle, "healing_amp", float(effect.get("value", 0.0)) * stack_multiplier)

		"mp_on_kill":
			_add_modifier(modifier_bundle, "mp_on_kill", float(effect.get("value", 0.0)) * stack_multiplier)

		"conditional_stat":
			var conditional_entries: Array = modifier_bundle.get("conditional_stats", [])
			conditional_entries.append({
				"stat": str(effect.get("stat", "")).strip_edges(),
				"value": float(effect.get("value", 0.0)) * stack_multiplier,
				"condition": str(effect.get("condition", "")).strip_edges().to_lower(),
				"threshold": float(effect.get("threshold", 0.0))
			})
			modifier_bundle["conditional_stats"] = conditional_entries

		_:
			push_warning("EffectEngine: 未实现的被动 op=%s" % op)


func _add_modifier(modifier_bundle: Dictionary, key: String, value: float) -> void:
	modifier_bundle[key] = float(modifier_bundle.get(key, 0.0)) + value
