extends SceneTree

const TAG_LINKAGE_RESOLVER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_tag_linkage_resolver.gd")

const TEST_BUFFS_PATH: String = "res://mods/test/data/buffs/m5_buff_tag_linkage_buffs.json"
const TEST_GONGFA_PATH: String = "res://mods/test/data/gongfa/m5_buff_tag_linkage_gongfa.json"
const TEST_UNITS_PATH: String = "res://mods/test/data/units/m5_buff_tag_linkage_units.json"


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var unit_id: String = ""
	var unit_name: String = ""
	var tags: Array = []
	var runtime_active_buff_ids: Array = []


class MockUnitCombat:
	extends Node
	var is_alive: bool = true


class MockHexGrid:
	extends Node

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= -16 and cell.y >= -16 and cell.x <= 16 and cell.y <= 16

	func get_neighbor_cells(cell: Vector2i) -> Array[Vector2i]:
		return [
			Vector2i(cell.x + 1, cell.y),
			Vector2i(cell.x - 1, cell.y),
			Vector2i(cell.x, cell.y + 1),
			Vector2i(cell.x, cell.y - 1),
			Vector2i(cell.x + 1, cell.y - 1),
			Vector2i(cell.x - 1, cell.y + 1)
		]

	func get_cell_distance(a: Vector2i, b: Vector2i) -> int:
		var dq: int = b.x - a.x
		var dr: int = b.y - a.y
		var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
		return int(distance_sum / 2.0)


class MockCombatManager:
	extends Node
	var unit_cells: Dictionary = {}
	var unit_lookup: Dictionary = {}

	func register_unit_cell(unit: Node, cell: Vector2i) -> void:
		if unit == null:
			return
		var iid: int = unit.get_instance_id()
		unit_cells[iid] = cell
		unit_lookup[iid] = unit

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null:
			return Vector2i(-1, -1)
		var iid: int = unit.get_instance_id()
		if not unit_cells.has(iid):
			return Vector2i(-1, -1)
		return unit_cells[iid]

	func collect_alive_units_in_cells(cells: Array[Vector2i], output: Array[Node]) -> void:
		output.clear()
		if cells.is_empty():
			return
		var seen_units: Dictionary = {}
		for cell in cells:
			for iid in unit_cells.keys():
				if unit_cells[iid] != cell:
					continue
				if seen_units.has(iid) or not unit_lookup.has(iid):
					continue
				seen_units[iid] = true
				var unit: Node = unit_lookup[iid]
				if unit == null or not is_instance_valid(unit):
					continue
				var combat: Node = unit.get_node_or_null("Components/UnitCombat")
				if combat == null or not bool(combat.get("is_alive")):
					continue
				output.append(unit)


class MockUnitAugmentManager:
	extends Node
	var resolver = TAG_LINKAGE_RESOLVER_SCRIPT.new()
	var buff_tag_map: Dictionary = {}

	func set_buff_tags(buff_map: Dictionary) -> void:
		buff_tag_map = buff_map.duplicate(true)
		var tag_to_index: Dictionary = {}
		var next_index: int = 0
		for tags_value in buff_tag_map.values():
			for tag in _normalize_tags(tags_value):
				if tag_to_index.has(tag):
					continue
				tag_to_index[tag] = next_index
				next_index += 1
		resolver.configure_tag_registry(tag_to_index, 1)

	func get_unit_buff_ids(unit: Node) -> Array[String]:
		if unit == null:
			return []
		return _normalize_ids(unit.get("runtime_active_buff_ids"))

	func get_buff_tags(buff_id: String) -> Array[String]:
		return _normalize_tags(buff_tag_map.get(buff_id, []))

	func evaluate_tag_linkage_branch(owner: Node, config: Dictionary, context: Dictionary) -> Dictionary:
		var eval_context: Dictionary = context.duplicate(false)
		eval_context["unit_augment_manager"] = self
		return resolver.evaluate(owner, config, eval_context)

	func _normalize_ids(raw: Variant) -> Array[String]:
		var out: Array[String] = []
		var seen: Dictionary = {}
		if raw is Array:
			for id_value in (raw as Array):
				var text: String = str(id_value).strip_edges()
				if text.is_empty() or seen.has(text):
					continue
				seen[text] = true
				out.append(text)
		return out

	func _normalize_tags(raw: Variant) -> Array[String]:
		var out: Array[String] = []
		var seen: Dictionary = {}
		if raw is Array:
			for tag in (raw as Array):
				var text: String = str(tag).strip_edges().to_lower()
				if text.is_empty() or seen.has(text):
					continue
				seen[text] = true
				out.append(text)
		return out


