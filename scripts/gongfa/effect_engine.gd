extends RefCounted
class_name GongfaEffectEngine

# ===========================
# 功法效果执行引擎（M3）
# ===========================
# 设计说明：
# 1. 将“效果字典(op + 参数)”翻译为可执行逻辑，避免业务层硬编码分散。
# 2. 被动效果与主动效果分离，便于战前构建属性、战中即时结算。
# 3. 对未实现 op 采用安全降级（打印告警 + 跳过），保证 Mod 异常不致崩溃。

const DEFAULT_HEX_SIZE: float = 26.0


func create_empty_modifier_bundle() -> Dictionary:
	# 这些字段是 UnitCombat 的“外部修正层”，不会直接写回 runtime_stats。
	return {
		"mp_regen_add": 0.0,
		"damage_reduce_flat": 0.0,
		"damage_reduce_percent": 0.0,
		"dodge_bonus": 0.0,
		"crit_bonus": 0.0,
		"crit_damage_bonus": 0.0,
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


func execute_active_effects(source: Node, target: Node, effects: Array, context: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = {
		"damage_total": 0.0,
		"heal_total": 0.0,
		"buff_applied": 0,
		"debuff_applied": 0
	}
	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value as Dictionary
		_execute_active_op(source, target, effect, context, summary)
	return summary


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

		_:
			push_warning("EffectEngine: 未实现的被动 op=%s" % op)


func _execute_active_op(source: Node, target: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	var op: String = str(effect.get("op", "")).strip_edges()
	if op.is_empty():
		return

	match op:
		"damage_target":
			var dmg: float = float(effect.get("value", 0.0))
			var mul: float = float(effect.get("multiplier", 1.0))
			var damage_type: String = str(effect.get("damage_type", "internal"))
			var dealt: float = _deal_damage(source, target, dmg * mul, damage_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt

		"damage_aoe":
			var radius_cells: float = float(effect.get("radius", 2.0))
			var base_damage: float = float(effect.get("value", 0.0))
			var damage_type_aoe: String = str(effect.get("damage_type", "internal"))
			var radius_world: float = _cells_to_world_distance(radius_cells, context)
			var center: Vector2 = _node_pos(source)
			var targets: Array[Node] = _collect_enemy_units_in_radius(source, center, radius_world, context)
			for enemy in targets:
				var dealt_aoe: float = _deal_damage(source, enemy, base_damage, damage_type_aoe)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_aoe

		"heal_self":
			var heal_value: float = float(effect.get("value", 0.0))
			var healed: float = _heal_unit(source, heal_value)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed

		"heal_self_percent":
			var ratio: float = float(effect.get("value", 0.0))
			var max_hp: float = _get_combat_value(source, "max_hp")
			var healed_percent: float = _heal_unit(source, max_hp * ratio)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_percent

		"heal_allies_aoe":
			var heal_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var heal_amount: float = float(effect.get("value", 0.0))
			var heal_center: Vector2 = _node_pos(source)
			var allies: Array[Node] = _collect_ally_units_in_radius(source, heal_center, heal_radius, context)
			for ally in allies:
				var healed_ally: float = _heal_unit(ally, heal_amount)
				summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_ally

		"buff_self":
			if _apply_buff_op(source, source, effect, context):
				summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1

		"buff_allies_aoe":
			var buff_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var buff_allies: Array[Node] = _collect_ally_units_in_radius(source, _node_pos(source), buff_radius, context)
			for ally_buff in buff_allies:
				if _apply_buff_op(source, ally_buff, effect, context):
					summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1

		"debuff_target":
			if _apply_buff_op(source, target, effect, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1

		"debuff_aoe":
			var debuff_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var enemies: Array[Node] = _collect_enemy_units_in_radius(source, _node_pos(source), debuff_radius, context)
			for enemy in enemies:
				if _apply_buff_op(source, enemy, effect, context):
					summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1

		"spawn_vfx":
			_spawn_vfx_by_effect(source, target, effect, context)

		# 下列 op 先保留接口；后续 M3.1 补完位移/召唤/嘲讽等行为细节。
		"teleport_behind", "dash_forward", "knockback_target", "summon_clone", "revive_random_ally", "taunt_aoe":
			push_warning("EffectEngine: op=%s 已预留，当前版本暂未实现。" % op)

		_:
			push_warning("EffectEngine: 未实现的主动 op=%s" % op)


func _add_modifier(modifier_bundle: Dictionary, key: String, value: float) -> void:
	modifier_bundle[key] = float(modifier_bundle.get(key, 0.0)) + value


func _deal_damage(source: Node, target: Node, amount: float, damage_type: String) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var combat: Node = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	var result: Dictionary = combat.call(
		"receive_damage",
		maxf(amount, 0.0),
		source,
		damage_type,
		true,
		false,
		false
	)
	return float(result.get("damage", 0.0))


func _heal_unit(target: Node, amount: float) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var combat: Node = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	var before: float = float(combat.get("current_hp"))
	combat.call("restore_hp", maxf(amount, 0.0))
	var after: float = float(combat.get("current_hp"))
	return maxf(after - before, 0.0)


func _apply_buff_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null:
		return false
	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return false
	var duration: float = float(effect.get("duration", 0.0))
	return bool(buff_manager.call("apply_buff", target, buff_id, duration, source))


func _spawn_vfx_by_effect(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> void:
	var vfx_factory: Node = context.get("vfx_factory", null)
	if vfx_factory == null:
		return
	var vfx_id: String = str(effect.get("vfx_id", "")).strip_edges()
	if vfx_id.is_empty():
		return

	var at: String = str(effect.get("at", "self"))
	var from_pos: Vector2 = _node_pos(source)
	var to_pos: Vector2 = _node_pos(target)
	match at:
		"target":
			from_pos = _node_pos(source)
			to_pos = _node_pos(target)
		"aoe_center":
			from_pos = _node_pos(source)
			to_pos = _node_pos(source)
		_:
			from_pos = _node_pos(source)
			to_pos = _node_pos(source)

	vfx_factory.call("play_attack_vfx", vfx_id, from_pos, to_pos)


func _collect_enemy_units_in_radius(source: Node, center: Vector2, radius_world: float, context: Dictionary) -> Array[Node]:
	var enemies: Array[Node] = []
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	for unit in _get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if unit == source:
			continue
		if source_team != 0 and int(unit.get("team_id")) == source_team:
			continue
		if _distance_sq(_node_pos(unit), center) > radius_world * radius_world:
			continue
		if not _is_unit_alive(unit):
			continue
		enemies.append(unit)
	return enemies


func _collect_ally_units_in_radius(source: Node, center: Vector2, radius_world: float, context: Dictionary) -> Array[Node]:
	var allies: Array[Node] = []
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	for unit in _get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) != source_team:
			continue
		if _distance_sq(_node_pos(unit), center) > radius_world * radius_world:
			continue
		if not _is_unit_alive(unit):
			continue
		allies.append(unit)
	return allies


func _get_all_units(context: Dictionary) -> Array[Node]:
	var output: Array[Node] = []
	var all_units: Variant = context.get("all_units", [])
	if all_units is Array:
		for unit in all_units:
			output.append(unit)
	return output


func _cells_to_world_distance(cells: float, context: Dictionary) -> float:
	var hex_size: float = float(context.get("hex_size", DEFAULT_HEX_SIZE))
	return maxf(cells, 0.0) * maxf(hex_size, 1.0) * 1.2


func _is_unit_alive(unit: Node) -> bool:
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return false
	return bool(combat.get("is_alive"))


func _get_combat_value(unit: Node, key: String) -> float:
	if unit == null or not is_instance_valid(unit):
		return 0.0
	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	return float(combat.get(key))


func _node_pos(node: Node) -> Vector2:
	if node == null or not is_instance_valid(node):
		return Vector2.ZERO
	var n2d: Node2D = node as Node2D
	if n2d == null:
		return Vector2.ZERO
	return n2d.position


func _distance_sq(a: Vector2, b: Vector2) -> float:
	return a.distance_squared_to(b)
