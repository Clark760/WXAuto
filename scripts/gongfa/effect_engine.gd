extends RefCounted
class_name GongfaEffectEngine
const DEFAULT_HEX_SIZE: float = 26.0
const PASSIVE_EFFECT_APPLIER_SCRIPT: Script = preload("res://scripts/domain/gongfa/effects/passive_effect_applier.gd")
const ACTIVE_EFFECT_DISPATCHER_SCRIPT: Script = preload("res://scripts/domain/gongfa/effects/active_effect_dispatcher.gd")
const EFFECT_OP_HANDLERS_SCRIPT: Script = preload("res://scripts/domain/gongfa/effects/effect_op_handlers.gd")
var _passive_effect_applier = PASSIVE_EFFECT_APPLIER_SCRIPT.new()
var _effect_op_handlers = EFFECT_OP_HANDLERS_SCRIPT.new()
var _active_effect_dispatcher = ACTIVE_EFFECT_DISPATCHER_SCRIPT.new(_effect_op_handlers)
var _last_damage_meta: Dictionary = {}
func create_empty_modifier_bundle() -> Dictionary:
	return _passive_effect_applier.create_empty_modifier_bundle()
func apply_passive_effects(runtime_stats: Dictionary, modifier_bundle: Dictionary, effects: Array, stack_multiplier: float = 1.0) -> void:
	_passive_effect_applier.apply_passive_effects(runtime_stats, modifier_bundle, effects, stack_multiplier)
func execute_active_effects(source: Node, target: Node, effects: Array, context: Dictionary = {}) -> Dictionary:
	var summary: Dictionary = _effect_op_handlers.create_empty_summary()
	for effect_value in effects:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value as Dictionary
		_dispatch_active_op(source, target, effect, context, summary)
	return summary
