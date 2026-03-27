extends SceneTree

const TERRAIN_MANAGER_SCRIPT: Script = preload("res://scripts/combat/terrain_manager.gd")
const TERRAIN_TEST_DATA_PATH: String = "res://mods/test/data/terrains/m5_terrain_effect_rework_terrains.json"


class MockHexGrid:
	extends Node

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.y >= 0 and cell.x < 12 and cell.y < 12

	func world_to_axial(world_pos: Vector2) -> Vector2i:
		return Vector2i(int(round(world_pos.x)), int(round(world_pos.y)))

	func get_neighbor_cells(cell: Vector2i) -> Array[Vector2i]:
		return [
			cell + Vector2i(1, 0),
			cell + Vector2i(-1, 0),
			cell + Vector2i(0, 1),
			cell + Vector2i(0, -1),
			cell + Vector2i(1, -1),
			cell + Vector2i(-1, 1)
		]


class DummyCombat:
	extends Node
	var is_alive: bool = true


class DummyUnit:
	extends Node2D
	var team_id: int = 0
	var unit_id: String = ""
	var unit_name: String = ""


class MockCombatManager:
	extends Node
	var _units: Dictionary = {}
	var _cells: Dictionary = {}

	func register(unit: Node, cell: Vector2i) -> void:
		if unit == null:
			return
		var iid: int = unit.get_instance_id()
		_units[iid] = unit
		_cells[iid] = cell

	func set_unit_cell(unit: Node, cell: Vector2i) -> void:
		if unit == null:
			return
		var iid: int = unit.get_instance_id()
		_cells[iid] = cell

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null:
			return Vector2i(-1, -1)
		var iid: int = unit.get_instance_id()
		if _cells.has(iid):
			return _cells[iid]
		return Vector2i(-1, -1)

	func get_unit_by_instance_id(iid: int) -> Node:
		if _units.has(iid):
			return _units[iid]
		return null


class MockUnitAugmentManager:
	extends Node
	var calls: Array[Dictionary] = []

	func execute_external_effects(
		source: Node,
		target: Node,
		effects: Array,
		_context: Dictionary,
		meta: Dictionary = {}
	) -> Dictionary:
		calls.append({
			"source": source,
			"target": target,
			"effects": effects.duplicate(true),
			"meta": meta.duplicate(true)
		})
		return {}

	func clear_calls() -> void:
		calls.clear()


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 terrain effect rework tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 terrain effect rework tests passed.")
	quit(0)


func _run() -> void:
	var terrain_manager = TERRAIN_MANAGER_SCRIPT.new()
	terrain_manager.call("set_terrain_registry", _load_terrain_test_records())

	var hex_grid: MockHexGrid = MockHexGrid.new()
	var combat_manager: MockCombatManager = MockCombatManager.new()
	var unit_augment_manager: MockUnitAugmentManager = MockUnitAugmentManager.new()

	var source: DummyUnit = _create_unit(1, "unit_source", "Source")
	var enemy: DummyUnit = _create_unit(2, "unit_enemy", "Enemy")
	var ally: DummyUnit = _create_unit(1, "unit_ally", "Ally")
	combat_manager.register(enemy, Vector2i(1, 1))
	combat_manager.register(ally, Vector2i(1, 1))

	_test_enter_and_tick(terrain_manager, hex_grid, combat_manager, unit_augment_manager, source, enemy, ally)
	_test_exit_phase(terrain_manager, hex_grid, combat_manager, unit_augment_manager, source, enemy)
	_test_expire_phase(terrain_manager, hex_grid, combat_manager, unit_augment_manager, source, enemy)
	_test_source_fallback(terrain_manager, hex_grid, combat_manager, unit_augment_manager, enemy)

	enemy.free()
	ally.free()
	source.free()
	combat_manager.free()
	unit_augment_manager.free()
	hex_grid.free()


func _test_enter_and_tick(
	terrain_manager: Object,
	hex_grid: Node,
	combat_manager: MockCombatManager,
	unit_augment_manager: MockUnitAugmentManager,
	source: Node,
	enemy: Node,
	ally: Node
) -> void:
	terrain_manager.call("clear_all")
	unit_augment_manager.clear_calls()
	combat_manager.set_unit_cell(enemy, Vector2i(1, 1))
	combat_manager.set_unit_cell(ally, Vector2i(1, 1))

	var added: Dictionary = terrain_manager.call("add_terrain", {
		"terrain_ref_id": "terrain_test_enter_tick",
		"cells": [Vector2i(1, 1)],
		"duration": 2.0
	}, source, {"hex_grid": hex_grid})
	_assert_true(bool(added.get("added", false)), "enter/tick terrain should be added")

	terrain_manager.call("tick", 0.25, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy, ally]))
	_assert_true(_count_phase_calls(unit_augment_manager.calls, "enter") == 1, "enter should trigger exactly once on first tick")
	_assert_true(_count_phase_calls(unit_augment_manager.calls, "tick") == 0, "tick should not trigger before interval")
	_assert_true(_all_phase_targets_team(unit_augment_manager.calls, "enter", 2), "enter should only target enemies")

	terrain_manager.call("tick", 0.30, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy, ally]))
	_assert_true(_count_phase_calls(unit_augment_manager.calls, "enter") == 1, "enter should not retrigger while staying in terrain")
	_assert_true(_count_phase_calls(unit_augment_manager.calls, "tick") == 1, "tick should trigger once after interval reached")


