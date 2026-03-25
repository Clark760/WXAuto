extends SceneTree

const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/gongfa/effect_engine.gd")


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var unit_id: String = ""
	var unit_name: String = ""
	var runtime_stats: Dictionary = {}


class MockUnitCombat:
	extends Node
	var is_alive: bool = true
	var current_hp: float = 1000.0
	var max_hp: float = 1000.0
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
			"immune_absorbed": 0.0
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


class MockBuffManager:
	extends Node
	var aura_targets: Array = []
	var applied: Array = []

	func apply_buff(target: Node, buff_id: String, duration: float, source: Node = null) -> bool:
		applied.append({"target": target, "buff_id": buff_id, "duration": duration, "source": source})
		return true

	func refresh_source_bound_aura(
		_source: Node,
		buff_id: String,
		_aura_key: String,
		_scope_key: String,
		_scope_refresh_token: int,
		targets: Array,
		_context: Dictionary
	) -> Dictionary:
		aura_targets.clear()
		for target in targets:
			aura_targets.append(target)
		return {
			"applied_count": targets.size(),
			"applied_targets": targets,
			"buff_id": buff_id
		}

	func has_debuff(_unit: Node, _debuff_id: String = "") -> bool:
		return false


class MockCombatManager:
	extends Node
	var unit_cells: Dictionary = {}

	func register_unit_cell(unit: Node, cell: Vector2i) -> void:
		if unit == null:
			return
		unit_cells[unit.get_instance_id()] = cell

	func get_unit_cell_of(unit: Node) -> Vector2i:
		if unit == null:
			return Vector2i(-1, -1)
		return unit_cells.get(unit.get_instance_id(), Vector2i(-1, -1))

	func move_unit_steps_away(unit: Node, threat_cell: Vector2i, max_steps: int) -> bool:
		var current: Vector2i = get_unit_cell_of(unit)
		if current.x < 0:
			return false
		var next: Vector2i = Vector2i(
			current.x + int(sign(float(current.x - threat_cell.x))) * maxi(max_steps, 1),
			current.y + int(sign(float(current.y - threat_cell.y))) * maxi(max_steps, 1)
		)
		unit_cells[unit.get_instance_id()] = next
		return true

	func move_unit_steps_towards(unit: Node, anchor_cell: Vector2i, _max_steps: int) -> bool:
		if unit == null:
			return false
		unit_cells[unit.get_instance_id()] = anchor_cell
		return true

	func swap_unit_cells(unit_a: Node, unit_b: Node) -> bool:
		var a: Vector2i = get_unit_cell_of(unit_a)
		var b: Vector2i = get_unit_cell_of(unit_b)
		unit_cells[unit_a.get_instance_id()] = b
		unit_cells[unit_b.get_instance_id()] = a
		return true

	func is_cell_blocked(_cell: Vector2i) -> bool:
		return false

	func add_temporary_terrain(_config: Dictionary, _source: Node = null) -> bool:
		return true

	func add_unit_mid_battle(_unit: Node) -> bool:
		return true

	func force_move_unit_to_cell(unit: Node, cell: Vector2i) -> bool:
		unit_cells[unit.get_instance_id()] = cell
		return true


class MockGongfaManager:
	extends Node
	func evaluate_tag_linkage_gate(_owner: Node, _effect: Dictionary, _context: Dictionary) -> Dictionary:
		return {"allowed": true}

	func evaluate_tag_linkage_branch(_owner: Node, _config: Dictionary, _context: Dictionary) -> Dictionary:
		return {
			"effects": [{"op": "damage_target", "value": 55.0, "damage_type": "internal"}],
			"matched_case_ids": ["contract_case"]
		}

	func notify_tag_linkage_evaluated(_source: Node, _effect: Dictionary, _context: Dictionary, _result: Dictionary) -> void:
		return

	func get_tag_linkage_state(_owner: Node, _effect: Dictionary) -> Dictionary:
		return {"last_case_id": "", "stateful_buff_ids": []}

	func set_tag_linkage_state(_owner: Node, _effect: Dictionary, _case_id: String, _buff_ids: Array[String]) -> void:
		return


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 effect engine facade contract tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 effect engine facade contract tests passed.")
	quit(0)


func _run() -> void:
	_test_public_surface_bundle_and_summary()
	_test_damage_heal_and_buff_debuff_ops()
	_test_movement_and_tag_linkage_and_source_bound_aura_ops()


