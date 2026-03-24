extends SceneTree

const SHOP_MANAGER_SCRIPT: Script = preload("res://scripts/economy/shop_manager.gd")
const STAGE_DATA_SCRIPT: Script = preload("res://scripts/stage/stage_data.gd")
const UNIT_DATA_SCRIPT: Script = preload("res://scripts/data/unit_data.gd")
const STAGE_SCHEMA_PATH: String = "res://data/stages/_schema/stage.schema.json"

class DummyUnitFactory:
	extends Node
	var _records: Dictionary = {}

	func setup(records: Dictionary) -> void:
		_records = records.duplicate(true)

	func get_unit_ids() -> Array[String]:
		var ids: Array[String] = []
		for key in _records.keys():
			ids.append(str(key))
		ids.sort()
		return ids

	func get_unit_record(unit_id: String) -> Dictionary:
		if not _records.has(unit_id):
			return {}
		return (_records[unit_id] as Dictionary).duplicate(true)


class DummyGongfaManager:
	extends Node
	var _gongfa: Array[Dictionary] = []
	var _equipment: Array[Dictionary] = []

	func setup(gongfa_rows: Array[Dictionary], equipment_rows: Array[Dictionary]) -> void:
		_gongfa = gongfa_rows.duplicate(true)
		_equipment = equipment_rows.duplicate(true)

	func get_all_gongfa() -> Array[Dictionary]:
		return _gongfa.duplicate(true)

	func get_all_equipment() -> Array[Dictionary]:
		return _equipment.duplicate(true)


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 data definition fix tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 data definition fix tests passed.")
	quit(0)


func _run() -> void:
	_test_unit_normalize_shop_visible_default()
	_test_shop_filters_hidden_entries()
	_test_stage_normalizes_enemy_rows_without_inline_build_fields()
	_test_stage_type_fallback_from_unknown_value()
	_test_stage_schema_type_enum_values()


func _test_unit_normalize_shop_visible_default() -> void:
	var visible_raw: Dictionary = {
		"id": "unit_test_visible_default"
	}
	var visible_norm: Dictionary = UNIT_DATA_SCRIPT.call("normalize_unit_record", visible_raw)
	_assert_true(bool(visible_norm.get("shop_visible", false)), "unit normalize should default shop_visible=true")

	var hidden_raw: Dictionary = {
		"id": "unit_test_hidden",
		"shop_visible": false
	}
	var hidden_norm: Dictionary = UNIT_DATA_SCRIPT.call("normalize_unit_record", hidden_raw)
	_assert_true(not bool(hidden_norm.get("shop_visible", true)), "unit normalize should preserve shop_visible=false")


func _test_shop_filters_hidden_entries() -> void:
	var shop_manager: Node = SHOP_MANAGER_SCRIPT.new()
	shop_manager.call("_ready")
	shop_manager.set("recruit_offer_count", 1)
	shop_manager.set("gongfa_offer_count", 1)
	shop_manager.set("equipment_offer_count", 1)

	var unit_factory: DummyUnitFactory = DummyUnitFactory.new()
	unit_factory.setup({
		"unit_visible": {
			"id": "unit_visible",
			"name": "Visible Unit",
			"quality": "white",
			"cost": 1,
			"shop_visible": true
		},
		"unit_hidden": {
			"id": "unit_hidden",
			"name": "Hidden Unit",
			"quality": "white",
			"cost": 1,
			"shop_visible": false
		}
	})

	var gongfa_manager: DummyGongfaManager = DummyGongfaManager.new()
	gongfa_manager.setup(
		[
			{
				"id": "gf_visible",
				"name": "Visible Gongfa",
				"type": "neigong",
				"quality": "white",
				"shop_visible": true
			},
			{
				"id": "gf_hidden",
				"name": "Hidden Gongfa",
				"type": "neigong",
				"quality": "white",
				"shop_visible": false
			}
		],
		[
			{
				"id": "eq_visible",
				"name": "Visible Equipment",
				"type": "weapon",
				"rarity": "white",
				"shop_visible": true
			},
			{
				"id": "eq_hidden",
				"name": "Hidden Equipment",
				"type": "weapon",
				"rarity": "white",
				"shop_visible": false
			}
		]
	)

	shop_manager.call("reload_pools", unit_factory, gongfa_manager)
	var probabilities: Dictionary = {
		"white": 1.0,
		"green": 0.0,
		"blue": 0.0,
		"purple": 0.0,
		"orange": 0.0,
		"red": 0.0
	}

	for _idx in range(10):
		var snapshot: Dictionary = shop_manager.call("refresh_shop", probabilities, false, true)
		var recruit: Array = snapshot.get("recruit", [])
		var gongfa_offers: Array = snapshot.get("gongfa", [])
		var equipment_offers: Array = snapshot.get("equipment", [])
		_assert_true(not _offers_contain_item(recruit, "unit_hidden"), "recruit offers should never contain hidden unit")
		_assert_true(not _offers_contain_item(gongfa_offers, "gf_hidden"), "gongfa offers should never contain hidden gongfa")
		_assert_true(not _offers_contain_item(equipment_offers, "eq_hidden"), "equipment offers should never contain hidden equipment")

	unit_factory.free()
	gongfa_manager.free()
	shop_manager.free()


