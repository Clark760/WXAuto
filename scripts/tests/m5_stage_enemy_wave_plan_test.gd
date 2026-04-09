extends SceneTree

const UNIT_DEPLOY_MANAGER_SCRIPT: Script = preload("res://scripts/battle/unit_deploy_manager.gd")

var _failed: int = 0


class MockHexGrid:
	extends Node
	var grid_width: int = 8
	var grid_height: int = 6

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.y >= 0 and cell.x < grid_width and cell.y < grid_height

	func axial_to_world(cell: Vector2i) -> Vector2:
		return Vector2(float(cell.x) * 10.0, float(cell.y) * 10.0)


class MockUnit:
	extends Node2D
	var unit_id: String = ""
	var team_id: int = 0
	var deployed_cell: Vector2i = Vector2i(-999, -999)
	var is_in_combat: bool = false
	var is_on_bench: bool = true

	func set_team(next_team: int) -> void:
		team_id = next_team

	func set_on_bench_state(on_bench: bool, _slot: int) -> void:
		is_on_bench = on_bench

	func play_anim_state(_state: int, _payload: Dictionary) -> void:
		pass


class MockUnitFactory:
	extends Node

	func acquire_unit(unit_id: String, parent: Node = null, _parent_override: Node = null) -> Node:
		var unit: MockUnit = MockUnit.new()
		unit.unit_id = unit_id
		if parent != null:
			parent.add_child(unit)
		return unit

	func release_unit(unit: Node) -> bool:
		if unit != null and is_instance_valid(unit):
			unit.queue_free()
		return true


class MockOwner:
	extends Node
	var hex_grid: MockHexGrid = MockHexGrid.new()
	var unit_factory: MockUnitFactory = MockUnitFactory.new()
	var unit_layer: Node2D = Node2D.new()
	var _ally_deployed: Dictionary = {}
	var _enemy_deployed: Dictionary = {}
	var _current_deploy_zone: Dictionary = {
		"x_min": 0,
		"x_max": 1,
		"y_min": 0,
		"y_max": 5
	}
	var _current_stage_config: Dictionary = {}

	func _init() -> void:
		add_child(hex_grid)
		add_child(unit_factory)
		add_child(unit_layer)

	func _cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

	func _set_unit_map_cache(_unit: Node, _key: String, _team_id: int) -> void:
		pass

	func _clear_unit_map_cache(_unit: Node) -> void:
		pass

	func _get_unit_map_key(_unit: Node) -> String:
		return ""

	func _apply_unit_visual_presentation(_unit: Node) -> void:
		pass

	func _is_valid_unit(unit: Variant) -> bool:
		return unit is Node and is_instance_valid(unit)


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 stage enemy wave plan tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 stage enemy wave plan tests passed.")
	quit(0)


func _run() -> void:
	await _test_stage_enemy_plan_uses_configured_counts()


func _test_stage_enemy_plan_uses_configured_counts() -> void:
	var owner: MockOwner = MockOwner.new()
	root.add_child(owner)
	owner._current_stage_config = {
		"id": "stage_test_enemy_counts",
		"enemies": [
			{
				"unit_id": "enemy_front",
				"count": 2,
				"deploy_zone": "front"
			},
			{
				"unit_id": "enemy_fixed",
				"count": 2,
				"deploy_zone": "fixed",
				"fixed_cells": [Vector2i(6, 1), Vector2i(7, 2)]
			},
			{
				"unit_id": "enemy_back",
				"count": 1,
				"deploy_zone": "back"
			}
		]
	}

	var manager: Node = UNIT_DEPLOY_MANAGER_SCRIPT.new()
	owner.add_child(manager)
	manager.call("configure", owner)

	var plan_value: Variant = manager.call("build_enemy_wave_plan", 99)
	_assert_true(plan_value is Array, "build_enemy_wave_plan should return an array")
	if not (plan_value is Array):
		owner.queue_free()
		await process_frame
		return

	var plan: Array = plan_value as Array
	_assert_true(plan.size() == 5, "stage-configured enemy count should override random wave size")

	var fixed_cells: Dictionary = {}
	var per_unit_counts: Dictionary = {}
	for entry_value in plan:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value as Dictionary
		var unit_id: String = str(entry.get("unit_id", ""))
		per_unit_counts[unit_id] = int(per_unit_counts.get(unit_id, 0)) + 1
		var cell: Variant = entry.get("cell", Vector2i(-1, -1))
		if cell is Vector2i:
			fixed_cells[owner._cell_key(cell)] = true

	_assert_true(int(per_unit_counts.get("enemy_front", 0)) == 2, "front row should keep configured count=2")
	_assert_true(int(per_unit_counts.get("enemy_fixed", 0)) == 2, "fixed row should keep configured count=2")
	_assert_true(int(per_unit_counts.get("enemy_back", 0)) == 1, "back row should keep configured count=1")
	_assert_true(fixed_cells.has("6,1"), "fixed cell 6,1 should be reserved for configured enemy")
	_assert_true(fixed_cells.has("7,2"), "fixed cell 7,2 should be reserved for configured enemy")

	manager.call("spawn_enemy_wave_from_plan", plan)
	_assert_true(owner._enemy_deployed.size() == 5, "spawned enemy count should match configured plan size")
	_assert_true(_count_units_by_id(owner._enemy_deployed, "enemy_fixed") == 2, "spawned fixed enemies should both exist on board")

	owner.queue_free()
	await process_frame


func _count_units_by_id(deployed_map: Dictionary, unit_id: String) -> int:
	var count: int = 0
	for unit_value in deployed_map.values():
		if unit_value == null or not is_instance_valid(unit_value):
			continue
		if str(unit_value.get("unit_id")) == unit_id:
			count += 1
	return count


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