func _test_public_surface_bundle_and_summary() -> void:
	var engine: Variant = EFFECT_ENGINE_SCRIPT.new()
	var bundle: Dictionary = engine.create_empty_modifier_bundle()
	_assert_true(bundle.has("mp_regen_add"), "bundle should expose mp_regen_add")
	_assert_true(bundle.has("damage_amp_percent"), "bundle should expose damage_amp_percent")
	_assert_true(bundle.has("conditional_stats"), "bundle should expose conditional_stats")

	var source: MockUnit = _make_unit("src_a", 1, Vector2.ZERO)
	var target: MockUnit = _make_unit("tgt_a", 2, Vector2(30, 0))
	var summary: Dictionary = engine.execute_active_effects(source, target, [{"op": "damage_target", "value": 10.0}], {"all_units": [source, target]})
	for key in ["damage_total", "heal_total", "mp_total", "summon_total", "hazard_total", "buff_applied", "debuff_applied", "damage_events", "heal_events", "mp_events", "buff_events"]:
		_assert_true(summary.has(key), "summary should contain key %s" % key)
	_free_nodes([source, target])


func _test_damage_heal_and_buff_debuff_ops() -> void:
	var engine: Variant = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_unit("src_b", 1, Vector2.ZERO)
	var target: MockUnit = _make_unit("tgt_b", 2, Vector2(30, 0))
	var source_combat: Node = source.get_node_or_null("Components/UnitCombat")
	if source_combat != null:
		source_combat.set("current_hp", 900.0)
	var buff_manager := MockBuffManager.new()
	var summary: Dictionary = engine.execute_active_effects(source, target, [
		{"op": "damage_target", "value": 120.0, "damage_type": "internal"},
		{"op": "heal_self", "value": 40.0},
		{"op": "buff_target", "buff_id": "buff_contract", "duration": 5.0},
		{"op": "debuff_target", "buff_id": "debuff_contract", "duration": 4.0}
	], {
		"all_units": [source, target],
		"buff_manager": buff_manager
	})
	_assert_true(float(summary.get("damage_total", 0.0)) > 0.0, "damage op should produce positive damage_total")
	_assert_true(float(summary.get("heal_total", 0.0)) > 0.0, "heal op should produce positive heal_total")
	_assert_true(int(summary.get("buff_applied", 0)) >= 1, "buff op should increment buff_applied")
	_assert_true(int(summary.get("debuff_applied", 0)) >= 1, "debuff op should increment debuff_applied")
	_free_nodes([source, target, buff_manager])


func _test_movement_and_tag_linkage_and_source_bound_aura_ops() -> void:
	var engine: Variant = EFFECT_ENGINE_SCRIPT.new()
	var source: MockUnit = _make_unit("src_c", 1, Vector2.ZERO)
	var ally: MockUnit = _make_unit("ally_c", 1, Vector2(20, 0))
	var target: MockUnit = _make_unit("tgt_c", 2, Vector2(40, 0))

	var combat := MockCombatManager.new()
	combat.register_unit_cell(source, Vector2i(0, 0))
	combat.register_unit_cell(target, Vector2i(2, 0))
	combat.register_unit_cell(ally, Vector2i(1, 0))

	var buff_manager := MockBuffManager.new()
	var gongfa_manager := MockGongfaManager.new()
	var summary: Dictionary = engine.execute_active_effects(source, target, [
		{"op": "knockback_target", "distance": 1},
		{
			"op": "tag_linkage_branch",
			"execution_mode": "continuous",
			"cases": [{"id": "contract_case", "effects": [{"op": "damage_target", "value": 55.0}]}]
		},
		{
			"op": "buff_allies_aoe",
			"buff_id": "buff_aura_contract",
			"radius": 2.0,
			"binding_mode": "source_bound_aura"
		}
	], {
		"all_units": [source, ally, target],
		"combat_manager": combat,
		"buff_manager": buff_manager,
		"gongfa_manager": gongfa_manager,
		"source_bound_aura_scope_key": "contract_scope",
		"source_bound_aura_scope_token": 1
	})

	var target_cell: Vector2i = combat.get_unit_cell_of(target)
	_assert_true(target_cell != Vector2i(2, 0), "movement op should change target cell")
	_assert_true(float(summary.get("damage_total", 0.0)) > 0.0, "tag_linkage_branch should execute nested effects")
	_assert_true(int(summary.get("buff_applied", 0)) >= 1, "source bound aura should report buff_applied")
	_assert_true(buff_manager.aura_targets.size() >= 1, "source bound aura should refresh aura targets")
	_free_nodes([source, ally, target, combat, buff_manager, gongfa_manager])


func _make_unit(id: String, team: int, pos: Vector2) -> MockUnit:
	var unit := MockUnit.new()
	unit.unit_id = id
	unit.unit_name = id
	unit.team_id = team
	unit.position = pos

	var components := Node.new()
	components.name = "Components"
	unit.add_child(components)

	var combat := MockUnitCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	return unit


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error(message)


func _free_nodes(nodes: Array) -> void:
	for node_value in nodes:
		if not (node_value is Node):
			continue
		var node: Node = node_value as Node
		if node != null and is_instance_valid(node):
			node.free()
