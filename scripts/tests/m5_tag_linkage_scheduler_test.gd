extends SceneTree

const SCHEDULER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_tag_linkage_scheduler.gd")
const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_effect_engine.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")

var _failed: int = 0


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var unit_id: String = ""
	var unit_name: String = ""
	var runtime_equipped_gongfa_ids: Array = []
	var runtime_equipped_equip_ids: Array = []
	var tags: Array = []
	var traits: Array = []


class MockUnitCombat:
	extends Node
	var is_alive: bool = true
	var current_hp: float = 1000.0
	var max_hp: float = 1000.0
	var current_mp: float = 100.0
	var max_mp: float = 100.0

	func add_mp(amount: float) -> void:
		current_mp = clampf(current_mp + amount, 0.0, max_mp)

	func restore_hp(amount: float, source: Node = null) -> void:
		var final_amount: float = maxf(amount, 0.0)
		if source != null and is_instance_valid(source):
			var source_combat: Node = source.get_node_or_null("Components/UnitCombat")
			if source_combat != null and source_combat.has_method("get_external_modifiers"):
				var modifiers_value: Variant = source_combat.get_external_modifiers()
				if modifiers_value is Dictionary:
					final_amount *= maxf(1.0 + float((modifiers_value as Dictionary).get("healing_amp", 0.0)), 0.0)
		current_hp = clampf(current_hp + final_amount, 0.0, max_hp)
		is_alive = current_hp > 0.0

	func receive_damage(
		amount: float,
		_source: Node,
		_damage_type: String = "internal",
		_is_skill: bool = false,
		_is_crit: bool = false,
		_is_dodged: bool = false,
		_can_trigger_thorns: bool = true
	) -> Dictionary:
		var final_amount: float = maxf(amount, 0.0)
		current_hp = maxf(current_hp - final_amount, 0.0)
		if current_hp <= 0.0:
			is_alive = false
		return {"damage": final_amount, "shield_absorbed": 0.0, "immune_absorbed": 0.0}

	func get_external_modifiers() -> Dictionary:
		return {}


class MockHexGrid:
	extends Node

	func is_inside_grid(cell: Vector2i) -> bool:
		return cell.x >= -10 and cell.y >= -10 and cell.x <= 10 and cell.y <= 10

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

	func world_to_axial(pos: Vector2) -> Vector2i:
		return Vector2i(int(round(pos.x / 32.0)), int(round(pos.y / 24.0)))

	func axial_to_world(cell: Vector2i) -> Vector2:
		return Vector2(float(cell.x) * 32.0, float(cell.y) * 24.0)


class MockCombatManager:
	extends Node
	signal unit_cell_changed(unit: Node, from_cell: Vector2i, to_cell: Vector2i)
	signal unit_spawned(unit: Node, team_id: int)
	signal unit_died(unit: Node, killer: Node, team_id: int)
	signal terrain_changed(changed_cells: Array, reason: String)
	var unit_cells: Dictionary = {}
	var hex_grid: MockHexGrid = null

	func setup(grid: MockHexGrid) -> void:
		hex_grid = grid

	func register_cell(unit: Node, cell: Vector2i) -> void:
		unit_cells[unit.get_instance_id()] = cell
		if unit is Node2D and hex_grid != null:
			(unit as Node2D).position = hex_grid.axial_to_world(cell)

	func move_cell(unit: Node, to_cell: Vector2i) -> void:
		var from_cell: Vector2i = get_unit_cell_of(unit)
		register_cell(unit, to_cell)
		unit_cell_changed.emit(unit, from_cell, to_cell)

	func spawn_unit(unit: Node, team_id: int, cell: Vector2i) -> void:
		register_cell(unit, cell)
		unit_spawned.emit(unit, team_id)

	func kill_unit(unit: Node, killer: Node = null) -> void:
		unit_died.emit(unit, killer, int(unit.get("team_id")))

	func emit_terrain(cells: Array[Vector2i], reason: String = "tick") -> void:
		terrain_changed.emit(cells, reason)

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null:
			return Vector2i(-1, -1)
		var iid: int = unit.get_instance_id()
		if not unit_cells.has(iid):
			return Vector2i(-1, -1)
		return unit_cells[iid]


class MockBuffManager:
	extends Node
	var apply_calls: Array = []
	var remove_calls: Array = []

	func apply_buff(target: Node, buff_id: String, duration: float, source: Node = null) -> bool:
		apply_calls.append({
			"target_id": target.get_instance_id() if target != null else -1,
			"buff_id": buff_id,
			"duration": duration
		})
		return true

	func remove_buff(target: Node, buff_id: String, reason: String = "manual") -> int:
		remove_calls.append({
			"target_id": target.get_instance_id() if target != null else -1,
			"buff_id": buff_id,
			"reason": reason
		})
		return 1


