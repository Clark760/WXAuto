extends SceneTree

const UNIT_DATA_SCRIPT: Script = preload("res://scripts/data/unit_data.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")
const UNIT_STATE_SERVICE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_unit_state_service.gd")


class MockRegistry:
	extends RefCounted
	var _equipment_map: Dictionary = {
		"eq_weapon": {"id": "eq_weapon", "type": "weapon", "effects": []},
		"eq_armor": {"id": "eq_armor", "type": "armor", "effects": []},
		"eq_accessory": {"id": "eq_accessory", "type": "accessory", "effects": []}
	}

	func has_equipment(equip_id: String) -> bool:
		return _equipment_map.has(equip_id)

	func get_equipment(equip_id: String) -> Dictionary:
		if not _equipment_map.has(equip_id):
			return {}
		return (_equipment_map[equip_id] as Dictionary).duplicate(true)

	func has_gongfa(_gongfa_id: String) -> bool:
		return false

	func get_gongfa(_gongfa_id: String) -> Dictionary:
		return {}

	func get_all_gongfa() -> Array[Dictionary]:
		return []

	func get_all_equipment() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for row in _equipment_map.values():
			out.append((row as Dictionary).duplicate(true))
		return out


class MockUnit:
	extends Node
	var unit_id: String = "mock_unit"
	var team_id: int = 1
	var base_stats: Dictionary = {"hp": 100.0, "rng": 1.0, "spd": 1.0, "wis": 1.0}
	var star_level: int = 1
	var traits: Array = []
	var gongfa_slots: Dictionary = {"neigong": "", "waigong": "", "qinggong": "", "zhenfa": ""}
	var equip_slots: Dictionary = {"slot_1": "", "slot_2": ""}
	var max_equip_count: int = 2
	var runtime_stats: Dictionary = {}
	var runtime_equipped_gongfa_ids: Array[String] = []
	var runtime_equipped_equip_ids: Array[String] = []


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 equip slot refactor tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 equip slot refactor tests passed.")
	quit(0)


func _run() -> void:
	_test_unit_data_keeps_dynamic_slots_and_count()
	_test_manager_accepts_any_equipment_type_with_dynamic_slots()


func _test_unit_data_keeps_dynamic_slots_and_count() -> void:
	var raw: Dictionary = {
		"id": "unit_equip_slot_schema_case",
		"equip_slots": {
			"slot_1": "eq_weapon",
			"slot_2": "eq_armor",
			"slot_3": "eq_accessory"
		},
		"max_equip_count": 3
	}
	var normalized: Dictionary = UNIT_DATA_SCRIPT.call("normalize_unit_record", raw)
	var slots: Dictionary = normalized.get("equip_slots", {})
	_assert_true(int(normalized.get("max_equip_count", -1)) == 3, "unit_data should keep configured max_equip_count")
	_assert_true(str(slots.get("slot_1", "")) == "eq_weapon", "unit_data should keep slot_1")
	_assert_true(str(slots.get("slot_2", "")) == "eq_armor", "unit_data should keep slot_2")
	_assert_true(str(slots.get("slot_3", "")) == "eq_accessory", "unit_data should keep dynamic slot_3")
	var auto_expand_raw: Dictionary = {
		"id": "unit_equip_slot_auto_expand",
		"equip_slots": {"slot_1": "eq_weapon"},
		"max_equip_count": 4
	}
	var auto_expand_norm: Dictionary = UNIT_DATA_SCRIPT.call("normalize_unit_record", auto_expand_raw)
	var auto_slots: Dictionary = auto_expand_norm.get("equip_slots", {})
	_assert_true(int(auto_expand_norm.get("max_equip_count", -1)) == 4, "unit_data should keep dynamic max_equip_count=4")
	_assert_true(auto_slots.has("slot_4"), "unit_data should auto-create missing slots up to max_equip_count")


func _test_manager_accepts_any_equipment_type_with_dynamic_slots() -> void:
	var manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	var registry: MockRegistry = MockRegistry.new()
	manager.set("_registry", registry)
	manager.set(
		"_state_service",
		UNIT_STATE_SERVICE_SCRIPT.new(
			registry,
			manager.get_effect_engine(),
			manager.get_buff_manager(),
			manager.get_tag_linkage_scheduler(),
			load("res://scripts/data/unit_data.gd")
		)
	)

	var unit: MockUnit = MockUnit.new()
	unit.equip_slots = {"slot_1": "", "slot_2": "", "slot_3": ""}
	unit.max_equip_count = 3

	var ok_1: bool = bool(manager.call("equip_equipment", unit, "slot_1", "eq_weapon"))
	var ok_2: bool = bool(manager.call("equip_equipment", unit, "slot_2", "eq_armor"))
	var ok_3: bool = bool(manager.call("equip_equipment", unit, "slot_3", "eq_accessory"))
	_assert_true(ok_1 and ok_2 and ok_3, "manager should allow any equipment type in dynamic slots")

	var slots: Dictionary = unit.get("equip_slots")
	_assert_true(str(slots.get("slot_1", "")) == "eq_weapon", "slot_1 should keep equipped item")
	_assert_true(str(slots.get("slot_2", "")) == "eq_armor", "slot_2 should keep equipped item")
	_assert_true(str(slots.get("slot_3", "")) == "eq_accessory", "slot_3 should be equipable when defined")
	_assert_true(int(unit.get("max_equip_count")) == 3, "equip_equipment should preserve dynamic max_equip_count")

	unit.set("equip_slots", {"slot_1": "eq_weapon", "slot_2": "eq_armor", "slot_3": "eq_accessory"})
	unit.set("max_equip_count", 3)
	var equipped_ids: Array[String] = manager.call("_resolve_equipped_equip_ids", unit)
	_assert_true(equipped_ids.size() == 3, "runtime equipped ids should follow dynamic max slot count")
	_assert_true(equipped_ids.has("eq_weapon") and equipped_ids.has("eq_armor") and equipped_ids.has("eq_accessory"), "runtime equipped ids should include dynamic slot values")

	manager.call("unequip_equipment", unit, "slot_2")
	slots = unit.get("equip_slots")
	_assert_true(str(slots.get("slot_2", "x")).is_empty(), "unequip should clear slot_2")

	var invalid_slot_ok: bool = bool(manager.call("equip_equipment", unit, "slot_4", "eq_weapon"))
	_assert_true(not invalid_slot_ok, "undefined equipment slot key should be rejected")

	unit.free()
	manager.free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
