extends "res://scripts/app/battlefield/battlefield_hud_effect_formatter_support.gd"

# 把运行时生效的功法与装备效果整理成详情面板的 bonus 列表。
# 这里故意读取 runtime_*_ids，而不是静态已装备槽，确保展示的是实际生效效果。
# 把运行时已生效的功法和装备效果整理成详情面板 bonus 列表。
# 这里只读 runtime_*_ids，确保展示的是战斗中真正生效的效果。
func build_gongfa_bonus_lines(unit: Node) -> Array[String]:
	var lines: Array[String] = []
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager == null:
		return lines
	var runtime_gongfa_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	for gongfa_id_value in runtime_gongfa_ids:
		var gongfa_id: String = str(gongfa_id_value)
		var data: Dictionary = unit_augment_manager.get_gongfa_data(gongfa_id)
		if data.is_empty():
			continue
		var gongfa_name: String = str(data.get("name", gongfa_id))
		var passive_effects: Variant = data.get("passive_effects", [])
		if passive_effects is Array:
			for effect_value in passive_effects:
				if effect_value is Dictionary:
					lines.append(
						"%s: %s" % [gongfa_name, format_effect_op(effect_value as Dictionary)]
					)
	var runtime_equip_ids: Array = unit.get("runtime_equipped_equip_ids")
	for equip_id_value in runtime_equip_ids:
		var equip_id: String = str(equip_id_value)
		var equip_data: Dictionary = unit_augment_manager.get_equipment_data(equip_id)
		if equip_data.is_empty():
			continue
		var equip_name: String = str(equip_data.get("name", equip_id))
		var effects: Variant = equip_data.get("effects", [])
		if effects is Array:
			for effect_value in effects:
				if effect_value is Dictionary:
					lines.append(
						"%s: %s" % [equip_name, format_effect_op(effect_value as Dictionary)]
					)
	return lines


# 把角色内置特性转成统一的物品 tooltip 结构，便于 tooltip 共用渲染。
# trait 和 item 最终共用一套 payload，是为了让 detail view 只维护一个 renderer。
func build_trait_item_tooltip_data(trait_data: Dictionary) -> Dictionary:
	var effects: Array[String] = []
	var trait_effects: Variant = trait_data.get("effects", [])
	if trait_effects is Array:
		for effect_value in trait_effects:
			if effect_value is Dictionary:
				effects.append(format_effect_op(effect_value as Dictionary))
	return {
		"name": "特性·%s" % str(trait_data.get("name", trait_data.get("id", "未命名特性"))),
		"type_line": "内置特性 · 不可装卸",
		"desc": str(trait_data.get("description", "无描述")),
		"effects": effects,
		"has_skill": false,
		"skill_trigger": "",
		"skill_effects": []
	}


# 把功法配置转成统一 tooltip payload，避免多个面板各自拼装文本。
# 缺数据时也返回完整 payload 结构，调用方就不用再写一层兜底分支。
func build_gongfa_item_tooltip_data(gongfa_id: String) -> Dictionary:
	var data: Dictionary = {}
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager != null:
		data = unit_augment_manager.get_gongfa_data(gongfa_id)
	if data.is_empty():
		return {
			"name": gongfa_id,
			"type_line": "功法",
			"desc": "未找到功法数据",
			"effects": [],
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": []
		}
	var effect_lines: Array[String] = []
	var passive_effects: Variant = data.get("passive_effects", [])
	if passive_effects is Array:
		for effect_value in passive_effects:
			if effect_value is Dictionary:
				effect_lines.append(format_effect_op(effect_value as Dictionary))
	var skill_payload: Dictionary = _build_skill_tooltip_payload(_extract_gongfa_skill_entries(data))
	return {
		"name": "%s [%s]" % [
			str(data.get("name", gongfa_id)),
			quality_to_cn(str(data.get("quality", "white")))
		],
		"type_line": "%s · %s" % [
			slot_to_cn(str(data.get("type", ""))),
			element_to_cn(str(data.get("element", "none")))
		],
		"desc": str(data.get("description", "无描述")),
		"effects": effect_lines,
		"has_skill": bool(skill_payload.get("has_skill", false)),
		"skill_trigger": str(skill_payload.get("skill_trigger", "")),
		"skill_effects": skill_payload.get("skill_effects", [])
	}


# 返回详情面板用的功法显示名，空槽时直接给出“空”。
# 名称入口收敛后，detail 行和其他地方不会再各自决定空槽文案。
func gongfa_name_or_empty(gongfa_id: String) -> String:
	if gongfa_id.is_empty():
		return "空"
	return str(build_gongfa_item_tooltip_data(gongfa_id).get("name", gongfa_id))


