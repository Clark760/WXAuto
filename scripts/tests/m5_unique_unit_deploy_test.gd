extends SceneTree

const UNIT_DEPLOY_MANAGER_SCRIPT: Script = preload("res://scripts/battle/unit_deploy_manager.gd")

var _failed: int = 0


class MockHexGrid:
	extends Node
	var grid_width: int = 6
	var grid_height: int = 6

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.y >= 0 and cell.x < grid_width and cell.y < grid_height

	func axial_to_world(cell: Vector2i) -> Vector2:
		return Vector2(float(cell.x) * 10.0, float(cell.y) * 10.0)


class MockBenchUI:
	extends Node
	var units: Array[Node] = []

	func get_all_units() -> Array:
		return units.duplicate()

	func remove_unit(unit: Node) -> void:
		units.erase(unit)

	func add_unit(unit: Node) -> bool:
		units.append(unit)
		return true


class MockUnit:
	extends Node2D
	var unit_id: String = ""
	var deployed_cell: Vector2i = Vector2i(-999, -999)
	var is_in_combat: bool = false
	var is_on_bench: bool = true

	func set_team(_team_id: int) -> void:
		pass

	func set_on_bench_state(on_bench: bool, _slot: int) -> void:
		is_on_bench = on_bench

	func play_anim_state(_state: int, _payload: Dictionary) -> void:
		pass


class MockOwner:
	extends Node
	var hex_grid: MockHexGrid = MockHexGrid.new()
	var bench_ui: MockBenchUI = MockBenchUI.new()
	var _ally_deployed: Dictionary = {}
	var _enemy_deployed: Dictionary = {}
	var _current_deploy_zone: Dictionary = {
		"x_min": 0,
		"x_max": 2,
		"y_min": 0,
		"y_max": 2
	}

	func _init() -> void:
		add_child(hex_grid)
		add_child(bench_ui)

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
		push_error("M5 unique unit deploy tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 unique unit deploy tests passed.")
	quit(0)


func _run() -> void:
	await _test_duplicate_id_allowed_on_board()
	await _test_auto_deploy_allows_duplicate_ids()


func _test_duplicate_id_allowed_on_board() -> void:
	var owner: MockOwner = MockOwner.new()
	root.add_child(owner)
	var manager: Node = UNIT_DEPLOY_MANAGER_SCRIPT.new()
	owner.add_child(manager)
	manager.call("configure", owner)

	var first: MockUnit = _make_unit("unit_hero_a")
	var duplicate: MockUnit = _make_unit("unit_hero_a")
	var other: MockUnit = _make_unit("unit_hero_b")
	owner.add_child(first)
	owner.add_child(duplicate)
	owner.add_child(other)

	manager.call("deploy_ally_unit_to_cell", first, Vector2i(0, 0))
	var can_place_duplicate: bool = bool(manager.call("can_deploy_ally_to_cell", duplicate, Vector2i(0, 1)))
	_assert_true(can_place_duplicate, "same unit_id should be deployable more than once")

	manager.call("deploy_ally_unit_to_cell", duplicate, Vector2i(0, 1))
	_assert_true(_count_ally_units(owner) == 2, "duplicate deploy should place a second same-id unit")
	_assert_true(_count_ally_units_by_id(owner, "unit_hero_a") == 2, "two same-id allies should stay on board")

	var can_place_other: bool = bool(manager.call("can_deploy_ally_to_cell", other, Vector2i(1, 0)))
	_assert_true(can_place_other, "different unit_id should remain deployable")

	owner.queue_free()
	await process_frame


func _test_auto_deploy_allows_duplicate_ids() -> void:
	var owner: MockOwner = MockOwner.new()
	root.add_child(owner)
	var manager: Node = UNIT_DEPLOY_MANAGER_SCRIPT.new()
	owner.add_child(manager)
	manager.call("configure", owner)

	var existing: MockUnit = _make_unit("unit_hero_a")
	owner.add_child(existing)
	manager.call("deploy_ally_unit_to_cell", existing, Vector2i(0, 0))

	var bench_duplicate: MockUnit = _make_unit("unit_hero_a")
	var bench_other: MockUnit = _make_unit("unit_hero_b")
	owner.add_child(bench_duplicate)
	owner.add_child(bench_other)
	owner.bench_ui.add_unit(bench_duplicate)
	owner.bench_ui.add_unit(bench_other)

	manager.call("auto_deploy_from_bench", 2)

	_assert_true(_count_ally_units_by_id(owner, "unit_hero_a") == 2, "auto deploy should add second same-id unit")
	_assert_true(_count_ally_units_by_id(owner, "unit_hero_b") == 1, "auto deploy should still place other unit")
	_assert_true(not owner.bench_ui.units.has(bench_duplicate), "duplicate unit should be removed from bench after deploy")

	owner.queue_free()
	await process_frame


func _make_unit(id_value: String) -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.unit_id = id_value
	return unit


func _count_ally_units(owner: MockOwner) -> int:
	return owner._ally_deployed.size()


func _count_ally_units_by_id(owner: MockOwner, unit_id: String) -> int:
	var count: int = 0
	for unit in owner._ally_deployed.values():
		if unit == null or not is_instance_valid(unit):
			continue
		if str(unit.get("unit_id")) == unit_id:
			count += 1
	return count


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
