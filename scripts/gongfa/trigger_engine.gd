extends RefCounted

# M5 ????????
# ??????????????????/????? gongfa_manager ???????


func poll_auto_triggers(ctx: Node) -> void:
	if ctx == null:
		return
	var unit_states: Dictionary = ctx.get("_unit_states")
	for key in unit_states.keys():
		var iid: int = int(key)
		var state: Dictionary = unit_states[iid]
		var unit: Node = state.get("unit", null)
		if unit == null or not is_instance_valid(unit):
			continue
		if not bool(ctx.call("_is_unit_alive", unit)):
			continue

		var triggers: Array = state.get("triggers", [])
		for idx in range(triggers.size()):
			var entry: Dictionary = triggers[idx]
			var trigger: String = str(entry.get("trigger", "")).strip_edges().to_lower()
			# ?????????????(on_kill/on_attacked/on_buff_expired)?????
			if trigger == "auto_mp_full" 			or trigger == "manual" 			or trigger == "auto_hp_below" 			or trigger == "passive_aura" 			or trigger == "on_hp_below" 			or trigger == "on_time_elapsed" 			or trigger == "periodic_seconds":
				if bool(ctx.call("_can_trigger_entry", unit, entry, {})):
					ctx.call("_try_fire_skill", unit, entry, {})
			triggers[idx] = entry
		state["triggers"] = triggers
		unit_states[iid] = state


func fire_trigger_for_all(ctx: Node, trigger: String, context: Dictionary) -> void:
	if ctx == null:
		return
	var battle_units: Array = ctx.get("_battle_units")
	for unit in battle_units:
		fire_trigger_for_unit(ctx, unit, trigger, context)


func fire_trigger_for_unit(ctx: Node, unit: Node, trigger: String, context: Dictionary) -> void:
	if ctx == null:
		return
	if unit == null or not is_instance_valid(unit):
		return
	var iid: int = unit.get_instance_id()
	var unit_states: Dictionary = ctx.get("_unit_states")
	if not unit_states.has(iid):
		return
	var state: Dictionary = unit_states[iid]
	var triggers: Array = state.get("triggers", [])
	var trigger_name: String = trigger.strip_edges().to_lower()
	for idx in range(triggers.size()):
		var entry: Dictionary = triggers[idx]
		if str(entry.get("trigger", "")).strip_edges().to_lower() != trigger_name:
			continue
		if bool(ctx.call("_can_trigger_entry", unit, entry, context)):
			ctx.call("_try_fire_skill", unit, entry, context)
		triggers[idx] = entry
	state["triggers"] = triggers
	unit_states[iid] = state
