extends SceneTree

const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/gongfa/effect_engine.gd")
const BUFF_MANAGER_SCRIPT: Script = preload("res://scripts/gongfa/buff_manager.gd")
const COMBAT_TARGETING_SCRIPT: Script = preload("res://scripts/combat/combat_targeting.gd")


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var unit_id: String = ""
	var unit_name: String = ""
	var star_level: int = 1
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
	var unit_cells: Dictionary = {}
	var mid_battle_added_units: Array[int] = []

	func add_temporary_terrain(config: Dictionary, _source: Node = null) -> bool:
		terrains.append(config.duplicate(true))
		return true

	func register_unit_cell(unit: Node, cell: Vector2i) -> void:
		if unit == null:
			return
		unit_cells[unit.get_instance_id()] = cell
		if unit is Node2D:
			(unit as Node2D).position = axial_to_world(cell)

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null:
			return Vector2i(-1, -1)
		var iid: int = unit.get_instance_id()
		if not unit_cells.has(iid):
			return Vector2i(-1, -1)
		return unit_cells[iid]

	func force_move_unit_to_cell(unit: Node, cell: Vector2i) -> bool:
		if unit == null:
			return false
		unit_cells[unit.get_instance_id()] = cell
		if unit is Node2D:
			(unit as Node2D).position = axial_to_world(cell)
		return true

	func move_unit_steps_towards(unit: Node, anchor_cell: Vector2i, max_steps: int) -> bool:
		var current: Vector2i = get_unit_cell_of(unit)
		if current.x < 0:
			return false
		var moved: bool = false
		var steps: int = maxi(max_steps, 0)
		while steps > 0:
			steps -= 1
			var next_x: int = current.x + int(sign(float(anchor_cell.x - current.x)))
			var next_y: int = current.y + int(sign(float(anchor_cell.y - current.y)))
			var next: Vector2i = Vector2i(next_x, next_y)
			if next == current:
				break
			force_move_unit_to_cell(unit, next)
			current = next
			moved = true
		return moved

	func move_unit_steps_away(unit: Node, threat_cell: Vector2i, max_steps: int) -> bool:
		var current: Vector2i = get_unit_cell_of(unit)
		if current.x < 0:
			return false
		var moved: bool = false
		var steps: int = maxi(max_steps, 0)
		while steps > 0:
			steps -= 1
			var next_x: int = current.x + int(sign(float(current.x - threat_cell.x)))
			var next_y: int = current.y + int(sign(float(current.y - threat_cell.y)))
			var next: Vector2i = Vector2i(next_x, next_y)
			if next == current:
				break
			force_move_unit_to_cell(unit, next)
			current = next
			moved = true
		return moved

	func is_cell_blocked(_cell: Vector2i) -> bool:
		return false

	func is_battle_running() -> bool:
		return true

	func add_unit_mid_battle(unit: Node) -> bool:
		if unit == null:
			return false
		mid_battle_added_units.append(unit.get_instance_id())
		return true

	func axial_to_world(cell: Vector2i) -> Vector2:
		return Vector2(float(cell.x) * 32.0, float(cell.y) * 24.0)


class MockBattlefield:
	extends Node
	var spawned_rows: Array = []

	func spawn_enemy_wave(wave_units_value: Variant) -> int:
		if not (wave_units_value is Array):
			return 0
		var wave_units: Array = wave_units_value
		spawned_rows = wave_units.duplicate(true)
		var total: int = 0
		for row_value in wave_units:
			if not (row_value is Dictionary):
				continue
			total += maxi(int((row_value as Dictionary).get("count", 0)), 0)
		return total


class MockHexGrid:
	extends Node

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= 0 and cell.y >= 0 and cell.x < 16 and cell.y < 16

	func world_to_axial(_world_pos: Vector2) -> Vector2i:
		return Vector2i(1, 1)

	func axial_to_world(cell: Vector2i) -> Vector2:
		return Vector2(float(cell.x) * 32.0, float(cell.y) * 24.0)

	func get_neighbor_cells(cell: Vector2i) -> Array[Vector2i]:
		return [
			Vector2i(cell.x + 1, cell.y),
			Vector2i(cell.x - 1, cell.y),
			Vector2i(cell.x, cell.y + 1),
			Vector2i(cell.x, cell.y - 1),
			Vector2i(cell.x + 1, cell.y - 1),
			Vector2i(cell.x - 1, cell.y + 1)
		]

	func get_cell_distance(a: Vector2i, b: Vector2i) -> int:
		var dq: int = b.x - a.x
		var dr: int = b.y - a.y
		var distance_sum: int = absi(dq) + absi(dq + dr) + absi(dr)
		return int(distance_sum / 2.0)


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
	_test_teleport_behind_op()
	_test_dash_forward_op()
	_test_knockback_target_op()
	_test_summon_clone_op()
	_test_revive_random_ally_op()
	_test_taunt_aoe_op()
	_test_taunt_targeting_integration()


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


