extends SceneTree

const TAG_LINKAGE_RESOLVER_SCRIPT: Script = preload("res://scripts/gongfa/tag_linkage_resolver.gd")
const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/gongfa/effect_engine.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")

const GONGFA_TEST_DATA_PATH: String = "res://data/gongfa/gongfa_m5_tag_linkage_test.json"
const EQUIPMENT_TEST_DATA_PATH: String = "res://data/equipment/equipment_m5_tag_linkage_test.json"
const UNIT_TEST_DATA_PATH: String = "res://data/units/units_m5_tag_linkage_test.json"
const TERRAIN_TEST_DATA_PATH: String = "res://data/terrains/terrains_m5_tag_linkage_test.json"


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var unit_id: String = ""
	var unit_name: String = ""
	var tags: Array = []
	var traits: Array = []
	var runtime_equipped_gongfa_ids: Array = []
	var runtime_equipped_equip_ids: Array = []


class MockUnitCombat:
	extends Node
	var is_alive: bool = true
	var current_hp: float = 1000.0
	var max_hp: float = 1000.0
	var current_mp: float = 50.0
	var max_mp: float = 300.0

	func receive_damage(
		amount: float,
		_source: Node,
		_damage_type: String = "internal",
		_is_skill: bool = true,
		_is_crit: bool = false,
		_is_dodged: bool = false,
		_can_trigger_thorns: bool = true
	) -> Dictionary:
		var final_amount: float = maxf(amount, 0.0)
		current_hp = maxf(current_hp - final_amount, 0.0)
		if current_hp <= 0.0:
			is_alive = false
		return {
			"damage": final_amount,
			"shield_absorbed": 0.0,
			"immune_absorbed": 0.0
		}

	func restore_hp(amount: float) -> void:
		current_hp = clampf(current_hp + maxf(amount, 0.0), 0.0, max_hp)
		is_alive = current_hp > 0.0

	func add_mp(amount: float) -> void:
		current_mp = clampf(current_mp + maxf(amount, 0.0), 0.0, max_mp)

	func get_external_modifiers() -> Dictionary:
		return {}


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

	func axial_to_world(cell: Vector2i) -> Vector2:
		return Vector2(float(cell.x) * 32.0, float(cell.y) * 24.0)

	func world_to_axial(world_pos: Vector2) -> Vector2i:
		return Vector2i(int(round(world_pos.x / 32.0)), int(round(world_pos.y / 24.0)))


class MockCombatManager:
	extends Node
	var unit_cells: Dictionary = {}
	var static_cell_tags: Dictionary = {}
	var dynamic_cell_tags: Dictionary = {}
	var hex_grid: MockHexGrid = null

	func setup(grid: MockHexGrid) -> void:
		hex_grid = grid

	func register_unit_cell(unit: Node, cell: Vector2i) -> void:
		if unit == null:
			return
		unit_cells[unit.get_instance_id()] = cell
		if unit is Node2D and hex_grid != null:
			(unit as Node2D).position = hex_grid.axial_to_world(cell)

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null:
			return Vector2i(-1, -1)
		var iid: int = unit.get_instance_id()
		if not unit_cells.has(iid):
			return Vector2i(-1, -1)
		return unit_cells[iid]

	func set_static_tags(cell: Vector2i, tags: Array) -> void:
		static_cell_tags[_cell_key(cell)] = _normalize_tags(tags)

	func set_dynamic_tags(cell: Vector2i, tags: Array) -> void:
		dynamic_cell_tags[_cell_key(cell)] = _normalize_tags(tags)

	func clear_cell_tags(cell: Vector2i) -> void:
		var key: String = _cell_key(cell)
		static_cell_tags.erase(key)
		dynamic_cell_tags.erase(key)

	func get_terrain_tags_at_cell(cell: Vector2i, scope: String = "all") -> Array[String]:
		var key: String = _cell_key(cell)
		var out: Array[String] = []
		var seen: Dictionary = {}
		var mode: String = scope.strip_edges().to_lower()
		if mode == "all" or mode == "static":
			for tag in static_cell_tags.get(key, []):
				if seen.has(tag):
					continue
				seen[tag] = true
				out.append(tag)
		if mode == "all" or mode == "dynamic":
			for tag in dynamic_cell_tags.get(key, []):
				if seen.has(tag):
					continue
				seen[tag] = true
				out.append(tag)
		return out

	func _cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

	func _normalize_tags(raw: Array) -> Array[String]:
		var out: Array[String] = []
		var seen: Dictionary = {}
		for tag in raw:
			var text: String = str(tag).strip_edges().to_lower()
			if text.is_empty() or seen.has(text):
				continue
			seen[text] = true
			out.append(text)
		return out


