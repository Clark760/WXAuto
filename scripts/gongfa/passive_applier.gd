extends RefCounted

# M5 ?????/??????
# ??? unit_state ?????????????????????


func apply_state_to_unit(ctx: Node, unit_id: int, preserve_health_ratio: bool) -> void:
	if ctx == null:
		return
	var unit_states: Dictionary = ctx.get("_unit_states")
	if not unit_states.has(unit_id):
		return
	var state: Dictionary = unit_states[unit_id]
	var unit: Node = state.get("unit", null)
	if unit == null or not is_instance_valid(unit):
		return

	var runtime_stats: Dictionary = (state.get("baseline_stats", {}) as Dictionary).duplicate(true)
	var effect_engine: Variant = ctx.get("_effect_engine")
	var buff_manager: Variant = ctx.get("_buff_manager")
	if effect_engine == null or buff_manager == null:
		return
	var modifiers: Dictionary = effect_engine.call("create_empty_modifier_bundle")

	# ??????????????????????
	effect_engine.call("apply_passive_effects", runtime_stats, modifiers, state.get("passive_effects", []))
	effect_engine.call("apply_passive_effects", runtime_stats, modifiers, state.get("equipment_effects", []))
	effect_engine.call("apply_passive_effects", runtime_stats, modifiers, state.get("linkage_effects", []))
	effect_engine.call(
		"apply_passive_effects",
		runtime_stats,
		modifiers,
		buff_manager.call("collect_passive_effects_for_unit", unit)
	)
	ctx.call("_clamp_runtime_stats", runtime_stats)

	unit.set("runtime_stats", runtime_stats)
	unit.set("runtime_linkage_tags", state.get("runtime_linkage_tags", []))
	unit.set("runtime_gongfa_elements", state.get("runtime_elements", []))
	unit.set("runtime_equipped_gongfa_ids", state.get("equipped_gongfa_ids", []))
	unit.set("runtime_equipped_equip_ids", state.get("equipped_equip_ids", []))

	var combat: Node = unit.get_node_or_null("Components/UnitCombat")
	if combat != null:
		if combat.has_method("refresh_runtime_stats"):
			combat.call("refresh_runtime_stats", runtime_stats, preserve_health_ratio)
		else:
			combat.call("reset_from_stats", runtime_stats)
		if combat.has_method("set_external_modifiers"):
			combat.call("set_external_modifiers", modifiers)

	var movement: Node = unit.get_node_or_null("Components/UnitMovement")
	if movement != null:
		if movement.has_method("refresh_runtime_stats"):
			movement.call("refresh_runtime_stats", runtime_stats)
		else:
			movement.call("reset_from_stats", runtime_stats)


func reapply_changed_units(ctx: Node, changed_ids_variant: Variant) -> void:
	if not (changed_ids_variant is Array):
		return
	for iid_value in changed_ids_variant:
		apply_state_to_unit(ctx, int(iid_value), true)