func _test_teleport_behind_op() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_teleport_source")
	var target: MockUnit = _make_test_unit(2, "unit_test_teleport_target")
	var combat_manager: MockCombatManager = MockCombatManager.new()
	var hex_grid: MockHexGrid = MockHexGrid.new()
	combat_manager.register_unit_cell(source, Vector2i(3, 3))
	combat_manager.register_unit_cell(target, Vector2i(5, 3))
	engine.call("execute_active_effects", source, target, [{
		"op": "teleport_behind",
		"distance": 1
	}], {
		"combat_manager": combat_manager,
		"hex_grid": hex_grid
	})
	var moved_cell: Vector2i = combat_manager.get_unit_cell_of(source)
	_assert_true(moved_cell != Vector2i(3, 3), "teleport_behind moved source")
	_assert_true(moved_cell.x >= 5, "teleport_behind moved to target backside")
	source.free()
	target.free()
	combat_manager.free()
	hex_grid.free()


func _test_dash_forward_op() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_dash_source")
	var target: MockUnit = _make_test_unit(2, "unit_test_dash_target")
	var combat_manager: MockCombatManager = MockCombatManager.new()
	combat_manager.register_unit_cell(source, Vector2i(2, 2))
	combat_manager.register_unit_cell(target, Vector2i(6, 2))
	engine.call("execute_active_effects", source, target, [{
		"op": "dash_forward",
		"distance": 2
	}], {
		"combat_manager": combat_manager
	})
	var moved_cell: Vector2i = combat_manager.get_unit_cell_of(source)
	_assert_true(moved_cell.x > 2, "dash_forward moved source towards target")
	source.free()
	target.free()
	combat_manager.free()


func _test_knockback_target_op() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_knock_source")
	var target: MockUnit = _make_test_unit(2, "unit_test_knock_target")
	var combat_manager: MockCombatManager = MockCombatManager.new()
	combat_manager.register_unit_cell(source, Vector2i(4, 4))
	combat_manager.register_unit_cell(target, Vector2i(5, 4))
	engine.call("execute_active_effects", source, target, [{
		"op": "knockback_target",
		"distance": 2
	}], {
		"combat_manager": combat_manager
	})
	var moved_cell: Vector2i = combat_manager.get_unit_cell_of(target)
	_assert_true(moved_cell.x > 5, "knockback_target moved target away from source")
	source.free()
	target.free()
	combat_manager.free()


func _test_summon_clone_op() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_clone_source")
	var battlefield: MockBattlefield = MockBattlefield.new()
	var summary: Dictionary = engine.call("execute_active_effects", source, null, [{
		"op": "summon_clone",
		"count": 2,
		"hp_ratio": 0.5,
		"atk_ratio": 0.6,
		"deploy": "around_self",
		"radius": 2
	}], {
		"battlefield": battlefield,
		"hex_grid": MockHexGrid.new()
	})
	_assert_true(int(summary.get("summon_total", 0)) == 2, "summon_clone summary count")
	_assert_true(battlefield.spawned_rows.size() == 1, "summon_clone spawned row recorded")
	var first_row: Dictionary = battlefield.spawned_rows[0]
	_assert_true(str(first_row.get("clone_source", "")) == "self", "summon_clone row uses self source")
	source.free()
	battlefield.free()


