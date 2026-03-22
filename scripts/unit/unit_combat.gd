extends Node

# ===========================
# 角色战斗组件
# ===========================
# 设计目标：
# 1. 将战斗数值与公式集中在组件内，外部管理器只负责调度与目标分配。
# 2. 同时支持“普攻”和“技能”两条伤害轨道（外功/内功）。
# 3. 实现总纲要求的闪避/暴击/内力机制，并保持组件接口稳定。

signal attacked(attacker: Node, target: Node, event: Dictionary)
signal damaged(target: Node, source: Node, event: Dictionary)
signal died(unit: Node, killer: Node)
signal healing_performed(source: Node, target: Node, amount: float, heal_type: String)
signal thorns_damage_dealt(source: Node, target: Node, event: Dictionary)

@export var attack_range_min_cells: int = 1
@export var attack_range_max_cells: int = 2

var owner_unit: Node = null
var is_alive: bool = true

var current_hp: float = 0.0
var current_mp: float = 0.0
var max_hp: float = 1.0
var max_mp: float = 0.0
# M5：护盾池（独立于生命值），受击时优先扣除。
var shield_hp: float = 0.0
var max_shield_hp: float = 0.0

var attack_interval: float = 0.8
var _attack_cd: float = 0.0
var _regen_heal_pending: float = 0.0
var _regen_emit_accum: float = 0.0
const REGEN_HEAL_EMIT_INTERVAL: float = 0.5

var normal_multiplier: float = 1.0
var skill_multiplier: float = 1.6
var skill_mp_cost: float = 60.0

var mp_gain_on_attack: float = 15.0
var mp_gain_on_hit: float = 10.0
var passive_mp_regen: float = 2.0
# 生命自然回复（基础值）。旧被动兼容值走 external_modifiers["hp_regen_add"]。
var passive_hp_regen: float = 0.0