func _test_exit_phase(
	terrain_manager: Object,
	hex_grid: Node,
	combat_manager: MockCombatManager,
	unit_augment_manager: MockUnitAugmentManager,
	source: Node,
	enemy: Node
) -> void:
	terrain_manager.call("clear_all")
	unit_augment_manager.clear_calls()
	combat_manager.set_unit_cell(enemy, Vector2i(2, 2))

	var added: Dictionary = terrain_manager.call("add_terrain", {
		"terrain_ref_id": "terrain_test_exit",
		"cells": [Vector2i(2, 2)],
		"duration": 2.0
	}, source, {"hex_grid": hex_grid})
	_assert_true(bool(added.get("added", false)), "exit terrain should be added")

	terrain_manager.call("tick", 0.10, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy]))
	combat_manager.set_unit_cell(enemy, Vector2i(6, 6))
	terrain_manager.call("tick", 0.10, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy]))
	_assert_true(_count_phase_calls(unit_augment_manager.calls, "exit") == 1, "exit should trigger once when unit leaves")


func _test_expire_phase(
	terrain_manager: Object,
	hex_grid: Node,
	combat_manager: MockCombatManager,
	unit_augment_manager: MockUnitAugmentManager,
	source: Node,
	enemy: Node
) -> void:
	terrain_manager.call("clear_all")
	unit_augment_manager.clear_calls()
	combat_manager.set_unit_cell(enemy, Vector2i(3, 3))

	var added: Dictionary = terrain_manager.call("add_terrain", {
		"terrain_ref_id": "terrain_test_expire",
		"cells": [Vector2i(3, 3)],
		"duration": 0.12
	}, source, {"hex_grid": hex_grid})
	_assert_true(bool(added.get("added", false)), "expire terrain should be added")

	terrain_manager.call("tick", 0.20, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy]))
	_assert_true(_count_phase_calls(unit_augment_manager.calls, "expire") == 1, "expire should trigger once when terrain expires")

	unit_augment_manager.clear_calls()
	terrain_manager.call("tick", 0.20, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy]))
	_assert_true(unit_augment_manager.calls.is_empty(), "expired terrain should be removed after expire phase")


func _test_source_fallback(
	terrain_manager: Object,
	hex_grid: Node,
	combat_manager: MockCombatManager,
	unit_augment_manager: MockUnitAugmentManager,
	enemy: Node
) -> void:
	terrain_manager.call("clear_all")
	unit_augment_manager.clear_calls()
	combat_manager.set_unit_cell(enemy, Vector2i(4, 4))

	var temp_source: DummyUnit = _create_unit(1, "unit_temp_source", "Temp Source")
	var source_iid: int = temp_source.get_instance_id()
	var added: Dictionary = terrain_manager.call("add_terrain", {
		"terrain_type": "fire",
		"cells": [Vector2i(4, 4)],
		"duration": 1.0,
		"tick_interval": 0.2,
		"target_mode": "enemies",
		"effects_on_tick": [
			{
				"op": "damage_target",
				"value": 2.0,
				"damage_type": "internal"
			}
		]
	}, temp_source, {"hex_grid": hex_grid})
	_assert_true(bool(added.get("added", false)), "fallback terrain should be added")

	temp_source.free()
	terrain_manager.call("tick", 0.20, _build_context(hex_grid, combat_manager, unit_augment_manager, [enemy]))
	_assert_true(not unit_augment_manager.calls.is_empty(), "fallback terrain should still execute effects after source deleted")
	if not unit_augment_manager.calls.is_empty():
		var first_call: Dictionary = unit_augment_manager.calls[0]
		_assert_true(first_call.get("source", null) == null, "deleted source should resolve to null node")
		var meta: Dictionary = first_call.get("meta", {})
		var extra_fields: Dictionary = meta.get("extra_fields", {})
		_assert_true(int(extra_fields.get("source_id", -1)) == source_iid, "fallback should keep source_id")
		_assert_true(str(extra_fields.get("source_unit_id", "")) == "unit_temp_source", "fallback should keep source_unit_id")
		_assert_true(str(extra_fields.get("source_name", "")) == "Temp Source", "fallback should keep source_name")
		_assert_true(int(extra_fields.get("source_team", 0)) == 1, "fallback should keep source_team")


func _create_unit(team_id: int, unit_id: String, unit_name: String) -> DummyUnit:
	var unit: DummyUnit = DummyUnit.new()
	unit.team_id = team_id
	unit.unit_id = unit_id
	unit.unit_name = unit_name
	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)
	var combat: DummyCombat = DummyCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	return unit


func _load_terrain_test_records() -> Array:
	var file: FileAccess = FileAccess.open(TERRAIN_TEST_DATA_PATH, FileAccess.READ)
	_assert_true(file != null, "terrain test data should exist")
	if file == null:
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	_assert_true(parsed is Array, "terrain test data should be json array")
	if parsed is Array:
		return parsed as Array
	return []


func _build_context(
	hex_grid: Node,
	combat_manager: Node,
	unit_augment_manager: Node,
	all_units: Array
) -> Dictionary:
	return {
		"hex_grid": hex_grid,
		"combat_manager": combat_manager,
		"unit_augment_manager": unit_augment_manager,
		"all_units": all_units
	}


func _count_phase_calls(calls: Array[Dictionary], phase: String) -> int:
	var count: int = 0
	for call in calls:
		var call_meta: Dictionary = call.get("meta", {})
		var extra_fields: Dictionary = call_meta.get("extra_fields", {})
		if str(extra_fields.get("terrain_phase", "")) == phase:
			count += 1
	return count


func _all_phase_targets_team(calls: Array[Dictionary], phase: String, team_id: int) -> bool:
	for call in calls:
		var call_meta: Dictionary = call.get("meta", {})
		var extra_fields: Dictionary = call_meta.get("extra_fields", {})
		if str(extra_fields.get("terrain_phase", "")) != phase:
			continue
		var target: Node = call.get("target", null)
		if target == null or not is_instance_valid(target):
			return false
		if int(target.get("team_id")) != team_id:
			return false
	return true


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
