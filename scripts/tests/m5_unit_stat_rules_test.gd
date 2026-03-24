extends SceneTree

const UNIT_DATA_SCRIPT: Script = preload("res://scripts/data/unit_data.gd")
const UNIT_COMBAT_SCRIPT: Script = preload("res://scripts/unit/unit_combat.gd")

var _failed: int = 0


class MockUnit:
	extends Node2D
	var runtime_stats: Dictionary = {}


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 unit stat rules tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 unit stat rules tests passed.")
	quit(0)


func _run() -> void:
	_test_mp_not_scaled_by_star()
	_test_crit_rate_cap_100_percent()
	_test_attack_speed_cap_applies()


func _test_mp_not_scaled_by_star() -> void:
	var base_stats: Dictionary = {
		"hp": 100.0,
		"mp": 80.0,
		"atk": 50.0,
		"iat": 40.0,
		"def": 30.0,
		"idr": 20.0,
		"spd": 90.0,
		"rng": 2.0,
		"wis": 60.0
	}
	var runtime_star3: Dictionary = UNIT_DATA_SCRIPT.call("build_runtime_stats", base_stats, 3)
	_assert_true(is_equal_approx(float(runtime_star3.get("mp", -1.0)), 80.0), "mp should not scale with star level")
	_assert_true(is_equal_approx(float(runtime_star3.get("hp", -1.0)), 300.0), "hp should still scale with star level")


func _test_crit_rate_cap_100_percent() -> void:
	var owner: MockUnit = MockUnit.new()
	owner.runtime_stats = {"wis": 2000.0}
	var combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(owner)
	owner.add_child(combat)
	combat.call("bind_unit", owner)
	combat.call("set_external_modifiers", {"crit_bonus": 3.0})
	var crit_rate: float = float(combat.call("_calc_crit_rate"))
	_assert_true(crit_rate <= 1.0 + 0.0001, "crit rate should be capped at 100%")
	owner.queue_free()


func _test_attack_speed_cap_applies() -> void:
	var owner: MockUnit = MockUnit.new()
	owner.runtime_stats = {
		"hp": 100.0,
		"mp": 50.0,
		"atk": 30.0,
		"iat": 30.0,
		"def": 20.0,
		"idr": 20.0,
		"spd": 9999.0,
		"rng": 1.0,
		"wis": 20.0
	}
	var combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(owner)
	owner.add_child(combat)
	combat.set("max_attack_speed_per_sec", 4.0)
	combat.call("bind_unit", owner)
	combat.call("set_external_modifiers", {"attack_speed_bonus": 0.9})
	combat.call("refresh_runtime_stats", owner.runtime_stats, false)
	var interval: float = float(combat.get("attack_interval"))
	_assert_true(interval >= 0.25 - 0.0001, "attack interval should respect cap (4.0 attacks/sec => min interval 0.25)")
	owner.queue_free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