# 外部修正层（功法/Buff/地形汇总）：
# 由 GongfaManager 注入，避免把功法逻辑耦合进基础战斗流程。
const DEFAULT_EXTERNAL_MODIFIERS: Dictionary = {
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
var _external_modifiers: Dictionary = DEFAULT_EXTERNAL_MODIFIERS.duplicate(true)


func bind_unit(unit: Node) -> void:
	owner_unit = unit


func reset_from_stats(runtime_stats: Dictionary) -> void:
	_external_modifiers = DEFAULT_EXTERNAL_MODIFIERS.duplicate(true)
	refresh_runtime_stats(runtime_stats, false)
	_attack_cd = 0.0
	_regen_heal_pending = 0.0
	_regen_emit_accum = 0.0
	clear_shield()

	# 技能蓝耗按最大内力比例估算，保证不同角色可自然触发技能。
	skill_mp_cost = clampf(max_mp * 0.6, 20.0, 120.0)
	is_alive = current_hp > 0.0


func prepare_for_battle() -> void:
	# 进入战斗时重置冷却，不清空 HP/MP（预留未来“战前状态继承”扩展点）。
	_attack_cd = 0.0
	_regen_heal_pending = 0.0
	_regen_emit_accum = 0.0


func tick_logic(delta: float) -> void:
	if not is_alive:
		return
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	# 生命回复在逻辑帧按秒结算；只处理正值，避免负回复绕过伤害流程。
	var hp_regen_per_sec: float = passive_hp_regen + float(_external_modifiers.get("hp_regen_add", 0.0))
	if hp_regen_per_sec > 0.0:
		var regen_healed: float = restore_hp(hp_regen_per_sec * delta)
		if regen_healed > 0.0:
			_regen_heal_pending += regen_healed
	if _regen_heal_pending > 0.0:
		_regen_emit_accum += delta
		if _regen_emit_accum >= REGEN_HEAL_EMIT_INTERVAL:
			if owner_unit != null and is_instance_valid(owner_unit):
				healing_performed.emit(owner_unit, owner_unit, _regen_heal_pending, "regen")
			_regen_heal_pending = 0.0
			_regen_emit_accum = 0.0
	else:
		_regen_emit_accum = 0.0
	add_mp((passive_mp_regen + float(_external_modifiers.get("mp_regen_add", 0.0))) * delta)


func can_attack() -> bool:
	return is_alive and _attack_cd <= 0.0 and not _is_stunned()


func try_attack_target(target: Node, rng_source: Variant = null) -> Dictionary:
	if owner_unit == null:
		return {}
	if not is_alive:
		return {"performed": false, "reason": "dead"}
	if _is_stunned():
		return {"performed": false, "reason": "stunned"}
	if not can_attack():
		return {"performed": false, "reason": "cooldown"}
	if target == null or not is_instance_valid(target):
		return {"performed": false, "reason": "invalid_target"}

	var target_combat: Node = _get_target_combat(target)
	if target_combat == null:
		return {"performed": false, "reason": "target_no_combat"}
	if not bool(target_combat.get("is_alive")):
		return {"performed": false, "reason": "target_dead"}

	var use_skill: bool = current_mp >= skill_mp_cost and max_mp > 0.0 and not _is_silenced()
	var attack_stats: Dictionary = _select_attack_profile(use_skill)
	var offense: float = float(attack_stats.get("offense", 1.0))
	var damage_type: String = str(attack_stats.get("damage_type", "external"))
	var defense: float = _get_target_stat(target, "def")
	if damage_type == "internal":
		defense = _get_target_stat(target, "idr")
	var multiplier: float = _get_attack_multiplier(use_skill)

	var attacker_spd: float = _get_owner_stat("spd")
	var target_spd: float = _get_target_stat(target, "spd")

	# 总纲公式：闪避率 = (自身SPD - 对方SPD) / (自身SPD + 100)，限制 [0, 40%]。
	# 这里“自身”按防守方理解，因此以 target_spd 为分子主项。
	var target_modifiers: Dictionary = {}
	if target_combat.has_method("get_external_modifiers"):
		target_modifiers = target_combat.call("get_external_modifiers")
	var dodge_rate: float = _calc_dodge_rate(attacker_spd, target_spd, target_modifiers)

	var rng_value_dodge: float = _randf(rng_source)
	var is_dodged: bool = rng_value_dodge < dodge_rate
	var is_crit: bool = false
	var raw_damage: float = 0.0
	var target_hp_before: float = float(target_combat.get("current_hp"))
	var target_max_hp: float = maxf(float(target_combat.get("max_hp")), 1.0)
	var target_debuff_ids: Array = _get_target_debuff_ids(target)

	if not is_dodged:
		var random_factor: float = lerpf(0.9, 1.1, _randf(rng_source))
		raw_damage = offense * multiplier * (100.0 / (100.0 + maxf(defense, 0.0))) * random_factor

		is_crit = _consume_force_crit_on_target(target)
		if not is_crit:
			var crit_rate: float = _calc_crit_rate()
			is_crit = _randf(rng_source) < crit_rate
		if is_crit:
			raw_damage *= _calc_crit_multiplier()

		var amp_ratio: float = float(_external_modifiers.get("damage_amp_percent", 0.0))
		if amp_ratio != 0.0:
			raw_damage *= maxf(1.0 + amp_ratio, 0.0)

		raw_damage *= _calc_debuff_damage_amp_ratio(target_debuff_ids)

		var execute_threshold: float = clampf(float(_external_modifiers.get("execute_threshold", 0.0)), 0.0, 0.95)
		if execute_threshold > 0.0 and target_hp_before / target_max_hp <= execute_threshold:
			raw_damage *= 2.0

		# M5-Boss 机制扩展：允许关卡机制给特定单位施加“额外输出系数”。
		var stage_outgoing_bonus: float = _get_stage_meta_float("stage_outgoing_damage_bonus", 0.0)
		raw_damage *= maxf(1.0 + stage_outgoing_bonus, 0.0)

	var receive_result: Dictionary = target_combat.call(
		"receive_damage",
		raw_damage,
		owner_unit,
		damage_type,
		use_skill,
		is_crit,
		is_dodged
	)

	# 攻击后的内力变化：
	# - 技能：消耗内力。
	# - 普攻命中：回内力。
	_apply_attack_resource_changes(use_skill, is_dodged)
	var dealt_damage: float = float(receive_result.get("damage", 0.0))
	if not is_dodged and dealt_damage > 0.0:
		_apply_vampire_lifesteal(dealt_damage, use_skill)

	_attack_cd = attack_interval
	var event: Dictionary = _build_attack_event(receive_result, use_skill, is_dodged, is_crit, damage_type)
	attacked.emit(owner_unit, target, event)
	return event


func receive_damage(
	amount: float,
	source: Node,
	_damage_type: String = "external",
	_is_skill: bool = false,
	_is_crit: bool = false,
	_is_dodged: bool = false,
	_can_trigger_thorns: bool = true
) -> Dictionary:
	if not is_alive:
		return {
			"damage": 0.0,
			"target_died": true,
			"target_hp_after": current_hp,
			"target_mp_after": current_mp,
			"shield_absorbed": 0.0,
			"shield_hp_after": shield_hp,
			"shield_broken": false,
			"immune_absorbed": 0.0
		}

	# M5：护盾优先吸收伤害，保留旧 stage_shield_hp 元数据兼容。
	var total_shield_before: float = get_current_shield()
	var shield_absorbed: float = 0.0
	var shield_broken: bool = false
	if total_shield_before > 0.0 and not _is_dodged:
		var incoming: float = maxf(amount, 0.0)
		shield_absorbed = minf(incoming, total_shield_before)
		incoming = maxf(incoming - shield_absorbed, 0.0)
		var total_shield_after: float = maxf(total_shield_before - shield_absorbed, 0.0)
		_set_shield_value(total_shield_after)
		shield_broken = total_shield_before > 0.0 and total_shield_after <= 0.0
		amount = incoming
		if incoming <= 0.0:
			var shield_event: Dictionary = {
				"damage": 0.0,
				"target_died": false,
				"target_hp_after": current_hp,
				"target_mp_after": current_mp,
				"shield_absorbed": shield_absorbed,
				"shield_hp_after": get_current_shield(),
				"shield_broken": shield_broken,
				"immune_absorbed": 0.0
			}
			damaged.emit(owner_unit, source, shield_event)
			return shield_event

	# M5-Boss 机制扩展：免伤开关（例如部分 Boss 相位）。
	if _get_stage_meta_bool("stage_damage_immune", false):
		var immune_absorbed: float = maxf(amount, 0.0)
		var immune_event: Dictionary = {
			"damage": 0.0,
			"target_died": false,
			"target_hp_after": current_hp,
			"target_mp_after": current_mp,
			"shield_absorbed": shield_absorbed,
			"shield_hp_after": get_current_shield(),
			"shield_broken": shield_broken,
			"immune_absorbed": immune_absorbed
		}
		damaged.emit(owner_unit, source, immune_event)
		return immune_event

	var final_damage: float = 0.0
	if not _is_dodged:
		final_damage = maxf(amount, 0.0)
		final_damage = maxf(final_damage - float(_external_modifiers.get("damage_reduce_flat", 0.0)), 0.0)
		var reduce_ratio: float = clampf(float(_external_modifiers.get("damage_reduce_percent", 0.0)), -0.95, 0.95)
		final_damage *= (1.0 - reduce_ratio)
		# M5-Boss 机制扩展：易伤/减伤倍率（默认 1.0）。
		final_damage *= maxf(_get_stage_meta_float("stage_damage_taken_multiplier", 1.0), 0.0)
		current_hp = maxf(current_hp - final_damage, 0.0)
		add_mp(mp_gain_on_hit)

		if _can_trigger_thorns and _damage_type == "external" and final_damage > 0.0 and source != null and is_instance_valid(source):
			_apply_thorns_reflect(source, final_damage)

	var dead_now: bool = false
	if current_hp <= 0.0:
		is_alive = false
		dead_now = true
		died.emit(owner_unit, source)

	var event: Dictionary = {
		"damage": final_damage,
		"target_died": dead_now,
		"target_hp_after": current_hp,
		"target_mp_after": current_mp,
		"shield_absorbed": shield_absorbed,
		"shield_hp_after": get_current_shield(),
		"shield_broken": shield_broken,
		"immune_absorbed": 0.0
	}
	damaged.emit(owner_unit, source, event)
	return event


func apply_damage(amount: float) -> float:
	var result: Dictionary = receive_damage(amount, null, "external", false, false, false)
	return float(result.get("damage", 0.0))


func restore_hp(amount: float) -> float:
	var before: float = current_hp
	current_hp = minf(current_hp + maxf(amount, 0.0), max_hp)
	if current_hp > 0.0:
		is_alive = true
	return maxf(current_hp - before, 0.0)


func add_mp(amount: float) -> void:
	current_mp = clampf(current_mp + amount, 0.0, max_mp)


func add_shield(amount: float) -> float:
	var delta: float = maxf(amount, 0.0)
	if delta <= 0.0:
		return get_current_shield()
	_set_shield_value(get_current_shield() + delta)
	return get_current_shield()


func clear_shield() -> void:
	_set_shield_value(0.0)


func get_current_shield() -> float:
	var legacy_meta: float = _get_stage_meta_float("stage_shield_hp", 0.0)
	return maxf(maxf(shield_hp, legacy_meta), 0.0)


func get_attack_range_world(hex_size: float = 26.0) -> float:
	# 把“格子攻击范围”换算为世界半径，便于 CombatManager 做距离判断。
	var range_cells: float = maxf(_get_owner_stat("rng") + float(_external_modifiers.get("range_add", 0.0)), 1.0)
	return maxf(range_cells * hex_size * 1.2, hex_size * 0.85)


func get_attack_range_cells() -> int:
	# 严格六角格战斗：攻击距离统一按“格子数”判定。
	# 为避免“全员超远射程”造成观感失真，默认对最终射程做上限约束。
	var range_cells: float = _get_owner_stat("rng") + float(_external_modifiers.get("range_add", 0.0))
	var min_cells: int = maxi(attack_range_min_cells, 1)
	var max_cells: int = maxi(attack_range_max_cells, min_cells)
	return clampi(int(range_cells), min_cells, max_cells)


func get_max_effective_range_cells() -> int:
	# M5 预留接口：
	# 目标是把“可立即释放的技能射程”也纳入有效射程判定，避免角色已能放远程技能
	# 却继续贴脸移动的错误行为。当前阶段先回落到普攻射程，后续接 GongfaManager。
	return get_attack_range_cells()


func refresh_runtime_stats(runtime_stats: Dictionary, preserve_ratio: bool = true) -> void:
	var hp_ratio: float = 1.0
	var mp_ratio: float = 0.35
	if preserve_ratio:
		if max_hp > 0.0:
			hp_ratio = clampf(current_hp / max_hp, 0.0, 1.0)
		if max_mp > 0.0:
			mp_ratio = clampf(current_mp / max_mp, 0.0, 1.0)

	max_hp = maxf(float(runtime_stats.get("hp", 1.0)), 1.0)
	max_mp = maxf(float(runtime_stats.get("mp", 0.0)), 0.0)
	current_hp = max_hp if not preserve_ratio else max_hp * hp_ratio
	current_mp = clampf(max_mp * 0.35, 0.0, max_mp) if not preserve_ratio else max_mp * mp_ratio
	current_hp = clampf(current_hp, 0.0, max_hp)
	current_mp = clampf(current_mp, 0.0, max_mp)

	_rebuild_attack_interval(runtime_stats)
	skill_mp_cost = clampf(max_mp * 0.6, 20.0, 120.0)
	is_alive = current_hp > 0.0


func set_external_modifiers(modifiers: Dictionary) -> void:
	_external_modifiers = DEFAULT_EXTERNAL_MODIFIERS.duplicate(true)
	for key in modifiers.keys():
		_external_modifiers[key] = modifiers[key]
	if owner_unit != null and is_instance_valid(owner_unit):
		refresh_runtime_stats(owner_unit.get("runtime_stats"), true)


func get_external_modifiers() -> Dictionary:
	return _external_modifiers.duplicate(true)


func _rebuild_attack_interval(runtime_stats: Dictionary) -> void:
	var spd: float = maxf(float(runtime_stats.get("spd", 60.0)), 1.0)
	var base_interval: float = clampf(1.8 - spd / 120.0, 0.24, 2.2)
	var speed_bonus: float = clampf(float(_external_modifiers.get("attack_speed_bonus", 0.0)), -0.8, 0.9)
	# 攻速加成为“间隔缩短百分比”，例如 0.2 => 间隔 * 0.8。
	attack_interval = clampf(base_interval * (1.0 - speed_bonus), 0.08, 3.0)


func _get_target_combat(target: Node) -> Node:
	if target == null or not is_instance_valid(target):
		return null
	return target.get_node_or_null("Components/UnitCombat")


func _get_attack_multiplier(use_skill: bool) -> float:
	return skill_multiplier if use_skill else normal_multiplier


func _calc_dodge_rate(attacker_spd: float, target_spd: float, target_modifiers: Dictionary) -> float:
	var dodge_rate: float = 0.0
	if target_spd > 0.0:
		dodge_rate = clampf((target_spd - attacker_spd) / (target_spd + 100.0), 0.0, 0.4)
	return clampf(dodge_rate + float(target_modifiers.get("dodge_bonus", 0.0)), 0.0, 0.75)


func _calc_crit_rate() -> float:
	return clampf(
		0.05 + _get_owner_stat("wis") * 0.001 + float(_external_modifiers.get("crit_bonus", 0.0)),
		0.05,
		0.8
	)


func _calc_crit_multiplier() -> float:
	return 1.5 + _get_owner_stat("wis") * 0.0005 + float(_external_modifiers.get("crit_damage_bonus", 0.0))


func _apply_attack_resource_changes(use_skill: bool, is_dodged: bool) -> void:
	if use_skill:
		add_mp(-skill_mp_cost)
	elif not is_dodged:
		add_mp(mp_gain_on_attack)


func _build_attack_event(
	receive_result: Dictionary,
	use_skill: bool,
	is_dodged: bool,
	is_crit: bool,
	damage_type: String
) -> Dictionary:
	return {
		"performed": true,
		"is_skill": use_skill,
		"is_dodged": is_dodged,
		"is_crit": is_crit,
		"damage_type": damage_type,
		"damage": float(receive_result.get("damage", 0.0)),
		"target_died": bool(receive_result.get("target_died", false)),
		"target_hp_after": float(receive_result.get("target_hp_after", 0.0)),
		"target_mp_after": float(receive_result.get("target_mp_after", 0.0)),
		"attacker_hp_after": current_hp,
		"attacker_mp_after": current_mp
	}


func _select_attack_profile(use_skill: bool) -> Dictionary:
	var atk: float = _get_owner_stat("atk")
	var iat: float = _get_owner_stat("iat")

	# 简化策略：
	# - 技能优先内功轨道（若内功明显不足，再回退外功）。
	# - 普攻优先外功轨道（若外功明显不足，再回退内功）。
	if use_skill:
		if iat >= atk * 0.6:
			return {
				"offense": iat,
				"damage_type": "internal"
			}
		return {
			"offense": atk,
			"damage_type": "external"
		}

	if atk >= iat * 0.8:
		return {
			"offense": atk,
			"damage_type": "external"
		}

	return {
		"offense": iat,
		"damage_type": "internal"
	}


func _get_owner_stat(stat_key: String) -> float:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return 0.0
	var stats: Dictionary = owner_unit.get("runtime_stats")
	var base_value: float = maxf(float(stats.get(stat_key, 0.0)), 0.0)
	return maxf(base_value + _get_conditional_stat_bonus(stat_key), 0.0)


func _get_conditional_stat_bonus(stat_key: String) -> float:
	var bonus: float = 0.0
	var entries_value: Variant = _external_modifiers.get("conditional_stats", [])
	if not (entries_value is Array):
		return 0.0
	for entry_value in (entries_value as Array):
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("stat", "")).strip_edges() != stat_key:
			continue
		if not _is_condition_met(entry):
			continue
		bonus += float(entry.get("value", 0.0))
	return bonus


