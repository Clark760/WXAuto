extends RefCounted
class_name LinkageDetector

# ===========================
# 联动检测器（M3）
# ===========================
# 设计目标：
# 1. 按联动配置遍历检测，不把某个联动写死在代码里。
# 2. 分队伍检测，避免己方与敌方互相“串联动”。
# 3. 输出统一结果结构，供 GongfaManager 后续应用效果与刷新 UI。

const AXIAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(1, -1),
	Vector2i(0, -1),
	Vector2i(-1, 0),
	Vector2i(-1, 1),
	Vector2i(0, 1)
]


func detect_all(linkages: Array[Dictionary], units: Array, hex_grid: Node = null) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if linkages.is_empty() or units.is_empty():
		return results

	var by_team: Dictionary = _group_units_by_team(units)
	for team_key in by_team.keys():
		var team_id: int = int(team_key)
		var team_units: Array = by_team[team_key]
		for linkage in linkages:
			var match_result: Dictionary = _match_linkage(linkage, team_units, team_id, hex_grid)
			if bool(match_result.get("is_active", false)):
				results.append(match_result)
	return results


func _match_linkage(linkage: Dictionary, team_units: Array, team_id: int, hex_grid: Node) -> Dictionary:
	var linkage_id: String = str(linkage.get("id", "")).strip_edges()
	var linkage_type: String = str(linkage.get("type", "")).strip_edges()
	var conditions: Dictionary = linkage.get("conditions", {})

	var participants: Array = []
	match linkage_type:
		"faction_combo":
			participants = _match_faction_combo(team_units, conditions, hex_grid)
		"element_resonance":
			participants = _match_element_resonance(team_units, conditions)
		"skill_chain":
			participants = _match_skill_chain(team_units, conditions)
		"formation_boost":
			participants = _match_formation_boost(team_units, conditions)
		_:
			participants = []

	var is_active: bool = not participants.is_empty()
	return {
		"linkage_id": linkage_id,
		"linkage_data": linkage.duplicate(true),
		"team_id": team_id,
		"participants": participants,
		"is_active": is_active
	}


func _match_faction_combo(team_units: Array, conditions: Dictionary, hex_grid: Node) -> Array:
	var faction: String = str(conditions.get("require_faction", ""))
	var min_count: int = maxi(int(conditions.get("min_count", 1)), 1)
	var require_any_tag: Array[String] = _to_string_array(conditions.get("require_any_tag", []))
	var require_all_tags: Array[String] = _to_string_array(conditions.get("require_all_tags", []))
	var require_adjacent: bool = bool(conditions.get("require_adjacent", false))

	var candidates: Array = []
	for unit in team_units:
		if faction != "" and str(unit.get("faction")) != faction:
			continue
		var tags: Array[String] = _to_string_array(_node_prop(unit, "runtime_linkage_tags", []))
		if not _contains_any(tags, require_any_tag):
			continue
		if not _contains_all(tags, require_all_tags):
			continue
		candidates.append(unit)

	if candidates.size() < min_count:
		return []

	if require_adjacent and hex_grid != null:
		if not _is_connected_by_hex_adjacency(candidates, hex_grid):
			return []

	return candidates


func _match_element_resonance(team_units: Array, conditions: Dictionary) -> Array:
	var required_pairs: Array = conditions.get("require_elements", [])
	var min_count: int = maxi(int(conditions.get("min_count", 2)), 1)
	if not (required_pairs is Array) or required_pairs.is_empty():
		return []

	var participants: Dictionary = {}
	for pair_value in required_pairs:
		if not (pair_value is Array):
			continue
		var pair: Array = pair_value
		if pair.size() < 2:
			continue
		var e1: String = str(pair[0])
		var e2: String = str(pair[1])
		var unit_a: Node = null
		var unit_b: Node = null

		for unit in team_units:
			var elements: Array[String] = _to_string_array(_node_prop(unit, "runtime_gongfa_elements", []))
			if unit_a == null and elements.has(e1):
				unit_a = unit
			if unit_b == null and elements.has(e2):
				unit_b = unit
			if unit_a != null and unit_b != null:
				break

		if unit_a == null or unit_b == null:
			return []
		participants[unit_a.get_instance_id()] = unit_a
		participants[unit_b.get_instance_id()] = unit_b

	var output: Array = []
	for u in participants.values():
		output.append(u)
	if output.size() < min_count:
		return []
	return output