class MockGongfaManager:
	extends Node
	var resolver = TAG_LINKAGE_RESOLVER_SCRIPT.new()
	var gongfa_tag_map: Dictionary = {}
	var equipment_tag_map: Dictionary = {}

	func set_tag_maps(gongfa_map: Dictionary, equipment_map: Dictionary) -> void:
		gongfa_tag_map = gongfa_map.duplicate(true)
		equipment_tag_map = equipment_map.duplicate(true)

	func get_gongfa_tags(gongfa_id: String) -> Array[String]:
		return _normalize_tags(gongfa_tag_map.get(gongfa_id, []))

	func get_equipment_tags(equip_id: String) -> Array[String]:
		return _normalize_tags(equipment_tag_map.get(equip_id, []))

	func get_unit_runtime_gongfa_ids(unit: Node) -> Array[String]:
		if unit == null:
			return []
		return _normalize_ids(unit.get("runtime_equipped_gongfa_ids"))

	func get_unit_runtime_equip_ids(unit: Node) -> Array[String]:
		if unit == null:
			return []
		return _normalize_ids(unit.get("runtime_equipped_equip_ids"))

	func evaluate_tag_linkage_branch(owner: Node, config: Dictionary, context: Dictionary) -> Dictionary:
		var eval_context: Dictionary = context.duplicate(false)
		eval_context["gongfa_manager"] = self
		return resolver.call("evaluate", owner, config, eval_context)

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
var _gongfa_tags: Dictionary = {}
var _equipment_tags: Dictionary = {}


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 tag linkage effect tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 tag linkage effect tests passed.")
	quit(0)


func _run() -> void:
	_test_data_files_are_loaded()
	_build_test_tag_maps()
	_test_range_zero_only_self_and_ground()
	_test_range_and_tag_match_any_all()
	_test_tier_case_order_3_5_7()
	_test_provider_count_not_multiplied_by_tag_count()
	_test_static_and_dynamic_terrain_tags()
	_test_wandu_ground_poison_fire_else()
	_test_effect_engine_dispatch_tag_linkage_branch()


func _test_data_files_are_loaded() -> void:
	var data_manager: Node = DATA_MANAGER_SCRIPT.new()
	var summary: Dictionary = data_manager.call("load_base_data")
	_assert_true(int(summary.get("total_records", 0)) > 0, "data manager should load records")

	_assert_true(not data_manager.call("get_record", "gongfa", "gongfa_tag_linkage_array_test").is_empty(), "gongfa test record should be loaded")
	_assert_true(not data_manager.call("get_record", "gongfa", "gongfa_tag_linkage_ground_test").is_empty(), "ground gongfa test record should be loaded")
	_assert_true(not data_manager.call("get_record", "equipment", "eq_m5_tag_array_token").is_empty(), "equipment test record should be loaded")
	_assert_true(not data_manager.call("get_record", "units", "unit_m5_tag_anchor").is_empty(), "unit test record should be loaded")
	_assert_true(not data_manager.call("get_record", "terrains", "terrain_m5_tag_poison_pool").is_empty(), "terrain test record should be loaded")
	data_manager.free()