func _is_condition_met(entry: Dictionary) -> bool:
	var condition: String = str(entry.get("condition", "")).strip_edges().to_lower()
	var threshold: float = float(entry.get("threshold", 0.0))
	match condition:
		"hp_below":
			return max_hp > 0.0 and current_hp / max_hp <= threshold
		"hp_above":
			return max_hp > 0.0 and current_hp / max_hp >= threshold
		"mp_below":
			return max_mp > 0.0 and current_mp / max_mp <= threshold
		"mp_above":
			return max_mp > 0.0 and current_mp / max_mp >= threshold
		_:
			return false


func _get_target_debuff_ids(target: Node) -> Array:
	if target == null or not is_instance_valid(target):
		return []
	var debuffs_value: Variant = target.get_meta("active_debuff_ids", [])
	if debuffs_value is Array:
		return (debuffs_value as Array).duplicate()
	return []


func _calc_debuff_damage_amp_ratio(target_debuff_ids: Array) -> float:
	var ratio: float = 1.0
	var any_bonus: float = float(_external_modifiers.get("damage_amp_vs_any_debuff", 0.0))
	var debuff_count: int = target_debuff_ids.size()
	if any_bonus != 0.0 and debuff_count > 0:
		ratio *= maxf(1.0 + any_bonus, 0.0)

	var map_value: Variant = _external_modifiers.get("damage_amp_vs_debuff_map", {})
	if map_value is Dictionary and debuff_count > 0:
		var amp_map: Dictionary = map_value
		for debuff_id in target_debuff_ids:
			var id_str: String = str(debuff_id).strip_edges()
			if id_str.is_empty():
				continue
			if not amp_map.has(id_str):
				continue
			ratio *= maxf(1.0 + float(amp_map.get(id_str, 0.0)), 0.0)
	return ratio


