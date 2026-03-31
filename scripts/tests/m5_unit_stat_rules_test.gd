extends SceneTree

const UNIT_DATA_SCRIPT: Script = preload("res://scripts/domain/unit/unit_data.gd")
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
	_test_stats_keep_base_values()
	_test_crit_rate_cap_100_percent()
	_test_crit_rate_wis_scale_x2()
	_test_attack_speed_cap_applies()
	_test_attack_interval_uses_inverse_spd_curve()
	_test_full_mp_attack_stays_basic_attack()
	_test_healing_amp_applies_to_self_heal()
	_test_healing_amp_applies_to_healer_source()
	_test_mp_gain_on_attack_modifier_applies()
	_test_mp_gain_on_hit_modifier_applies()


func _test_stats_keep_base_values() -> void:
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
	var runtime_stats: Dictionary = UNIT_DATA_SCRIPT.call("build_runtime_stats", base_stats)
	_assert_true(is_equal_approx(float(runtime_stats.get("mp", -1.0)), 80.0), "mp should remain unchanged")
	_assert_true(is_equal_approx(float(runtime_stats.get("hp", -1.0)), 100.0), "hp should remain unchanged")
	_assert_true(is_equal_approx(float(runtime_stats.get("atk", -1.0)), 50.0), "atk should remain unchanged")


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


func _test_crit_rate_wis_scale_x2() -> void:
	var owner: MockUnit = MockUnit.new()
	owner.runtime_stats = {"wis": 100.0}
	var combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(owner)
	owner.add_child(combat)
	combat.call("bind_unit", owner)
	combat.call("set_external_modifiers", {"crit_bonus": 0.0})
	var crit_rate: float = float(combat.call("_calc_crit_rate"))
	_assert_true(is_equal_approx(crit_rate, 0.25), "wis=100 should yield 25% crit rate with x2 wis scale")
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


func _test_attack_interval_uses_inverse_spd_curve() -> void:
	var owner: MockUnit = MockUnit.new()
	owner.runtime_stats = {
		"hp": 100.0,
		"mp": 50.0,
		"atk": 30.0,
		"iat": 30.0,
		"def": 20.0,
		"idr": 20.0,
		"spd": 160.0,
		"rng": 1.0,
		"wis": 20.0
	}
	var combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(owner)
	owner.add_child(combat)
	combat.call("bind_unit", owner)
	combat.call("set_external_modifiers", {})
	combat.call("refresh_runtime_stats", owner.runtime_stats, false)
	var interval: float = float(combat.get("attack_interval"))
	_assert_true(is_equal_approx(interval, 1.8 / 2.6), "spd interval should follow inverse formula: 1.8 / (1 + spd/100)")
	owner.queue_free()


func _test_full_mp_attack_stays_basic_attack() -> void:
	var attacker: MockUnit = MockUnit.new()
	attacker.runtime_stats = {
		"hp": 100.0,
		"mp": 100.0,
		"atk": 80.0,
		"iat": 120.0,
		"def": 20.0,
		"idr": 20.0,
		"spd": 80.0,
		"rng": 1.0,
		"wis": 0.0
	}
	var attacker_components: Node = Node.new()
	attacker_components.name = "Components"
	var attacker_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(attacker)
	attacker.add_child(attacker_components)
	attacker_components.add_child(attacker_combat)
	attacker_combat.name = "UnitCombat"
	attacker_combat.call("bind_unit", attacker)
	attacker_combat.call("refresh_runtime_stats", attacker.runtime_stats, false)
	attacker_combat.set("current_mp", 100.0)

	var target: MockUnit = MockUnit.new()
	target.runtime_stats = {
		"hp": 100.0,
		"mp": 0.0,
		"atk": 20.0,
		"iat": 20.0,
		"def": 20.0,
		"idr": 20.0,
		"spd": 0.0,
		"rng": 1.0,
		"wis": 0.0
	}
	var target_components: Node = Node.new()
	target_components.name = "Components"
	var target_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(target)
	target.add_child(target_components)
	target_components.add_child(target_combat)
	target_combat.name = "UnitCombat"
	target_combat.call("bind_unit", target)
	target_combat.call("refresh_runtime_stats", target.runtime_stats, false)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260331
	var event: Dictionary = attacker_combat.call("try_attack_target", target, rng)
	_assert_true(bool(event.get("performed", false)), "full mp basic attack should still perform")
	_assert_true(not bool(event.get("is_skill", true)), "full mp basic attack should never mark is_skill")
	_assert_true(is_equal_approx(float(event.get("attacker_mp_after", -1.0)), 100.0), "full mp basic attack should not spend mp")
	_assert_true(is_equal_approx(float(attacker_combat.get("current_mp")), 100.0), "full mp basic attack should keep mp capped after on-hit gain")
	attacker.queue_free()
	target.queue_free()


func _test_healing_amp_applies_to_self_heal() -> void:
	var owner: MockUnit = MockUnit.new()
	owner.runtime_stats = {"hp": 100.0, "mp": 0.0, "atk": 0.0, "iat": 0.0, "def": 0.0, "idr": 0.0, "spd": 0.0, "rng": 1.0, "wis": 0.0}
	var combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(owner)
	owner.add_child(combat)
	combat.call("bind_unit", owner)
	combat.call("refresh_runtime_stats", owner.runtime_stats, false)
	combat.set("current_hp", 40.0)
	combat.call("set_external_modifiers", {"healing_amp": 0.25})
	var healed: float = float(combat.call("restore_hp", 20.0))
	_assert_true(is_equal_approx(healed, 25.0), "self heal should consume own healing_amp")
	_assert_true(is_equal_approx(float(combat.get("current_hp")), 65.0), "self heal should increase hp by amplified amount")
	owner.queue_free()


