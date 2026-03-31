extends SceneTree

const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2


class MockHexGrid:
	extends Node

	var hex_size: float = 26.0

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= -8 and cell.y >= -8 and cell.x <= 8 and cell.y <= 8

	func get_neighbor_cells(cell: Vector2i) -> Array[Vector2i]:
		return [
			cell + Vector2i(1, 0),
			cell + Vector2i(1, -1),
			cell + Vector2i(0, -1),
			cell + Vector2i(-1, 0),
			cell + Vector2i(-1, 1),
			cell + Vector2i(0, 1)
		]


class MockCombatManager:
	extends Node
	signal battle_started(ally_count: int, enemy_count: int)
	signal damage_resolved(event: Dictionary)
	signal unit_died(unit: Node, killer: Node, team_id: int)
	signal battle_ended(winner_team: int, summary: Dictionary)

	var terrains: Array[Dictionary] = []
	var _unit_cells: Dictionary = {}
	var _spatial_hash = null
	var _unit_by_instance_id: Dictionary = {}

	func register(unit: Node, cell: Vector2i) -> void:
		if unit == null or not is_instance_valid(unit):
			return
		_unit_by_instance_id[unit.get_instance_id()] = unit
		_unit_cells[unit.get_instance_id()] = cell

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null or not is_instance_valid(unit):
			return Vector2i(-1, -1)
		return _unit_cells.get(unit.get_instance_id(), Vector2i(-1, -1))

	func add_temporary_terrain(config: Dictionary, _source: Node = null) -> bool:
		terrains.append(config.duplicate(true))
		return true


class MockUnit:
	extends Node2D

	var team_id: int = TEAM_ALLY
	var unit_id: String = ""
	var unit_name: String = ""
	var runtime_stats: Dictionary = {}
	var is_in_combat: bool = true

	func set_team(next_team: int) -> void:
		team_id = next_team

	func play_anim_state(_state: int, _params: Dictionary = {}) -> void:
		return

	func enter_combat() -> void:
		is_in_combat = true

	func leave_combat() -> void:
		is_in_combat = false

	func set_on_bench_state(_on_bench: bool, _index: int = -1) -> void:
		return


class MockUnitCombat:
	extends Node

	var is_alive: bool = true
	var current_mp: float = 300.0
	var max_mp: float = 300.0
	var current_hp: float = 100.0
	var max_hp: float = 100.0

	func add_mp(amount: float) -> void:
		current_mp = clampf(current_mp + amount, 0.0, max_mp)

	func add_shield(_amount: float) -> void:
		return

	func get_external_modifiers() -> Dictionary:
		return {}


var _failed: int = 0
var _owned_nodes: Array[Node] = []


func _init() -> void:
	_run()
	_cleanup_owned_nodes()
	if _failed > 0:
		push_error("M5 skill enemy nearby gate tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 skill enemy nearby gate tests passed.")
	quit(0)


func _run() -> void:
	_test_battlefield_side_effect_skill_requires_nearby_enemy()
	_test_battlefield_side_effect_skill_casts_when_enemy_is_nearby()
	_test_trigger_params_require_enemy_nearby_blocks_without_enemy()
	_test_trigger_params_require_enemy_nearby_passes_with_enemy()


func _test_battlefield_side_effect_skill_requires_nearby_enemy() -> void:
	var bundle: Dictionary = _build_bundle()
	var manager: Node = bundle.get("manager")
	var combat_manager: MockCombatManager = bundle.get("combat_manager")
	var source: MockUnit = bundle.get("source")

	var fired: bool = bool(manager.get_trigger_runtime().try_fire_skill(
		manager,
		source,
		_build_entry(manager, source.unit_id, {
			"trigger": "auto_mp_full",
			"range": 2,
			"effects": [{"op": "create_terrain", "terrain_type": "fire", "duration": 1.0}]
		}),
		{}
	))

	_assert_true(not fired, "battlefield side-effect skill should not fire without nearby enemy")
	_assert_true(combat_manager.terrains.is_empty(), "no nearby enemy should skip terrain creation")