# 把装备配置转成统一 tooltip payload，供 detail / inventory / shop 共用。
# 装备与功法 payload 结构对齐，方便 tooltip renderer 直接复用。
func build_equip_item_tooltip_data(equip_id: String) -> Dictionary:
	var data: Dictionary = {}
	var unit_augment_manager = _get_unit_augment_manager()
	if unit_augment_manager != null:
		data = unit_augment_manager.get_equipment_data(equip_id)
	if data.is_empty():
		return {
			"name": equip_id,
			"type_line": "装备",
			"desc": "未找到装备数据",
			"effects": [],
			"has_skill": false,
			"skill_trigger": "",
			"skill_effects": []
		}
	var effect_lines: Array[String] = []
	var effects: Variant = data.get("effects", [])
	if effects is Array:
		for effect_value in effects:
			if effect_value is Dictionary:
				effect_lines.append(format_effect_op(effect_value as Dictionary))
	var skill_payload: Dictionary = _build_skill_tooltip_payload(_extract_equip_skill_entries(data))
	return {
		"name": "%s [%s]" % [
			str(data.get("name", equip_id)),
			quality_to_cn(str(data.get("quality", "white")))
		],
		"type_line": "%s · %s" % [
			equip_type_to_cn(str(data.get("type", "weapon"))),
			element_to_cn(str(data.get("element", "none")))
		],
		"desc": str(data.get("description", "江湖器物")),
		"effects": effect_lines,
		"has_skill": bool(skill_payload.get("has_skill", false)),
		"skill_trigger": str(skill_payload.get("skill_trigger", "")),
		"skill_effects": skill_payload.get("skill_effects", [])
	}


# 返回详情面板用的装备显示名，空槽时直接给出“空”。
# 这里直接复用 tooltip payload 中的名字，避免显示名来源分叉。
func equip_name_or_empty(equip_id: String) -> String:
	if equip_id.is_empty():
		return "空"
	return str(build_equip_item_tooltip_data(equip_id).get("name", equip_id))


# 把 tooltip payload 压成一行短说明，供特性/功法/装备列表行复用。
func build_payload_brief_text(payload: Dictionary, fallback: String = "") -> String:
	if payload.is_empty():
		return fallback
	var type_line: String = str(payload.get("type_line", "")).strip_edges()
	var effect_line: String = ""
	var effects_value: Variant = payload.get("effects", [])
	if effects_value is Array:
		for line_value in (effects_value as Array):
			effect_line = str(line_value).strip_edges()
			if not effect_line.is_empty():
				break
	if effect_line.is_empty():
		effect_line = fallback.strip_edges()
	if type_line.is_empty():
		return effect_line
	if effect_line.is_empty():
		return type_line
	return "%s｜%s" % [type_line, effect_line]


# 构建单位详情页“联动与特效”分页所需的实时快照。
func build_unit_runtime_snapshot(unit: Node) -> Dictionary:
	var empty_snapshot: Dictionary = {
		"linkage_lines": [],
		"effect_lines": []
	}
	if not is_valid_unit(unit):
		return empty_snapshot
	var manager = _get_unit_augment_manager()
	if manager == null:
		return empty_snapshot
	var state_snapshot: Dictionary = _get_unit_state_snapshot(unit, manager)
	var linkage_lines: Array[String] = _build_runtime_linkage_lines(unit, manager, state_snapshot)
	var effect_lines: Array[String] = _build_runtime_effect_lines(unit, manager, state_snapshot)
	return {
		"linkage_lines": _trim_lines(linkage_lines, 18, "联动"),
		"effect_lines": _trim_lines(effect_lines, 24, "特效")
	}


