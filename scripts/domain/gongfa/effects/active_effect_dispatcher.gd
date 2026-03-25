extends RefCounted
class_name ActiveEffectDispatcher

const EFFECT_OP_HANDLERS_SCRIPT: Script = preload("res://scripts/domain/gongfa/effects/effect_op_handlers.gd")

var _handlers = EFFECT_OP_HANDLERS_SCRIPT.new()


func _init(handlers = null) -> void:
	if handlers != null:
		_handlers = handlers


func execute_active_op(gateway: Variant, source: Node, target: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	var op: String = str(effect.get("op", "")).strip_edges()
	if op.is_empty():
		return

	match op:
		"damage_target":
			var dmg: float = float(effect.get("value", 0.0))
			var mul: float = float(effect.get("multiplier", 1.0))
			var damage_type: String = str(effect.get("damage_type", "internal"))
			var dealt: float = gateway._deal_damage(source, target, dmg * mul, damage_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt
			_handlers.append_damage_event(summary, gateway, source, target, dealt, damage_type, op)

		"damage_aoe":
			var radius_cells: float = float(effect.get("radius", 2.0))
			var base_damage: float = float(effect.get("value", 0.0))
			var damage_type_aoe: String = str(effect.get("damage_type", "internal"))
			var radius_world: float = gateway._cells_to_world_distance(radius_cells, context)
			var center: Vector2 = gateway._node_pos(source)
			var targets: Array[Node] = gateway._collect_enemy_units_in_radius(source, center, radius_world, context)
			for enemy in targets:
				var dealt_aoe: float = gateway._deal_damage(source, enemy, base_damage, damage_type_aoe)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_aoe
				_handlers.append_damage_event(summary, gateway, source, enemy, dealt_aoe, damage_type_aoe, op)

		"heal_self":
			var heal_value: float = float(effect.get("value", 0.0))
			var healed: float = gateway._heal_unit(source, heal_value, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed
			_handlers.append_heal_event(summary, source, source, healed, op)

		"heal_self_percent":
			var ratio: float = float(effect.get("value", 0.0))
			var max_hp: float = gateway._get_combat_value(source, "max_hp")
			var healed_percent: float = gateway._heal_unit(source, max_hp * ratio, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_percent
			_handlers.append_heal_event(summary, source, source, healed_percent, op)

		"heal_allies_aoe":
			var heal_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var heal_amount: float = float(effect.get("value", 0.0))
			var heal_center: Vector2 = gateway._node_pos(source)
			var heal_exclude_self: bool = bool(effect.get("exclude_self", false))
			var allies: Array[Node] = gateway._collect_ally_units_in_radius(source, heal_center, heal_radius, context, heal_exclude_self)
			for ally in allies:
				var healed_ally: float = gateway._heal_unit(ally, heal_amount, source)
				summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_ally
				_handlers.append_heal_event(summary, source, ally, healed_ally, op)

		"heal_target_flat":
			var heal_target_flat: Node = target if target != null and is_instance_valid(target) else source
			var heal_flat_amount: float = float(effect.get("value", 0.0))
			var healed_flat: float = gateway._heal_unit(heal_target_flat, heal_flat_amount, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_flat
			_handlers.append_heal_event(summary, source, heal_target_flat, healed_flat, op)

		"mp_regen_add":
			var mp_target: Node = target if target != null and is_instance_valid(target) else source
			var restored_mp: float = gateway._restore_mp_unit(mp_target, float(effect.get("value", 0.0)))
			summary["mp_total"] = float(summary.get("mp_total", 0.0)) + restored_mp
			_handlers.append_mp_event(summary, source, mp_target, restored_mp, op)

		"buff_self":
			if gateway._apply_buff_op(source, source, effect, context):
				summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, source, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"buff_allies_aoe":
			var buff_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var buff_exclude_self: bool = bool(effect.get("exclude_self", false))
			var buff_allies: Array[Node] = gateway._collect_ally_units_in_radius(source, gateway._node_pos(source), buff_radius, context, buff_exclude_self)
			if gateway._is_source_bound_aura_binding(effect):
				var aura_apply_result: Dictionary = gateway._execute_source_bound_aura_op(source, effect, buff_allies, context)
				summary["buff_applied"] = int(summary.get("buff_applied", 0)) + int(aura_apply_result.get("applied_count", 0))
				var aura_applied_targets_value: Variant = aura_apply_result.get("applied_targets", [])
				if aura_applied_targets_value is Array:
					for applied_target_value in (aura_applied_targets_value as Array):
						if not (applied_target_value is Node):
							continue
						var applied_target: Node = applied_target_value as Node
						_handlers.append_buff_event(summary, source, applied_target, str(effect.get("buff_id", "")), -1.0, op)
				return
			for ally_buff in buff_allies:
				if gateway._apply_buff_op(source, ally_buff, effect, context):
					summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
					_handlers.append_buff_event(summary, source, ally_buff, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"debuff_target":
			if gateway._apply_buff_op(source, target, effect, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, target, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"buff_target":
			if gateway._apply_buff_op(source, target, effect, context):
				summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, target, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"debuff_aoe":
			var debuff_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var enemies: Array[Node] = gateway._collect_enemy_units_in_radius(source, gateway._node_pos(source), debuff_radius, context)
			if gateway._is_source_bound_aura_binding(effect):
				var aura_debuff_result: Dictionary = gateway._execute_source_bound_aura_op(source, effect, enemies, context)
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + int(aura_debuff_result.get("applied_count", 0))
				var aura_debuff_targets_value: Variant = aura_debuff_result.get("applied_targets", [])
				if aura_debuff_targets_value is Array:
					for applied_debuff_target_value in (aura_debuff_targets_value as Array):
						if not (applied_debuff_target_value is Node):
							continue
						var applied_debuff_target: Node = applied_debuff_target_value as Node
						_handlers.append_buff_event(summary, source, applied_debuff_target, str(effect.get("buff_id", "")), -1.0, op)
				return
			for enemy in enemies:
				if gateway._apply_buff_op(source, enemy, effect, context):
					summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
					_handlers.append_buff_event(summary, source, enemy, str(effect.get("buff_id", "")), float(effect.get("duration", 0.0)), op)

		"damage_target_scaling":
			var scale_base: float = float(effect.get("value", 0.0))
			var scale_stat: String = str(effect.get("scale_stat", "max_hp")).strip_edges().to_lower()
			var scale_ratio: float = float(effect.get("scale_ratio", 0.0))
			var scale_source_pref: String = str(effect.get("scale_source", "auto")).strip_edges().to_lower()
			var scale_node: Node = source
			if scale_source_pref == "target" or ((scale_stat == "max_hp" or scale_stat == "current_hp") and target != null and is_instance_valid(target)):
				scale_node = target
			var scale_value: float = gateway._resolve_scale_stat_value(scale_node, scale_stat)
			var scaled_damage: float = maxf(scale_base + scale_value * scale_ratio, 0.0)
			var scaling_type: String = str(effect.get("damage_type", "internal"))
			var dealt_scaling: float = gateway._deal_damage(source, target, scaled_damage, scaling_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_scaling
			_handlers.append_damage_event(summary, gateway, source, target, dealt_scaling, scaling_type, op)

		"damage_if_debuffed":
			var base_if_debuffed: float = float(effect.get("value", 0.0))
			var bonus_mul: float = maxf(float(effect.get("bonus_multiplier", 1.0)), 0.0)
			var need_debuff: String = str(effect.get("require_debuff", "")).strip_edges()
			if gateway._target_has_debuff(target, need_debuff):
				base_if_debuffed *= bonus_mul
			var if_debuff_type: String = str(effect.get("damage_type", "internal"))
			var dealt_if_debuffed: float = gateway._deal_damage(source, target, base_if_debuffed, if_debuff_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_if_debuffed
			_handlers.append_damage_event(summary, gateway, source, target, dealt_if_debuffed, if_debuff_type, op)

		"damage_chain":
			var chain_base: float = float(effect.get("value", 0.0))
			var chain_count: int = maxi(int(effect.get("chain_count", 0)), 0)
			var decay_ratio: float = clampf(float(effect.get("decay", 0.0)), 0.0, 0.95)
			var chain_type: String = str(effect.get("damage_type", "internal"))
			var visited: Dictionary = {}
			var current_target: Node = target
			if current_target == null or not is_instance_valid(current_target):
				current_target = gateway._pick_nearest_enemy_unit(source, context, gateway._node_pos(source), INF, visited)
			for hop in range(chain_count + 1):
				if current_target == null or not is_instance_valid(current_target):
					break
				var hop_damage: float = chain_base * pow(1.0 - decay_ratio, float(hop))
				var dealt_chain: float = gateway._deal_damage(source, current_target, hop_damage, chain_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_chain
				_handlers.append_damage_event(summary, gateway, source, current_target, dealt_chain, chain_type, op)
				visited[current_target.get_instance_id()] = true
				if hop >= chain_count:
					break
				current_target = gateway._pick_nearest_enemy_unit(
					source,
					context,
					gateway._node_pos(current_target),
					gateway._cells_to_world_distance(3.0, context),
					visited
				)

		"damage_cone":
			var cone_value: float = float(effect.get("value", 0.0))
			var cone_type: String = str(effect.get("damage_type", "internal"))
			var cone_angle_deg: float = clampf(float(effect.get("angle", 60.0)), 1.0, 180.0)
			var cone_range_world: float = gateway._cells_to_world_distance(float(effect.get("range", 2.0)), context)
			var cone_origin: Vector2 = gateway._node_pos(source)
			var cone_dir: Vector2 = (gateway._node_pos(target) - cone_origin).normalized() if target != null and is_instance_valid(target) else Vector2.RIGHT
			if cone_dir.is_zero_approx():
				cone_dir = Vector2.RIGHT
			var cone_half_cos: float = cos(deg_to_rad(cone_angle_deg * 0.5))
			for enemy_cone in gateway._collect_enemy_units_in_radius(source, cone_origin, cone_range_world, context):
				var offset: Vector2 = gateway._node_pos(enemy_cone) - cone_origin
				if offset.is_zero_approx():
					continue
				var dir: Vector2 = offset.normalized()
				if cone_dir.dot(dir) < cone_half_cos:
					continue
				var dealt_cone: float = gateway._deal_damage(source, enemy_cone, cone_value, cone_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_cone
				_handlers.append_damage_event(summary, gateway, source, enemy_cone, dealt_cone, cone_type, op)

		"heal_lowest_ally":
			var lowest_ally: Node = gateway._find_lowest_hp_ally(source, context)
			if lowest_ally != null and is_instance_valid(lowest_ally):
				var heal_lowest_amount: float = gateway._heal_unit(lowest_ally, float(effect.get("value", 0.0)), source)
				summary["heal_total"] = float(summary.get("heal_total", 0.0)) + heal_lowest_amount
				_handlers.append_heal_event(summary, source, lowest_ally, heal_lowest_amount, op)

		"heal_percent_missing_hp":
			var heal_target: Node = target if target != null and is_instance_valid(target) else source
			var missing_ratio: float = clampf(float(effect.get("value", 0.0)), 0.0, 5.0)
			var missing_hp: float = maxf(gateway._get_combat_value(heal_target, "max_hp") - gateway._get_combat_value(heal_target, "current_hp"), 0.0)
			var healed_missing: float = gateway._heal_unit(heal_target, missing_hp * missing_ratio, source)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_missing
			_handlers.append_heal_event(summary, source, heal_target, healed_missing, op)

		"shield_allies_aoe":
			var shield_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var shield_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
			var shield_exclude_self: bool = bool(effect.get("exclude_self", false))
			for ally_shield in gateway._collect_ally_units_in_radius(source, gateway._node_pos(source), shield_radius, context, shield_exclude_self):
				var ally_combat: Node = ally_shield.get_node_or_null("Components/UnitCombat")
				if ally_combat == null:
					continue
				if ally_combat.has_method("add_shield"):
					ally_combat.add_shield(shield_value)
				var shield_duration: float = float(effect.get("duration", 0.0))
				if shield_duration > 0.0 and gateway._apply_buff_op(source, ally_shield, {
					"buff_id": str(effect.get("shield_buff_id", "buff_qi_shield")).strip_edges(),
					"duration": shield_duration
				}, context):
					summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
					_handlers.append_buff_event(summary, source, ally_shield, str(effect.get("shield_buff_id", "buff_qi_shield")), shield_duration, op)

		"cleanse_self":
			var buff_manager_cleanse: Variant = context.get("buff_manager", null)
			if buff_manager_cleanse != null and buff_manager_cleanse.has_method("cleanse_debuffs"):
				buff_manager_cleanse.cleanse_debuffs(source)

		"cleanse_ally":
			var buff_manager_cleanse_ally: Variant = context.get("buff_manager", null)
			if buff_manager_cleanse_ally != null and buff_manager_cleanse_ally.has_method("cleanse_debuffs"):
				var ally_to_cleanse: Node = gateway._find_lowest_hp_ally(source, context)
				if ally_to_cleanse != null and is_instance_valid(ally_to_cleanse):
					buff_manager_cleanse_ally.cleanse_debuffs(ally_to_cleanse)

		"steal_buff":
			var buff_manager_steal: Variant = context.get("buff_manager", null)
			if buff_manager_steal != null and buff_manager_steal.has_method("steal_buffs"):
				buff_manager_steal.steal_buffs(target, source, maxi(int(effect.get("count", 1)), 1), source)

		"dispel_target":
			var buff_manager_dispel: Variant = context.get("buff_manager", null)
			if buff_manager_dispel != null and buff_manager_dispel.has_method("dispel_buffs"):
				buff_manager_dispel.dispel_buffs(target, maxi(int(effect.get("count", 1)), 1))

		"pull_target":
			var combat_manager_pull: Node = context.get("combat_manager", null)
			if combat_manager_pull != null and combat_manager_pull.has_method("move_unit_steps_towards"):
				var source_cell: Vector2i = combat_manager_pull.get_unit_cell_of(source)
				var pull_distance: int = maxi(int(effect.get("distance", 1)), 1)
				combat_manager_pull.move_unit_steps_towards(target, source_cell, pull_distance)

		"knockback_aoe":
			var combat_manager_knock: Node = context.get("combat_manager", null)
			if combat_manager_knock != null and combat_manager_knock.has_method("move_unit_steps_away"):
				var kb_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 2.0)), context)
				var kb_distance: int = maxi(int(effect.get("distance", 1)), 1)
				var kb_center_cell: Vector2i = combat_manager_knock.get_unit_cell_of(source)
				for enemy_kb in gateway._collect_enemy_units_in_radius(source, gateway._node_pos(source), kb_radius, context):
					combat_manager_knock.move_unit_steps_away(enemy_kb, kb_center_cell, kb_distance)

		"swap_position":
			var combat_manager_swap: Node = context.get("combat_manager", null)
			if combat_manager_swap != null and combat_manager_swap.has_method("swap_unit_cells"):
				combat_manager_swap.swap_unit_cells(source, target)

		"create_terrain":
			gateway._apply_create_terrain_op(source, target, effect, context)

		"mark_target":
			if gateway._apply_mark_target_op(source, target, effect, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, target, str(effect.get("mark_id", "")), float(effect.get("duration", 0.0)), op)

		"damage_if_marked":
			var mark_id: String = str(effect.get("mark_id", "")).strip_edges()
			var marked_damage: float = float(effect.get("value", 0.0))
			if gateway._target_has_mark(target, mark_id, context):
				marked_damage *= maxf(float(effect.get("bonus_multiplier", 1.0)), 0.0)
			var marked_type: String = str(effect.get("damage_type", "internal"))
			var dealt_marked: float = gateway._deal_damage(source, target, marked_damage, marked_type)
			summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_marked
			_handlers.append_damage_event(summary, gateway, source, target, dealt_marked, marked_type, op)

		"execute_target":
			var hp_threshold: float = clampf(float(effect.get("hp_threshold", 0.15)), 0.0, 0.95)
			var target_hp_ratio: float = gateway._get_hp_ratio(target)
			if target_hp_ratio <= hp_threshold:
				var execute_damage: float = maxf(float(effect.get("value", 0.0)), 0.0)
				var execute_type: String = str(effect.get("damage_type", "external"))
				var dealt_execute: float = gateway._deal_damage(source, target, execute_damage, execute_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_execute
				_handlers.append_damage_event(summary, gateway, source, target, dealt_execute, execute_type, op)

		"drain_mp":
			var drain_target: Node = target if target != null and is_instance_valid(target) else null
			if drain_target != null:
				var drain_amount: float = maxf(float(effect.get("value", 0.0)), 0.0)
				var target_combat_drain: Node = drain_target.get_node_or_null("Components/UnitCombat")
				var source_combat_drain: Node = source.get_node_or_null("Components/UnitCombat") if source != null else null
				if target_combat_drain != null and source_combat_drain != null:
					var before_mp: float = float(target_combat_drain.get("current_mp"))
					target_combat_drain.add_mp(-drain_amount)
					var after_mp: float = float(target_combat_drain.get("current_mp"))
					var drained: float = maxf(before_mp - after_mp, 0.0)
					source_combat_drain.add_mp(drained)
					summary["mp_total"] = float(summary.get("mp_total", 0.0)) + drained
					_handlers.append_mp_event(summary, source, source, drained, op)

		"silence_target":
			gateway._apply_control_state(target, "silence", float(effect.get("duration", 2.0)), context)
			if gateway._apply_buff_op(source, target, {"buff_id": "debuff_silence", "duration": float(effect.get("duration", 2.0))}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, target, "debuff_silence", float(effect.get("duration", 2.0)), op)

		"stun_target":
			gateway._apply_control_state(target, "stun", float(effect.get("duration", 1.5)), context)
			if gateway._apply_buff_op(source, target, {"buff_id": "debuff_freeze", "duration": float(effect.get("duration", 1.5))}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, target, "debuff_freeze", float(effect.get("duration", 1.5)), op)

		"fear_aoe":
			var fear_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 2.0)), context)
			var fear_duration: float = float(effect.get("duration", 2.0))
			for enemy_fear in gateway._collect_enemy_units_in_radius(source, gateway._node_pos(source), fear_radius, context):
				gateway._apply_control_state(enemy_fear, "fear", fear_duration, context)
				if gateway._apply_buff_op(source, enemy_fear, {"buff_id": "debuff_fear", "duration": fear_duration}, context):
					summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
					_handlers.append_buff_event(summary, source, enemy_fear, "debuff_fear", fear_duration, op)

		"freeze_target":
			gateway._apply_control_state(target, "stun", float(effect.get("duration", 2.0)), context)
			if target != null and is_instance_valid(target):
				target.set_meta("status_frozen_force_crit", true)
			if gateway._apply_buff_op(source, target, {"buff_id": "debuff_freeze", "duration": float(effect.get("duration", 2.0))}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_handlers.append_buff_event(summary, source, target, "debuff_freeze", float(effect.get("duration", 2.0)), op)

		"resurrect_self":
			var resurrect_key: String = "resurrect_used_%s" % str(effect.get("resurrect_key", "default"))
			if source != null and is_instance_valid(source) and not bool(source.get_meta(resurrect_key, false)):
				var source_combat_res: Node = source.get_node_or_null("Components/UnitCombat")
				if source_combat_res != null:
					var hp_percent: float = clampf(float(effect.get("hp_percent", 0.3)), 0.01, 1.0)
					var max_hp_res: float = maxf(float(source_combat_res.get("max_hp")), 1.0)
					source_combat_res.restore_hp(max_hp_res * hp_percent)
					source.set_meta(resurrect_key, true)

		"aoe_percent_hp_damage":
			var aoe_radius: float = gateway._cells_to_world_distance(float(effect.get("radius", 2.0)), context)
			var percent: float = clampf(float(effect.get("percent", 0.05)), 0.0, 1.0)
			var aoe_type: String = str(effect.get("damage_type", "internal"))
			for enemy_percent in gateway._collect_enemy_units_in_radius(source, gateway._node_pos(source), aoe_radius, context):
				var enemy_max_hp: float = gateway._get_combat_value(enemy_percent, "max_hp")
				var percent_damage: float = maxf(enemy_max_hp * percent, 0.0)
				var dealt_percent: float = gateway._deal_damage(source, enemy_percent, percent_damage, aoe_type)
				summary["damage_total"] = float(summary.get("damage_total", 0.0)) + dealt_percent
				_handlers.append_damage_event(summary, gateway, source, enemy_percent, dealt_percent, aoe_type, op)

		"shield_self":
			gateway._apply_shield_self_op(source, effect, context, summary)

		"immunity_self":
			gateway._apply_immunity_self_op(source, effect, context, summary)

		"summon_units":
			var summoned_count: int = gateway._execute_summon_units_op(source, effect, context)
			summary["summon_total"] = int(summary.get("summon_total", 0)) + summoned_count

		"hazard_zone":
			var hazard_count: int = gateway._execute_hazard_zone_op(source, effect, context)
			summary["hazard_total"] = int(summary.get("hazard_total", 0)) + hazard_count

		"spawn_vfx":
			gateway._spawn_vfx_by_effect(source, target, effect, context)

		"teleport_behind":
			gateway._execute_teleport_behind_op(source, target, effect, context)

		"dash_forward":
			gateway._execute_dash_forward_op(source, target, effect, context)

		"knockback_target":
			gateway._execute_knockback_target_op(source, target, effect, context)

		"summon_clone":
			var clone_count: int = gateway._execute_summon_clone_op(source, effect, context)
			summary["summon_total"] = int(summary.get("summon_total", 0)) + clone_count

		"revive_random_ally":
			var revive_result: Dictionary = gateway._execute_revive_random_ally_op(source, effect, context)
			var revived_heal: float = float(revive_result.get("healed", 0.0))
			if revived_heal > 0.0:
				summary["heal_total"] = float(summary.get("heal_total", 0.0)) + revived_heal
				var revived_unit: Node = revive_result.get("unit", null)
				_handlers.append_heal_event(summary, source, revived_unit, revived_heal, op)

		"taunt_aoe":
			gateway._execute_taunt_aoe_op(source, effect, context, summary)

		"tag_linkage_branch":
			gateway._execute_tag_linkage_branch_op(source, target, effect, context, summary)

		_:
			push_warning("EffectEngine: 未实现效果?op=%s" % op)
