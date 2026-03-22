extends RefCounted
class_name GongfaEffectEngine

# ===========================
# 功法效果执行引擎
# ===========================
# 设计说明：
# 1. 将“效果字典(op + 参数)”翻译为可执行逻辑，避免业务层硬编码分散。
# 2. 被动效果与主动效果分离，便于战前构建属性、战中即时结算。
# 3. 对未实现 op 采用安全降级（打印告警 + 跳过），保证 Mod 异常不致崩溃。

const DEFAULT_HEX_SIZE: float = 26.0
var _last_damage_meta: Dictionary = {}


func create_empty_modifier_bundle() -> Dictionary:
	# 这些字段是 UnitCombat 的“外部修正层”，不会直接写回 runtime_stats。
	return {
		"mp_regen_add": 0.0,
		# 生命回复同样放在外部修正层，按秒结算，避免污染基础面板数值。
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


func execute_active_effects(source: Node, target: Node, effects: Array, context: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = {
		"damage_total": 0.0,
		"heal_total": 0.0,
		"mp_total": 0.0,
		"summon_total": 0,
		"hazard_total": 0,
		"buff_applied": 0,
		"debuff_applied": 0,
		# 详细事件列表用于外层日志系统：
		# - damage_events：记录每次实际造成的伤害目标/数值/类型/来源 op
		# - heal_events：记录每次实际治疗目标/数值/来源 op
		# - buff_events：记录每次实际施加的 Buff 目标/ID/持续时间/来源 op
		"damage_events": [],
		"heal_events": [],
		"mp_events": [],
		"buff_events": []
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

		# 兼容旧数据：hp_regen / hp_regen_add 都归一到每秒生命回复外部修正。
		"hp_regen", "hp_regen_add":
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

		# 兼容旧版被动写法：直接用属性名作为 op（如 atk、iat、hp）。
		# 语义规则：
		# 1) mode=add/percent 可显式指定。
		# 2) mode=auto（默认）时，|value|<=1 且属于常见百分比属性，则按百分比处理；
		#    否则按平加处理。这样可同时兼容「iat=0.3」和「iat=150」两类老数据。
		"hp", "mp", "atk", "def", "iat", "idr", "spd", "wis", "rng", "mov":
			_apply_legacy_stat_alias(runtime_stats, effect, op, stack_multiplier)

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
			_append_damage_event(summary, source, target, dealt, damage_type, op)

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
				_append_damage_event(summary, source, enemy, dealt_aoe, damage_type_aoe, op)

		"heal_self":
			var heal_value: float = float(effect.get("value", 0.0))
			var healed: float = _heal_unit(source, heal_value, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed
			_append_heal_event(summary, source, source, healed, op)

		"heal_self_percent":
			var ratio: float = float(effect.get("value", 0.0))
			var max_hp: float = _get_combat_value(source, "max_hp")
			var healed_percent: float = _heal_unit(source, max_hp * ratio, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_percent
			_append_heal_event(summary, source, source, healed_percent, op)

		"heal_allies_aoe":
			var heal_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var heal_amount: float = float(effect.get("value", 0.0))
			var heal_center: Vector2 = _node_pos(source)
			var allies: Array[Node] = _collect_ally_units_in_radius(source, heal_center, heal_radius, context)
			for ally in allies:
				var healed_ally: float = _heal_unit(ally, heal_amount, source)
				summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_ally
				_append_heal_event(summary, source, ally, healed_ally, op)

		# 周期回蓝效果会走主动执行链路；这里按“立即回复内力”处理。
		"mp_regen_add":
			var mp_target: Node = target if target != null and is_instance_valid(target) else source
			var restored_mp: float = _restore_mp_unit(mp_target, float(effect.get("value", 0.0)))
			summary["mp_total"] = float(summary.get("mp_total", 0.0)) + restored_mp
			_append_mp_event(summary, source, mp_target, restored_mp, op)

		"buff_self":
			if _apply_buff_op(source, source, effect, context):
				summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
				_append_buff_event(summary, source, source, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"buff_allies_aoe":
			var buff_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var buff_allies: Array[Node] = _collect_ally_units_in_radius(source, _node_pos(source), buff_radius, context)
			for ally_buff in buff_allies:
				if _apply_buff_op(source, ally_buff, effect, context):
					summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
					_append_buff_event(summary, source, ally_buff, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"debuff_target":
			if _apply_buff_op(source, target, effect, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_append_buff_event(summary, source, target, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"debuff_aoe":
			var debuff_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var enemies: Array[Node] = _collect_enemy_units_in_radius(source, _node_pos(source), debuff_radius, context)
			for enemy in enemies:
				if _apply_buff_op(source, enemy, effect, context):
					summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
					_append_buff_event(summary, source, enemy, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"damage_target_scaling":
			var scale_base: float = float(effect.get("value", 0.0))
			var scale_stat: String = str(effect.get("scale_stat", "max_hp")).strip_edges().to_lower()
			var scale_ratio: float = float(effect.get("scale_ratio", 0.0))
			var scale_source_pref: String = str(effect.get("scale_source", "auto")).strip_edges().to_lower()
			var scale_node: Node = source
			if scale_source_pref == "target" or ((scale_stat == "max_hp" or scale_stat == "current_hp") and target != null and is_instance_valid(target)):
				scale_node = target
			var scale_value: float = _resolve_scale_stat_value(scale_node, scale_stat)
			var scaled_damage: float = maxf(scale_base + scale_value * scale_ratio, 0.0)
			var scaling_type: String = str(effect.get("damage_type", "internal"))
			var dealt_scaling: float = _deal_damage(source, target, scaled_damage, scaling_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_scaling
			_append_damage_event(summary, source, target, dealt_scaling, scaling_type, op)

		"damage_if_debuffed":
			var base_if_debuffed: float = float(effect.get("value", 0.0))
			var bonus_mul: float = maxf(float(effect.get("bonus_multiplier", 1.0)), 0.0)
			var need_debuff: String = str(effect.get("require_debuff", "")).strip_edges()
			if _target_has_debuff(target, need_debuff):
				base_if_debuffed *= bonus_mul
			var if_debuff_type: String = str(effect.get("damage_type", "internal"))
			var dealt_if_debuffed: float = _deal_damage(source, target, base_if_debuffed, if_debuff_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_if_debuffed
			_append_damage_event(summary, source, target, dealt_if_debuffed, if_debuff_type, op)

		"damage_chain":
			var chain_base: float = float(effect.get("value", 0.0))
			var chain_count: int = maxi(int(effect.get("chain_count", 0)), 0)
			var decay_ratio: float = clampf(float(effect.get("decay", 0.0)), 0.0, 0.95)
			var chain_type: String = str(effect.get("damage_type", "internal"))
			var visited: Dictionary = {}
			var current_target: Node = target
			if current_target == null or not is_instance_valid(current_target):
				current_target = _pick_nearest_enemy_unit(source, context, _node_pos(source), INF, visited)
			for hop in range(chain_count + 1):
				if current_target == null or not is_instance_valid(current_target):
					break
				var hop_damage: float = chain_base * pow(1.0 - decay_ratio, float(hop))
				var dealt_chain: float = _deal_damage(source, current_target, hop_damage, chain_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_chain
				_append_damage_event(summary, source, current_target, dealt_chain, chain_type, op)
				visited[current_target.get_instance_id()] = true
				if hop >= chain_count:
					break
				current_target = _pick_nearest_enemy_unit(source, context, _node_pos(current_target), _cells_to_world_distance(3.0, context), visited)

		"damage_cone":
			var cone_value: float = float(effect.get("value", 0.0))
			var cone_type: String = str(effect.get("damage_type", "internal"))
			var cone_angle_deg: float = clampf(float(effect.get("angle", 60.0)), 1.0, 180.0)
			var cone_range_world: float = _cells_to_world_distance(float(effect.get("range", 2.0)), context)
			var cone_origin: Vector2 = _node_pos(source)
			var cone_dir: Vector2 = (_node_pos(target) - cone_origin).normalized() if target != null and is_instance_valid(target) else Vector2.RIGHT
			if cone_dir.is_zero_approx():
				cone_dir = Vector2.RIGHT
			var cone_half_cos: float = cos(deg_to_rad(cone_angle_deg * 0.5))
			for enemy_cone in _collect_enemy_units_in_radius(source, cone_origin, cone_range_world, context):
				var offset: Vector2 = _node_pos(enemy_cone) - cone_origin
				if offset.is_zero_approx():
					continue
				var dir: Vector2 = offset.normalized()
				if cone_dir.dot(dir) < cone_half_cos:
					continue
				var dealt_cone: float = _deal_damage(source, enemy_cone, cone_value, cone_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_cone
				_append_damage_event(summary, source, enemy_cone, dealt_cone, cone_type, op)

		"heal_lowest_ally":
			var lowest_ally: Node = _find_lowest_hp_ally(source, context)
			if lowest_ally != null and is_instance_valid(lowest_ally):
				var heal_lowest_amount: float = _heal_unit(lowest_ally, float(effect.get("value", 0.0)), source)
				summary["heal_total"] = float(summary.get("heal_total", 0.0)) + heal_lowest_amount
				_append_heal_event(summary, source, lowest_ally, heal_lowest_amount, op)

		"heal_percent_missing_hp":
			var heal_target: Node = target if target != null and is_instance_valid(target) else source
			var missing_ratio: float = clampf(float(effect.get("value", 0.0)), 0.0, 5.0)
			var missing_hp: float = maxf(_get_combat_value(heal_target, "max_hp") - _get_combat_value(heal_target, "current_hp"), 0.0)
			var healed_missing: float = _heal_unit(heal_target, missing_hp * missing_ratio, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_missing
			_append_heal_event(summary, source, heal_target, healed_missing, op)

		"shield_allies_aoe":
			var shield_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var shield_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
			for ally_shield in _collect_ally_units_in_radius(source, _node_pos(source), shield_radius, context):
				var ally_combat: Node = ally_shield.get_node_or_null("Components/UnitCombat")
				if ally_combat == null:
					continue
				if ally_combat.has_method("add_shield"):
					ally_combat.call("add_shield", shield_value)
				var shield_duration: float = float(effect.get("duration", 0.0))
				if shield_duration > 0.0 and _apply_buff_op(source, ally_shield, {
					"buff_id": str(effect.get("shield_buff_id", "buff_qi_shield")).strip_edges(),
					"duration": shield_duration
				}, context):
					summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
					_append_buff_event(summary, source, ally_shield, str(effect.get("shield_buff_id", "buff_qi_shield")), shield_duration, op)

		"cleanse_self":
			var buff_manager_cleanse: Variant = context.get("buff_manager", null)
			if buff_manager_cleanse != null and buff_manager_cleanse.has_method("cleanse_debuffs"):
				buff_manager_cleanse.call("cleanse_debuffs", source)

		"cleanse_ally":
			var buff_manager_cleanse_ally: Variant = context.get("buff_manager", null)
			if buff_manager_cleanse_ally != null and buff_manager_cleanse_ally.has_method("cleanse_debuffs"):
				var ally_to_cleanse: Node = _find_lowest_hp_ally(source, context)
				if ally_to_cleanse != null and is_instance_valid(ally_to_cleanse):
					buff_manager_cleanse_ally.call("cleanse_debuffs", ally_to_cleanse)

		"steal_buff":
			var buff_manager_steal: Variant = context.get("buff_manager", null)
			if buff_manager_steal != null and buff_manager_steal.has_method("steal_buffs"):
				buff_manager_steal.call("steal_buffs", target, source, maxi(int(effect.get("count", 1)), 1), source)

		"dispel_target":
			var buff_manager_dispel: Variant = context.get("buff_manager", null)
			if buff_manager_dispel != null and buff_manager_dispel.has_method("dispel_buffs"):
				buff_manager_dispel.call("dispel_buffs", target, maxi(int(effect.get("count", 1)), 1))

		"pull_target":
			var combat_manager_pull: Node = context.get("combat_manager", null)
			if combat_manager_pull != null and combat_manager_pull.has_method("move_unit_steps_towards"):
				var source_cell: Vector2i = combat_manager_pull.call("get_unit_cell_of", source)
				var pull_distance: int = maxi(int(effect.get("distance", 1)), 1)
				combat_manager_pull.call("move_unit_steps_towards", target, source_cell, pull_distance)

		"knockback_aoe":
			var combat_manager_knock: Node = context.get("combat_manager", null)
			if combat_manager_knock != null and combat_manager_knock.has_method("move_unit_steps_away"):
				var kb_radius: float = _cells_to_world_distance(float(effect.get("radius", 2.0)), context)
				var kb_distance: int = maxi(int(effect.get("distance", 1)), 1)
				var kb_center_cell: Vector2i = combat_manager_knock.call("get_unit_cell_of", source)
				for enemy_kb in _collect_enemy_units_in_radius(source, _node_pos(source), kb_radius, context):
					combat_manager_knock.call("move_unit_steps_away", enemy_kb, kb_center_cell, kb_distance)

		"swap_position":
			var combat_manager_swap: Node = context.get("combat_manager", null)
			if combat_manager_swap != null and combat_manager_swap.has_method("swap_unit_cells"):
				combat_manager_swap.call("swap_unit_cells", source, target)

		"create_terrain":
			_apply_create_terrain_op(source, target, effect, context)

		"mark_target":
			if _apply_mark_target_op(source, target, effect, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_append_buff_event(summary, source, target, str(effect.get("mark_id", "")), float(effect.get("duration", 0.0)), op)

		"damage_if_marked":
			var mark_id: String = str(effect.get("mark_id", "")).strip_edges()
			var marked_damage: float = float(effect.get("value", 0.0))
			if _target_has_mark(target, mark_id, context):
				marked_damage *= maxf(float(effect.get("bonus_multiplier", 1.0)), 0.0)
			var marked_type: String = str(effect.get("damage_type", "internal"))
			var dealt_marked: float = _deal_damage(source, target, marked_damage, marked_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_marked
			_append_damage_event(summary, source, target, dealt_marked, marked_type, op)

		"execute_target":
			var hp_threshold: float = clampf(float(effect.get("hp_threshold", 0.15)), 0.0, 0.95)
			var target_hp_ratio: float = _get_hp_ratio(target)
			if target_hp_ratio <= hp_threshold:
				var execute_damage: float = maxf(float(effect.get("value", 0.0)), 0.0)
				var execute_type: String = str(effect.get("damage_type", "external"))
				var dealt_execute: float = _deal_damage(source, target, execute_damage, execute_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_execute
				_append_damage_event(summary, source, target, dealt_execute, execute_type, op)

		"drain_mp":
			var drain_target: Node = target if target != null and is_instance_valid(target) else null
			if drain_target != null:
				var drain_amount: float = maxf(float(effect.get("value", 0.0)), 0.0)
				var target_combat_drain: Node = drain_target.get_node_or_null("Components/UnitCombat")
				var source_combat_drain: Node = source.get_node_or_null("Components/UnitCombat") if source != null else null
				if target_combat_drain != null and source_combat_drain != null:
					var before_mp: float = float(target_combat_drain.get("current_mp"))
					target_combat_drain.call("add_mp", -drain_amount)
					var after_mp: float = float(target_combat_drain.get("current_mp"))
					var drained: float = maxf(before_mp - after_mp, 0.0)
					source_combat_drain.call("add_mp", drained)
					summary["mp_total"] = float(summary.get("mp_total", 0.0)) + drained
					_append_mp_event(summary, source, source, drained, op)

		"silence_target":
			_apply_control_state(target, "silence", float(effect.get("duration", 2.0)), context)
			if _apply_buff_op(source, target, {"buff_id": "debuff_silence", "duration": float(effect.get("duration", 2.0))}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_append_buff_event(summary, source, target, "debuff_silence", float(effect.get("duration", 2.0)), op)

		"stun_target":
			_apply_control_state(target, "stun", float(effect.get("duration", 1.5)), context)
			if _apply_buff_op(source, target, {"buff_id": "debuff_freeze", "duration": float(effect.get("duration", 1.5))}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_append_buff_event(summary, source, target, "debuff_freeze", float(effect.get("duration", 1.5)), op)

		"fear_aoe":
			var fear_radius: float = _cells_to_world_distance(float(effect.get("radius", 2.0)), context)
			var fear_duration: float = float(effect.get("duration", 2.0))
			for enemy_fear in _collect_enemy_units_in_radius(source, _node_pos(source), fear_radius, context):
				_apply_control_state(enemy_fear, "fear", fear_duration, context)
				if _apply_buff_op(source, enemy_fear, {"buff_id": "debuff_fear", "duration": fear_duration}, context):
					summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
					_append_buff_event(summary, source, enemy_fear, "debuff_fear", fear_duration, op)

		"burn_ground":
			var burn_effect: Dictionary = {
				"terrain_type": "fire",
				"radius": int(effect.get("radius", 2)),
				"duration": float(effect.get("duration", 5.0)),
				"damage_per_second": float(effect.get("damage_per_second", 20.0)),
				"at": str(effect.get("at", "self")).strip_edges()
			}
			_apply_create_terrain_op(source, target, burn_effect, context)

		"freeze_target":
			_apply_control_state(target, "stun", float(effect.get("duration", 2.0)), context)
			if target != null and is_instance_valid(target):
				target.set_meta("status_frozen_force_crit", true)
			if _apply_buff_op(source, target, {"buff_id": "debuff_freeze", "duration": float(effect.get("duration", 2.0))}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_append_buff_event(summary, source, target, "debuff_freeze", float(effect.get("duration", 2.0)), op)

		"resurrect_self":
			var resurrect_key: String = "resurrect_used_%s" % str(effect.get("resurrect_key", "default"))
			if source != null and is_instance_valid(source) and not bool(source.get_meta(resurrect_key, false)):
				var source_combat_res: Node = source.get_node_or_null("Components/UnitCombat")
				if source_combat_res != null:
					var hp_percent: float = clampf(float(effect.get("hp_percent", 0.3)), 0.01, 1.0)
					var max_hp_res: float = maxf(float(source_combat_res.get("max_hp")), 1.0)
					source_combat_res.call("restore_hp", max_hp_res * hp_percent)
					source.set_meta(resurrect_key, true)

		"aoe_percent_hp_damage":
			var aoe_radius: float = _cells_to_world_distance(float(effect.get("radius", 2.0)), context)
			var percent: float = clampf(float(effect.get("percent", 0.05)), 0.0, 1.0)
			var aoe_type: String = str(effect.get("damage_type", "internal"))
			for enemy_percent in _collect_enemy_units_in_radius(source, _node_pos(source), aoe_radius, context):
				var enemy_max_hp: float = _get_combat_value(enemy_percent, "max_hp")
				var percent_damage: float = maxf(enemy_max_hp * percent, 0.0)
				var dealt_percent: float = _deal_damage(source, enemy_percent, percent_damage, aoe_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_percent
				_append_damage_event(summary, source, enemy_percent, dealt_percent, aoe_type, op)

		"shield_self":
			_apply_shield_self_op(source, effect, context, summary)

		"immunity_self":
			_apply_immunity_self_op(source, effect, context, summary)

		"summon_units":
			var summoned_count: int = _execute_summon_units_op(source, effect, context)
			summary["summon_total"] = int(summary.get("summon_total", 0)) + summoned_count

		"hazard_zone":
			var hazard_count: int = _execute_hazard_zone_op(source, effect, context)
			summary["hazard_total"] = int(summary.get("hazard_total", 0)) + hazard_count

		"spawn_vfx":
			_spawn_vfx_by_effect(source, target, effect, context)

		# 下列 op 先保留接口，后续再补完位移/召唤/嘲讽等行为细节。
		"teleport_behind", "dash_forward", "knockback_target", "summon_clone", "revive_random_ally", "taunt_aoe":
			push_warning("EffectEngine: op=%s 已预留，当前版本暂未实现。" % op)

		_:
			push_warning("EffectEngine: 未实现的主动 op=%s" % op)


func _resolve_scale_stat_value(node: Node, scale_stat: String) -> float:
	match scale_stat:
		"max_hp":
			return _get_combat_value(node, "max_hp")
		"current_hp":
			return _get_combat_value(node, "current_hp")
		"atk", "iat", "def", "idr":
			if node == null or not is_instance_valid(node):
				return 0.0
			var stats_value: Variant = node.get("runtime_stats")
			if stats_value is Dictionary:
				return float((stats_value as Dictionary).get(scale_stat, 0.0))
			return 0.0
		_:
			return 0.0


func _target_has_debuff(target: Node, debuff_id: String = "") -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var debuffs_value: Variant = target.get_meta("active_debuff_ids", [])
	if not (debuffs_value is Array):
		return false
	var debuffs: Array = debuffs_value as Array
	if debuff_id.strip_edges().is_empty():
		return not debuffs.is_empty()
	for debuff in debuffs:
		if str(debuff).strip_edges() == debuff_id.strip_edges():
			return true
	return false


func _pick_nearest_enemy_unit(source: Node, context: Dictionary, center: Vector2, max_radius_world: float, visited: Dictionary = {}) -> Node:
	var best: Node = null
	var best_d2: float = INF
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var max_d2: float = max_radius_world * max_radius_world
	for unit in _get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) == source_team:
			continue
		if not _is_unit_alive(unit):
			continue
		var iid: int = unit.get_instance_id()
		if visited.has(iid):
			continue
		var d2: float = _distance_sq(_node_pos(unit), center)
		if max_radius_world < INF and d2 > max_d2:
			continue
		if d2 < best_d2:
			best_d2 = d2
			best = unit
	return best


func _find_lowest_hp_ally(source: Node, context: Dictionary) -> Node:
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var best: Node = null
	var best_ratio: float = INF
	for unit in _get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) != source_team:
			continue
		if not _is_unit_alive(unit):
			continue
		var max_hp: float = maxf(_get_combat_value(unit, "max_hp"), 1.0)
		var hp_ratio: float = _get_combat_value(unit, "current_hp") / max_hp
		if hp_ratio < best_ratio:
			best_ratio = hp_ratio
			best = unit
	return best


func _apply_create_terrain_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	var combat_manager: Node = context.get("combat_manager", null)
	var hex_grid: Node = context.get("hex_grid", null)
	if combat_manager == null or not is_instance_valid(combat_manager):
		return false
	if hex_grid == null or not is_instance_valid(hex_grid):
		return false
	if not combat_manager.has_method("add_temporary_terrain"):
		return false
	var at_mode: String = str(effect.get("at", "target")).strip_edges().to_lower()
	var anchor: Node = source
	if at_mode == "target" and target != null and is_instance_valid(target):
		anchor = target
	elif at_mode == "self":
		anchor = source
	elif at_mode == "source":
		anchor = source
	var center_cell: Vector2i = Vector2i(-1, -1)
	if anchor != null and is_instance_valid(anchor) and combat_manager.has_method("get_unit_cell_of"):
		var cell_value: Variant = combat_manager.call("get_unit_cell_of", anchor)
		if cell_value is Vector2i:
			center_cell = cell_value as Vector2i
	if center_cell.x < 0 and anchor != null and is_instance_valid(anchor) and hex_grid.has_method("world_to_axial"):
		center_cell = hex_grid.call("world_to_axial", _node_pos(anchor))
	if center_cell.x < 0:
		return false
	var terrain_type: String = str(effect.get("terrain_type", "fire")).strip_edges().to_lower()
	var terrain_config: Dictionary = {
		"terrain_id": "terrain_%d_%s" % [Time.get_ticks_msec(), terrain_type],
		"terrain_type": terrain_type,
		"center_cell": center_cell,
		"radius": maxi(int(effect.get("radius", 1)), 0),
		"duration": maxf(float(effect.get("duration", 1.0)), 0.1),
		"buff_id": str(effect.get("buff_id", "")).strip_edges(),
		"debuff_id": str(effect.get("debuff_id", "")).strip_edges(),
		"target_mode": str(effect.get("target_mode", "")).strip_edges().to_lower()
	}
	if effect.has("damage_per_second"):
		terrain_config["damage_per_second"] = maxf(float(effect.get("damage_per_second", 0.0)), 0.0)
	elif effect.has("dps"):
		terrain_config["damage_per_second"] = maxf(float(effect.get("dps", 0.0)), 0.0)
	elif effect.has("value"):
		terrain_config["damage_per_second"] = maxf(float(effect.get("value", 0.0)), 0.0)
	if effect.has("heal_per_second"):
		terrain_config["heal_per_second"] = maxf(float(effect.get("heal_per_second", 0.0)), 0.0)
	return bool(combat_manager.call("add_temporary_terrain", terrain_config, source))


func _apply_mark_target_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var mark_id: String = str(effect.get("mark_id", "")).strip_edges()
	if mark_id.is_empty():
		return false
	var duration: float = float(effect.get("duration", 5.0))
	# 优先走 debuff，便于状态栏显示与联动判断。
	if _apply_buff_op(source, target, {"buff_id": mark_id, "duration": duration}, context):
		return true
	var marks: Dictionary = target.get_meta("runtime_marks", {})
	var expire_time: float = float(context.get("battle_elapsed", 0.0)) + maxf(duration, 0.1)
	marks[mark_id] = expire_time
	target.set_meta("runtime_marks", marks)
	return true


func _target_has_mark(target: Node, mark_id: String, context: Dictionary) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if mark_id.strip_edges().is_empty():
		return false
	# 优先看 debuff 列表（来自 BuffManager）。
	if _target_has_debuff(target, mark_id):
		return true
	var marks: Dictionary = target.get_meta("runtime_marks", {})
	if not marks.has(mark_id):
		return false
	var expire_time: float = float(marks.get(mark_id, 0.0))
	var now_time: float = float(context.get("battle_elapsed", 0.0))
	if expire_time <= now_time:
		marks.erase(mark_id)
		target.set_meta("runtime_marks", marks)
		return false
	return true


func _get_hp_ratio(unit: Node) -> float:
	if unit == null or not is_instance_valid(unit):
		return 1.0
	var max_hp: float = maxf(_get_combat_value(unit, "max_hp"), 1.0)
	var hp: float = _get_combat_value(unit, "current_hp")
	return clampf(hp / max_hp, 0.0, 1.0)


func _apply_control_state(target: Node, control_type: String, duration: float, context: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target):
		return
	var logic_now: float = float(context.get("battle_elapsed", 0.0))
	var until_logic: float = logic_now + maxf(duration, 0.05)
	var real_now: float = float(Time.get_ticks_msec()) * 0.001
	var until_real: float = real_now + maxf(duration, 0.05)
	match control_type:
		"silence":
			target.set_meta("status_silence_until", maxf(float(target.get_meta("status_silence_until", 0.0)), until_real))
		"stun":
			target.set_meta("status_stun_until", maxf(float(target.get_meta("status_stun_until", 0.0)), until_logic))
		"fear":
			target.set_meta("status_fear_until", maxf(float(target.get_meta("status_fear_until", 0.0)), until_logic))
		_:
			return


func _apply_shield_self_op(source: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return
	var shield_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
	if shield_value <= 0.0:
		return
	var combat: Node = source.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return
	if combat.has_method("add_shield"):
		combat.call("add_shield", shield_value)
	else:
		# 旧战斗组件兜底：仍兼容 stage_shield_hp 元数据。
		var old_shield: float = float(source.get_meta("stage_shield_hp", 0.0))
		source.set_meta("stage_shield_hp", maxf(old_shield + shield_value, 0.0))

	var buff_manager: Variant = context.get("buff_manager", null)
	var shield_buff_id: String = str(effect.get("shield_buff_id", effect.get("buff_id", "boss_shield"))).strip_edges()
	var shield_duration: float = float(effect.get("duration", -1.0))
	if buff_manager != null and not shield_buff_id.is_empty():
		if bool(buff_manager.call("apply_buff", source, shield_buff_id, shield_duration, source)):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_append_buff_event(summary, source, source, shield_buff_id, shield_duration, "shield_self")
			source.set_meta("shield_bound_buff_id", shield_buff_id)

	# 可选：护盾开启时同步挂“免疫类 Buff”，便于按 Buff 时长自动过期。
	var immunity_buff_id: String = str(effect.get("immunity_buff_id", "")).strip_edges()
	if buff_manager != null and not immunity_buff_id.is_empty():
		var immunity_duration: float = float(effect.get("immunity_duration", shield_duration))
		if bool(buff_manager.call("apply_buff", source, immunity_buff_id, immunity_duration, source)):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_append_buff_event(summary, source, source, immunity_buff_id, immunity_duration, "shield_self")
			source.set_meta("shield_immunity_buff_id", immunity_buff_id)


func _apply_immunity_self_op(source: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return
	# 推荐走 Buff 实现（可自动过期、可被 on_buff_expired 监听）。
	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	var duration: float = float(effect.get("duration", 0.0))
	if not buff_id.is_empty():
		if _apply_buff_op(source, source, {"buff_id": buff_id, "duration": duration}, context):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_append_buff_event(summary, source, source, buff_id, duration, "immunity_self")
		return
	# 无 buff_id 时退化为元数据开关（持续到本场结束或外部手动关闭）。
	source.set_meta("stage_damage_immune", true)


func _execute_summon_units_op(source: Node, effect: Dictionary, context: Dictionary) -> int:
	var battlefield: Node = context.get("battlefield", null)
	if battlefield == null or not is_instance_valid(battlefield):
		return 0
	if not battlefield.has_method("spawn_mechanic_enemy_wave"):
		return 0
	var units_value: Variant = effect.get("units", [])
	if not (units_value is Array):
		return 0
	var source_unit_id: String = str(source.get("unit_id")) if source != null and is_instance_valid(source) else ""
	var source_star: int = int(source.get("star_level")) if source != null and is_instance_valid(source) else 1
	var deploy_mode: String = str(effect.get("deploy", "around_self")).strip_edges().to_lower()
	var radius_cells: int = maxi(int(effect.get("radius", 2)), 0)
	var hex_grid: Node = context.get("hex_grid", null)
	var rows: Array[Dictionary] = []
	for row_value in (units_value as Array):
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = (row_value as Dictionary).duplicate(true)
		var clone_source: String = str(row.get("clone_source", "")).strip_edges().to_lower()
		if clone_source == "self":
			if source_unit_id.is_empty():
				continue
			row["unit_id"] = source_unit_id
			if not row.has("star"):
				row["star"] = source_star
		var unit_id: String = str(row.get("unit_id", "")).strip_edges()
		var count: int = maxi(int(row.get("count", 1)), 0)
		if unit_id.is_empty() or count <= 0:
			continue
		if deploy_mode == "around_self" and source != null and is_instance_valid(source):
			var center_cell: Vector2i = Vector2i(-1, -1)
			if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("world_to_axial"):
				center_cell = hex_grid.call("world_to_axial", _node_pos(source))
			var candidate_cells: Array[Vector2i] = _collect_cells_in_radius(hex_grid, center_cell, radius_cells)
			if not candidate_cells.is_empty():
				row["deploy_zone"] = "fixed"
				row["fixed_cells"] = candidate_cells
			else:
				row["deploy_zone"] = "back"
		else:
			row["deploy_zone"] = deploy_mode
		rows.append(row)
	if rows.is_empty():
		return 0
	return int(battlefield.call("spawn_mechanic_enemy_wave", rows))


func _execute_hazard_zone_op(source: Node, effect: Dictionary, context: Dictionary) -> int:
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null:
		return 0
	if not buff_manager.has_method("add_battlefield_effect"):
		return 0
	var hex_grid: Node = context.get("hex_grid", null)
	if hex_grid == null or not is_instance_valid(hex_grid):
		return 0
	var count: int = maxi(int(effect.get("count", 1)), 1)
	var radius_cells: int = maxi(int(effect.get("radius_cells", effect.get("radius", 2))), 0)
	var duration: float = maxf(float(effect.get("duration", 6.0)), 0.1)
	var warning_seconds: float = maxf(float(effect.get("warning_seconds", 0.0)), 0.0)
	var tick_interval: float = maxf(float(effect.get("tick_interval", 0.5)), 0.05)
	var dps: float = maxf(float(effect.get("damage_per_second", effect.get("value", 0.0))), 0.0)
	if dps <= 0.0:
		return 0
	var damage_per_tick: float = dps * tick_interval
	var center_mode: String = str(effect.get("target_mode", "random_position")).strip_edges().to_lower()
	var affect_mode: String = str(effect.get("affect_mode", "enemies")).strip_edges().to_lower()
	var damage_type: String = str(effect.get("damage_type", "internal")).strip_edges().to_lower()
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	var created: int = 0
	for idx in range(count):
		var center_cell: Vector2i = _pick_hazard_center_cell(center_mode, source, hex_grid, radius_cells)
		if center_cell.x < 0:
			continue
		var ok: bool = bool(buff_manager.call("add_battlefield_effect", {
			"effect_id": "hazard_zone_%d_%d" % [Time.get_ticks_msec(), idx],
			"center_cell": center_cell,
			"radius_cells": radius_cells,
			"target_mode": affect_mode,
			"duration": duration,
			"warning_seconds": warning_seconds,
			"tick_interval": tick_interval,
			"source_team": source_team,
			"tick_effects": [{
				"op": "damage_target",
				"value": damage_per_tick,
				"damage_type": damage_type
			}]
		}, source))
		if ok:
			created += 1
	return created


func _pick_hazard_center_cell(mode: String, source: Node, hex_grid: Node, radius_cells: int) -> Vector2i:
	if mode == "around_self" and source != null and is_instance_valid(source):
		var source_cell: Vector2i = hex_grid.call("world_to_axial", _node_pos(source))
		var pool: Array[Vector2i] = _collect_cells_in_radius(hex_grid, source_cell, radius_cells)
		if pool.is_empty():
			return source_cell
		pool.shuffle()
		return pool[0]
	var width: int = maxi(int(hex_grid.get("grid_width")), 1)
	var height: int = maxi(int(hex_grid.get("grid_height")), 1)
	return Vector2i(randi() % width, randi() % height)


func _collect_cells_in_radius(hex_grid: Node, center_cell: Vector2i, radius_cells: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	if center_cell.x < 0 or center_cell.y < 0:
		return out
	if not bool(hex_grid.call("is_inside_grid", center_cell)):
		return out
	var queue: Array[Vector2i] = [center_cell]
	var visited: Dictionary = {"%d,%d" % [center_cell.x, center_cell.y]: true}
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		if _hex_distance_by_cell(center_cell, cell, hex_grid) > radius_cells:
			continue
		out.append(cell)
		var neighbors_value: Variant = hex_grid.call("get_neighbor_cells", cell)
		if not (neighbors_value is Array):
			continue
		for neighbor_value in (neighbors_value as Array):
			if not (neighbor_value is Vector2i):
				continue
			var neighbor: Vector2i = neighbor_value as Vector2i
			if not bool(hex_grid.call("is_inside_grid", neighbor)):
				continue
			var key: String = "%d,%d" % [neighbor.x, neighbor.y]
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(neighbor)
	return out


func _hex_distance_by_cell(a: Vector2i, b: Vector2i, hex_grid: Node) -> int:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("get_cell_distance"):
		return int(hex_grid.call("get_cell_distance", a, b))
	var dq: int = b.x - a.x
	var dr: int = b.y - a.y
	var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
	return int(distance_sum / 2.0)


func _add_modifier(modifier_bundle: Dictionary, key: String, value: float) -> void:
	modifier_bundle[key] = float(modifier_bundle.get(key, 0.0)) + value


func _apply_legacy_stat_alias(
	runtime_stats: Dictionary,
	effect: Dictionary,
	default_stat_key: String,
	stack_multiplier: float
) -> void:
	var stat_key: String = str(effect.get("stat", default_stat_key)).strip_edges()
	if stat_key.is_empty():
		stat_key = default_stat_key

	var value: float = float(effect.get("value", 0.0)) * stack_multiplier
	var mode: String = str(effect.get("mode", "auto")).strip_edges().to_lower()
	var use_percent: bool = false
	match mode:
		"percent":
			use_percent = true
		"add":
			use_percent = false
		_:
			use_percent = absf(value) <= 1.0 and _is_legacy_ratio_friendly_stat(stat_key)

	if use_percent:
		runtime_stats[stat_key] = float(runtime_stats.get(stat_key, 0.0)) * (1.0 + value)
		return

	runtime_stats[stat_key] = float(runtime_stats.get(stat_key, 0.0)) + value


func _is_legacy_ratio_friendly_stat(stat_key: String) -> bool:
	match stat_key:
		"hp", "mp", "atk", "def", "iat", "idr", "spd", "wis", "mov":
			return true
		_:
			return false


func _append_damage_event(
	summary: Dictionary,
	source: Node,
	target: Node,
	damage: float,
	damage_type: String,
	op: String
) -> void:
	var shield_absorbed: float = float(_last_damage_meta.get("shield_absorbed", 0.0))
	var immune_absorbed: float = float(_last_damage_meta.get("immune_absorbed", 0.0))
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
	_last_damage_meta = {}


func _append_buff_event(
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
	buff_events.append({
		"source": source,
		"target": target,
		"buff_id": buff_id,
		"duration": duration,
		"op": op
	})
	summary["buff_events"] = buff_events


func _append_heal_event(
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


func _append_mp_event(
	summary: Dictionary,
	source: Node,
	target: Node,
	mp: float,
	op: String
) -> void:
	if mp <= 0.0:
		return
	var mp_events: Array = summary.get("mp_events", [])
	mp_events.append({
		"source": source,
		"target": target,
		"mp": mp,
		"op": op
	})
	summary["mp_events"] = mp_events


func _deal_damage(source: Node, target: Node, amount: float, damage_type: String) -> float:
	_last_damage_meta = {"shield_absorbed": 0.0, "immune_absorbed": 0.0}
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
	_last_damage_meta["shield_absorbed"] = float(result.get("shield_absorbed", 0.0))
	_last_damage_meta["immune_absorbed"] = float(result.get("immune_absorbed", 0.0))
	return float(result.get("damage", 0.0))


func _heal_unit(target: Node, amount: float, source: Node = null) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var combat: Node = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	var final_amount: float = maxf(amount, 0.0)
	if source != null and is_instance_valid(source):
		var source_combat: Node = source.get_node_or_null("Components/UnitCombat")
		if source_combat != null and source_combat.has_method("get_external_modifiers"):
			var modifiers_value: Variant = source_combat.call("get_external_modifiers")
			if modifiers_value is Dictionary:
				var healing_amp: float = float((modifiers_value as Dictionary).get("healing_amp", 0.0))
				final_amount *= maxf(1.0 + healing_amp, 0.0)
	var before: float = float(combat.get("current_hp"))
	combat.call("restore_hp", final_amount)
	var after: float = float(combat.get("current_hp"))
	return maxf(after - before, 0.0)


func _restore_mp_unit(target: Node, amount: float) -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var combat: Node = target.get_node_or_null("Components/UnitCombat")
	if combat == null:
		return 0.0
	var before: float = float(combat.get("current_mp"))
	combat.call("add_mp", maxf(amount, 0.0))
	var after: float = float(combat.get("current_mp"))
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