func _build_runtime_linkage_lines(
	unit: Node,
	manager,
	state_snapshot: Dictionary
) -> Array[String]:
	var lines: Array[String] = []
	var entries: Array[Dictionary] = _collect_linkage_effect_entries(state_snapshot)
	if entries.is_empty():
		return lines
	var trait_owner_labels: Dictionary = _build_trait_owner_label_map(unit)
	var context: Dictionary = _build_linkage_eval_context(unit, manager)
	for entry in entries:
		var effect: Dictionary = entry.get("effect", {})
		if effect.is_empty():
			continue
		var linkage_id: String = str(effect.get("linkage_id", "未命名联动")).strip_edges()
		if linkage_id.is_empty():
			linkage_id = "未命名联动"
		var owner_id: String = str(entry.get("owner_id", "")).strip_edges()
		var owner_label: String = _resolve_owner_label(owner_id, manager, trait_owner_labels)
		var trigger_name: String = str(entry.get("trigger", "")).strip_edges().to_lower()
		var trigger_suffix: String = ""
		if not trigger_name.is_empty():
			trigger_suffix = "，%s" % trigger_to_cn(trigger_name)
		var result: Dictionary = {}
		if manager.has_method("evaluate_tag_linkage_branch"):
			var result_value: Variant = manager.evaluate_tag_linkage_branch(unit, effect, context)
			if result_value is Dictionary:
				result = result_value as Dictionary
		var matched_case_ids: Array[String] = []
		var matched_case_value: Variant = result.get("matched_case_ids", [])
		if matched_case_value is Array:
			for case_value in (matched_case_value as Array):
				var case_id: String = str(case_value).strip_edges()
				if not case_id.is_empty():
					matched_case_ids.append(case_id)
		var matched_text: String = "未命中"
		if not matched_case_ids.is_empty():
			matched_text = "命中=%s" % "/".join(matched_case_ids)
		var active_case: String = ""
		if manager.has_method("get_tag_linkage_state"):
			var linkage_state_value: Variant = manager.get_tag_linkage_state(unit, effect)
			if linkage_state_value is Dictionary:
				active_case = str(
					(linkage_state_value as Dictionary).get("last_case_id", "")
				).strip_edges()
		var active_text: String = ""
		if not active_case.is_empty():
			active_text = "，当前档位=%s" % active_case
		var query_counts_text: String = _format_query_counts(result.get("query_counts", {}))
		lines.append("%s｜%s%s：%s%s%s" % [
			linkage_id,
			owner_label,
			trigger_suffix,
			matched_text,
			active_text,
			query_counts_text
		])
	return lines


func _build_runtime_effect_lines(
	unit: Node,
	manager,
	state_snapshot: Dictionary
) -> Array[String]:
	var lines: Array[String] = []
	var trait_values: Variant = safe_node_prop(unit, "traits", [])
	if trait_values is Array:
		for trait_value in (trait_values as Array):
			if not (trait_value is Dictionary):
				continue
			var trait_data: Dictionary = trait_value as Dictionary
			_append_source_effect_lines(
				lines,
				"特性·%s" % str(trait_data.get("name", trait_data.get("id", "未命名特性"))),
				trait_data.get("effects", [])
			)
	var runtime_gongfa_ids: Array = unit.get("runtime_equipped_gongfa_ids")
	for gongfa_id_value in runtime_gongfa_ids:
		var gongfa_id: String = str(gongfa_id_value).strip_edges()
		if gongfa_id.is_empty():
			continue
		var gongfa_data: Dictionary = manager.get_gongfa_data(gongfa_id)
		if gongfa_data.is_empty():
			continue
		_append_source_effect_lines(
			lines,
			"功法·%s" % str(gongfa_data.get("name", gongfa_id)),
			gongfa_data.get("passive_effects", [])
		)
	var runtime_equip_ids: Array = unit.get("runtime_equipped_equip_ids")
	for equip_id_value in runtime_equip_ids:
		var equip_id: String = str(equip_id_value).strip_edges()
		if equip_id.is_empty():
			continue
		var equip_data: Dictionary = manager.get_equipment_data(equip_id)
		if equip_data.is_empty():
			continue
		_append_source_effect_lines(
			lines,
			"装备·%s" % str(equip_data.get("name", equip_id)),
			equip_data.get("effects", [])
		)
	_append_trigger_effect_lines(lines, state_snapshot, manager, unit)
	if manager.has_method("get_unit_buff_ids"):
		var buff_ids: Array[String] = manager.get_unit_buff_ids(unit)
		if not buff_ids.is_empty():
			var buff_names: Array[String] = []
			for buff_id in buff_ids:
				buff_names.append(buff_name_from_id(buff_id))
			lines.append("当前 Buff：%s" % " / ".join(buff_names))
	return lines


func _append_source_effect_lines(lines: Array[String], source_label: String, effects_value: Variant) -> void:
	if not (effects_value is Array):
		return
	for effect_value in (effects_value as Array):
		if not (effect_value is Dictionary):
			continue
		var effect_data: Dictionary = effect_value as Dictionary
		if str(effect_data.get("op", "")).strip_edges().to_lower() == "tag_linkage_branch":
			continue
		lines.append("%s：%s" % [source_label, format_effect_op(effect_data)])


