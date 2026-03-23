extends SceneTree

const STAGE_DATA_SCRIPT: Script = preload("res://scripts/stage/stage_data.gd")
const STAGE_BOSS_PATH: String = "res://data/stages/stage_1_3_boss.json"
const STAGE_SCHEMA_PATH: String = "res://data/stages/_schema/stage.schema.json"
const BOSS_UNIT_PATH: String = "res://data/units/units_boss_m5.json"
const BOSS_UNIT_ID: String = "unit_boss_stage_1_3"

var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 boss trait pipeline tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 boss trait pipeline tests passed.")
	quit(0)


func _run() -> void:
	_test_stage_data_rejects_removed_boss_fields()
	_test_stage_schema_removed_inline_enemy_fields()
	_test_stage_boss_references_boss_unit_only()
	_test_boss_unit_contains_mechanics()


func _test_stage_data_rejects_removed_boss_fields() -> void:
	var stage_data = STAGE_DATA_SCRIPT.new()

	var with_boss_gongfa: Dictionary = {
		"id": "stage_invalid_boss_gongfa",
		"chapter": 1,
		"index": 1,
		"type": "boss",
		"grid": {},
		"enemies": [],
		"rewards": {},
		"boss_gongfa_ids": ["boss_phase_shield"]
	}
	var normalized_a: Dictionary = stage_data.call("normalize_stage_record", with_boss_gongfa)
	_assert_true(normalized_a.is_empty(), "stage_data should reject removed boss_gongfa_ids")

	var with_enemy_is_boss: Dictionary = {
		"id": "stage_invalid_enemy_is_boss",
		"chapter": 1,
		"index": 1,
		"type": "boss",
		"grid": {},
		"enemies": [
			{
				"unit_id": "unit_blue_183",
				"count": 1,
				"is_boss": true
			}
		],
		"rewards": {}
	}
	var normalized_b: Dictionary = stage_data.call("normalize_stage_record", with_enemy_is_boss)
	_assert_true(normalized_b.is_empty(), "stage_data should reject removed enemies[].is_boss")

	var with_enemy_inline_data: Dictionary = {
		"id": "stage_invalid_enemy_inline_data",
		"chapter": 1,
		"index": 1,
		"type": "boss",
		"grid": {},
		"enemies": [
			{
				"unit_id": "unit_blue_183",
				"count": 1,
				"gongfa_ids": ["gf_jiuyin"],
				"equip_ids": ["eq_tulong"],
				"traits": [{"id": "x", "name": "y"}]
			}
		],
		"rewards": {}
	}
	var normalized_c: Dictionary = stage_data.call("normalize_stage_record", with_enemy_inline_data)
	_assert_true(normalized_c.is_empty(), "stage_data should reject enemies inline boss data")


func _test_stage_schema_removed_inline_enemy_fields() -> void:
	var schema: Dictionary = _load_json_dict(STAGE_SCHEMA_PATH)
	var properties: Dictionary = schema.get("properties", {})
	_assert_true(not properties.has("boss_gongfa_ids"), "stage schema should not define boss_gongfa_ids")
	_assert_true(not properties.has("boss_mechanics"), "stage schema should not define boss_mechanics")

	var enemies: Dictionary = properties.get("enemies", {})
	var enemy_items: Dictionary = enemies.get("items", {})
	var enemy_props: Dictionary = enemy_items.get("properties", {})
	_assert_true(not enemy_props.has("is_boss"), "stage schema should not define enemies[].is_boss")
	_assert_true(not enemy_props.has("gongfa_ids"), "stage schema should not define enemies[].gongfa_ids")
	_assert_true(not enemy_props.has("equip_ids"), "stage schema should not define enemies[].equip_ids")
	_assert_true(not enemy_props.has("traits"), "stage schema should not define enemies[].traits")


func _test_stage_boss_references_boss_unit_only() -> void:
	var stage_data = STAGE_DATA_SCRIPT.new()
	var raw_stage: Dictionary = _load_json_dict(STAGE_BOSS_PATH)
	var normalized: Dictionary = stage_data.call("normalize_stage_record", raw_stage)
	_assert_true(not normalized.is_empty(), "stage_1_3_boss should normalize successfully")

	var enemies: Array = normalized.get("enemies", [])
	var boss_row: Dictionary = {}
	for row in enemies:
		if not (row is Dictionary):
			continue
		if str((row as Dictionary).get("unit_id", "")) == BOSS_UNIT_ID:
			boss_row = row
			break
	_assert_true(not boss_row.is_empty(), "stage_1_3_boss should reference %s" % BOSS_UNIT_ID)
	_assert_true(not boss_row.has("gongfa_ids"), "boss enemy row should not contain gongfa_ids")
	_assert_true(not boss_row.has("equip_ids"), "boss enemy row should not contain equip_ids")
	_assert_true(not boss_row.has("traits"), "boss enemy row should not contain traits")


func _test_boss_unit_contains_mechanics() -> void:
	var rows: Array = _load_json_array(BOSS_UNIT_PATH)
	var boss_row: Dictionary = {}
	for item in rows:
		if not (item is Dictionary):
			continue
		var row: Dictionary = item as Dictionary
		if str(row.get("id", "")) == BOSS_UNIT_ID:
			boss_row = row
			break
	_assert_true(not boss_row.is_empty(), "boss unit data should exist: %s" % BOSS_UNIT_ID)
	_assert_true(not bool(boss_row.get("shop_visible", true)), "boss unit should be hidden from shop")
	var traits: Array = boss_row.get("traits", [])
	_assert_true(traits.size() >= 3, "boss unit should carry migrated boss traits")
	_assert_true(_trait_exists(traits, "trait_stage_boss_phase_shield"), "phase shield trait should exist on boss unit")
	_assert_true(_trait_exists(traits, "trait_stage_boss_summon_hazard"), "summon hazard trait should exist on boss unit")
	_assert_true(_trait_exists(traits, "trait_stage_boss_enrage"), "enrage trait should exist on boss unit")


func _trait_exists(traits: Array, trait_id: String) -> bool:
	for trait_row in traits:
		if not (trait_row is Dictionary):
			continue
		if str((trait_row as Dictionary).get("id", "")) == trait_id:
			return true
	return false


func _load_json_array(path: String) -> Array:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	_assert_true(file != null, "file should exist: %s" % path)
	if file == null:
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_assert_true(parsed is Array, "file should be JSON array: %s" % path)
	if parsed is Array:
		return parsed as Array
	return []


func _load_json_dict(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	_assert_true(file != null, "file should exist: %s" % path)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_assert_true(parsed is Dictionary, "file should be JSON object: %s" % path)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
