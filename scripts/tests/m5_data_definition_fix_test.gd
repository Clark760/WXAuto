extends SceneTree

const SHOP_MANAGER_SCRIPT: Script = preload("res://scripts/economy/shop_manager.gd")
const STAGE_DATA_SCRIPT: Script = preload("res://scripts/domain/stage/stage_data.gd")
const UNIT_DATA_SCRIPT: Script = preload("res://scripts/domain/unit/unit_data.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")
const HUD_SUPPORT_SCRIPT: Script = preload("res://scripts/app/battlefield/battlefield_hud_support.gd")
const STAGE_SCHEMA_PATH: String = "res://data/stages/_schema/stage.schema.json"
const EQUIPMENT_SCHEMA_PATH: String = "res://data/equipment/_schema/equipment.schema.json"
const UI_TEXTS_MOD_DIR: String = "res://mods/base/data/ui_texts"

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


class DummyUnitAugmentManager:
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


class DummyHudRefs:
	extends Node
	var data_repository: Node = null
	var unit_augment_manager = null
	var bench_ui = null
	var combat_manager = null

	func setup(data_repository_value: Node) -> void:
		data_repository = data_repository_value

	func get_data_repository() -> Node:
		return data_repository


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
	_test_equipment_schema_quality_only()
	_test_stage_normalizes_enemy_rows_without_inline_build_fields()
	_test_stage_type_fallback_from_unknown_value()
	_test_stage_schema_type_enum_values()
	_test_battlefield_hud_display_config_loads_from_data()


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

	var unit_augment_manager: DummyUnitAugmentManager = DummyUnitAugmentManager.new()
	unit_augment_manager.setup(
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
				"quality": "white",
				"shop_visible": true
			},
			{
				"id": "eq_hidden",
				"name": "Hidden Equipment",
				"type": "weapon",
				"quality": "white",
				"shop_visible": false
			}
		]
	)

	shop_manager.call("reload_pools", unit_factory, unit_augment_manager)
	var probabilities: Dictionary = {
		"white": 1.0,
		"green": 0.0,
		"blue": 0.0,
		"purple": 0.0,
		"orange": 0.0
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
	unit_augment_manager.free()
	shop_manager.free()


func _test_equipment_schema_quality_only() -> void:
	var file: FileAccess = FileAccess.open(EQUIPMENT_SCHEMA_PATH, FileAccess.READ)
	_assert_true(file != null, "equipment schema file should exist")
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_assert_true(parsed is Dictionary, "equipment schema should be a dictionary")
	if not (parsed is Dictionary):
		return
	var schema: Dictionary = parsed as Dictionary
	var required_fields: Variant = schema.get("required", [])
	_assert_true(required_fields is Array, "equipment schema required should be an array")
	if not (required_fields is Array):
		return
	var required: Array = required_fields as Array
	_assert_true(required.has("quality"), "equipment schema should require quality")
	_assert_true(not required.has("rarity"), "equipment schema should not require rarity")
	var properties: Dictionary = schema.get("properties", {})
	_assert_true(properties.has("quality"), "equipment schema should define quality property")
	_assert_true(not properties.has("rarity"), "equipment schema should not define rarity property")


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


func _test_battlefield_hud_display_config_loads_from_data() -> void:
	var data_manager: Node = DATA_MANAGER_SCRIPT.new()
	var supported_categories: Array[String] = data_manager.get_supported_categories()
	_assert_true(supported_categories.has("ui_texts"), "data_manager should support ui_texts category")

	var base_summary: Dictionary = data_manager.load_base_data()
	var category_counts: Dictionary = base_summary.get("categories", {})
	_assert_true(category_counts.has("ui_texts"), "base data summary should include ui_texts category")

	var ui_texts_result: Dictionary = data_manager.load_category_from_dir(
		"ui_texts",
		UI_TEXTS_MOD_DIR,
		"mod:test_ui_texts"
	)
	_assert_true(int(ui_texts_result.get("records", 0)) == 1, "ui_texts mod data should load one record")

	var display_record: Dictionary = data_manager.get_record("ui_texts", "battlefield_hud_display")
	_assert_true(not display_record.is_empty(), "battlefield_hud_display record should exist")
	if display_record.is_empty():
		data_manager.free()
		return

	var refs: DummyHudRefs = DummyHudRefs.new()
	refs.setup(data_manager)
	var support = HUD_SUPPORT_SCRIPT.new()
	support.initialize(null, refs, null)
	support.reload_external_item_data()

	var slot_labels: Dictionary = display_record.get("slot_labels", {})
	var neigong_entry: Dictionary = slot_labels.get("neigong", {})
	_assert_true(
		str(neigong_entry.get("text", "")) == support.slot_to_cn("neigong"),
		"slot_to_cn should read label from ui_texts config"
	)
	_assert_true(
		str(neigong_entry.get("icon", "")) == support.slot_icon("neigong"),
		"slot_icon should read icon from ui_texts config"
	)

	var equip_labels: Dictionary = display_record.get("equip_type_labels", {})
	var weapon_entry: Dictionary = equip_labels.get("weapon", {})
	_assert_true(
		str(weapon_entry.get("text", "")) == support.equip_type_to_cn("weapon"),
		"equip_type_to_cn should read label from ui_texts config"
	)
	_assert_true(
		str(weapon_entry.get("icon", "")) == support.equip_icon("weapon"),
		"equip_icon should read icon from ui_texts config"
	)

	var stat_labels: Dictionary = display_record.get("stat_labels", {})
	_assert_true(
		str(stat_labels.get("hp", "")) == support.stat_key_to_cn("hp"),
		"stat_key_to_cn should read label from ui_texts config"
	)

	var quality_labels: Dictionary = display_record.get("quality_labels", {})
	_assert_true(
		str(quality_labels.get("orange", "")) == support.quality_to_cn("orange"),
		"quality_to_cn should read label from ui_texts config"
	)

	var quality_colors: Dictionary = display_record.get("quality_colors", {})
	_assert_color_equals_array(
		support.quality_color("orange"),
		quality_colors.get("orange", []),
		"quality_color should read rgba from ui_texts config"
	)

	var damage_type_labels: Dictionary = display_record.get("damage_type_labels", {})
	_assert_true(
		str(damage_type_labels.get("reflect", "")) == support.damage_type_to_cn("reflect"),
		"damage_type_to_cn should read label from ui_texts config"
	)

	refs.free()
	data_manager.free()


func _offers_contain_item(offers: Array, item_id: String) -> bool:
	for offer_value in offers:
		if not (offer_value is Dictionary):
			continue
		if str((offer_value as Dictionary).get("item_id", "")) == item_id:
			return true
	return false


func _assert_color_equals_array(actual: Color, expected_value: Variant, message: String) -> void:
	_assert_true(expected_value is Array, "%s (expected array)" % message)
	if not (expected_value is Array):
		return
	var channels: Array = expected_value as Array
	_assert_true(channels.size() >= 4, "%s (expected 4 channels)" % message)
	if channels.size() < 4:
		return
	_assert_true(
		is_equal_approx(actual.r, float(channels[0]))
		and is_equal_approx(actual.g, float(channels[1]))
		and is_equal_approx(actual.b, float(channels[2]))
		and is_equal_approx(actual.a, float(channels[3])),
		message
	)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
