extends SceneTree

const COMBAT_MANAGER_SCRIPT: Script = preload("res://scripts/combat/combat_manager.gd")
const UNIT_COMBAT_SCRIPT: Script = preload("res://scripts/unit/unit_combat.gd")

const TEAM_ALLY: int = 1
const TEAM_ENEMY: int = 2


class MockUnit:
	extends Node2D
	var team_id: int = TEAM_ALLY
	var unit_id: String = ""
	var unit_name: String = ""
	var runtime_stats: Dictionary = {}
	var is_in_combat: bool = false
	var is_on_bench: bool = false

	func set_team(value: int) -> void:
		team_id = value

	func enter_combat() -> void:
		is_in_combat = true

	func leave_combat() -> void:
		is_in_combat = false

	func set_on_bench_state(value: bool, _slot_index: int = -1) -> void:
		is_on_bench = value

	func play_anim_state(_state: int, _context: Dictionary = {}) -> void:
		return


var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 combat death signal regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 combat death signal regression tests passed.")
	quit(0)


func _run() -> void:
	await _test_direct_receive_damage_emits_unit_died()
	await _test_thorns_reflect_kill_emits_unit_died()


func _test_direct_receive_damage_emits_unit_died() -> void:
	var ctx: Dictionary = await _create_harness(140.0, 220.0)
	var combat_manager: Node = ctx["combat_manager"]
	var ally: Node = ctx["ally"]
	var enemy: Node = ctx["enemy"]
	var enemy_combat: Node = ctx["enemy_combat"]

	var dead_ids: Array[int] = []
	var dead_cb: Callable = func(dead_unit: Node, _killer: Node, _team_id: int) -> void:
		if dead_unit != null and is_instance_valid(dead_unit):
			dead_ids.append(dead_unit.get_instance_id())
	combat_manager.connect("unit_died", dead_cb)

	var ally_units: Array[Node] = [ally]
	var enemy_units: Array[Node] = [enemy]
	var started: bool = bool(combat_manager.call("start_battle", ally_units, enemy_units, 20260323))
	_assert_true(started, "start_battle should succeed in direct damage regression test")
	if started:
		enemy_combat.call("receive_damage", 99999.0, ally, "internal", true, false, false, false)
		await process_frame
		await process_frame
		_assert_true(dead_ids.has(enemy.get_instance_id()), "direct receive_damage kill should emit CombatManager.unit_died")
		_assert_true(int(combat_manager.call("get_alive_count", TEAM_ENEMY)) == 0, "enemy alive count should drop immediately after direct kill")
		_assert_true(combat_manager.call("get_unit_by_instance_id", enemy.get_instance_id()) == null, "dead enemy should be removed from runtime lookup")

	_cleanup_harness(ctx, dead_cb)


func _test_thorns_reflect_kill_emits_unit_died() -> void:
	var ctx: Dictionary = await _create_harness(120.0, 1500.0)
	var combat_manager: Node = ctx["combat_manager"]
	var ally: Node = ctx["ally"]
	var enemy: Node = ctx["enemy"]
	var ally_combat: Node = ctx["ally_combat"]
	var enemy_combat: Node = ctx["enemy_combat"]

	var dead_ids: Array[int] = []
	var dead_cb: Callable = func(dead_unit: Node, _killer: Node, _team_id: int) -> void:
		if dead_unit != null and is_instance_valid(dead_unit):
			dead_ids.append(dead_unit.get_instance_id())
	combat_manager.connect("unit_died", dead_cb)

	var ally_units: Array[Node] = [ally]
	var enemy_units: Array[Node] = [enemy]
	var started: bool = bool(combat_manager.call("start_battle", ally_units, enemy_units, 20260323))
	_assert_true(started, "start_battle should succeed in thorns regression test")
	if started:
		enemy_combat.call("set_external_modifiers", {"thorns_percent": 3.0})
		enemy_combat.call("receive_damage", 60.0, ally, "external", false, false, false, true)
		await process_frame
		await process_frame
		_assert_true(not bool(ally_combat.get("is_alive")), "thorns reflect should kill attacker in this setup")
		_assert_true(dead_ids.has(ally.get_instance_id()), "thorns reflect kill should emit CombatManager.unit_died")
		_assert_true(int(combat_manager.call("get_alive_count", TEAM_ALLY)) == 0, "ally alive count should drop immediately after thorns kill")
		_assert_true(combat_manager.call("get_unit_by_instance_id", ally.get_instance_id()) == null, "dead ally should be removed from runtime lookup")

	_cleanup_harness(ctx, dead_cb)


func _create_harness(ally_hp: float, enemy_hp: float) -> Dictionary:
	var combat_manager: Node = COMBAT_MANAGER_SCRIPT.new()
	root.add_child(combat_manager)
	await process_frame

	var ally_bundle: Dictionary = _make_unit_bundle(TEAM_ALLY, "unit_test_ally", "Test Ally", ally_hp, Vector2(0.0, 0.0))
	var enemy_bundle: Dictionary = _make_unit_bundle(TEAM_ENEMY, "unit_test_enemy", "Test Enemy", enemy_hp, Vector2(10.0, 0.0))
	var ally: Node = ally_bundle["unit"]
	var enemy: Node = enemy_bundle["unit"]
	root.add_child(ally)
	root.add_child(enemy)
	await process_frame

	return {
		"combat_manager": combat_manager,
		"ally": ally,
		"enemy": enemy,
		"ally_combat": ally_bundle["combat"],
		"enemy_combat": enemy_bundle["combat"]
	}


func _make_unit_bundle(team_id: int, unit_id: String, unit_name: String, hp_value: float, world_pos: Vector2) -> Dictionary:
	var unit := MockUnit.new()
	unit.team_id = team_id
	unit.unit_id = unit_id
	unit.unit_name = unit_name
	unit.position = world_pos
	unit.runtime_stats = {
		"hp": maxf(hp_value, 1.0),
		"mp": 100.0,
		"atk": 80.0,
		"iat": 60.0,
		"def": 40.0,
		"idr": 30.0,
		"spd": 70.0,
		"rng": 1.0,
		"wis": 40.0
	}

	var components := Node.new()
	components.name = "Components"
	unit.add_child(components)

	var combat: Node = UNIT_COMBAT_SCRIPT.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	combat.call("bind_unit", unit)
	combat.call("reset_from_stats", unit.runtime_stats)

	return {
		"unit": unit,
		"combat": combat
	}


func _cleanup_harness(ctx: Dictionary, dead_cb: Callable) -> void:
	var combat_manager: Node = ctx.get("combat_manager", null)
	if combat_manager != null and is_instance_valid(combat_manager):
		if combat_manager.is_connected("unit_died", dead_cb):
			combat_manager.disconnect("unit_died", dead_cb)
		if bool(combat_manager.call("is_battle_running")):
			combat_manager.call("stop_battle", "test_cleanup", 0)
		combat_manager.queue_free()

	var ally: Node = ctx.get("ally", null)
	if ally != null and is_instance_valid(ally):
		ally.queue_free()
	var enemy: Node = ctx.get("enemy", null)
	if enemy != null and is_instance_valid(enemy):
		enemy.queue_free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