func _test_healing_amp_applies_to_healer_source() -> void:
	var healer: MockUnit = MockUnit.new()
	healer.runtime_stats = {"hp": 100.0, "mp": 0.0, "atk": 0.0, "iat": 0.0, "def": 0.0, "idr": 0.0, "spd": 0.0, "rng": 1.0, "wis": 0.0}
	var healer_components: Node = Node.new()
	healer_components.name = "Components"
	var healer_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(healer)
	healer.add_child(healer_components)
	healer_components.add_child(healer_combat)
	healer_combat.name = "UnitCombat"
	healer_combat.call("bind_unit", healer)
	healer_combat.call("refresh_runtime_stats", healer.runtime_stats, false)
	healer_combat.call("set_external_modifiers", {"healing_amp": 0.5})

	var target: MockUnit = MockUnit.new()
	target.runtime_stats = {"hp": 100.0, "mp": 0.0, "atk": 0.0, "iat": 0.0, "def": 0.0, "idr": 0.0, "spd": 0.0, "rng": 1.0, "wis": 0.0}
	var target_components: Node = Node.new()
	target_components.name = "Components"
	var target_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(target)
	target.add_child(target_components)
	target_components.add_child(target_combat)
	target_combat.name = "UnitCombat"
	target_combat.call("bind_unit", target)
	target_combat.call("refresh_runtime_stats", target.runtime_stats, false)
	target_combat.set("current_hp", 40.0)
	var healed: float = float(target_combat.call("restore_hp", 20.0, healer))
	_assert_true(is_equal_approx(healed, 30.0), "target heal should consume healer source healing_amp")
	_assert_true(is_equal_approx(float(target_combat.get("current_hp")), 70.0), "target hp should reflect healer amplification")
	healer.queue_free()
	target.queue_free()


func _test_mp_gain_on_attack_modifier_applies() -> void:
	var attacker: MockUnit = MockUnit.new()
	attacker.runtime_stats = {
		"hp": 100.0,
		"mp": 100.0,
		"atk": 80.0,
		"iat": 20.0,
		"def": 20.0,
		"idr": 20.0,
		"spd": 80.0,
		"rng": 1.0,
		"wis": 0.0
	}
	var attacker_components: Node = Node.new()
	attacker_components.name = "Components"
	var attacker_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(attacker)
	attacker.add_child(attacker_components)
	attacker_components.add_child(attacker_combat)
	attacker_combat.name = "UnitCombat"
	attacker_combat.call("bind_unit", attacker)
	attacker_combat.call("refresh_runtime_stats", attacker.runtime_stats, false)
	attacker_combat.set("current_mp", 0.0)
	attacker_combat.call("set_external_modifiers", {"mp_gain_on_attack": 5.0})

	var target: MockUnit = MockUnit.new()
	target.runtime_stats = {
		"hp": 100.0,
		"mp": 0.0,
		"atk": 20.0,
		"iat": 20.0,
		"def": 20.0,
		"idr": 20.0,
		"spd": 0.0,
		"rng": 1.0,
		"wis": 0.0
	}
	var target_components: Node = Node.new()
	target_components.name = "Components"
	var target_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(target)
	target.add_child(target_components)
	target_components.add_child(target_combat)
	target_combat.name = "UnitCombat"
	target_combat.call("bind_unit", target)
	target_combat.call("refresh_runtime_stats", target.runtime_stats, false)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260331
	var event: Dictionary = attacker_combat.call("try_attack_target", target, rng)
	_assert_true(bool(event.get("performed", false)), "attack should perform for mp_gain_on_attack test")
	_assert_true(is_equal_approx(float(attacker_combat.get("current_mp")), 20.0), "mp_gain_on_attack modifier should add to base attack mp gain")
	attacker.queue_free()
	target.queue_free()


func _test_mp_gain_on_hit_modifier_applies() -> void:
	var source: MockUnit = MockUnit.new()
	source.runtime_stats = {"hp": 100.0, "mp": 0.0, "atk": 0.0, "iat": 0.0, "def": 0.0, "idr": 0.0, "spd": 0.0, "rng": 1.0, "wis": 0.0}
	var source_components: Node = Node.new()
	source_components.name = "Components"
	var source_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(source)
	source.add_child(source_components)
	source_components.add_child(source_combat)
	source_combat.name = "UnitCombat"
	source_combat.call("bind_unit", source)
	source_combat.call("refresh_runtime_stats", source.runtime_stats, false)

	var target: MockUnit = MockUnit.new()
	target.runtime_stats = {"hp": 100.0, "mp": 100.0, "atk": 0.0, "iat": 0.0, "def": 0.0, "idr": 0.0, "spd": 0.0, "rng": 1.0, "wis": 0.0}
	var target_components: Node = Node.new()
	target_components.name = "Components"
	var target_combat: Node = UNIT_COMBAT_SCRIPT.new()
	root.add_child(target)
	target.add_child(target_components)
	target_components.add_child(target_combat)
	target_combat.name = "UnitCombat"
	target_combat.call("bind_unit", target)
	target_combat.call("refresh_runtime_stats", target.runtime_stats, false)
	target_combat.set("current_mp", 0.0)
	target_combat.set("mp_gain_on_hit", 3.0)
	target_combat.call("set_external_modifiers", {"mp_gain_on_hit": 4.0})
	target_combat.call("receive_damage", 10.0, source, "external", false, false, false)
	_assert_true(is_equal_approx(float(target_combat.get("current_mp")), 7.0), "mp_gain_on_hit modifier should add to base hit mp gain")
	source.queue_free()
	target.queue_free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
