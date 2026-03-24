extends SceneTree

const STAGE_DATA_SCRIPT: Script = preload("res://scripts/stage/stage_data.gd")
const STAGE_SCHEMA_PATH: String = "res://data/stages/_schema/stage.schema.json"

var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 stage schema pipeline tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 stage schema pipeline tests passed.")
	quit(0)


func _run() -> void:
	_test_stage_schema_type_enum()
	_test_stage_type_fallback_to_normal()
	_test_stage_type_accepts_supported_values()


func _test_stage_schema_type_enum() -> void:
	var schema: Dictionary = _load_json_dict(STAGE_SCHEMA_PATH)
	var properties: Dictionary = schema.get("properties", {})
	var type_prop: Dictionary = properties.get("type", {})
	var enum_values: Variant = type_prop.get("enum", [])
	_assert_true(enum_values is Array, "stage schema type enum should exist")
	if not (enum_values is Array):
		return
	var enums: Array = enum_values as Array
	_assert_true(enums.has("normal"), "stage schema type enum should contain normal")
	_assert_true(enums.has("elite"), "stage schema type enum should contain elite")
	_assert_true(enums.has("rest"), "stage schema type enum should contain rest")
	_assert_true(enums.has("event"), "stage schema type enum should contain event")
	_assert_true(enums.size() == 4, "stage schema type enum should only contain 4 supported values")


func _test_stage_type_fallback_to_normal() -> void:
	var stage_data = STAGE_DATA_SCRIPT.new()
	var normalized: Dictionary = stage_data.call("normalize_stage_record", {
		"id": "stage_type_fallback",
		"chapter": 1,
		"index": 1,
		"type": "legacy_removed_type",
		"grid": {},
		"enemies": [{"unit_id": "unit_a", "count": 1}],
		"rewards": {}
	})
	_assert_true(not normalized.is_empty(), "stage_data should normalize fallback stage")
	_assert_true(str(normalized.get("type", "")) == "normal", "unknown stage type should fallback to normal")


func _test_stage_type_accepts_supported_values() -> void:
	var stage_data = STAGE_DATA_SCRIPT.new()
	for stage_type in ["normal", "elite", "rest", "event"]:
		var normalized: Dictionary = stage_data.call("normalize_stage_record", {
			"id": "stage_type_%s" % stage_type,
			"chapter": 1,
			"index": 1,
			"type": stage_type,
			"grid": {},
			"enemies": [{"unit_id": "unit_a", "count": 1}],
			"rewards": {}
		})
		_assert_true(not normalized.is_empty(), "stage_data should normalize supported type=%s" % stage_type)
		_assert_true(str(normalized.get("type", "")) == stage_type, "stage_data should keep type=%s" % stage_type)


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