func _append_trigger_effect_lines(
	lines: Array[String],
	state_snapshot: Dictionary,
	manager,
	unit: Node
) -> void:
	var triggers_value: Variant = state_snapshot.get("triggers", [])
	if not (triggers_value is Array):
		return
	var trait_owner_labels: Dictionary = _build_trait_owner_label_map(unit)
	for trigger_value in (triggers_value as Array):
		if not (trigger_value is Dictionary):
			continue
		var trigger_entry: Dictionary = trigger_value as Dictionary
		var trigger_count: int = int(trigger_entry.get("trigger_count", 0))
		var time_elapsed_fired: bool = bool(trigger_entry.get("time_elapsed_fired", false))
		if trigger_count <= 0 and not time_elapsed_fired:
			continue
		var skill_data_value: Variant = trigger_entry.get("skill_data", {})
		if not (skill_data_value is Dictionary):
			continue
		var skill_data: Dictionary = skill_data_value as Dictionary
		var effect_texts: Array[String] = []
		var effect_items_value: Variant = skill_data.get("effects", [])
		if effect_items_value is Array:
			for effect_value in (effect_items_value as Array):
				if not (effect_value is Dictionary):
					continue
				var effect_data: Dictionary = effect_value as Dictionary
				if str(effect_data.get("op", "")).strip_edges().to_lower() == "tag_linkage_branch":
					continue
				effect_texts.append(format_effect_op(effect_data))
		if effect_texts.is_empty():
			continue
		var owner_id: String = str(trigger_entry.get("gongfa_id", "")).strip_edges()
		var owner_label: String = _resolve_owner_label(owner_id, manager, trait_owner_labels)
		var trigger_label: String = trigger_to_cn(
			str(trigger_entry.get("trigger", "")).strip_edges().to_lower()
		)
		var count_label: String = "已触发"
		if trigger_count > 0:
			count_label += " x%d" % trigger_count
		var next_ready: float = float(trigger_entry.get("next_ready_time", 0.0))
		var remain_cooldown: float = 0.0
		if _state != null:
			remain_cooldown = maxf(next_ready - float(_state.combat_elapsed), 0.0)
		if remain_cooldown > 0.05:
			count_label += "（冷却%.1fs）" % remain_cooldown
		var summary: String = effect_texts[0]
		if effect_texts.size() > 1:
			summary += "；等%d项" % effect_texts.size()
		lines.append("%s｜%s：%s，%s" % [owner_label, trigger_label, count_label, summary])


