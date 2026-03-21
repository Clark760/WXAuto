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


func create_empty_modifier_bundle() -> Dictionary:
	# 这些字段是 UnitCombat 的“外部修正层”，不会直接写回 runtime_stats。
	return {
		"mp_regen_add": 0.0,
		# 生命回复同样放在外部修正层，按秒结算，避免污染基础面板数值。
		"hp_regen_add": 0.0,
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
			var healed: float = _heal_unit(source, heal_value)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed
			_append_heal_event(summary, source, source, healed, op)

		"heal_self_percent":
			var ratio: float = float(effect.get("value", 0.0))
			var max_hp: float = _get_combat_value(source, "max_hp")
			var healed_percent: float = _heal_unit(source, max_hp * ratio)
			summary["heal_total"] = float(summary.get("heal_total", 0.0)) + healed_percent
			_append_heal_event(summary, source, source, healed_percent, op)

		"heal_allies_aoe":
			var heal_radius: float = _cells_to_world_distance(float(effect.get("radius", 3.0)), context)
			var heal_amount: float = float(effect.get("value", 0.0))
			var heal_center: Vector2 = _node_pos(source)
			var allies: Array[Node] = _collect_ally_units_in_radius(source, heal_center, heal_radius, context)
			for ally in allies:
				var healed_ally: float = _heal_unit(ally, heal_amount)
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
	return (absi(dq) + absi(dq + dr) + absi(dr)) / 2


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
	if damage <= 0.0:
		return
	var damage_events: Array = summary.get("damage_events", [])
	damage_events.append({
		"source": source,
		"target": target,
		"damage": damage,
		"damage_type": damage_type,
		"op": op
	})
	summary["damage_events"] = damage_events


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