func _apply_vampire_lifesteal(dealt_damage: float, used_skill: bool) -> void:
	if used_skill:
		return
	var vampire_ratio: float = clampf(float(_external_modifiers.get("vampire", 0.0)), 0.0, 5.0)
	if vampire_ratio <= 0.0:
		return
	var healed: float = restore_hp(dealt_damage * vampire_ratio)
	if healed > 0.0 and owner_unit != null and is_instance_valid(owner_unit):
		healing_performed.emit(owner_unit, owner_unit, healed, "vampire")


func _apply_thorns_reflect(source: Node, taken_damage: float) -> void:
	if source == null or not is_instance_valid(source):
		return
	var source_combat: Node = source.get_node_or_null("Components/UnitCombat")
	if source_combat == null or not bool(source_combat.get("is_alive")):
		return
	var thorns_percent: float = maxf(float(_external_modifiers.get("thorns_percent", 0.0)), 0.0)
	var thorns_flat: float = maxf(float(_external_modifiers.get("thorns_flat", 0.0)), 0.0)
	var reflect_damage: float = taken_damage * thorns_percent + thorns_flat
	if reflect_damage <= 0.0:
		return
	var reflect_result_value: Variant = source_combat.call(
		"receive_damage",
		reflect_damage,
		owner_unit,
		"external",
		false,
		false,
		false,
		false
	)
	var reflect_event: Dictionary = {
		"damage": reflect_damage,
		"shield_absorbed": 0.0,
		"immune_absorbed": 0.0
	}
	if reflect_result_value is Dictionary:
		reflect_event["damage"] = float((reflect_result_value as Dictionary).get("damage", 0.0))
		reflect_event["shield_absorbed"] = float((reflect_result_value as Dictionary).get("shield_absorbed", 0.0))
		reflect_event["immune_absorbed"] = float((reflect_result_value as Dictionary).get("immune_absorbed", 0.0))
	if owner_unit != null and is_instance_valid(owner_unit):
		thorns_damage_dealt.emit(owner_unit, source, reflect_event)