var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 mod/test buff-tag linkage tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 mod/test buff-tag linkage tests passed.")
	quit(0)


func _run() -> void:
	var buffs: Array = _load_json_array(TEST_BUFFS_PATH)
	var gongfa_rows: Array = _load_json_array(TEST_GONGFA_PATH)
	var unit_rows: Array = _load_json_array(TEST_UNITS_PATH)
	_assert_true(buffs.size() >= 3, "buff test data should include at least 3 rows")
	_assert_true(gongfa_rows.size() >= 2, "gongfa test data should include at least 2 rows")
	_assert_true(unit_rows.size() >= 3, "unit test data should include at least 3 rows")
	if _failed > 0:
		return

	var buff_tags: Dictionary = {}
	for buff_value in buffs:
		if not (buff_value is Dictionary):
			continue
		var buff: Dictionary = buff_value as Dictionary
		var buff_id: String = str(buff.get("id", "")).strip_edges()
		if buff_id.is_empty():
			continue
		buff_tags[buff_id] = _normalize_tags(buff.get("tags", []))

	var effect_by_gongfa_id: Dictionary = {}
	for row_value in gongfa_rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		var gid: String = str(row.get("id", "")).strip_edges()
		if gid.is_empty():
			continue
		var effect: Dictionary = _extract_tag_linkage_effect(row)
		if not effect.is_empty():
			effect_by_gongfa_id[gid] = effect

	_assert_true(
		effect_by_gongfa_id.has("gongfa_test_buff_linkage_poison_bonus"),
		"gongfa_test_buff_linkage_poison_bonus should provide tag_linkage_branch"
	)
	_assert_true(
		effect_by_gongfa_id.has("gongfa_test_buff_linkage_no_enemy_fire"),
		"gongfa_test_buff_linkage_no_enemy_fire should provide tag_linkage_branch"
	)
	if _failed > 0:
		return

	var grid: MockHexGrid = MockHexGrid.new()
	var combat_manager: MockCombatManager = MockCombatManager.new()
	var manager: MockUnitAugmentManager = MockUnitAugmentManager.new()
	manager.set_buff_tags(buff_tags)

	var units: Array = []
	var unit_by_id: Dictionary = {}
	for row_value in unit_rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		var unit: MockUnit = _make_unit_from_row(row)
		if unit == null:
			continue
		var unit_id: String = str(row.get("id", "")).strip_edges()
		if unit_id.is_empty():
			unit.free()
			continue
		unit_by_id[unit_id] = unit
		units.append(unit)
		combat_manager.register_unit_cell(unit, _read_cell(row))

	_assert_true(unit_by_id.has("unit_test_buff_link_owner"), "owner unit row should exist")
	_assert_true(unit_by_id.has("unit_test_buff_link_ally_dot"), "ally dot unit row should exist")
	_assert_true(unit_by_id.has("unit_test_buff_link_enemy_fire"), "enemy fire unit row should exist")
	if _failed > 0:
		_free_units(units)
		grid.free()
		combat_manager.free()
		manager.free()
		return

	var owner: MockUnit = unit_by_id["unit_test_buff_link_owner"]
	var enemy_fire: MockUnit = unit_by_id["unit_test_buff_link_enemy_fire"]

	var context: Dictionary = {
		"all_units": units,
		"hex_grid": grid,
		"combat_manager": combat_manager,
		"unit_augment_manager": manager,
		"hex_size": 32.0
	}

	var dot_effect: Dictionary = effect_by_gongfa_id["gongfa_test_buff_linkage_poison_bonus"]
	var dot_result: Dictionary = manager.evaluate_tag_linkage_branch(owner, dot_effect, context)
	var dot_counts: Dictionary = dot_result.get("query_counts", {})
	_assert_true(int(dot_counts.get("q_ally_dot_buff", 0)) == 1, "ally dot buff query should count exactly 1")
	_assert_true(_array_has_str(dot_result.get("matched_case_ids", []), "dot_ready"), "dot_ready branch should match")
	_assert_true(_first_effect_value(dot_result.get("effects", [])) == 18.0, "dot_ready branch effect should be 18.0")

	var forbid_effect: Dictionary = effect_by_gongfa_id["gongfa_test_buff_linkage_no_enemy_fire"]
	var forbid_hit_result: Dictionary = manager.evaluate_tag_linkage_branch(owner, forbid_effect, context)
	var forbid_hit_counts: Dictionary = forbid_hit_result.get("query_counts", {})
	_assert_true(
		int(forbid_hit_counts.get("q_enemy_fire_forbid", 0)) >= 1,
		"forbid query should count violating enemy fire buff providers"
	)
	_assert_true(
		not _array_has_str(forbid_hit_result.get("matched_case_ids", []), "safe_window"),
		"safe_window should not match while enemy has fire buff"
	)
	_assert_true(_first_effect_value(forbid_hit_result.get("effects", [])) == 0.05, "else branch effect should be 0.05")

	enemy_fire.runtime_active_buff_ids = ["test_buff_linkage_shield"]
	var forbid_safe_result: Dictionary = manager.evaluate_tag_linkage_branch(owner, forbid_effect, context)
	var forbid_safe_counts: Dictionary = forbid_safe_result.get("query_counts", {})
	_assert_true(int(forbid_safe_counts.get("q_enemy_fire_forbid", 0)) == 0, "forbid query should be 0 after removing enemy fire buff")
	_assert_true(_array_has_str(forbid_safe_result.get("matched_case_ids", []), "safe_window"), "safe_window should match after removing enemy fire buff")
	_assert_true(_first_effect_value(forbid_safe_result.get("effects", [])) == 0.2, "safe_window branch effect should be 0.2")

	_free_units(units)
	grid.free()
	combat_manager.free()
	manager.free()