class MockTagLinkageManager:
	extends Node
	var next_case_id: String = "case_a"
	var next_effects: Array = [{"op": "buff_self", "buff_id": "buff_case_a", "duration": 0.25}]
	var state_by_key: Dictionary = {}
	var gate_allowed: bool = true
	var evaluate_count: int = 0

	func evaluate_tag_linkage_gate(_owner: Node, _effect: Dictionary, _context: Dictionary) -> Dictionary:
		return {"allowed": gate_allowed}

	func evaluate_tag_linkage_branch(_owner: Node, _effect: Dictionary, _context: Dictionary) -> Dictionary:
		evaluate_count += 1
		return {
			"matched_case_ids": [next_case_id] if not next_case_id.is_empty() else [],
			"effects": next_effects.duplicate(true),
			"providers": []
		}

	func notify_tag_linkage_evaluated(_owner: Node, _effect: Dictionary, _context: Dictionary, _result: Dictionary) -> void:
		return

	func get_tag_linkage_state(owner: Node, effect: Dictionary) -> Dictionary:
		var key: String = _state_key(owner, effect)
		if not state_by_key.has(key):
			return {"last_case_id": "", "stateful_buff_ids": []}
		return (state_by_key[key] as Dictionary).duplicate(true)

	func set_tag_linkage_state(owner: Node, effect: Dictionary, case_id: String, buff_ids: Array[String]) -> void:
		state_by_key[_state_key(owner, effect)] = {
			"last_case_id": case_id,
			"stateful_buff_ids": buff_ids.duplicate()
		}

	func _state_key(owner: Node, effect: Dictionary) -> String:
		return "%d|%s" % [owner.get_instance_id(), var_to_str(effect)]


class MockSchedulerAlwaysSkip:
	extends RefCounted

	func should_evaluate(_owner: Node, _effect: Dictionary, _context: Dictionary) -> Dictionary:
		return {"allowed": false, "reason": "forced_skip"}

	func bind_combat_manager(_combat_manager: Node) -> void:
		return

	func clear() -> void:
		return

	func mark_all_dirty(_reason: String = "") -> void:
		return

	func notify_unit_tags_changed(_unit: Node) -> void:
		return


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 tag linkage scheduler tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 tag linkage scheduler tests passed.")
	quit(0)


func _run() -> void:
	await _test_scheduler_dirty_event_and_stagger()
	_test_effect_engine_stateful_branch_switch()
	await _test_unit_augment_manager_skip_linkage_only_precheck()


func _test_scheduler_dirty_event_and_stagger() -> void:
	var scheduler = SCHEDULER_SCRIPT.new()
	var grid: MockHexGrid = MockHexGrid.new()
	var combat: MockCombatManager = MockCombatManager.new()
	combat.setup(grid)
	scheduler.call("bind_combat_manager", combat)

	var owner: MockUnit = _make_unit("owner", 1)
	var ally: MockUnit = _make_unit("ally", 1)
	combat.register_cell(owner, Vector2i(0, 0))
	combat.register_cell(ally, Vector2i(1, 0))

	var effect: Dictionary = {"op": "tag_linkage_branch", "range": 2, "stagger_buckets": 4}
	var context: Dictionary = {"hex_grid": grid, "combat_manager": combat, "tag_linkage_stagger_buckets": 4}
	var gate_dirty: Dictionary = scheduler.call("should_evaluate", owner, effect, context)
	_assert_true(bool(gate_dirty.get("allowed", false)), "dirty watcher should evaluate immediately")
	_assert_true(bool(gate_dirty.get("dirty", false)), "first evaluation should be dirty")

	scheduler.call("on_evaluated", owner, effect, context, {
		"providers": [
			{"unit_id": owner.get_instance_id()},
			{"unit_id": ally.get_instance_id()}
		]
	})
	var gate_stagger: Dictionary = scheduler.call("should_evaluate", owner, effect, context)
	var buckets: int = int(gate_stagger.get("buckets", 1))
	var physics_frame: int = int(gate_stagger.get("physics_frame", 0))
	var expected_allowed: bool = true
	if buckets > 1:
		expected_allowed = posmod(physics_frame, buckets) == posmod(owner.get_instance_id(), buckets)
	_assert_true(bool(gate_stagger.get("allowed", false)) == expected_allowed, "non-dirty watcher should follow stagger gate")

	combat.move_cell(ally, Vector2i(2, 0))
	var gate_after_move: Dictionary = scheduler.call("should_evaluate", owner, effect, context)
	_assert_true(bool(gate_after_move.get("allowed", false)), "unit move should mark subscribed watcher dirty")
	_assert_true(bool(gate_after_move.get("dirty", false)), "unit move should set dirty=true")

	scheduler.call("on_evaluated", owner, effect, context, {"providers": [{"unit_id": owner.get_instance_id()}]})
	combat.emit_terrain([Vector2i(0, 0)], "tick")
	var gate_after_terrain: Dictionary = scheduler.call("should_evaluate", owner, effect, context)
	_assert_true(bool(gate_after_terrain.get("allowed", false)), "terrain change in subscribed cell should force evaluate")

	scheduler.call("on_evaluated", owner, effect, context, {"providers": [{"unit_id": owner.get_instance_id()}]})
	var spawned: MockUnit = _make_unit("spawned", 1)
	combat.spawn_unit(spawned, 1, Vector2i(0, 0))
	var gate_after_spawn: Dictionary = scheduler.call("should_evaluate", owner, effect, context)
	_assert_true(bool(gate_after_spawn.get("allowed", false)), "spawn in subscribed cell should force evaluate")

	owner.free()
	ally.free()
	spawned.free()
	combat.free()
	grid.free()