func _build_test_tag_maps() -> void:
	var gongfa_rows: Array = _load_json_array(GONGFA_TEST_DATA_PATH)
	var equipment_rows: Array = _load_json_array(EQUIPMENT_TEST_DATA_PATH)
	var unit_rows: Array = _load_json_array(UNIT_TEST_DATA_PATH)
	var terrain_rows: Array = _load_json_array(TERRAIN_TEST_DATA_PATH)
	_assert_true(gongfa_rows.size() >= 2, "gongfa tag linkage test data should have at least 2 rows")
	_assert_true(equipment_rows.size() >= 3, "equipment tag linkage test data should have at least 3 rows")
	_assert_true(unit_rows.size() >= 3, "unit tag linkage test data should have at least 3 rows")
	_assert_true(terrain_rows.size() >= 3, "terrain tag linkage test data should have at least 3 rows")

	_gongfa_tags.clear()
	for row_value in gongfa_rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		var rid: String = str(row.get("id", "")).strip_edges()
		if rid.is_empty():
			continue
		_gongfa_tags[rid] = _normalize_tags(row.get("tags", []))

	_equipment_tags.clear()
	for row_value in equipment_rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value as Dictionary
		var rid: String = str(row.get("id", "")).strip_edges()
		if rid.is_empty():
			continue
		_equipment_tags[rid] = _normalize_tags(row.get("tags", []))


func _test_range_zero_only_self_and_ground() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var owner: MockUnit = _make_unit(
		"owner_zero",
		1,
		["unit.anchor"],
		[{"id": "trait_wandu_guxin", "tags": ["trait.wandu_guxin"]}],
		["gongfa_tag_linkage_ground_test"],
		["eq_m5_tag_poison_ring"]
	)
	var nearby: MockUnit = _make_unit(
		"nearby_zero",
		1,
		["array.zhenwu"],
		[{"id": "trait_fake", "tags": ["trait.wandu_guxin"]}],
		[],
		[]
	)
	bundle.combat_manager.register_unit_cell(owner, Vector2i(0, 0))
	bundle.combat_manager.register_unit_cell(nearby, Vector2i(1, 0))
	bundle.combat_manager.set_static_tags(Vector2i(0, 0), ["element.poison"])

	var config: Dictionary = {
		"range": 0,
		"include_self": true,
		"team_scope": "ally",
		"source_types": ["trait", "terrain", "unit", "gongfa", "equipment"],
		"queries": [
			{"id": "q_self_trait", "tags": ["trait.wandu_guxin"], "tag_match": "all", "source_types": ["trait"], "origin_scope": "self"},
			{"id": "q_ground_poison", "tags": ["element.poison"], "tag_match": "any", "source_types": ["terrain"]},
			{"id": "q_nearby_array", "tags": ["array.zhenwu"], "tag_match": "any", "source_types": ["unit", "trait", "gongfa", "equipment"], "origin_scope": "nearby"}
		],
		"cases": [
			{
				"id": "poison_ok",
				"all": [
					{"query_id": "q_self_trait", "min_count": 1},
					{"query_id": "q_ground_poison", "min_count": 1}
				],
				"effects": [{"op": "mp_regen_add", "value": 12.0}]
			}
		],
		"else_effects": [{"op": "mp_regen_add", "value": 2.0}],
		"stop_after_first_case": true
	}

	var result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner, nearby]))
	var query_counts: Dictionary = result.get("query_counts", {})
	_assert_true(int(query_counts.get("q_self_trait", 0)) == 1, "range=0 should include self trait")
	_assert_true(int(query_counts.get("q_ground_poison", 0)) == 1, "range=0 should include current cell terrain")
	_assert_true(int(query_counts.get("q_nearby_array", 0)) == 0, "range=0 should exclude nearby units")
	_assert_true(_array_has_str(result.get("matched_case_ids", []), "poison_ok"), "range=0 poison case should match")

	_free_bundle(bundle, [owner, nearby])