func _make_unit_from_row(row: Dictionary) -> MockUnit:
	var uid: String = str(row.get("id", "")).strip_edges()
	if uid.is_empty():
		return null
	var unit: MockUnit = MockUnit.new()
	unit.unit_id = uid
	unit.unit_name = str(row.get("name", uid)).strip_edges()
	unit.team_id = int(row.get("test_team_id", 1))
	unit.tags = _normalize_tags(row.get("tags", []))
	unit.runtime_active_buff_ids = _normalize_ids(row.get("test_active_buff_ids", []))

	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)
	var combat: MockUnitCombat = MockUnitCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	return unit


func _read_cell(row: Dictionary) -> Vector2i:
	var value: Variant = row.get("test_cell", [])
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int((value as Array)[0]), int((value as Array)[1]))
	return Vector2i(0, 0)


func _extract_tag_linkage_effect(gongfa_row: Dictionary) -> Dictionary:
	var skills_value: Variant = gongfa_row.get("skills", [])
	if not (skills_value is Array):
		return {}
	for skill_value in (skills_value as Array):
		if not (skill_value is Dictionary):
			continue
		var skill: Dictionary = skill_value as Dictionary
		var effects_value: Variant = skill.get("effects", [])
		if not (effects_value is Array):
			continue
		for effect_value in (effects_value as Array):
			if not (effect_value is Dictionary):
				continue
			var effect: Dictionary = effect_value as Dictionary
			if str(effect.get("op", "")).strip_edges() == "tag_linkage_branch":
				return effect.duplicate(true)
	return {}


func _first_effect_value(effects_value: Variant) -> float:
	if not (effects_value is Array):
		return 0.0
	var effects: Array = effects_value as Array
	if effects.is_empty() or not (effects[0] is Dictionary):
		return 0.0
	return float((effects[0] as Dictionary).get("value", 0.0))


func _load_json_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		_failed += 1
		push_error("missing test data file: %s" % path)
		return []
	var raw: String = FileAccess.get_file_as_string(path)
	var parser := JSON.new()
	var err: Error = parser.parse(raw)
	if err != OK:
		_failed += 1
		push_error("failed to parse json: %s line=%d error=%s" % [path, parser.get_error_line(), parser.get_error_message()])
		return []
	if not (parser.data is Array):
		_failed += 1
		push_error("json payload should be array: %s" % path)
		return []
	return parser.data as Array


func _normalize_tags(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for tag in (raw as Array):
			var text: String = str(tag).strip_edges().to_lower()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


func _normalize_ids(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	var seen: Dictionary = {}
	if raw is Array:
		for id_value in (raw as Array):
			var text: String = str(id_value).strip_edges()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
	return out


func _array_has_str(raw: Variant, target: String) -> bool:
	if not (raw is Array):
		return false
	for item in (raw as Array):
		if str(item) == target:
			return true
	return false


func _free_units(units: Array) -> void:
	for unit_value in units:
		var unit: Node = unit_value as Node
		if unit == null or not is_instance_valid(unit):
			continue
		unit.free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