func _collect_linkage_effect_entries(state_snapshot: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var seen: Dictionary = {}
	var grouped_effect_sets: Array[Dictionary] = [
		{"owner_id": "", "trigger": "", "effects": state_snapshot.get("passive_effects", [])},
		{"owner_id": "", "trigger": "", "effects": state_snapshot.get("equipment_effects", [])}
	]
	for group in grouped_effect_sets:
		var effects_value: Variant = group.get("effects", [])
		if not (effects_value is Array):
			continue
		for effect_value in (effects_value as Array):
			if not (effect_value is Dictionary):
				continue
			var effect_data: Dictionary = effect_value as Dictionary
			if str(effect_data.get("op", "")).strip_edges().to_lower() != "tag_linkage_branch":
				continue
			var key: String = "%s|%s|%s" % [
				str(group.get("owner_id", "")),
				str(group.get("trigger", "")),
				var_to_str(effect_data)
			]
			if seen.has(key):
				continue
			seen[key] = true
			entries.append({
				"owner_id": str(group.get("owner_id", "")),
				"trigger": str(group.get("trigger", "")),
				"effect": effect_data.duplicate(true)
			})
	var triggers_value: Variant = state_snapshot.get("triggers", [])
	if not (triggers_value is Array):
		return entries
	for trigger_value in (triggers_value as Array):
		if not (trigger_value is Dictionary):
			continue
		var trigger_entry: Dictionary = trigger_value as Dictionary
		var owner_id: String = str(trigger_entry.get("gongfa_id", "")).strip_edges()
		var trigger_name: String = str(trigger_entry.get("trigger", "")).strip_edges().to_lower()
		var skill_data_value: Variant = trigger_entry.get("skill_data", {})
		if not (skill_data_value is Dictionary):
			continue
		var effects_value: Variant = (skill_data_value as Dictionary).get("effects", [])
		if not (effects_value is Array):
			continue
		for effect_value in (effects_value as Array):
			if not (effect_value is Dictionary):
				continue
			var effect_data: Dictionary = effect_value as Dictionary
			if str(effect_data.get("op", "")).strip_edges().to_lower() != "tag_linkage_branch":
				continue
			var key: String = "%s|%s|%s" % [owner_id, trigger_name, var_to_str(effect_data)]
			if seen.has(key):
				continue
			seen[key] = true
			entries.append({
				"owner_id": owner_id,
				"trigger": trigger_name,
				"effect": effect_data.duplicate(true)
			})
	return entries


func _get_unit_state_snapshot(unit: Node, manager) -> Dictionary:
	if manager == null or not manager.has_method("get_state_service"):
		return {}
	var state_service: Variant = manager.get_state_service()
	if state_service == null or not state_service.has_method("get_state_for_unit"):
		return {}
	var state_value: Variant = state_service.get_state_for_unit(unit)
	if state_value is Dictionary:
		return state_value as Dictionary
	return {}


func _build_linkage_eval_context(unit: Node, manager) -> Dictionary:
	var context: Dictionary = {
		"all_units": _collect_board_units(unit),
		"combat_manager": _refs.combat_manager if _refs != null else null,
		"hex_grid": _refs.hex_grid if _refs != null else null
	}
	if _refs != null and _refs.hex_grid != null:
		context["hex_size"] = float(_refs.hex_grid.get("hex_size"))
	if manager != null and is_instance_valid(manager):
		context["tag_linkage_stagger_buckets"] = int(manager.get("tag_linkage_stagger_buckets"))
	return context


func _collect_board_units(unit: Node) -> Array[Node]:
	var output: Array[Node] = []
	var seen: Dictionary = {}
	if _state != null:
		for unit_value in _state.ally_deployed.values():
			if not is_valid_unit(unit_value):
				continue
			var ally_unit: Node = unit_value as Node
			var ally_id: int = ally_unit.get_instance_id()
			if seen.has(ally_id):
				continue
			seen[ally_id] = true
			output.append(ally_unit)
		for unit_value in _state.enemy_deployed.values():
			if not is_valid_unit(unit_value):
				continue
			var enemy_unit: Node = unit_value as Node
			var enemy_id: int = enemy_unit.get_instance_id()
			if seen.has(enemy_id):
				continue
			seen[enemy_id] = true
			output.append(enemy_unit)
	if is_valid_unit(unit):
		var self_id: int = unit.get_instance_id()
		if not seen.has(self_id):
			output.append(unit)
	return output


func _resolve_owner_label(owner_id: String, manager, trait_owner_labels: Dictionary) -> String:
	if owner_id.is_empty():
		return "单位特效"
	if trait_owner_labels.has(owner_id):
		return str(trait_owner_labels.get(owner_id, owner_id))
	var gongfa_data: Dictionary = manager.get_gongfa_data(owner_id)
	if not gongfa_data.is_empty():
		return "功法·%s" % str(gongfa_data.get("name", owner_id))
	var equip_data: Dictionary = manager.get_equipment_data(owner_id)
	if not equip_data.is_empty():
		return "装备·%s" % str(equip_data.get("name", owner_id))
	return owner_id


func _build_trait_owner_label_map(unit: Node) -> Dictionary:
	var labels: Dictionary = {}
	var unit_id: String = str(safe_node_prop(unit, "unit_id", "unit")).strip_edges()
	if unit_id.is_empty():
		unit_id = "unit"
	var trait_values: Variant = safe_node_prop(unit, "traits", [])
	if not (trait_values is Array):
		return labels
	for trait_index in range((trait_values as Array).size()):
		var trait_value: Variant = (trait_values as Array)[trait_index]
		if not (trait_value is Dictionary):
			continue
		var trait_data: Dictionary = trait_value as Dictionary
		var trait_id: String = str(trait_data.get("id", "trait_%d" % trait_index)).strip_edges()
		if trait_id.is_empty():
			trait_id = "trait_%d" % trait_index
		var trait_name: String = str(trait_data.get("name", trait_id)).strip_edges()
		var label: String = "特性·%s" % trait_name
		labels["trait_%s_%s" % [unit_id, trait_id]] = label
		labels[trait_id] = label
	return labels


func _format_query_counts(query_counts_value: Variant) -> String:
	if not (query_counts_value is Dictionary):
		return ""
	var query_counts: Dictionary = query_counts_value as Dictionary
	if query_counts.is_empty():
		return ""
	var keys: Array[String] = []
	for key_value in query_counts.keys():
		keys.append(str(key_value))
	keys.sort()
	var parts: Array[String] = []
	for key in keys:
		parts.append("%s=%d" % [key, int(query_counts.get(key, 0))])
	return "，计数[%s]" % " / ".join(parts)


func _trim_lines(lines: Array[String], max_lines: int, section_name: String) -> Array[String]:
	if lines.size() <= max_lines:
		return lines
	var output: Array[String] = []
	for index in range(max_lines):
		output.append(lines[index])
	output.append("……其余%d条%s已折叠" % [lines.size() - max_lines, section_name])
	return output