func _test_range_and_tag_match_any_all() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var owner: MockUnit = _make_unit("owner_range", 1, [], [], [], [])
	var ally_a: MockUnit = _make_unit("ally_a", 1, ["array.zhenwu", "faction.wudang"], [], [], [])
	var ally_b: MockUnit = _make_unit("ally_b", 1, ["array.zhenwu"], [], [], [])
	var enemy_a: MockUnit = _make_unit("enemy_a", 2, ["array.zhenwu", "enemy.flag"], [], [], [])

	bundle.combat_manager.register_unit_cell(owner, Vector2i(0, 0))
	bundle.combat_manager.register_unit_cell(ally_a, Vector2i(1, 0))
	bundle.combat_manager.register_unit_cell(ally_b, Vector2i(2, 0))
	bundle.combat_manager.register_unit_cell(enemy_a, Vector2i(1, -1))

	var config: Dictionary = {
		"range": 2,
		"include_self": false,
		"team_scope": "ally",
		"source_types": ["unit"],
		"queries": [
			{"id": "q_any", "tags": ["array.zhenwu", "faction.wudang"], "tag_match": "any", "source_types": ["unit"]},
			{"id": "q_all", "tags": ["array.zhenwu", "faction.wudang"], "tag_match": "all", "source_types": ["unit"]},
			{"id": "q_enemy", "tags": ["enemy.flag"], "tag_match": "any", "source_types": ["unit"], "team_scope": "enemy"}
		]
	}

	var result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner, ally_a, ally_b, enemy_a]))
	var query_counts: Dictionary = result.get("query_counts", {})
	_assert_true(int(query_counts.get("q_any", 0)) == 2, "tag_match any should count two allies")
	_assert_true(int(query_counts.get("q_all", 0)) == 1, "tag_match all should count one ally")
	_assert_true(int(query_counts.get("q_enemy", 0)) == 1, "query-level enemy scope should work")

	_free_bundle(bundle, [owner, ally_a, ally_b, enemy_a])


func _test_tier_case_order_3_5_7() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var units: Array = []
	for i in range(5):
		var unit: MockUnit = _make_unit("tier_%d" % i, 1, ["array.zhenwu"], [], [], [])
		units.append(unit)
		bundle.combat_manager.register_unit_cell(unit, Vector2i(i, 0))
	var owner: MockUnit = units[0]

	var config: Dictionary = {
		"range": 5,
		"include_self": true,
		"team_scope": "ally",
		"source_types": ["unit"],
		"queries": [{"id": "q_array", "tags": ["array.zhenwu"], "tag_match": "any"}],
		"cases": [
			{"id": "tier_7", "all": [{"query_id": "q_array", "min_count": 7}], "effects": [{"op": "mp_regen_add", "value": 70.0}]},
			{"id": "tier_5", "all": [{"query_id": "q_array", "min_count": 5}], "effects": [{"op": "mp_regen_add", "value": 50.0}]},
			{"id": "tier_3", "all": [{"query_id": "q_array", "min_count": 3}], "effects": [{"op": "mp_regen_add", "value": 30.0}]}
		],
		"stop_after_first_case": true
	}

	var result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, units))
	_assert_true(_array_has_str(result.get("matched_case_ids", []), "tier_5"), "5 units should hit tier_5")
	_assert_true(not _array_has_str(result.get("matched_case_ids", []), "tier_3"), "stop_after_first_case should prevent lower tier match")
	var effects: Array = result.get("effects", [])
	_assert_true(effects.size() == 1 and is_equal_approx(float((effects[0] as Dictionary).get("value", 0.0)), 50.0), "tier_5 should return 50 mp effect")

	_free_bundle(bundle, units)


func _test_provider_count_not_multiplied_by_tag_count() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var owner: MockUnit = _make_unit("provider_owner", 1, ["array.zhenwu", "formation"], [], [], [])
	bundle.combat_manager.register_unit_cell(owner, Vector2i(0, 0))

	var config: Dictionary = {
		"range": 0,
		"include_self": true,
		"team_scope": "ally",
		"source_types": ["unit"],
		"count_mode": "provider",
		"queries": [
			{"id": "q_dual_tag", "tags": ["array.zhenwu", "formation"], "tag_match": "any", "source_types": ["unit"]}
		]
	}

	var result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner]))
	var query_counts: Dictionary = result.get("query_counts", {})
	_assert_true(int(query_counts.get("q_dual_tag", 0)) == 1, "single provider should count once for multi-tag any query")

	_free_bundle(bundle, [owner])


