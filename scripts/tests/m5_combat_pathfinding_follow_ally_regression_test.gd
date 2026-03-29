extends SceneTree

const PATHFINDING_RULES_SCRIPT: Script = preload("res://scripts/domain/combat/combat_pathfinding.gd")


class MockFlowField:
	extends RefCounted

	var costs: Dictionary = {}

	func sample_cost(cell: Vector2i) -> int:
		return int(costs.get(cell, -1))


class MockUnit:
	extends Node2D

	var team_id: int = 1


class MockRuntimePort:
	extends Node

	var free_cells: Dictionary = {}
	var unit_cells: Dictionary = {}

	func _pick_target_in_attack_range(_unit: Node, _enemy_team: int) -> Node:
		return null

	func _neighbors_of(cell: Vector2i) -> Array[Vector2i]:
		return [
			Vector2i(cell.x + 1, cell.y),
			Vector2i(cell.x + 1, cell.y - 1),
			Vector2i(cell.x, cell.y - 1),
			Vector2i(cell.x - 1, cell.y),
			Vector2i(cell.x - 1, cell.y + 1),
			Vector2i(cell.x, cell.y + 1)
		]

	func _is_cell_free(cell: Vector2i) -> bool:
		return bool(free_cells.get(cell, false))

	func _hex_distance(a: Vector2i, b: Vector2i) -> int:
		var dq: int = b.x - a.x
		var dr: int = b.y - a.y
		return (absi(dq) + absi(dq + dr) + absi(dr)) / 2

	func _get_unit_cell(unit: Node) -> Vector2i:
		return unit_cells.get(unit.get_instance_id(), Vector2i(-1, -1))

	func _is_live_unit(node: Node) -> bool:
		return node != null and is_instance_valid(node)

	func _is_unit_alive(node: Node) -> bool:
		return node != null and is_instance_valid(node)


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 combat pathfinding follow-ally regression test failed: %d" % _failed)
		quit(1)
		return
	print("M5 combat pathfinding follow-ally regression test passed.")
	quit(0)


func _run() -> void:
	_test_follow_front_ally_when_forward_route_is_blocked()


func _test_follow_front_ally_when_forward_route_is_blocked() -> void:
	var rules = PATHFINDING_RULES_SCRIPT.new()
	var runtime_port: MockRuntimePort = MockRuntimePort.new()
	var flow_field: MockFlowField = MockFlowField.new()
	var rear_unit: MockUnit = MockUnit.new()
	var front_ally: MockUnit = MockUnit.new()
	var focus_enemy: MockUnit = MockUnit.new()

	rear_unit.team_id = 1
	front_ally.team_id = 1
	focus_enemy.team_id = 2

	var rear_cell: Vector2i = Vector2i(0, 0)
	var ally_cell: Vector2i = Vector2i(1, 0)
	var enemy_cell: Vector2i = Vector2i(4, 0)
	runtime_port.unit_cells[rear_unit.get_instance_id()] = rear_cell
	runtime_port.unit_cells[front_ally.get_instance_id()] = ally_cell
	runtime_port.unit_cells[focus_enemy.get_instance_id()] = enemy_cell
	var unit_by_id: Dictionary = {
		rear_unit.get_instance_id(): rear_unit,
		front_ally.get_instance_id(): front_ally,
		focus_enemy.get_instance_id(): focus_enemy
	}
	var team_alive_cache: Dictionary = {
		1: [rear_unit, front_ally],
		2: [focus_enemy]
	}
	var follow_anchor_cache: Dictionary = rules.rebuild_follow_anchor_cache(
		runtime_port,
		{1: focus_enemy.get_instance_id()},
		unit_by_id,
		team_alive_cache
	)

	# 正前方盟友占位，常规流场无法给后排直接降代价路径。
	runtime_port.free_cells = {
		Vector2i(1, -1): true,
		Vector2i(0, -1): true,
		Vector2i(-1, 0): true,
		Vector2i(-1, 1): true,
		Vector2i(0, 1): true
	}
	flow_field.costs = {
		rear_cell: 5,
		Vector2i(1, -1): 6,
		Vector2i(0, -1): 6,
		Vector2i(-1, 0): 7,
		Vector2i(-1, 1): 7,
		Vector2i(0, 1): 7
	}

	var next_cell: Vector2i = rules.pick_best_adjacent_cell(
		runtime_port,
		rear_unit,
		rear_cell,
		flow_field,
		flow_field,
		false,
		{1: focus_enemy.get_instance_id()},
		unit_by_id,
		follow_anchor_cache,
		null
	)

	_assert_true(
		next_cell == Vector2i(1, -1),
		"rear unit should step toward the front ally when the forward route is blocked"
	)

	rear_unit.free()
	front_ally.free()
	focus_enemy.free()
	runtime_port.free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