func _test_battlefield_side_effect_skill_casts_when_enemy_is_nearby() -> void:
	var bundle: Dictionary = _build_bundle(true)
	var manager: Node = bundle.get("manager")
	var combat_manager: MockCombatManager = bundle.get("combat_manager")
	var source: MockUnit = bundle.get("source")

	var fired: bool = bool(manager.get_trigger_runtime().try_fire_skill(
		manager,
		source,
		_build_entry(manager, source.unit_id, {
			"trigger": "auto_mp_full",
			"range": 2,
			"effects": [{"op": "create_terrain", "terrain_type": "fire", "duration": 1.0}]
		}),
		{}
	))

	_assert_true(fired, "battlefield side-effect skill should fire when enemy is nearby")
	_assert_true(combat_manager.terrains.size() == 1, "nearby enemy should allow terrain creation")


func _test_trigger_params_require_enemy_nearby_blocks_without_enemy() -> void:
	var bundle: Dictionary = _build_bundle()
	var manager: Node = bundle.get("manager")
	var source: MockUnit = bundle.get("source")
	var entry: Dictionary = _build_entry(manager, source.unit_id, {
		"trigger": "manual",
		"range": 2,
		"trigger_params": {"require_enemy_nearby": true},
		"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
	})

	_assert_true(
		not bool(manager.get_trigger_runtime().can_trigger_entry(manager, source, entry, {})),
		"require_enemy_nearby should block trigger when no enemy is in range"
	)


func _test_trigger_params_require_enemy_nearby_passes_with_enemy() -> void:
	var bundle: Dictionary = _build_bundle(true)
	var manager: Node = bundle.get("manager")
	var source: MockUnit = bundle.get("source")
	var entry: Dictionary = _build_entry(manager, source.unit_id, {
		"trigger": "manual",
		"range": 2,
		"trigger_params": {"require_enemy_nearby": true},
		"effects": [{"op": "buff_self", "buff_id": "buff_test", "duration": 1.0}]
	})

	_assert_true(
		bool(manager.get_trigger_runtime().can_trigger_entry(manager, source, entry, {})),
		"require_enemy_nearby should pass when an enemy is in range"
	)


func _build_bundle(include_enemy: bool = false) -> Dictionary:
	var manager: Node = _track_node(UNIT_AUGMENT_MANAGER_SCRIPT.new())
	var combat_manager: MockCombatManager = _track_node(MockCombatManager.new()) as MockCombatManager
	var hex_grid: MockHexGrid = _track_node(MockHexGrid.new()) as MockHexGrid
	var source: MockUnit = _make_unit("source", TEAM_ALLY, Vector2.ZERO)

	manager.get_buff_manager().set_buff_definitions({
		"buff_test": {
			"id": "buff_test",
			"type": "buff",
			"default_duration": 1.0,
			"effects": []
		}
	})
	manager.get_state_service().reset_battle_state()
	manager.get_state_service().register_battle_unit(source)
	combat_manager.register(source, Vector2i(0, 0))
	manager.get_battle_runtime().bind_combat_context(manager, combat_manager, hex_grid, null)

	var enemy: MockUnit = null
	if include_enemy:
		enemy = _make_unit("enemy", TEAM_ENEMY, Vector2(16.0, 0.0))
		manager.get_state_service().register_battle_unit(enemy)
		combat_manager.register(enemy, Vector2i(1, 0))

	return {
		"manager": manager,
		"combat_manager": combat_manager,
		"hex_grid": hex_grid,
		"source": source,
		"enemy": enemy
	}


func _build_entry(manager: Node, owner_id: String, skill_data: Dictionary) -> Dictionary:
	return manager.get_state_service().call("_build_trigger_entry", owner_id, skill_data)


func _make_unit(unit_id: String, team_id: int, world_pos: Vector2) -> MockUnit:
	var unit: MockUnit = _track_node(MockUnit.new()) as MockUnit
	unit.unit_id = unit_id
	unit.unit_name = unit_id
	unit.team_id = team_id
	unit.position = world_pos
	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)
	var combat: MockUnitCombat = MockUnitCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	return unit


func _track_node(node: Node) -> Node:
	if node != null and is_instance_valid(node):
		_owned_nodes.append(node)
	return node


func _cleanup_owned_nodes() -> void:
	for index in range(_owned_nodes.size() - 1, -1, -1):
		var node: Node = _owned_nodes[index]
		if node != null and is_instance_valid(node):
			node.free()
	_owned_nodes.clear()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