func _test_effect_engine_stateful_branch_switch() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_unit("state_owner", 1)
	var target: MockUnit = _make_unit("state_target", 2)
	var manager: MockTagLinkageManager = MockTagLinkageManager.new()
	var buff_manager: MockBuffManager = MockBuffManager.new()

	var continuous_summary_a: Dictionary = engine.call("execute_active_effects", source, target, [{
		"op": "tag_linkage_branch",
		"execution_mode": "continuous",
		"queries": [{"id": "q", "tags": ["a"]}],
		"cases": []
	}], {
		"unit_augment_manager": manager,
		"buff_manager": buff_manager
	})
	var continuous_summary_b: Dictionary = engine.call("execute_active_effects", source, target, [{
		"op": "tag_linkage_branch",
		"execution_mode": "continuous",
		"queries": [{"id": "q", "tags": ["a"]}],
		"cases": []
	}], {
		"unit_augment_manager": manager,
		"buff_manager": buff_manager
	})
	_assert_true(int(continuous_summary_a.get("buff_applied", 0)) == 1, "continuous mode should execute branch every time (first)")
	_assert_true(int(continuous_summary_b.get("buff_applied", 0)) == 1, "continuous mode should execute branch every time (second)")

	manager.next_case_id = "case_a"
	manager.next_effects = [{"op": "buff_self", "buff_id": "buff_case_a", "duration": 0.2}]
	var effect_stateful: Dictionary = {
		"op": "tag_linkage_branch",
		"execution_mode": "stateful",
		"queries": [{"id": "q", "tags": ["a"]}],
		"cases": []
	}
	var first_stateful: Dictionary = engine.call("execute_active_effects", source, target, [effect_stateful], {
		"unit_augment_manager": manager,
		"buff_manager": buff_manager
	})
	var second_stateful: Dictionary = engine.call("execute_active_effects", source, target, [effect_stateful], {
		"unit_augment_manager": manager,
		"buff_manager": buff_manager
	})
	_assert_true(int(first_stateful.get("buff_applied", 0)) == 1, "stateful first hit should apply buff")
	_assert_true(int(second_stateful.get("buff_applied", 0)) == 0, "stateful stable branch should not re-apply buff")

	manager.next_case_id = "case_b"
	manager.next_effects = [{"op": "buff_self", "buff_id": "buff_case_b", "duration": 0.2}]
	var third_stateful: Dictionary = engine.call("execute_active_effects", source, target, [effect_stateful], {
		"unit_augment_manager": manager,
		"buff_manager": buff_manager
	})
	_assert_true(int(third_stateful.get("buff_applied", 0)) == 1, "stateful branch change should apply new buff")
	_assert_true(buff_manager.remove_calls.size() >= 1, "stateful branch change should remove old buff")
	var removed_first: Dictionary = buff_manager.remove_calls[0]
	_assert_true(str(removed_first.get("buff_id", "")) == "buff_case_a", "stateful should remove previous branch buff")

	source.free()
	target.free()
	manager.free()
	buff_manager.free()


func _test_unit_augment_manager_skip_linkage_only_precheck() -> void:
	var manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	root.add_child(manager)
	await process_frame

	var source: MockUnit = _make_unit("gm_owner", 1)
	var combat: MockUnitCombat = source.get_node("Components/UnitCombat") as MockUnitCombat
	var before_mp: float = combat.current_mp

	manager.set("_tag_linkage_scheduler", MockSchedulerAlwaysSkip.new())
	var entry: Dictionary = {
		"gongfa_id": "test_linkage_skill",
		"trigger": "passive_aura",
		"chance": 1.0,
		"mp_cost": 20.0,
		"cooldown": 3.0,
		"next_ready_time": 0.0,
		"trigger_count": 0,
		"skill_data": {
			"effects": [
				{
					"op": "tag_linkage_branch",
					"queries": [{"id": "q", "tags": ["a"]}],
					"cases": []
				}
			]
		}
	}
	var fired: bool = bool(manager.get_trigger_runtime().try_fire_skill(manager, source, entry, {}))
	_assert_true(not fired, "linkage-only skill should skip when stagger precheck says no")
	_assert_true(is_equal_approx(combat.current_mp, before_mp), "skip should not consume MP")
	_assert_true(is_equal_approx(float(entry.get("next_ready_time", 0.0)), 0.0), "skip should not set cooldown")
	_assert_true(int(entry.get("trigger_count", 0)) == 0, "skip should not increase trigger count")

	source.free()
	manager.queue_free()


func _make_unit(unit_id: String, team_id: int) -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.unit_id = unit_id
	unit.unit_name = unit_id
	unit.team_id = team_id
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
