extends SceneTree

const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/gongfa/effect_engine.gd")
const BUFF_MANAGER_SCRIPT: Script = preload("res://scripts/gongfa/buff_manager.gd")


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var runtime_stats: Dictionary = {}


class MockUnitCombat:
	extends Node
	var is_alive: bool = true
	var current_hp: float = 1200.0
	var max_hp: float = 1200.0
	var current_mp: float = 300.0
	var max_mp: float = 300.0

	func receive_damage(
		amount: float,
		_source: Node,
		_damage_type: String = "external",
		_is_skill: bool = false,
		_is_crit: bool = false,
		_is_dodged: bool = false,
		_can_trigger_thorns: bool = true
	) -> Dictionary:
		var final_damage: float = maxf(amount, 0.0)
		current_hp = maxf(current_hp - final_damage, 0.0)
		if current_hp <= 0.0:
			is_alive = false
		return {
			"damage": final_damage,
			"target_died": not is_alive,
			"target_hp_after": current_hp,
			"target_mp_after": current_mp,
			"shield_absorbed": 0.0,
			"shield_hp_after": 0.0,
			"shield_broken": false
		}

	func restore_hp(amount: float) -> void:
		current_hp = minf(current_hp + maxf(amount, 0.0), max_hp)
		is_alive = current_hp > 0.0

	func add_mp(amount: float) -> void:
		current_mp = clampf(current_mp + amount, 0.0, max_mp)

	func add_shield(_amount: float) -> void:
		return

	func get_external_modifiers() -> Dictionary:
		return {}


class MockCombatManager:
	extends Node
	var terrains: Array = []

	func add_temporary_terrain(config: Dictionary, _source: Node = null) -> bool:
		terrains.append(config.duplicate(true))
		return true

	func get_unit_cell_of(_unit: Node) -> Vector2i:
		return Vector2i(1, 1)


class MockHexGrid:
	extends Node

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.y >= 0 and cell.x < 16 and cell.y < 16

	func world_to_axial(_world_pos: Vector2) -> Vector2i:
		return Vector2i(1, 1)


var _failed: int = 0


func _init() -> void:
	_run_smoke_tests()
	if _failed > 0:
		push_error("M5 effect smoke tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 effect smoke tests passed.")
	quit(0)


func _run_smoke_tests() -> void:
	_test_passive_modifier_bundle()
	_test_damage_if_debuffed_scaling()
	_test_create_terrain_dispatch()
	_test_create_terrain_all_types()


func _test_passive_modifier_bundle() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var runtime_stats: Dictionary = {"atk": 100.0, "hp": 1000.0}
	var modifiers: Dictionary = engine.call("create_empty_modifier_bundle")
	engine.call("apply_passive_effects", runtime_stats, modifiers, [
		{"op": "damage_amp_percent", "value": 0.2},
		{"op": "conditional_stat", "stat": "atk", "value": 30.0, "condition": "hp_below", "threshold": 0.5}
	])
	_assert_true(is_equal_approx(float(modifiers.get("damage_amp_percent", 0.0)), 0.2), "passive damage_amp_percent")
	var conditional_list: Variant = modifiers.get("conditional_stats", [])
	_assert_true(conditional_list is Array and (conditional_list as Array).size() == 1, "passive conditional_stat list")


func _test_damage_if_debuffed_scaling() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var buff_manager = BUFF_MANAGER_SCRIPT.new()
	buff_manager.call("set_buff_definitions", {
		"test_debuff": {
			"id": "test_debuff",
			"type": "debuff",
			"stackable": false,
			"max_stacks": 1,
			"default_duration": 3.0,
			"effects": [],
			"tick_effects": [],
			"tick_interval": 0.0
		}
	})
	var source: MockUnit = _make_test_unit(1)
	var target: MockUnit = _make_test_unit(2)
	var context: Dictionary = {
		"all_units": [source, target],
		"buff_manager": buff_manager
	}
	var effect_payload: Array = [{
		"op": "damage_if_debuffed",
		"value": 120.0,
		"damage_type": "external",
		"require_debuff": "test_debuff",
		"bonus_multiplier": 2.0
	}]
	var summary_without: Dictionary = engine.call("execute_active_effects", source, target, effect_payload, context)
	buff_manager.call("apply_buff", target, "test_debuff", 3.0, source)
	var summary_with: Dictionary = engine.call("execute_active_effects", source, target, effect_payload, context)
	_assert_true(float(summary_with.get("damage_total", 0.0)) > float(summary_without.get("damage_total", 0.0)), "damage_if_debuffed bonus")
	source.free()
	target.free()


func _test_create_terrain_dispatch() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1)
	var target: MockUnit = _make_test_unit(2)
	var combat_manager: MockCombatManager = MockCombatManager.new()
	var hex_grid: MockHexGrid = MockHexGrid.new()
	var summary: Dictionary = engine.call("execute_active_effects", source, target, [{
		"op": "create_terrain",
		"terrain_type": "fire",
		"radius": 2,
		"duration": 6.0
	}], {
		"combat_manager": combat_manager,
		"hex_grid": hex_grid
	})
	_assert_true(summary is Dictionary, "create_terrain summary shape")
	_assert_true(combat_manager.terrains.size() == 1, "create_terrain dispatched to combat manager")
	source.free()
	target.free()
	combat_manager.free()
	hex_grid.free()


func _test_create_terrain_all_types() -> void:
	var terrain_types: Array[String] = ["fire", "ice", "poison", "heal", "barrier", "slow", "amp_damage"]
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1)
	var target: MockUnit = _make_test_unit(2)
	var combat_manager: MockCombatManager = MockCombatManager.new()
	var hex_grid: MockHexGrid = MockHexGrid.new()
	for terrain_type in terrain_types:
		var summary: Dictionary = engine.call("execute_active_effects", source, target, [{
			"op": "create_terrain",
			"terrain_type": terrain_type,
			"radius": 2,
			"duration": 4.0
		}], {
			"combat_manager": combat_manager,
			"hex_grid": hex_grid
		})
		_assert_true(summary is Dictionary, "create_terrain summary (%s)" % terrain_type)
	_assert_true(combat_manager.terrains.size() == terrain_types.size(), "create_terrain all terrain types dispatched")
	source.free()
	target.free()
	combat_manager.free()
	hex_grid.free()


func _make_test_unit(team_id: int) -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.team_id = team_id
	unit.runtime_stats = {
		"hp": 1200.0,
		"mp": 300.0,
		"atk": 120.0,
		"def": 80.0,
		"iat": 100.0,
		"idr": 60.0,
		"spd": 100.0,
		"wis": 60.0,
		"rng": 2.0,
		"mov": 2.0
	}
	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)
	var combat: MockUnitCombat = MockUnitCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	return unit


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