func _test_stage_normalizes_enemy_rows_without_inline_build_fields() -> void:
	var stage_data = STAGE_DATA_SCRIPT.new()
	var raw: Dictionary = {
		"id": "stage_enemy_inline_fields",
		"chapter": 1,
		"index": 99,
		"type": "normal",
		"grid": {},
		"enemies": [
			{
				"unit_id": "unit_a",
				"count": 1,
				"gongfa_ids": ["gf_x"],
				"equip_ids": ["eq_x"],
				"traits": [{"id": "t1", "name": "x"}]
			}
		],
		"rewards": {}
	}
	var normalized: Dictionary = stage_data.call("normalize_stage_record", raw)
	_assert_true(not normalized.is_empty(), "stage_data should normalize valid stage rows")
	var enemies: Array = normalized.get("enemies", [])
	_assert_true(enemies.size() == 1, "stage_data should keep enemy row")
	var row: Dictionary = enemies[0] if enemies.size() > 0 and enemies[0] is Dictionary else {}
	_assert_true(not row.has("gongfa_ids"), "normalized enemy should drop inline gongfa_ids")
	_assert_true(not row.has("equip_ids"), "normalized enemy should drop inline equip_ids")
	_assert_true(not row.has("traits"), "normalized enemy should drop inline traits")


func _test_stage_type_fallback_from_unknown_value() -> void:
	var stage_data = STAGE_DATA_SCRIPT.new()
	var raw: Dictionary = {
		"id": "stage_invalid_type_fallback",
		"chapter": 1,
		"index": 1,
		"type": "unknown_type",
		"grid": {},
		"enemies": [{"unit_id": "unit_a", "count": 1}],
		"rewards": {}
	}
	var normalized: Dictionary = stage_data.call("normalize_stage_record", raw)
	_assert_true(not normalized.is_empty(), "stage_data should normalize unknown type by fallback")
	_assert_true(str(normalized.get("type", "")) == "normal", "stage_data should fallback unknown type to normal")


func _test_stage_schema_type_enum_values() -> void:
	var file: FileAccess = FileAccess.open(STAGE_SCHEMA_PATH, FileAccess.READ)
	_assert_true(file != null, "stage schema file should exist")
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_assert_true(parsed is Dictionary, "stage schema should be a dictionary")
	if not (parsed is Dictionary):
		return
	var schema: Dictionary = parsed as Dictionary
	var properties: Dictionary = schema.get("properties", {})
	var type_prop: Dictionary = properties.get("type", {})
	var enum_values: Variant = type_prop.get("enum", [])
	_assert_true(enum_values is Array, "stage schema type enum should exist")
	if not (enum_values is Array):
		return
	var enum_array: Array = enum_values as Array
	_assert_true(enum_array.has("normal"), "stage schema type enum should contain normal")
	_assert_true(enum_array.has("elite"), "stage schema type enum should contain elite")
	_assert_true(enum_array.has("rest"), "stage schema type enum should contain rest")
	_assert_true(enum_array.has("event"), "stage schema type enum should contain event")
	_assert_true(enum_array.size() == 4, "stage schema type enum should only contain 4 supported values")


func _offers_contain_item(offers: Array, item_id: String) -> bool:
	for offer_value in offers:
		if not (offer_value is Dictionary):
			continue
		if str((offer_value as Dictionary).get("item_id", "")) == item_id:
			return true
	return false


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