func _test_static_and_dynamic_terrain_tags() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var owner: MockUnit = _make_unit("terrain_owner", 1, [], [], [], [])
	bundle.combat_manager.register_unit_cell(owner, Vector2i(0, 0))
	bundle.combat_manager.set_static_tags(Vector2i(0, 0), ["terrain.rock"])
	bundle.combat_manager.set_dynamic_tags(Vector2i(0, 0), ["terrain.fire"])

	var config: Dictionary = {
		"range": 0,
		"include_self": true,
		"source_types": ["terrain"],
		"queries": [
			{"id": "q_static", "tags": ["terrain.rock"], "tag_match": "any", "source_types": ["terrain"]},
			{"id": "q_dynamic", "tags": ["terrain.fire"], "tag_match": "any", "source_types": ["terrain"]}
		]
	}

	var result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner]))
	var query_counts: Dictionary = result.get("query_counts", {})
	_assert_true(int(query_counts.get("q_static", 0)) == 1, "terrain static tags should be visible to resolver")
	_assert_true(int(query_counts.get("q_dynamic", 0)) == 1, "terrain dynamic tags should be visible to resolver")

	_free_bundle(bundle, [owner])


func _test_wandu_ground_poison_fire_else() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var owner: MockUnit = _make_unit(
		"wandu_owner",
		1,
		[],
		[{"id": "trait_wandu_guxin", "tags": ["trait.wandu_guxin", "element.poison"]}],
		[],
		[]
	)
	bundle.combat_manager.register_unit_cell(owner, Vector2i(0, 0))

	var config: Dictionary = {
		"range": 0,
		"include_self": true,
		"team_scope": "ally",
		"source_types": ["trait", "terrain"],
		"queries": [
			{"id": "q_self_trait", "tags": ["trait.wandu_guxin"], "tag_match": "all", "source_types": ["trait"], "origin_scope": "self"},
			{"id": "q_ground_poison", "tags": ["element.poison"], "tag_match": "any", "source_types": ["terrain"]},
			{"id": "q_ground_fire", "tags": ["element.fire"], "tag_match": "any", "source_types": ["terrain"]}
		],
		"cases": [
			{
				"id": "on_poison_ground",
				"all": [
					{"query_id": "q_self_trait", "min_count": 1},
					{"query_id": "q_ground_poison", "min_count": 1}
				],
				"effects": [{"op": "mp_regen_add", "value": 12.0}]
			},
			{
				"id": "on_fire_ground",
				"all": [
					{"query_id": "q_self_trait", "min_count": 1},
					{"query_id": "q_ground_fire", "min_count": 1}
				],
				"effects": [{"op": "mp_regen_add", "value": 1.0}]
			}
		],
		"else_effects": [{"op": "mp_regen_add", "value": 0.2}],
		"stop_after_first_case": true
	}

	bundle.combat_manager.set_static_tags(Vector2i(0, 0), ["element.poison"])
	bundle.combat_manager.set_dynamic_tags(Vector2i(0, 0), [])
	var poison_result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner]))
	_assert_true(_array_has_str(poison_result.get("matched_case_ids", []), "on_poison_ground"), "poison ground branch should match")

	bundle.combat_manager.set_static_tags(Vector2i(0, 0), ["element.fire"])
	bundle.combat_manager.set_dynamic_tags(Vector2i(0, 0), [])
	var fire_result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner]))
	_assert_true(_array_has_str(fire_result.get("matched_case_ids", []), "on_fire_ground"), "fire ground branch should match")

	bundle.combat_manager.clear_cell_tags(Vector2i(0, 0))
	var else_result: Dictionary = bundle.manager.evaluate_tag_linkage_branch(owner, config, _build_effect_context(bundle, [owner]))
	_assert_true((else_result.get("matched_case_ids", []) as Array).is_empty(), "no terrain should not match any case")
	var else_effects: Array = else_result.get("effects", [])
	_assert_true(else_effects.size() == 1 and is_equal_approx(float((else_effects[0] as Dictionary).get("value", 0.0)), 0.2), "else branch should return fallback effect")

	_free_bundle(bundle, [owner])


