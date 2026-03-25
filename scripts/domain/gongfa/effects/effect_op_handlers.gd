extends RefCounted
class_name EffectOpHandlers


func create_empty_summary() -> Dictionary:
	return {
		"damage_total": 0.0,
		"heal_total": 0.0,
		"mp_total": 0.0,
		"summon_total": 0,
		"hazard_total": 0,
		"buff_applied": 0,
		"debuff_applied": 0,
		"damage_events": [],
		"heal_events": [],
		"mp_events": [],
		"buff_events": []
	}


func append_damage_event(
	summary: Dictionary,
	gateway: Variant,
	source: Node,
	target: Node,
	damage: float,
	damage_type: String,
	op: String
) -> void:
	var shield_absorbed: float = 0.0
	var immune_absorbed: float = 0.0
	if gateway != null:
		var last_meta: Variant = gateway.get("_last_damage_meta")
		if last_meta is Dictionary:
			shield_absorbed = float((last_meta as Dictionary).get("shield_absorbed", 0.0))
			immune_absorbed = float((last_meta as Dictionary).get("immune_absorbed", 0.0))
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
	if gateway != null:
		gateway.set("_last_damage_meta", {})


func append_buff_event(
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


func append_heal_event(
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


func append_mp_event(
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