func _dispatch_active_op(source: Node, target: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	_active_effect_dispatcher.execute_active_op(self, source, target, effect, context, summary)
func _execute_teleport_behind_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	var distance_steps: int = maxi(int(effect.get("distance", 1)), 1)
	var combat_manager: Node = context.get("combat_manager", null)
	var hex_grid: Node = context.get("hex_grid", null)
	var has_grid_movement: bool = combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of")
	if has_grid_movement:
		var source_cell_value: Variant = combat_manager.call("get_unit_cell_of", source)
		var target_cell_value: Variant = combat_manager.call("get_unit_cell_of", target)
		if source_cell_value is Vector2i and target_cell_value is Vector2i:
			var source_cell: Vector2i = source_cell_value as Vector2i
			var target_cell: Vector2i = target_cell_value as Vector2i
			var target_cell_behind: Vector2i = _find_cell_behind_target(target_cell, source_cell, distance_steps, combat_manager, hex_grid)
			if target_cell_behind.x >= 0 and combat_manager.has_method("force_move_unit_to_cell"):
				if bool(combat_manager.call("force_move_unit_to_cell", source, target_cell_behind)):
					return true
		return false
	# Fallback without grid context: move in world-space direction.
	var source_pos: Vector2 = _node_pos(source)
	var target_pos: Vector2 = _node_pos(target)
	var dir: Vector2 = (target_pos - source_pos).normalized()
	if dir.is_zero_approx():
		dir = Vector2.RIGHT
	var teleport_world_distance: float = _cells_to_world_distance(float(distance_steps), context)
	var n2d_source: Node2D = source as Node2D
	if n2d_source != null:
		n2d_source.position = target_pos + dir * teleport_world_distance
		return true
	return false
func _execute_dash_forward_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	var distance_steps: int = maxi(int(effect.get("distance", 1)), 1)
	var combat_manager: Node = context.get("combat_manager", null)
	var has_grid_movement: bool = combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of") and combat_manager.has_method("move_unit_steps_towards")
	if has_grid_movement:
		var target_cell_value: Variant = combat_manager.call("get_unit_cell_of", target)
		if target_cell_value is Vector2i:
			return bool(combat_manager.call("move_unit_steps_towards", source, target_cell_value as Vector2i, distance_steps))
		return false
	var source_node: Node2D = source as Node2D
	var target_node: Node2D = target as Node2D
	if source_node == null or target_node == null:
		return false
	var dir: Vector2 = (target_node.position - source_node.position).normalized()
	if dir.is_zero_approx():
		return false
	source_node.position += dir * _cells_to_world_distance(float(distance_steps), context)
	return true
func _execute_knockback_target_op(source: Node, target: Node, effect: Dictionary, context: Dictionary) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if target == null or not is_instance_valid(target):
		return false
	var distance_steps: int = maxi(int(effect.get("distance", 1)), 1)
	var combat_manager: Node = context.get("combat_manager", null)
	var has_grid_movement: bool = combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("get_unit_cell_of") and combat_manager.has_method("move_unit_steps_away")
	if has_grid_movement:
		var source_cell_value: Variant = combat_manager.call("get_unit_cell_of", source)
		if source_cell_value is Vector2i:
			return bool(combat_manager.call("move_unit_steps_away", target, source_cell_value as Vector2i, distance_steps))
		return false
	var source_node: Node2D = source as Node2D
	var target_node: Node2D = target as Node2D
	if source_node == null or target_node == null:
		return false
	var dir: Vector2 = (target_node.position - source_node.position).normalized()
	if dir.is_zero_approx():
		dir = Vector2.RIGHT
	target_node.position += dir * _cells_to_world_distance(float(distance_steps), context)
	return true
func _execute_summon_clone_op(source: Node, effect: Dictionary, context: Dictionary) -> int:
	if source == null or not is_instance_valid(source):
		return 0
	var clone_count: int = maxi(int(effect.get("count", 1)), 1)
	var clone_star: int = clampi(int(effect.get("star", int(source.get("star_level")))), 1, 3)
	var clone_row: Dictionary = {
		"clone_source": "self",
		"count": clone_count,
		"star": clone_star
	}
	if effect.has("unit_id"):
		var unit_id: String = str(effect.get("unit_id", "")).strip_edges()
		if not unit_id.is_empty():
			clone_row["unit_id"] = unit_id
	if effect.has("hp_ratio"):
		clone_row["hp_ratio"] = maxf(float(effect.get("hp_ratio", 1.0)), 0.01)
	if effect.has("atk_ratio"):
		clone_row["atk_ratio"] = maxf(float(effect.get("atk_ratio", 1.0)), 0.01)
	var summon_effect: Dictionary = {
		"units": [clone_row],
		"deploy": str(effect.get("deploy", "around_self")).strip_edges().to_lower(),
		"radius": maxi(int(effect.get("radius", 2)), 0)
	}
	return _execute_summon_units_op(source, summon_effect, context)
func _execute_revive_random_ally_op(source: Node, effect: Dictionary, context: Dictionary) -> Dictionary:
	var result: Dictionary = {
		"unit": null,
		"healed": 0.0
	}
	if source == null or not is_instance_valid(source):
		return result
	var source_team: int = int(source.get("team_id"))
	var dead_allies: Array[Node] = []
	for unit in _get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if source_team != 0 and int(unit.get("team_id")) != source_team:
			continue
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null:
			continue
		if bool(combat.get("is_alive")):
			continue
		dead_allies.append(unit)
	if dead_allies.is_empty():
		return result
	var revive_index: int = randi() % dead_allies.size()
	var revived_unit: Node = dead_allies[revive_index]
	var revived_combat: Node = revived_unit.get_node_or_null("Components/UnitCombat")
	if revived_combat == null:
		return result
	var max_hp: float = maxf(float(revived_combat.get("max_hp")), 1.0)
	var revive_value: float = maxf(float(effect.get("value", 0.0)), 0.0)
	var revive_percent: float = clampf(float(effect.get("hp_percent", 0.35)), 0.01, 1.0)
	var restore_amount: float = revive_value if revive_value > 0.0 else max_hp * revive_percent
	var before_hp: float = float(revived_combat.get("current_hp"))
	revived_combat.call("restore_hp", restore_amount)
	var healed: float = maxf(float(revived_combat.get("current_hp")) - before_hp, 0.0)
	if healed <= 0.0:
		return result
	var combat_manager: Node = context.get("combat_manager", null)
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("add_unit_mid_battle"):
		combat_manager.call("add_unit_mid_battle", revived_unit)
	result["unit"] = revived_unit
	result["healed"] = healed
	return result
func _execute_taunt_aoe_op(source: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> int:
	if source == null or not is_instance_valid(source):
		return 0
	var taunt_radius: float = _cells_to_world_distance(float(effect.get("radius", 2.0)), context)
	var taunt_duration: float = maxf(float(effect.get("duration", 2.0)), 0.05)
	var taunt_buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	var taunted_count: int = 0
	for enemy in _collect_enemy_units_in_radius(source, _node_pos(source), taunt_radius, context):
		_apply_taunt_state(enemy, source, taunt_duration, context)
		taunted_count += 1
		if not taunt_buff_id.is_empty():
			if _apply_buff_op(source, enemy, {"buff_id": taunt_buff_id, "duration": taunt_duration}, context):
				summary["debuff_applied"] = int(summary.get("debuff_applied", 0)) + 1
				_effect_op_handlers.append_buff_event(summary, source, enemy, taunt_buff_id, taunt_duration, "taunt_aoe")
	return taunted_count
func _execute_tag_linkage_branch_op(source: Node, target: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return
	var gongfa_manager: Node = context.get("gongfa_manager", null)
	if gongfa_manager == null or not is_instance_valid(gongfa_manager):
		return
	var effect_key: String = _tag_linkage_effect_key(effect)
	var gate_allowed: bool = true
	var gate_decided: bool = false
	var gate_map_value: Variant = context.get("tag_linkage_gate_map", {})
	if gate_map_value is Dictionary:
		var gate_map: Dictionary = gate_map_value as Dictionary
		if gate_map.has(effect_key):
			gate_allowed = bool(gate_map.get(effect_key, true))
			gate_decided = true
	if not gate_decided and gongfa_manager.has_method("evaluate_tag_linkage_gate"):
		var gate_result_value: Variant = gongfa_manager.call("evaluate_tag_linkage_gate", source, effect, context)
		if gate_result_value is Dictionary:
			gate_allowed = bool((gate_result_value as Dictionary).get("allowed", true))
	if not gate_allowed:
		return
	if not gongfa_manager.has_method("evaluate_tag_linkage_branch"):
		return
	var result_value: Variant = gongfa_manager.call("evaluate_tag_linkage_branch", source, effect, context)
	if not (result_value is Dictionary):
		return
	var result: Dictionary = result_value as Dictionary
	if gongfa_manager.has_method("notify_tag_linkage_evaluated"):
		gongfa_manager.call("notify_tag_linkage_evaluated", source, effect, context, result)
	var branch_effects_value: Variant = result.get("effects", [])
	if not (branch_effects_value is Array):
		return
	var branch_effects: Array = branch_effects_value as Array
	var execution_mode: String = str(effect.get("execution_mode", "continuous")).strip_edges().to_lower()
	if execution_mode != "stateful":
		_execute_tag_linkage_child_effects(source, target, branch_effects, context, summary)
		return
	_execute_tag_linkage_stateful(source, target, effect, result, branch_effects, context, summary, gongfa_manager, effect_key)
func _execute_tag_linkage_child_effects(source: Node, target: Node, branch_effects: Array, context: Dictionary, summary: Dictionary) -> void:
	for child_effect_value in branch_effects:
		if not (child_effect_value is Dictionary):
			continue
		_dispatch_active_op(source, target, child_effect_value as Dictionary, context, summary)
func _execute_tag_linkage_stateful(
	source: Node,
	target: Node,
	effect: Dictionary,
	result: Dictionary,
	branch_effects: Array,
	context: Dictionary,
	summary: Dictionary,
	gongfa_manager: Node,
	effect_key: String
) -> void:
	var state: Dictionary = _get_tag_linkage_state(gongfa_manager, source, effect, effect_key)
	var previous_case_id: String = str(state.get("last_case_id", "")).strip_edges()
	var previous_buff_ids: Array[String] = _normalize_id_array(state.get("stateful_buff_ids", []))
	var next_case_id: String = _resolve_tag_linkage_case_id(result, branch_effects)
	var case_changed: bool = previous_case_id != next_case_id
	var next_buff_ids: Array[String] = previous_buff_ids.duplicate()
	if case_changed:
		_remove_stateful_buffs(source, previous_buff_ids, context)
		next_buff_ids.clear()
		var prepared_effects: Array[Dictionary] = _build_stateful_branch_effects(branch_effects, next_buff_ids)
		_execute_tag_linkage_child_effects(source, target, prepared_effects, context, summary)
	_set_tag_linkage_state(gongfa_manager, source, effect, effect_key, next_case_id, next_buff_ids)
func _build_stateful_branch_effects(branch_effects: Array, next_buff_ids: Array[String]) -> Array[Dictionary]:
	var prepared: Array[Dictionary] = []
	for child_effect_value in branch_effects:
		if not (child_effect_value is Dictionary):
			continue
		var child_effect: Dictionary = (child_effect_value as Dictionary).duplicate(true)
		var op: String = str(child_effect.get("op", "")).strip_edges()
		if op == "buff_self":
			var buff_id: String = str(child_effect.get("buff_id", "")).strip_edges()
			if not buff_id.is_empty() and not next_buff_ids.has(buff_id):
				next_buff_ids.append(buff_id)
			child_effect["duration"] = -1.0
		prepared.append(child_effect)
	return prepared
func _remove_stateful_buffs(source: Node, buff_ids: Array[String], context: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null or not buff_manager.has_method("remove_buff"):
		return
	for buff_id in buff_ids:
		var bid: String = buff_id.strip_edges()
		if bid.is_empty():
			continue
		buff_manager.call("remove_buff", source, bid, "tag_linkage_state_switch")
func _resolve_tag_linkage_case_id(result: Dictionary, branch_effects: Array) -> String:
	var matched_value: Variant = result.get("matched_case_ids", [])
	if matched_value is Array and not (matched_value as Array).is_empty():
		return str((matched_value as Array)[0]).strip_edges()
	if not branch_effects.is_empty():
		return "__else__"
	return ""
func _get_tag_linkage_state(gongfa_manager: Node, source: Node, effect: Dictionary, _effect_key: String) -> Dictionary:
	if gongfa_manager != null and is_instance_valid(gongfa_manager) and gongfa_manager.has_method("get_tag_linkage_state"):
		var state_value: Variant = gongfa_manager.call("get_tag_linkage_state", source, effect)
		if state_value is Dictionary:
			return (state_value as Dictionary).duplicate(true)
	return {"last_case_id": "", "stateful_buff_ids": []}
func _set_tag_linkage_state(gongfa_manager: Node, source: Node, effect: Dictionary, _effect_key: String, case_id: String, buff_ids: Array[String]) -> void:
	var normalized_ids: Array[String] = _normalize_id_array(buff_ids)
	if gongfa_manager != null and is_instance_valid(gongfa_manager) and gongfa_manager.has_method("set_tag_linkage_state"):
		gongfa_manager.call("set_tag_linkage_state", source, effect, case_id, normalized_ids)
	return
func _tag_linkage_effect_key(effect: Dictionary) -> String:
	return var_to_str(effect)
func _normalize_id_array(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for value in (raw as Array):
			var text: String = str(value).strip_edges()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out
func _apply_taunt_state(target: Node, source: Node, duration: float, context: Dictionary) -> void:
	if target == null or not is_instance_valid(target):
		return
	var now_logic: float = float(context.get("battle_elapsed", 0.0))
	var until_logic: float = now_logic + maxf(duration, 0.05)
	target.set_meta("status_taunt_until", maxf(float(target.get_meta("status_taunt_until", 0.0)), until_logic))
	if source != null and is_instance_valid(source):
		target.set_meta("status_taunt_source_id", source.get_instance_id())
		target.set_meta("status_taunt_source_team", int(source.get("team_id")))
func _find_cell_behind_target(target_cell: Vector2i, source_cell: Vector2i, distance_steps: int, combat_manager: Node, hex_grid: Node) -> Vector2i:
	var current: Vector2i = target_cell
	for _i in range(maxi(distance_steps, 1)):
		var next: Vector2i = _pick_neighbor_away_from_anchor(current, source_cell, combat_manager, hex_grid)
		if next == current:
			break
		current = next
	return current
func _pick_neighbor_away_from_anchor(current: Vector2i, anchor: Vector2i, combat_manager: Node, hex_grid: Node) -> Vector2i:
	var neighbors: Array[Vector2i] = _get_neighbor_cells(current, hex_grid)
	if neighbors.is_empty():
		return current
	var best: Vector2i = current
	var best_dist: int = _hex_distance_by_cell(current, anchor, hex_grid)
	for neighbor in neighbors:
		if not _is_cell_walkable_for_effect(neighbor, combat_manager, hex_grid):
			continue
		var dist: int = _hex_distance_by_cell(neighbor, anchor, hex_grid)
		if dist > best_dist:
			best_dist = dist
			best = neighbor
	return best
func _get_neighbor_cells(cell: Vector2i, hex_grid: Node) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if hex_grid == null or not is_instance_valid(hex_grid):
		return out
	if not hex_grid.has_method("get_neighbor_cells"):
		return out
	var neighbors_value: Variant = hex_grid.call("get_neighbor_cells", cell)
	if not (neighbors_value is Array):
		return out
	for neighbor_value in (neighbors_value as Array):
		if neighbor_value is Vector2i:
			out.append(neighbor_value as Vector2i)
	return out
func _is_cell_walkable_for_effect(cell: Vector2i, combat_manager: Node, hex_grid: Node) -> bool:
	if hex_grid != null and is_instance_valid(hex_grid) and hex_grid.has_method("is_inside_grid"):
		if not bool(hex_grid.call("is_inside_grid", cell)):
			return false
	if combat_manager != null and is_instance_valid(combat_manager) and combat_manager.has_method("is_cell_blocked"):
		if bool(combat_manager.call("is_cell_blocked", cell)):
			return false
	return true
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
	var terrain_ref_id: String = str(effect.get("terrain_ref_id", "")).strip_edges().to_lower()
	var terrain_type: String = str(effect.get("terrain_type", "")).strip_edges().to_lower()
	if terrain_ref_id.is_empty() and terrain_type.is_empty():
		terrain_type = "fire"
	var terrain_config: Dictionary = {
		"terrain_id": "terrain_%d_%s" % [Time.get_ticks_msec(), terrain_type if not terrain_type.is_empty() else terrain_ref_id],
		"center_cell": center_cell,
		"radius": maxi(int(effect.get("radius", 1)), 0),
		"duration": maxf(float(effect.get("duration", 1.0)), 0.1),
		"target_mode": str(effect.get("target_mode", "")).strip_edges().to_lower()
	}
	if effect.has("tick_interval"):
		terrain_config["tick_interval"] = maxf(float(effect.get("tick_interval", 0.5)), 0.05)
	if not terrain_ref_id.is_empty():
		terrain_config["terrain_ref_id"] = terrain_ref_id
	if not terrain_type.is_empty():
		terrain_config["terrain_type"] = terrain_type
	if effect.has("cells"):
		terrain_config["cells"] = effect.get("cells", [])
	if effect.has("tags"):
		terrain_config["tags"] = effect.get("tags", [])
	if effect.has("is_barrier"):
		terrain_config["is_barrier"] = bool(effect.get("is_barrier", false))
	if effect.has("effects_on_enter"):
		terrain_config["effects_on_enter"] = effect.get("effects_on_enter", [])
	if effect.has("effects_on_tick"):
		terrain_config["effects_on_tick"] = effect.get("effects_on_tick", [])
	if effect.has("effects_on_exit"):
		terrain_config["effects_on_exit"] = effect.get("effects_on_exit", [])
	if effect.has("effects_on_expire"):
		terrain_config["effects_on_expire"] = effect.get("effects_on_expire", [])
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
	var buff_manager: Variant = context.get("buff_manager", null)
	var shield_buff_id: String = str(effect.get("shield_buff_id", effect.get("buff_id", "buff_qi_shield"))).strip_edges()
	var shield_duration: float = float(effect.get("duration", -1.0))
	if buff_manager != null and not shield_buff_id.is_empty():
		if bool(buff_manager.call("apply_buff", source, shield_buff_id, shield_duration, source)):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_effect_op_handlers.append_buff_event(summary, source, source, shield_buff_id, shield_duration, "shield_self")
			source.set_meta("shield_bound_buff_id", shield_buff_id)
	# 可选：护盾开启时同步挂“免疫类 Buff”，便于按 Buff 时长自动过期。
	var immunity_buff_id: String = str(effect.get("immunity_buff_id", "")).strip_edges()
	if buff_manager != null and not immunity_buff_id.is_empty():
		var immunity_duration: float = float(effect.get("immunity_duration", shield_duration))
		if bool(buff_manager.call("apply_buff", source, immunity_buff_id, immunity_duration, source)):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_effect_op_handlers.append_buff_event(summary, source, source, immunity_buff_id, immunity_duration, "shield_self")
			source.set_meta("shield_immunity_buff_id", immunity_buff_id)
func _apply_immunity_self_op(source: Node, effect: Dictionary, context: Dictionary, summary: Dictionary) -> void:
	if source == null or not is_instance_valid(source):
		return
	# 仅通过 Buff 实现免疫，避免写入战斗元数据造成无过期状态。
	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	var duration: float = float(effect.get("duration", 0.0))
	if not buff_id.is_empty():
		if _apply_buff_op(source, source, {"buff_id": buff_id, "duration": duration}, context):
			summary["buff_applied"] = int(summary.get("buff_applied", 0)) + 1
			_effect_op_handlers.append_buff_event(summary, source, source, buff_id, duration, "immunity_self")
		return
	push_warning("EffectEngine: immunity_self missing buff_id, skipped.")
func _execute_summon_units_op(source: Node, effect: Dictionary, context: Dictionary) -> int:
	var battlefield: Node = context.get("battlefield", null)
	if battlefield == null or not is_instance_valid(battlefield):
		return 0
	if not battlefield.has_method("spawn_enemy_wave"):
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
	return int(battlefield.call("spawn_enemy_wave", rows))
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
	var dps: float = maxf(float(effect.get("value", 0.0)), 0.0)
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
	var application_key: String = str(effect.get("application_key", "")).strip_edges()
	if not application_key.is_empty() and buff_manager.has_method("apply_buff_with_options"):
		return bool(buff_manager.call(
			"apply_buff_with_options",
			target,
			buff_id,
			duration,
			source,
			{"application_key": application_key}
		))
	return bool(buff_manager.call("apply_buff", target, buff_id, duration, source))
func _is_source_bound_aura_binding(effect: Dictionary) -> bool:
	return str(effect.get("binding_mode", "default")).strip_edges().to_lower() == "source_bound_aura"
func _execute_source_bound_aura_op(source: Node, effect: Dictionary, targets: Array[Node], context: Dictionary) -> Dictionary:
	if source == null or not is_instance_valid(source):
		return {"applied_count": 0, "applied_targets": []}
	var buff_manager: Variant = context.get("buff_manager", null)
	if buff_manager == null or not buff_manager.has_method("refresh_source_bound_aura"):
		return {"applied_count": 0, "applied_targets": []}
	var buff_id: String = str(effect.get("buff_id", "")).strip_edges()
	if buff_id.is_empty():
		return {"applied_count": 0, "applied_targets": []}
	var scope_key: String = str(context.get("source_bound_aura_scope_key", "")).strip_edges()
	if scope_key.is_empty():
		scope_key = "%d|fallback_scope" % source.get_instance_id()
	var scope_refresh_token: int = int(context.get("source_bound_aura_scope_token", 0))
	var aura_key: String = _build_source_bound_aura_key(source, effect, scope_key)
	return buff_manager.call(
		"refresh_source_bound_aura",
		source,
		buff_id,
		aura_key,
		scope_key,
		scope_refresh_token,
		targets,
		context
	)
func _build_source_bound_aura_key(source: Node, effect: Dictionary, scope_key: String) -> String:
	var effect_signature: String = var_to_str(effect)
	if not scope_key.is_empty():
		return "%s|%s" % [scope_key, effect_signature]
	if source == null or not is_instance_valid(source):
		return effect_signature
	return "%d|%s" % [source.get_instance_id(), effect_signature]
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
func _collect_ally_units_in_radius(source: Node, center: Vector2, radius_world: float, context: Dictionary, exclude_self: bool = false) -> Array[Node]:
	var allies: Array[Node] = []
	var source_team: int = int(source.get("team_id")) if source != null and is_instance_valid(source) else 0
	for unit in _get_all_units(context):
		if unit == null or not is_instance_valid(unit):
			continue
		if exclude_self and unit == source:
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