func _is_silenced() -> bool:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return false
	if bool(owner_unit.get_meta("status_silenced", false)):
		return true
	var until_time: float = float(owner_unit.get_meta("status_silence_until", 0.0))
	var now_sec: float = float(Time.get_ticks_msec()) * 0.001
	if until_time > now_sec:
		return true
	if until_time > 0.0:
		owner_unit.remove_meta("status_silence_until")
	var debuffs: Array = _get_target_debuff_ids(owner_unit)
	return debuffs.has("debuff_silence")


func _is_stunned() -> bool:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return false
	if bool(owner_unit.get_meta("status_stunned", false)):
		return true
	var debuffs: Array = _get_target_debuff_ids(owner_unit)
	return debuffs.has("debuff_freeze") or debuffs.has("debuff_stun")


func _consume_force_crit_on_target(target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if bool(target.get_meta("status_frozen_force_crit", false)):
		target.remove_meta("status_frozen_force_crit")
		return true
	return false


func _get_target_stat(target: Node, stat_key: String) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var stats: Dictionary = target.get("runtime_stats")
	return maxf(float(stats.get(stat_key, 0.0)), 0.0)


func _randf(rng_source: Variant) -> float:
	if rng_source != null and is_instance_valid(rng_source):
		var rng: RandomNumberGenerator = rng_source as RandomNumberGenerator
		if rng != null:
			return rng.randf()
	return randf()


func _get_stage_meta_float(meta_key: String, fallback: float) -> float:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return fallback
	return float(owner_unit.get_meta(meta_key, fallback))


func _get_stage_meta_bool(meta_key: String, fallback: bool) -> bool:
	if owner_unit == null or not is_instance_valid(owner_unit):
		return fallback
	return bool(owner_unit.get_meta(meta_key, fallback))


func _set_shield_value(value: float) -> void:
	var next_value: float = maxf(value, 0.0)
	shield_hp = next_value
	max_shield_hp = maxf(max_shield_hp, next_value)
	if next_value <= 0.0:
		max_shield_hp = 0.0
	if owner_unit != null and is_instance_valid(owner_unit):
		# 保留旧字段兼容，避免仍在读取 meta 的老逻辑失效。
		owner_unit.set_meta("stage_shield_hp", next_value)