func _test_revive_random_ally_op() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_revive_source")
	var dead_ally: MockUnit = _make_test_unit(1, "unit_test_revive_dead")
	var enemy: MockUnit = _make_test_unit(2, "unit_test_revive_enemy")
	var dead_combat: MockUnitCombat = dead_ally.get_node("Components/UnitCombat") as MockUnitCombat
	dead_combat.current_hp = 0.0
	dead_combat.is_alive = false
	var combat_manager: MockCombatManager = MockCombatManager.new()
	var summary: Dictionary = engine.call("execute_active_effects", source, enemy, [{
		"op": "revive_random_ally",
		"hp_percent": 0.4
	}], {
		"all_units": [source, dead_ally, enemy],
		"combat_manager": combat_manager
	})
	_assert_true(bool(dead_combat.is_alive), "revive_random_ally revived dead ally")
	_assert_true(float(summary.get("heal_total", 0.0)) > 0.0, "revive_random_ally produced heal")
	_assert_true(combat_manager.mid_battle_added_units.has(dead_ally.get_instance_id()), "revive_random_ally re-registered unit")
	source.free()
	dead_ally.free()
	enemy.free()
	combat_manager.free()


func _test_taunt_aoe_op() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_taunt_source")
	var enemy_a: MockUnit = _make_test_unit(2, "unit_test_taunt_enemy_a")
	var enemy_b: MockUnit = _make_test_unit(2, "unit_test_taunt_enemy_b")
	source.position = Vector2(0, 0)
	enemy_a.position = Vector2(20, 0)
	enemy_b.position = Vector2(28, 10)
	engine.call("execute_active_effects", source, enemy_a, [{
		"op": "taunt_aoe",
		"radius": 3.0,
		"duration": 3.0
	}], {
		"all_units": [source, enemy_a, enemy_b],
		"hex_size": 26.0,
		"battle_elapsed": 10.0
	})
	_assert_true(int(enemy_a.get_meta("status_taunt_source_id", -1)) == source.get_instance_id(), "taunt_aoe set source id on enemy A")
	_assert_true(float(enemy_a.get_meta("status_taunt_until", 0.0)) > 10.0, "taunt_aoe set duration on enemy A")
	_assert_true(int(enemy_b.get_meta("status_taunt_source_id", -1)) == source.get_instance_id(), "taunt_aoe set source id on enemy B")
	source.free()
	enemy_a.free()
	enemy_b.free()


func _test_taunt_targeting_integration() -> void:
	var targeter = COMBAT_TARGETING_SCRIPT.new()
	var source: MockUnit = _make_test_unit(1, "unit_test_taunt_focus_source")
	var enemy: MockUnit = _make_test_unit(2, "unit_test_taunt_focus_enemy")
	enemy.set_meta("status_taunt_until", 12.0)
	enemy.set_meta("status_taunt_source_id", source.get_instance_id())
	var owner: MockTargetingOwner = MockTargetingOwner.new()
	owner._unit_by_instance_id = {
		source.get_instance_id(): source,
		enemy.get_instance_id(): enemy
	}
	owner._logic_time = 11.0
	var picked: Node = targeter.call("pick_target_for_unit", owner, enemy)
	_assert_true(picked == source, "taunt targeting forces enemy to source")
	source.free()
	enemy.free()
	owner.free()


class MockSpatialHash:
	extends RefCounted

	func query_radius(_center: Vector2, _radius: float) -> Array[int]:
		return []


class MockTargetingOwner:
	extends Node
	var prioritize_targets_in_attack_range: bool = false
	var _group_focus_target_id: Dictionary = {}
	var _unit_by_instance_id: Dictionary = {}
	var _spatial_hash: MockSpatialHash = MockSpatialHash.new()
	var _team_alive_cache: Dictionary = {1: [], 2: []}
	var _logic_time: float = 0.0

	func get_logic_time() -> float:
		return _logic_time

	func _is_live_unit(node: Node) -> bool:
		return node != null and is_instance_valid(node)

	func _is_unit_alive(node: Node) -> bool:
		var combat: Node = node.get_node_or_null("Components/UnitCombat")
		return combat != null and bool(combat.get("is_alive"))


func _make_test_unit(team_id: int, unit_id: String = "") -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.team_id = team_id
	unit.unit_id = unit_id if not unit_id.is_empty() else "mock_unit_%d" % team_id
	unit.unit_name = unit.unit_id
	unit.star_level = 1
	unit.runtime_stats = {
		"hp": 1200.0,
		"mp": 300.0,
		"atk": 120.0,
		"def": 80.0,
		"iat": 100.0,
		"idr": 60.0,
		"spd": 100.0,
		"wis": 60.0,
		"rng": 2.0
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