func _match_skill_chain(team_units: Array, conditions: Dictionary) -> Array:
	var combos: Array = conditions.get("require_tags_combo", [])
	var min_count: int = maxi(int(conditions.get("min_count", 2)), 1)
	if not (combos is Array) or combos.is_empty():
		return []

	var used: Dictionary = {}
	var participants: Array = []
	for group_value in combos:
		var group_tags: Array[String] = _to_string_array(group_value)
		var found: Node = null
		for unit in team_units:
			var iid: int = unit.get_instance_id()
			if used.has(iid):
				continue
			var tags: Array[String] = _to_string_array(_node_prop(unit, "runtime_linkage_tags", []))
			if _contains_any(tags, group_tags):
				found = unit
				break
		if found == null:
			return []
		participants.append(found)
		used[found.get_instance_id()] = true

	if participants.size() < min_count:
		return []
	return participants


func _match_formation_boost(team_units: Array, conditions: Dictionary) -> Array:
	var zhenfa_tag: String = str(conditions.get("require_zhenfa_tag", "")).strip_edges()
	var require_any_tag: Array[String] = _to_string_array(conditions.get("require_any_tag", []))
	var min_count: int = maxi(int(conditions.get("min_count", 1)), 1)

	if zhenfa_tag.is_empty():
		return []

	var has_zhenfa: bool = false
	for unit in team_units:
		var tags: Array[String] = _to_string_array(_node_prop(unit, "runtime_linkage_tags", []))
		if tags.has(zhenfa_tag):
			has_zhenfa = true
			break
	if not has_zhenfa:
		return []

	var participants: Array = []
	for unit in team_units:
		var tags: Array[String] = _to_string_array(_node_prop(unit, "runtime_linkage_tags", []))
		if _contains_any(tags, require_any_tag):
			participants.append(unit)

	if participants.size() < min_count:
		return []
	return participants


func _group_units_by_team(units: Array) -> Dictionary:
	var output: Dictionary = {}
	for unit in units:
		if unit == null or not is_instance_valid(unit):
			continue
		var combat: Node = unit.get_node_or_null("Components/UnitCombat")
		if combat == null or not bool(combat.get("is_alive")):
			continue
		var team_id: int = int(unit.get("team_id"))
		if not output.has(team_id):
			output[team_id] = []
		var team_arr: Array = output[team_id]
		team_arr.append(unit)
		output[team_id] = team_arr
	return output


func _is_connected_by_hex_adjacency(units: Array, hex_grid: Node) -> bool:
	if units.size() <= 1:
		return true

	var cell_to_unit: Dictionary = {}
	for unit in units:
		var cell: Vector2i = hex_grid.call("world_to_axial", (unit as Node2D).position)
		cell_to_unit[_cell_key(cell)] = unit

	var queue: Array[Vector2i] = []
	var visited: Dictionary = {}
	var first_cell: Vector2i = hex_grid.call("world_to_axial", (units[0] as Node2D).position)
	queue.append(first_cell)
	visited[_cell_key(first_cell)] = true

	var head: int = 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for d in AXIAL_DIRS:
			var next_cell: Vector2i = current + d
			var key: String = _cell_key(next_cell)
			if not cell_to_unit.has(key):
				continue
			if visited.has(key):
				continue
			visited[key] = true
			queue.append(next_cell)

	return visited.size() == cell_to_unit.size()


func _to_string_array(value: Variant) -> Array[String]:
	var output: Array[String] = []
	if value is Array:
		for item in value:
			output.append(str(item))
	return output


func _contains_any(source: Array[String], required: Array[String]) -> bool:
	if required.is_empty():
		return true
	for tag in required:
		if source.has(tag):
			return true
	return false


func _contains_all(source: Array[String], required: Array[String]) -> bool:
	for tag in required:
		if not source.has(tag):
			return false
	return true


func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


func _node_prop(node: Node, key: String, fallback: Variant) -> Variant:
	if node == null or not is_instance_valid(node):
		return fallback
	var value: Variant = node.get(key)
	if value == null:
		return fallback
	return value
