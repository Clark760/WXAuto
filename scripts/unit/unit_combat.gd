extends Node

# ===========================
# 角色战斗组件（M2）
# ===========================
# 设计目标：
# 1. 将战斗数值与公式集中在组件内，外部管理器只负责调度与目标分配。
# 2. 同时支持“普攻”和“技能”两条伤害轨道（外功/内功）。
# 3. 实现总纲要求的闪避/暴击/内力机制，并保持与 M1 组件接口兼容。

signal attacked(attacker: Node, target: Node, event: Dictionary)
signal damaged(target: Node, source: Node, event: Dictionary)
signal died(unit: Node, killer: Node)

var owner_unit: Node = null
var is_alive: bool = true

var current_hp: float = 0.0
var current_mp: float = 0.0
var max_hp: float = 1.0
var max_mp: float = 0.0

var attack_interval: float = 0.8
var _attack_cd: float = 0.0

var normal_multiplier: float = 1.0
var skill_multiplier: float = 1.6
var skill_mp_cost: float = 60.0

var mp_gain_on_attack: float = 15.0
var mp_gain_on_hit: float = 10.0
var passive_mp_regen: float = 2.0

# 外部修正层（功法/联动/Buff 汇总）：
# 由 GongfaManager 注入，避免把 M3 逻辑耦合进基础战斗流程。
const DEFAULT_EXTERNAL_MODIFIERS: Dictionary = {
	"mp_regen_add": 0.0,
	"damage_reduce_flat": 0.0,
	"damage_reduce_percent": 0.0,
	"dodge_bonus": 0.0,
	"crit_bonus": 0.0,
	"crit_damage_bonus": 0.0,
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

	# 技能蓝耗按最大内力比例估算，保证不同角色可自然触发技能。
	skill_mp_cost = clampf(max_mp * 0.6, 20.0, 120.0)
	is_alive = current_hp > 0.0


func prepare_for_battle() -> void:
	# 进入战斗时重置冷却，不清空 HP/MP（预留未来“战前状态继承”扩展点）。
	_attack_cd = 0.0


func tick_logic(delta: float) -> void:
	if not is_alive:
		return
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	add_mp((passive_mp_regen + float(_external_modifiers.get("mp_regen_add", 0.0))) * delta)


func can_attack() -> bool:
	return is_alive and _attack_cd <= 0.0


func try_attack_target(target: Node, rng_source: Variant = null) -> Dictionary:
	if owner_unit == null:
		return {}
	if not is_alive:
		return {"performed": false, "reason": "dead"}
	if not can_attack():
		return {"performed": false, "reason": "cooldown"}
	if target == null or not is_instance_valid(target):
		return {"performed": false, "reason": "invalid_target"}

	var target_combat: Node = target.get_node_or_null("Components/UnitCombat")
	if target_combat == null:
		return {"performed": false, "reason": "target_no_combat"}
	if not bool(target_combat.get("is_alive")):
		return {"performed": false, "reason": "target_dead"}

	var use_skill: bool = current_mp >= skill_mp_cost and max_mp > 0.0
	var attack_stats: Dictionary = _select_attack_profile(use_skill)

	var offense: float = float(attack_stats.get("offense", 1.0))
	var damage_type: String = str(attack_stats.get("damage_type", "external"))
	var defense: float = _get_target_stat(target, "def")
	if damage_type == "internal":
		defense = _get_target_stat(target, "idr")
	var multiplier: float = skill_multiplier if use_skill else normal_multiplier

	var attacker_spd: float = _get_owner_stat("spd")
	var target_spd: float = _get_target_stat(target, "spd")

	# 总纲公式：闪避率 = (自身SPD - 对方SPD) / (自身SPD + 100)，限制 [0, 40%]。
	# 这里“自身”按防守方理解，因此以 target_spd 为分子主项。
	var dodge_rate: float = 0.0
	if target_spd > 0.0:
		dodge_rate = clampf((target_spd - attacker_spd) / (target_spd + 100.0), 0.0, 0.4)
	var target_modifiers: Dictionary = {}
	if target_combat.has_method("get_external_modifiers"):
		target_modifiers = target_combat.call("get_external_modifiers")
	dodge_rate = clampf(dodge_rate + float(target_modifiers.get("dodge_bonus", 0.0)), 0.0, 0.75)

	var rng_value_dodge: float = _randf(rng_source)
	var is_dodged: bool = rng_value_dodge < dodge_rate
	var is_crit: bool = false
	var raw_damage: float = 0.0

	if not is_dodged:
		var random_factor: float = lerpf(0.9, 1.1, _randf(rng_source))
		raw_damage = offense * multiplier * (100.0 / (100.0 + maxf(defense, 0.0))) * random_factor

		var crit_rate: float = clampf(
			0.05 + _get_owner_stat("wis") * 0.001 + float(_external_modifiers.get("crit_bonus", 0.0)),
			0.05,
			0.8
		)
		is_crit = _randf(rng_source) < crit_rate
		if is_crit:
			var crit_multiplier: float = 1.5 + _get_owner_stat("wis") * 0.0005 + float(_external_modifiers.get("crit_damage_bonus", 0.0))
			raw_damage *= crit_multiplier

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
	if use_skill:
		add_mp(-skill_mp_cost)
	elif not is_dodged:
		add_mp(mp_gain_on_attack)

	_attack_cd = attack_interval

	var event: Dictionary = {
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
	attacked.emit(owner_unit, target, event)
	return event


func receive_damage(
	amount: float,
	source: Node,
	_damage_type: String = "external",
	_is_skill: bool = false,
	_is_crit: bool = false,
	_is_dodged: bool = false
) -> Dictionary:
	if not is_alive:
		return {
			"damage": 0.0,
			"target_died": true,
			"target_hp_after": current_hp,
			"target_mp_after": current_mp
		}

	var final_damage: float = 0.0
	if not _is_dodged:
		final_damage = maxf(amount, 0.0)
		final_damage = maxf(final_damage - float(_external_modifiers.get("damage_reduce_flat", 0.0)), 0.0)
		var reduce_ratio: float = clampf(float(_external_modifiers.get("damage_reduce_percent", 0.0)), 0.0, 0.95)
		final_damage *= (1.0 - reduce_ratio)
		current_hp = maxf(current_hp - final_damage, 0.0)
		add_mp(mp_gain_on_hit)

	var dead_now: bool = false
	if current_hp <= 0.0:
		is_alive = false
		dead_now = true
		died.emit(owner_unit, source)

	var event: Dictionary = {
		"damage": final_damage,
		"target_died": dead_now,
		"target_hp_after": current_hp,
		"target_mp_after": current_mp
	}
	damaged.emit(owner_unit, source, event)
	return event


func apply_damage(amount: float) -> float:
	var result: Dictionary = receive_damage(amount, null, "external", false, false, false)
	return float(result.get("damage", 0.0))


func restore_hp(amount: float) -> void:
	current_hp = minf(current_hp + maxf(amount, 0.0), max_hp)
	if current_hp > 0.0:
		is_alive = true


func add_mp(amount: float) -> void:
	current_mp = clampf(current_mp + amount, 0.0, max_mp)


func get_attack_range_world(hex_size: float = 26.0) -> float:
	# 把“格子攻击范围”换算为世界半径，便于 CombatManager 做距离判断。
	var range_cells: float = maxf(_get_owner_stat("rng") + float(_external_modifiers.get("range_add", 0.0)), 1.0)
	return maxf(range_cells * hex_size * 1.2, hex_size * 0.85)


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
	_external_modifiers = modifiers.duplicate(true)
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
	return maxf(float(stats.get(stat_key, 0.0)), 0.0)


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
