extends SceneTree

const TERRAIN_MANAGER_SCRIPT: Script = preload("res://scripts/board/terrain_manager.gd")


class MockHexGrid:
	extends Node

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.y >= 0 and cell.x < 8 and cell.y < 8

	func world_to_axial(_world_pos: Vector2) -> Vector2i:
		return Vector2i(1, 1)

	func get_neighbor_cells(_cell: Vector2i) -> Array[Vector2i]:
		return []


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
	var calls: Array[Dictionary] = []

	func get_unit_cell_of(_unit: Node) -> Vector2i:
		return Vector2i(1, 1)

	func apply_environment_damage(
		target: Node,
		damage_amount: float,
		source: Node = null,
		damage_type: String = "internal",
		source_fallback: Dictionary = {}
	) -> Dictionary:
		calls.append({
			"target": target,
			"damage": damage_amount,
			"source": source,
			"damage_type": damage_type,
			"source_fallback": source_fallback.duplicate(true)
		})
		return {}


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 terrain source fallback tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 terrain source fallback tests passed.")
	quit(0)


func _run() -> void:
	var manager = TERRAIN_MANAGER_SCRIPT.new()
	var hex_grid: MockHexGrid = MockHexGrid.new()
	var source: DummyUnit = DummyUnit.new()
	source.team_id = 1
	source.unit_id = "unit_caster_1"
	source.unit_name = "Caster One"
	source.position = Vector2.ZERO
	var source_iid: int = source.get_instance_id()

	var add_result: Dictionary = manager.call("add_terrain", {
		"terrain_type": "fire",
		"radius": 0,
		"duration": 1.0,
		"tick_interval": 0.1,
		"damage_per_second": 12.0
	}, source, {"hex_grid": hex_grid})
	_assert_true(bool(add_result.get("added", false)), "terrain should be added")

	var target: DummyUnit = DummyUnit.new()
	target.team_id = 2
	target.unit_id = "unit_target_1"
	target.unit_name = "Target One"
	target.position = Vector2.ZERO
	var components: Node = Node.new()
	components.name = "Components"
	target.add_child(components)
	var combat: DummyCombat = DummyCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)

	source.free() # 模拟来源节点已经失效/移除

	var combat_manager: MockCombatManager = MockCombatManager.new()
	manager.call("tick", 0.2, {
		"all_units": [target],
		"combat_manager": combat_manager,
		"hex_grid": hex_grid
	})

	_assert_true(not combat_manager.calls.is_empty(), "terrain tick should deal environment damage")
	if not combat_manager.calls.is_empty():
		var first_call: Dictionary = combat_manager.calls[0]
		_assert_true(first_call.get("source", null) == null, "resolved source node should be null")
		var fallback: Dictionary = first_call.get("source_fallback", {})
		_assert_true(int(fallback.get("source_id", -1)) == source_iid, "fallback should keep source_id")
		_assert_true(str(fallback.get("source_unit_id", "")) == "unit_caster_1", "fallback should keep source_unit_id")
		_assert_true(str(fallback.get("source_name", "")) == "Caster One", "fallback should keep source_name")
		_assert_true(int(fallback.get("source_team", 0)) == 1, "fallback should keep source_team")

	target.free()
	hex_grid.free()
	combat_manager.free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
