extends "res://scripts/app/battlefield/battlefield_hud_text_support.gd"

# 把效果配置翻译成玩家可读文本，供 detail / tooltip / log 共用。
# 所有效果说明统一经过这里，后续改文案时只需要维护一个出口。
func format_effect_op(effect: Dictionary) -> String:
	var op: String = str(effect.get("op", "")).strip_edges()
	if op.is_empty():
		return ""
	var op_label: String = effect_op_to_cn(op)
	match op:
		"stat_add":
			return "%s：%s %s" % [
				op_label,
				stat_key_to_cn(str(effect.get("stat", ""))),
				_format_signed_number(float(effect.get("value", 0.0)))
			]
		"stat_percent":
			return "%s：%s %s" % [
				op_label,
				stat_key_to_cn(str(effect.get("stat", ""))),
				_format_signed_percent(float(effect.get("value", 0.0)))
			]
		"conditional_stat":
			return "%s：%s %s（条件=%s，阈值=%s）" % [
				op_label,
				stat_key_to_cn(str(effect.get("stat", ""))),
				_format_signed_number(float(effect.get("value", 0.0))),
				str(effect.get("condition", "")).strip_edges(),
				_format_number(float(effect.get("threshold", 0.0)))
			]
		"mp_regen_add":
			return "%s：%s/秒" % [op_label, _format_signed_number(float(effect.get("value", 0.0)))]
		"hp_regen_add":
			return "%s：%s/秒" % [op_label, _format_signed_number(float(effect.get("value", 0.0)))]
		"damage_reduce_flat", "thorns_flat", "shield_on_combat_start", "mp_on_kill", "range_add":
			return "%s：%s" % [op_label, _format_signed_number(float(effect.get("value", 0.0)))]
		"damage_reduce_percent", "dodge_bonus", "crit_bonus", "crit_damage_bonus", \
		"vampire", "damage_amp_percent", "tenacity", "thorns_percent", "execute_threshold", \
		"healing_amp", "attack_speed_bonus":
			return "%s：%s" % [op_label, _format_signed_percent(float(effect.get("value", 0.0)))]
		"damage_amp_vs_debuffed":
			var require_debuff: String = str(effect.get("require_debuff", "")).strip_edges()
			var debuff_text: String = "任意减益" if require_debuff.is_empty() else require_debuff
			return "%s：%s（%s）" % [
				op_label,
				_format_signed_percent(float(effect.get("value", 0.0))),
				debuff_text
			]
		"damage_target":
			return "%s：%s %s伤害" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external")))
			]
		"damage_aoe":
			return "%s：%s %s伤害（范围=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				_format_number(float(effect.get("radius", 0.0)))
			]
		"damage_chain":
			return "%s：%s %s伤害（跳数=%d，衰减=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				int(effect.get("chain_count", 0)),
				_format_percent(float(effect.get("decay", 0.0)))
			]
		"damage_cone":
			return "%s：%s %s伤害（距离=%s，角度=%s°）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				_format_number(float(effect.get("range", 0.0))),
				_format_number(float(effect.get("angle", 0.0)))
			]
		"damage_if_debuffed":
			var require_buff_id: String = str(effect.get("require_debuff", "")).strip_edges()
			return "%s：%s %s伤害（增伤倍率=%s，条件=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				_format_number(float(effect.get("bonus_multiplier", 1.0))),
				"任意减益" if require_buff_id.is_empty() else require_buff_id
			]
		"damage_if_marked":
			return "%s：%s %s伤害（标记=%s，增伤倍率=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				str(effect.get("mark_id", "")).strip_edges(),
				_format_number(float(effect.get("bonus_multiplier", 1.0)))
			]
		"damage_target_scaling":
			return "%s：%s %s伤害（%s×%s，来源=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				str(effect.get("scale_stat", "")).strip_edges(),
				_format_number(float(effect.get("scale_ratio", 0.0))),
				str(effect.get("scale_source", "auto")).strip_edges()
			]
		"execute_target":
			return "%s：%s %s伤害（阈值=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				_format_percent(float(effect.get("hp_threshold", 0.15)))
			]
		"aoe_percent_hp_damage":
			return "%s：%s最大生命 %s伤害（范围=%s）" % [
				op_label,
				_format_percent(float(effect.get("percent", 0.0))),
				damage_type_to_cn(str(effect.get("damage_type", "external"))),
				_format_number(float(effect.get("radius", 0.0)))
			]
		"heal_target_flat", "heal_self", "heal_lowest_ally":
			return "%s：%s" % [op_label, _format_number(float(effect.get("value", 0.0)))]
		"heal_self_percent":
			return "%s：%s最大生命" % [op_label, _format_percent(float(effect.get("value", 0.0)))]
		"heal_percent_missing_hp":
			return "%s：%s已损失生命" % [op_label, _format_percent(float(effect.get("value", 0.0)))]
		"heal_allies_aoe":
			return "%s：%s（范围=%s）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				_format_number(float(effect.get("radius", 0.0)))
			]
		"drain_mp":
			return "%s：%s" % [op_label, _format_number(float(effect.get("value", 0.0)))]
		"shield_self":
			return "%s：%s（%ss）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"shield_allies_aoe":
			return "%s：%s（范围=%s，%ss）" % [
				op_label,
				_format_number(float(effect.get("value", 0.0))),
				_format_number(float(effect.get("radius", 0.0))),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"immunity_self":
			return "%s：%s（%ss）" % [
				op_label,
				buff_name_from_id(str(effect.get("buff_id", ""))),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"buff_self", "buff_target", "debuff_target":
			return "%s：%s（%ss）" % [
				op_label,
				buff_name_from_id(str(effect.get("buff_id", ""))),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"buff_allies_aoe", "debuff_aoe":
			return "%s：%s（范围=%s，%ss）" % [
				op_label,
				buff_name_from_id(str(effect.get("buff_id", ""))),
				_format_number(float(effect.get("radius", 0.0))),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"mark_target":
			return "%s：%s（%ss）" % [
				op_label,
				str(effect.get("mark_id", "")).strip_edges(),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"cleanse_self", "cleanse_ally", "swap_position":
			return op_label
		"steal_buff", "dispel_target":
			return "%s：%d" % [op_label, maxi(int(effect.get("count", 1)), 1)]
		"pull_target", "knockback_target", "dash_forward", "teleport_behind":
			return "%s：距离=%s" % [op_label, _format_number(float(effect.get("distance", 1.0)))]
		"knockback_aoe":
			return "%s：范围=%s，距离=%s" % [
				op_label,
				_format_number(float(effect.get("radius", 0.0))),
				_format_number(float(effect.get("distance", 1.0)))
			]
		"silence_target", "stun_target", "freeze_target":
			return "%s：%ss" % [op_label, _format_number(float(effect.get("duration", 0.0)))]
		"fear_aoe", "taunt_aoe":
			return "%s：范围=%s，%ss" % [
				op_label,
				_format_number(float(effect.get("radius", 0.0))),
				_format_number(float(effect.get("duration", 0.0)))
			]
		"create_terrain":
			var terrain_id: String = str(effect.get("terrain_id", "")).strip_edges()
			if terrain_id.is_empty():
				terrain_id = str(effect.get("id", "")).strip_edges()
			return op_label if terrain_id.is_empty() else "%s：%s" % [op_label, terrain_id]
		"summon_units":
			var unit_count: int = 0
			if effect.has("units") and effect.get("units") is Array:
				for row in effect.get("units", []):
					if row is Dictionary:
						unit_count += maxi(int((row as Dictionary).get("count", 1)), 1)
			unit_count = unit_count if unit_count > 0 else maxi(int(effect.get("count", 1)), 1)
			return "%s：%d（部署=%s）" % [
				op_label,
				unit_count,
				str(effect.get("deploy", "")).strip_edges()
			]
		"hazard_zone":
			var hazard_text: String = "%s：范围=%s" % [
				op_label,
				_format_number(float(effect.get("radius", 0.0)))
			]
			if effect.has("value"):
				hazard_text += "，伤害=%s" % _format_number(float(effect.get("value", 0.0)))
			if effect.has("duration"):
				hazard_text += "，%ss" % _format_number(float(effect.get("duration", 0.0)))
			return hazard_text
		"spawn_vfx":
			return "%s：%s" % [op_label, str(effect.get("vfx_id", "")).strip_edges()]
		"summon_clone":
			return "%s：%d（单位=%s）" % [
				op_label,
				maxi(int(effect.get("count", 1)), 1),
				str(effect.get("unit_id", "")).strip_edges()
			]
		"revive_random_ally":
			var revive_text: String = "%s：%s" % [op_label, _format_number(float(effect.get("value", 0.0)))]
			if effect.has("hp_percent"):
				revive_text += "（或%s最大生命）" % _format_percent(float(effect.get("hp_percent", 0.0)))
			return revive_text
		"resurrect_self":
			return "%s：%s最大生命（key=%s）" % [
				op_label,
				_format_percent(float(effect.get("hp_percent", 0.0))),
				str(effect.get("resurrect_key", "default")).strip_edges()
			]
		"tag_linkage_branch":
			return _format_tag_linkage_branch_op(op_label, effect)
		_:
			return "%s：%s" % [op_label, str(effect)]


func _extract_gongfa_skill_entries(gongfa_data: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var skills_value: Variant = gongfa_data.get("skills", [])
	if not (skills_value is Array):
		return output
	for skill_value in (skills_value as Array):
		if not (skill_value is Dictionary):
			continue
		var entry: Dictionary = _normalize_skill_entry(skill_value as Dictionary)
		if not entry.is_empty():
			output.append(entry)
	return output


func _extract_equip_skill_entries(equip_data: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var trigger_value: Variant = equip_data.get("trigger", {})
	if trigger_value is Dictionary:
		var single_entry: Dictionary = _normalize_skill_entry(trigger_value as Dictionary)
		if not single_entry.is_empty():
			output.append(single_entry)
		return output
	if not (trigger_value is Array):
		return output
	for trigger_item in (trigger_value as Array):
		if not (trigger_item is Dictionary):
			continue
		var entry: Dictionary = _normalize_skill_entry(trigger_item as Dictionary)
		if not entry.is_empty():
			output.append(entry)
	return output


func _normalize_skill_entry(raw_entry: Dictionary) -> Dictionary:
	var entry: Dictionary = raw_entry.duplicate(true)
	var trigger_name: String = _normalize_trigger_name(
		str(entry.get("trigger", entry.get("type", "")))
	)
	if trigger_name.is_empty():
		return {}
	entry["trigger"] = trigger_name
	var trigger_params_value: Variant = entry.get("trigger_params", {})
	if not (trigger_params_value is Dictionary):
		entry["trigger_params"] = {}
	return entry


func _build_skill_tooltip_payload(skill_entries: Array[Dictionary]) -> Dictionary:
	if skill_entries.is_empty():
		return {
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": []
		}
	var trigger_parts: Array[String] = []
	var effect_lines: Array[String] = []
	var section_counters: Dictionary = {}
	for entry in skill_entries:
		var section_label: String = _resolve_skill_section_label(entry, section_counters)
		trigger_parts.append("%s：%s" % [section_label, _format_skill_trigger_summary(entry)])
		effect_lines.append_array(
			_format_skill_effect_lines(section_label, entry.get("effects", []))
		)
	if effect_lines.is_empty():
		effect_lines.append("未命中触发器：无效果")
	return {
		"has_skill": true,
		"skill_trigger": "触发：%s" % "；".join(trigger_parts),
		"skill_effects": effect_lines
	}


func _resolve_skill_section_label(skill_entry: Dictionary, counters: Dictionary) -> String:
	var trigger_name: String = _normalize_trigger_name(
		str(skill_entry.get("trigger", skill_entry.get("type", "")))
	)
	var group_key: String = _resolve_trigger_group_key(trigger_name)
	var count: int = int(counters.get(group_key, 0)) + 1
	counters[group_key] = count
	var base_label: String = _trigger_group_key_to_cn(group_key)
	if count <= 1:
		return base_label
	return "%s#%d" % [base_label, count]


func _resolve_trigger_group_key(trigger_name: String) -> String:
	if trigger_name == "manual":
		return "manual"
	if trigger_name == "auto_mp_full" \
	or trigger_name == "auto_hp_below" \
	or trigger_name == "on_hp_below" \
	or trigger_name == "on_time_elapsed" \
	or trigger_name == "periodic_seconds" \
	or trigger_name == "passive_aura":
		return "periodic"
	if trigger_name.begins_with("on_"):
		return "event"
	return "misc"


func _trigger_group_key_to_cn(group_key: String) -> String:
	match group_key:
		"manual":
			return "主动触发"
		"periodic":
			return "轮询触发"
		"event":
			return "事件触发"
		_:
			return "其他触发"


func _format_skill_effect_lines(section_label: String, effects_value: Variant) -> Array[String]:
	var lines: Array[String] = []
	if effects_value is Array:
		for effect_value in (effects_value as Array):
			if not (effect_value is Dictionary):
				continue
			var effect_line: String = format_effect_op(effect_value as Dictionary)
			if effect_line.is_empty():
				continue
			lines.append("%s：%s" % [section_label, effect_line])
	if lines.is_empty():
		lines.append("%s：无效果" % section_label)
	return lines


func _format_skill_trigger_summary(skill_entry: Dictionary) -> String:
	var trigger_name: String = _normalize_trigger_name(
		str(skill_entry.get("trigger", skill_entry.get("type", "")))
	)
	if trigger_name.is_empty():
		return "未配置触发器"
	var trigger_label: String = trigger_to_cn(trigger_name)
	var trigger_params: Dictionary = {}
	var trigger_params_value: Variant = skill_entry.get("trigger_params", {})
	if trigger_params_value is Dictionary:
		trigger_params = trigger_params_value as Dictionary
	var details: Array[String] = []
	_append_trigger_condition_details(details, trigger_name, trigger_params, skill_entry)
	var cooldown: float = maxf(float(skill_entry.get("cooldown", 0.0)), 0.0)
	if cooldown > 0.0:
		details.append("冷却=%ss" % _format_number(cooldown))
	var chance: float = clampf(float(skill_entry.get("chance", 1.0)), 0.0, 1.0)
	if chance < 0.999:
		details.append("概率=%s" % _format_percent(chance))
	var mp_cost: float = maxf(float(skill_entry.get("mp_cost", 0.0)), 0.0)
	if mp_cost > 0.0:
		details.append("耗内=%s" % _format_number(mp_cost))
	if details.is_empty():
		return trigger_label
	return "%s（%s）" % [trigger_label, "，".join(details)]


func _append_trigger_condition_details(
	details: Array[String],
	trigger_name: String,
	trigger_params: Dictionary,
	skill_entry: Dictionary
) -> void:
	match trigger_name:
		"periodic_seconds":
			var interval: float = maxf(
				float(trigger_params.get("interval", skill_entry.get("interval", 0.0))),
				0.0
			)
			if interval > 0.0:
				details.append("间隔=%ss" % _format_number(interval))
		"on_time_elapsed":
			var at_seconds: float = float(
				trigger_params.get("at_seconds", skill_entry.get("at_seconds", -1.0))
			)
			if at_seconds >= 0.0:
				details.append("时点=%ss" % _format_number(at_seconds))
		"auto_hp_below", "on_hp_below":
			var threshold: float = clampf(
				float(trigger_params.get("threshold", skill_entry.get("threshold", 0.3))),
				0.0,
				1.0
			)
			details.append("阈值=%s" % _format_percent(threshold))
		"on_attack_fail", "on_unit_move_failed":
			var reasons: Array[String] = _variant_to_string_array(trigger_params.get("reasons", []))
			if not reasons.is_empty():
				details.append("原因=%s" % " / ".join(reasons))
		"on_damage_received":
			if trigger_params.has("min_damage"):
				details.append("最低受伤=%s" % _format_number(float(trigger_params.get("min_damage", 0.0))))
		"on_heal_received":
			if trigger_params.has("min_heal"):
				details.append("最低受疗=%s" % _format_number(float(trigger_params.get("min_heal", 0.0))))
		"on_thorns_triggered":
			if trigger_params.has("min_reflect"):
				details.append("最低反伤=%s" % _format_number(float(trigger_params.get("min_reflect", 0.0))))
		"on_debuff_applied":
			var debuff_id: String = str(
				trigger_params.get("debuff_id", skill_entry.get("debuff_id", ""))
			).strip_edges()
			if not debuff_id.is_empty():
				details.append("Debuff=%s" % debuff_id)
		"on_buff_expired":
			var watch_buff_id: String = str(
				trigger_params.get("watch_buff_id", trigger_params.get("buff_id", ""))
			).strip_edges()
			if watch_buff_id.is_empty():
				watch_buff_id = str(
					skill_entry.get("watch_buff_id", skill_entry.get("buff_id", ""))
				).strip_edges()
			if not watch_buff_id.is_empty():
				details.append("监听Buff=%s" % watch_buff_id)
		"on_terrain_created", "on_terrain_enter", "on_terrain_tick", "on_terrain_exit", "on_terrain_expire":
			var any_tags: Array[String] = _variant_to_string_array(trigger_params.get("terrain_tags_any", []))
			if not any_tags.is_empty():
				details.append("地形任一=%s" % " / ".join(any_tags))
			var all_tags: Array[String] = _variant_to_string_array(trigger_params.get("terrain_tags_all", []))
			if not all_tags.is_empty():
				details.append("地形全部=%s" % " / ".join(all_tags))
		_:
			pass
	_append_team_alive_filter_details(details, trigger_params)


func _append_team_alive_filter_details(details: Array[String], trigger_params: Dictionary) -> void:
	var has_min_alive: bool = trigger_params.has("team_alive_at_least")
	var has_max_alive: bool = trigger_params.has("team_alive_at_most")
	if not has_min_alive and not has_max_alive:
		return
	var scope_key: String = str(
		trigger_params.get("team_scope", trigger_params.get("team_alive_scope", "ally"))
	).strip_edges().to_lower()
	var scope_label: String = trigger_team_scope_to_cn(scope_key)
	var scope_text: String = "统计阵营=%s" % scope_label
	if bool(trigger_params.get("exclude_self", false)):
		scope_text += "（不含自身）"
	details.append(scope_text)
	if has_min_alive:
		details.append("存活>= %d" % int(trigger_params.get("team_alive_at_least", 0)))
	if has_max_alive:
		details.append("存活<= %d" % int(trigger_params.get("team_alive_at_most", 0)))


func _format_tag_linkage_branch_op(op_label: String, effect: Dictionary) -> String:
	var linkage_id: String = str(effect.get("linkage_id", "")).strip_edges()
	if linkage_id.is_empty():
		linkage_id = "未命名联动"
	var summary: Array[String] = []
	if effect.has("range"):
		summary.append("范围=%s格" % _format_number(float(effect.get("range", 0.0))))
	if effect.has("include_self"):
		summary.append("含自身=%s" % ("是" if bool(effect.get("include_self", false)) else "否"))
	var team_scope_key: String = str(effect.get("team_scope", "ally")).strip_edges().to_lower()
	summary.append("阵营=%s" % linkage_team_scope_to_cn(team_scope_key))
	var count_mode_key: String = str(effect.get("count_mode", "provider")).strip_edges().to_lower()
	summary.append("计数=%s" % linkage_count_mode_to_cn(count_mode_key))
	var execution_mode_key: String = str(effect.get("execution_mode", "continuous")).strip_edges().to_lower()
	summary.append("模式=%s" % linkage_execution_mode_to_cn(execution_mode_key))
	var source_types: Array[String] = _variant_to_string_array(effect.get("source_types", []), true)
	if not source_types.is_empty():
		var source_labels: Array[String] = []
		for source_type in source_types:
			source_labels.append(linkage_source_type_to_cn(source_type))
		summary.append("来源=%s" % " / ".join(source_labels))
	if effect.has("stop_after_first_case"):
		summary.append("首档停表=%s" % ("是" if bool(effect.get("stop_after_first_case", false)) else "否"))
	var text: String = "%s：%s" % [op_label, linkage_id]
	if not summary.is_empty():
		text += "（%s）" % "，".join(summary)

	var query_descs: Array[String] = []
	var queries_value: Variant = effect.get("queries", [])
	if queries_value is Array:
		for idx in range((queries_value as Array).size()):
			var query_value: Variant = (queries_value as Array)[idx]
			if query_value is Dictionary:
				query_descs.append(_format_tag_linkage_query_desc(query_value as Dictionary, idx))
	if not query_descs.is_empty():
		text += "；查询：" + "；".join(query_descs)

	var case_descs: Array[String] = []
	var cases_value: Variant = effect.get("cases", [])
	if cases_value is Array:
		for idx in range((cases_value as Array).size()):
			var case_value: Variant = (cases_value as Array)[idx]
			if case_value is Dictionary:
				case_descs.append(_format_tag_linkage_case_desc(case_value as Dictionary, idx))
	if not case_descs.is_empty():
		text += "；档位：" + "；".join(case_descs)
	var else_effects_value: Variant = effect.get("else_effects", [])
	if else_effects_value is Array and not (else_effects_value as Array).is_empty():
		text += "；否则：生效"
	return text


func _format_tag_linkage_query_desc(query: Dictionary, index: int) -> String:
	var query_id: String = str(query.get("id", "q_%d" % index)).strip_edges()
	if query_id.is_empty():
		query_id = "q_%d" % index
	var query_type: String = str(query.get("query_type", "match_tags")).strip_edges().to_lower()
	var tags: Array[String] = _variant_to_string_array(query.get("tags", []), true)
	var base_desc: String = "无标签"
	if query_type == "forbid_tags":
		base_desc = "禁匹配[%s]" % " / ".join(tags)
	elif not tags.is_empty():
		base_desc = "%s[%s]" % [
			linkage_tag_match_to_cn(str(query.get("tag_match", "any")).strip_edges().to_lower()),
			" / ".join(tags)
		]
	var details: Array[String] = []
	var source_types: Array[String] = _variant_to_string_array(query.get("source_types", []), true)
	if not source_types.is_empty():
		var source_labels: Array[String] = []
		for source_type in source_types:
			source_labels.append(linkage_source_type_to_cn(source_type))
		details.append("来源=%s" % " / ".join(source_labels))
	var team_scope_key: String = str(query.get("team_scope", "")).strip_edges().to_lower()
	if not team_scope_key.is_empty():
		details.append("阵营=%s" % linkage_team_scope_to_cn(team_scope_key))
	var origin_scope_key: String = str(query.get("origin_scope", "")).strip_edges().to_lower()
	if not origin_scope_key.is_empty():
		details.append("来源域=%s" % linkage_origin_scope_to_cn(origin_scope_key))
	if bool(query.get("unique_source_name", false)):
		details.append("同名去重")
	var exclude_tags: Array[String] = _variant_to_string_array(query.get("exclude_tags", []), true)
	if not exclude_tags.is_empty():
		details.append("排除=%s[%s]" % [
			linkage_tag_match_to_cn(str(query.get("exclude_match", "any")).strip_edges().to_lower()),
			" / ".join(exclude_tags)
		])
	if details.is_empty():
		return "%s：%s" % [query_id, base_desc]
	return "%s：%s（%s）" % [query_id, base_desc, "，".join(details)]


func _format_tag_linkage_case_desc(case_data: Dictionary, index: int) -> String:
	var case_id: String = str(case_data.get("id", "case_%d" % index)).strip_edges()
	if case_id.is_empty():
		case_id = "case_%d" % index
	var clause_descs: Array[String] = []
	var all_clause: String = _format_tag_linkage_case_clause("全满足", case_data.get("all", null))
	if not all_clause.is_empty():
		clause_descs.append(all_clause)
	var any_clause: String = _format_tag_linkage_case_clause("任一满足", case_data.get("any", null))
	if not any_clause.is_empty():
		clause_descs.append(any_clause)
	var not_clause: String = _format_tag_linkage_case_clause("全部不满足", case_data.get("not", null))
	if not not_clause.is_empty():
		clause_descs.append(not_clause)
	if case_data.has("query_id"):
		var default_term: String = _format_tag_linkage_case_term(case_data)
		if not default_term.is_empty():
			clause_descs.append("条件=%s" % default_term)
	if clause_descs.is_empty():
		clause_descs.append("默认命中")
	return "%s[%s]" % [case_id, "；".join(clause_descs)]


func _format_tag_linkage_case_clause(label: String, clause_value: Variant) -> String:
	if not (clause_value is Array):
		return ""
	var term_texts: Array[String] = []
	for term_value in (clause_value as Array):
		if not (term_value is Dictionary):
			continue
		var term_text: String = _format_tag_linkage_case_term(term_value as Dictionary)
		if not term_text.is_empty():
			term_texts.append(term_text)
	if term_texts.is_empty():
		return ""
	return "%s:%s" % [label, " 且 ".join(term_texts)]


func _format_tag_linkage_case_term(term: Dictionary) -> String:
	var query_id: String = str(term.get("query_id", "")).strip_edges()
	if query_id.is_empty():
		return ""
	var parts: Array[String] = [query_id]
	if term.has("min_count"):
		parts.append(">=%d" % int(term.get("min_count", 0)))
	if term.has("max_count"):
		parts.append("<=%d" % int(term.get("max_count", 0)))
	if term.has("equals"):
		parts.append("=%d" % int(term.get("equals", 0)))
	if term.has("count"):
		parts.append("=%d" % int(term.get("count", 0)))
	return " ".join(parts)


func _variant_to_string_array(value: Variant, to_lower: bool = false) -> Array[String]:
	var out: Array[String] = []
	if not (value is Array):
		return out
	for item in (value as Array):
		var text: String = str(item).strip_edges()
		if to_lower:
			text = text.to_lower()
		if text.is_empty():
			continue
		out.append(text)
	return out