func _test_effect_engine_dispatch_tag_linkage_branch() -> void:
	var bundle: Dictionary = _build_context_bundle()
	var owner: MockUnit = _make_unit("engine_owner", 1, [], [{"id": "trait_wandu_guxin", "tags": ["trait.wandu_guxin"]}], [], [])
	bundle.combat_manager.register_unit_cell(owner, Vector2i(0, 0))
	bundle.combat_manager.set_static_tags(Vector2i(0, 0), ["element.poison"])

	var engine = EFFECT_ENGINE_SCRIPT.new()
	var summary: Dictionary = engine.call("execute_active_effects", owner, owner, [
		{
			"op": "tag_linkage_branch",
			"range": 0,
			"include_self": true,
			"source_types": ["trait", "terrain"],
			"queries": [
				{"id": "q_trait", "tags": ["trait.wandu_guxin"], "tag_match": "all", "source_types": ["trait"], "origin_scope": "self"},
				{"id": "q_poison", "tags": ["element.poison"], "tag_match": "any", "source_types": ["terrain"]}
			],
			"cases": [
				{
					"id": "hit",
					"all": [
						{"query_id": "q_trait", "min_count": 1},
						{"query_id": "q_poison", "min_count": 1}
					],
					"effects": [{"op": "mp_regen_add", "value": 9.0}]
				}
			],
			"else_effects": [{"op": "mp_regen_add", "value": 1.0}],
			"stop_after_first_case": true
		}
	], _build_effect_context(bundle, [owner]))

	_assert_true(is_equal_approx(float(summary.get("mp_total", 0.0)), 9.0), "effect engine should execute selected tag linkage branch effect")
	var mp_events: Array = summary.get("mp_events", [])
	_assert_true(mp_events.size() == 1, "effect engine should emit one mp event for branch effect")

	engine = null
	_free_bundle(bundle, [owner])


func _build_context_bundle() -> Dictionary:
	var grid: MockHexGrid = MockHexGrid.new()
	var combat_manager: MockCombatManager = MockCombatManager.new()
	combat_manager.setup(grid)
	var manager: MockGongfaManager = MockGongfaManager.new()
	manager.set_tag_maps(_gongfa_tags, _equipment_tags)
	return {
		"hex_grid": grid,
		"combat_manager": combat_manager,
		"manager": manager
	}


func _build_effect_context(bundle: Dictionary, units: Array) -> Dictionary:
	return {
		"all_units": units,
		"hex_grid": bundle.hex_grid,
		"combat_manager": bundle.combat_manager,
		"gongfa_manager": bundle.manager,
		"hex_size": 32.0
	}


func _make_unit(
	unit_id: String,
	team_id: int,
	tags: Array,
	traits: Array,
	runtime_gongfa_ids: Array,
	runtime_equip_ids: Array
) -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.unit_id = unit_id
	unit.unit_name = unit_id
	unit.team_id = team_id
	unit.tags = tags.duplicate(true)
	unit.traits = traits.duplicate(true)
	unit.runtime_equipped_gongfa_ids = runtime_gongfa_ids.duplicate(true)
	unit.runtime_equipped_equip_ids = runtime_equip_ids.duplicate(true)

	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)

	var combat: MockUnitCombat = MockUnitCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)

	return unit


func _free_bundle(bundle: Dictionary, units: Array) -> void:
	for unit in units:
		if unit != null and is_instance_valid(unit):
			unit.free()
	if bundle.has("manager") and bundle.manager != null and is_instance_valid(bundle.manager):
		bundle.manager.free()
	if bundle.has("combat_manager") and bundle.combat_manager != null and is_instance_valid(bundle.combat_manager):
		bundle.combat_manager.free()
	if bundle.has("hex_grid") and bundle.hex_grid != null and is_instance_valid(bundle.hex_grid):
		bundle.hex_grid.free()


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


func _array_has_str(raw: Variant, target: String) -> bool:
	if not (raw is Array):
		return false
	for item in (raw as Array):
		if str(item) == target:
			return true
	return false


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
