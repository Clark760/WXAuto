extends SceneTree

const UNIT_DATA_SCRIPT: Script = preload("res://scripts/domain/unit/unit_data.gd")
const UNIT_BASE_SCENE: PackedScene = preload("res://scenes/units/unit_base.tscn")
const STAGE_DATA_SCRIPT: Script = preload("res://scripts/domain/stage/stage_data.gd")
const TERRAIN_MANAGER_SCRIPT: Script = preload("res://scripts/combat/terrain_manager.gd")

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 trait/terrain tag support tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 trait/terrain tag support tests passed.")
	quit(0)


func _run() -> void:
	await _test_unit_trait_tags_support()
	await _test_stage_terrain_tags_normalization()
	await _test_terrain_manager_tags_support()


func _test_unit_trait_tags_support() -> void:
	var raw_record: Dictionary = {
		"id": "unit_tag_test",
		"name": "Tag Tester",
		"tags": [" Frontline ", "frontline", "Leader", ""],
		"traits": [
			{
				"id": "trait_support_aura",
				"name": "Support Aura",
				"tags": [" Support ", "heal", "Heal", ""]
			}
		]
	}
	var normalized: Dictionary = UNIT_DATA_SCRIPT.call("normalize_unit_record", raw_record)
	var normalized_unit_tags: Array = normalized.get("tags", [])
	_assert_true(normalized_unit_tags.size() == 2, "unit tags should be trimmed and deduplicated")
	_assert_true(str(normalized_unit_tags[0]) == "Frontline", "unit tag keeps first normalized spelling")
	_assert_true(str(normalized_unit_tags[1]) == "Leader", "unit tag keeps second normalized spelling")

	var normalized_traits: Array = normalized.get("traits", [])
	_assert_true(normalized_traits.size() == 1, "unit should keep one trait")
	var trait_tags: Array = (normalized_traits[0] as Dictionary).get("tags", [])
	_assert_true(trait_tags.size() == 2, "trait tags should be trimmed and deduplicated")

	var unit_node: Node = UNIT_BASE_SCENE.instantiate()
	root.add_child(unit_node)
	await process_frame
	unit_node.call("setup_from_unit_record", normalized)

	_assert_true(bool(unit_node.call("has_trait_tag", "support")), "unit should support trait tag lookup")
	_assert_true(bool(unit_node.call("has_trait_tag", "HEAL")), "trait tag lookup should be case-insensitive")
	_assert_true(bool(unit_node.call("has_unit_tag", "leader", false)), "unit tag lookup should support own tags")
	_assert_true(not bool(unit_node.call("has_unit_tag", "support", false)), "unit-only tag lookup should exclude trait tags")
	_assert_true(bool(unit_node.call("has_unit_tag", "support", true)), "unit tag lookup with include_trait_tags should include trait tags")

	unit_node.queue_free()


func _test_stage_terrain_tags_normalization() -> void:
	var stage_data: Object = STAGE_DATA_SCRIPT.new()

	var stage_with_terrains: Dictionary = stage_data.call("normalize_stage_record", {
		"id": "stage_tag_test_terrain",
		"chapter": 1,
		"index": 1,
		"type": "normal",
		"grid": {},
		"enemies": [],
		"terrains": [
			{
				"terrain_id": "terrain_fire",
				"cells": [[2, 2]],
				"tags": [" Hazard ", "burn", "Burn", ""]
			}
		],
		"rewards": {}
	})
	var terrains_rows: Array = stage_with_terrains.get("terrains", [])
	_assert_true(terrains_rows.size() == 1, "stage terrains should keep one row")
	var first_terrain_tags: Array = (terrains_rows[0] as Dictionary).get("tags", [])
	_assert_true(first_terrain_tags.size() == 2, "stage terrain tags should be trimmed and deduplicated")

	var stage_with_legacy_obstacle: Dictionary = stage_data.call("normalize_stage_record", {
		"id": "stage_tag_test_obstacle",
		"chapter": 1,
		"index": 2,
		"type": "normal",
		"grid": {},
		"enemies": [],
		"obstacles": [
			{
				"type": "rock",
				"cells": [[1, 1]]
			}
		],
		"rewards": {}
	})
	var legacy_rows: Array = stage_with_legacy_obstacle.get("terrains", [])
	_assert_true(legacy_rows.size() == 1, "legacy obstacles should convert into one terrain row")
	var legacy_tags: Array = (legacy_rows[0] as Dictionary).get("tags", [])
	_assert_true(legacy_tags.has("obstacle"), "legacy obstacle terrain should include obstacle tag")
	_assert_true(legacy_tags.has("rock"), "legacy obstacle terrain should include obstacle type tag")


func _test_terrain_manager_tags_support() -> void:
	var terrain_manager: Object = TERRAIN_MANAGER_SCRIPT.new()
	terrain_manager.call("set_terrain_registry", [
		{
			"id": "terrain_fire",
			"type": "hazard",
			"tags": ["Hazard", "burn", "Burn", ""]
		}
	])

	var added_static: Dictionary = terrain_manager.call("add_static_terrain", "fire", [Vector2i(3, 4)], {}, {})
	_assert_true(bool(added_static.get("added", false)), "static terrain should be added")
	_assert_true(bool(terrain_manager.call("cell_has_terrain_tag", Vector2i(3, 4), "hazard", "all", null)), "cell should inherit terrain-definition tag")
	_assert_true(bool(terrain_manager.call("cell_has_terrain_tag", Vector2i(3, 4), "burn", "static", null)), "static scope should include static terrain tags")

	var added_static_override: Dictionary = terrain_manager.call(
		"add_static_terrain",
		"fire",
		[Vector2i(5, 6)],
		{},
		{"tags": ["StoneField", "burn"]}
	)
	_assert_true(bool(added_static_override.get("added", false)), "static terrain with override tags should be added")
	_assert_true(bool(terrain_manager.call("cell_has_terrain_tag", Vector2i(5, 6), "stonefield", "all", null)), "override tags should be normalized and queryable")
	_assert_true(not bool(terrain_manager.call("cell_has_terrain_tag", Vector2i(5, 6), "stonefield", "dynamic", null)), "dynamic scope should exclude static terrains")

	var added_dynamic: Dictionary = terrain_manager.call(
		"add_terrain",
		{
			"terrain_ref_id": "fire",
			"cells": [Vector2i(7, 8)],
			"duration": 2.0,
			"tags": ["DynamicHot"]
		},
		null,
		{}
	)
	_assert_true(bool(added_dynamic.get("added", false)), "dynamic terrain should be added")
	_assert_true(bool(terrain_manager.call("cell_has_terrain_tag", Vector2i(7, 8), "dynamichot", "dynamic", null)), "dynamic scope should include temporary terrain tags")
	_assert_true(not bool(terrain_manager.call("cell_has_terrain_tag", Vector2i(7, 8), "dynamichot", "static", null)), "static scope should exclude temporary terrain tags")


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
