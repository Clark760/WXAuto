extends SceneTree

const EFFECT_ENGINE_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_effect_engine.gd")
const BUFF_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_buff_manager.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")


class MockUnit:
	extends Node2D
	var team_id: int = 1
	var unit_id: String = ""
	var unit_name: String = ""
	var runtime_stats: Dictionary = {}

	func play_anim_state(_state: int, _params: Dictionary = {}) -> void:
		return


class MockUnitCombat:
	extends Node
	var is_alive: bool = true
	var current_hp: float = 1000.0
	var max_hp: float = 1000.0
	var current_mp: float = 300.0
	var max_mp: float = 300.0

	func add_mp(amount: float) -> void:
		current_mp = clampf(current_mp + amount, 0.0, max_mp)

	func add_shield(_amount: float) -> void:
		return

	func get_external_modifiers() -> Dictionary:
		return {}


var _failed: int = 0
var _buff_removed_events: Array[Dictionary] = []


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 source bound aura tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 source bound aura tests passed.")
	quit(0)


func _run() -> void:
	_test_source_bound_aura_apply_and_range_removal()
	_test_source_bound_aura_removed_when_provider_dies()
	_test_source_bound_aura_coexists_with_regular_buff()
	_test_source_bound_aura_keeps_multiple_providers_separate()


func _test_source_bound_aura_apply_and_range_removal() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var buff_manager = _make_buff_manager()
	var source: MockUnit = _make_unit("source_aura", 1, Vector2.ZERO)
	var ally: MockUnit = _make_unit("ally_in_range", 1, Vector2(20.0, 0.0))
	var ally_far: MockUnit = _make_unit("ally_far", 1, Vector2(120.0, 0.0))
	var units: Array[Node] = [source, ally, ally_far]
	var effect: Dictionary = {
		"op": "buff_allies_aoe",
		"buff_id": "buff_source_bound_aura",
		"radius": 1,
		"exclude_self": true,
		"binding_mode": "source_bound_aura"
	}

	_buff_removed_events.clear()
	var context_a: Dictionary = _build_aura_context(buff_manager, units, source, 11, 101)
	var summary_a: Dictionary = engine.execute_active_effects(source, source, [effect], context_a)
	buff_manager.finalize_source_bound_aura_scope("11", 101, context_a)

	_assert_eq_int(int(summary_a.get("buff_applied", 0)), 1, "source_bound_aura should apply once to nearby ally")
	_assert_true(buff_manager.has_buff(ally, "buff_source_bound_aura"), "nearby ally should receive aura buff")
	_assert_true(not buff_manager.has_buff(ally_far, "buff_source_bound_aura"), "far ally should not receive aura buff")
	_assert_true(_has_stat_add_effect(buff_manager.collect_passive_effects_for_unit(ally), "atk", 10.0), "aura buff should contribute stat_add passive")

	ally.position = Vector2(100.0, 0.0)
	var context_b: Dictionary = _build_aura_context(buff_manager, units, source, 11, 102)
	var summary_b: Dictionary = engine.execute_active_effects(source, source, [effect], context_b)
	buff_manager.finalize_source_bound_aura_scope("11", 102, context_b)

	_assert_eq_int(int(summary_b.get("buff_applied", 0)), 0, "moving out of range should not count as new application")
	_assert_true(not buff_manager.has_buff(ally, "buff_source_bound_aura"), "leaving aura range should remove the buff")
	_assert_true(_has_removed_reason("buff_source_bound_aura", "aura_condition_lost"), "range loss should emit aura_condition_lost")

	source.free()
	ally.free()
	ally_far.free()


func _test_source_bound_aura_removed_when_provider_dies() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var buff_manager = _make_buff_manager()

	var source: MockUnit = _make_unit("source_dead", 1, Vector2.ZERO)
	var ally: MockUnit = _make_unit("ally_bound", 1, Vector2(20.0, 0.0))
	var units: Array[Node] = [source, ally]
	var manager: Node = _make_unit_augment_manager(buff_manager, units)

	var effect: Dictionary = {
		"op": "buff_allies_aoe",
		"buff_id": "buff_source_bound_aura",
		"radius": 1,
		"exclude_self": true,
		"binding_mode": "source_bound_aura"
	}
	var context: Dictionary = _build_aura_context(buff_manager, units, source, 21, 201)
	engine.execute_active_effects(source, source, [effect], context)
	buff_manager.finalize_source_bound_aura_scope("21", 201, context)
	_assert_true(buff_manager.has_buff(ally, "buff_source_bound_aura"), "aura should exist before provider death")

	_buff_removed_events.clear()
	var combat_event_bridge: Variant = manager.get("_combat_event_bridge")
	combat_event_bridge._on_unit_died(source, null, 1)

	_assert_true(not buff_manager.has_buff(ally, "buff_source_bound_aura"), "provider death should remove source bound aura from allies")
	_assert_true(_has_removed_reason("buff_source_bound_aura", "aura_source_dead"), "provider death should emit aura_source_dead")

	source.free()
	ally.free()
	manager.queue_free()


func _test_source_bound_aura_coexists_with_regular_buff() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var buff_manager = _make_buff_manager()
	var source: MockUnit = _make_unit("source_regular_mix", 1, Vector2.ZERO)
	var ally: MockUnit = _make_unit("ally_regular_mix", 1, Vector2(20.0, 0.0))
	var units: Array[Node] = [source, ally]
	var effect: Dictionary = {
		"op": "buff_allies_aoe",
		"buff_id": "buff_source_bound_aura",
		"radius": 1,
		"exclude_self": true,
		"binding_mode": "source_bound_aura"
	}

	_assert_true(buff_manager.apply_buff(ally, "buff_source_bound_aura", 5.0, source), "regular buff apply should succeed")
	var context_a: Dictionary = _build_aura_context(buff_manager, units, source, 31, 301)
	engine.execute_active_effects(source, source, [effect], context_a)
	buff_manager.finalize_source_bound_aura_scope("31", 301, context_a)

	var entries_before: Array = _get_entries_for_unit(buff_manager, ally)
	_assert_eq_int(entries_before.size(), 2, "regular buff and aura buff should coexist for same source and buff_id")

	_buff_removed_events.clear()
	ally.position = Vector2(100.0, 0.0)
	var context_b: Dictionary = _build_aura_context(buff_manager, units, source, 31, 302)
	engine.execute_active_effects(source, source, [effect], context_b)
	buff_manager.finalize_source_bound_aura_scope("31", 302, context_b)

	var entries_after: Array = _get_entries_for_unit(buff_manager, ally)
	_assert_eq_int(entries_after.size(), 1, "removing aura instance should keep regular buff instance")
	_assert_true(_entry_has_application_key(entries_after, ""), "remaining entry should be the regular buff bucket")
	_assert_true(_has_removed_reason("buff_source_bound_aura", "aura_condition_lost"), "coexistence removal should still use aura_condition_lost")

	source.free()
	ally.free()


func _test_source_bound_aura_keeps_multiple_providers_separate() -> void:
	var engine = EFFECT_ENGINE_SCRIPT.new()
	var buff_manager = _make_buff_manager()

	var source_a: MockUnit = _make_unit("source_multi_a", 1, Vector2.ZERO)
	var source_b: MockUnit = _make_unit("source_multi_b", 1, Vector2(10.0, 0.0))
	var ally: MockUnit = _make_unit("ally_multi", 1, Vector2(20.0, 0.0))
	var units: Array[Node] = [source_a, source_b, ally]
	var manager: Node = _make_unit_augment_manager(buff_manager, units)

	var effect: Dictionary = {
		"op": "buff_allies_aoe",
		"buff_id": "buff_source_bound_aura",
		"radius": 1,
		"exclude_self": true,
		"binding_mode": "source_bound_aura"
	}

	var context_a: Dictionary = _build_aura_context(buff_manager, units, source_a, 41, 401)
	engine.execute_active_effects(source_a, source_a, [effect], context_a)
	buff_manager.finalize_source_bound_aura_scope("41", 401, context_a)
	var context_b: Dictionary = _build_aura_context(buff_manager, units, source_b, 42, 402)
	engine.execute_active_effects(source_b, source_b, [effect], context_b)
	buff_manager.finalize_source_bound_aura_scope("42", 402, context_b)

	var entries_before: Array = _get_entries_for_unit(buff_manager, ally)
	_assert_eq_int(entries_before.size(), 2, "two providers should create two independent aura buckets")

	_buff_removed_events.clear()
	var combat_event_bridge: Variant = manager.get("_combat_event_bridge")
	combat_event_bridge._on_unit_died(source_a, null, 1)

	var entries_after: Array = _get_entries_for_unit(buff_manager, ally)
	_assert_eq_int(entries_after.size(), 1, "removing one provider should keep the other provider aura")
	_assert_true(_entry_has_source_id(entries_after, source_b.get_instance_id()), "remaining aura should belong to surviving provider")
	_assert_true(_has_removed_reason("buff_source_bound_aura", "aura_source_dead"), "provider-specific cleanup should use aura_source_dead")

	source_a.free()
	source_b.free()
	ally.free()
	manager.queue_free()


func _make_buff_manager() -> RefCounted:
	var manager = BUFF_MANAGER_SCRIPT.new()
	manager.set_buff_definitions({
		"buff_source_bound_aura": {
			"id": "buff_source_bound_aura",
			"name": "Source Bound Aura",
			"type": "buff",
			"stackable": false,
			"max_stacks": 1,
			"default_duration": 5.0,
			"effects": [{"op": "stat_add", "stat": "atk", "value": 10.0}],
			"tick_effects": [],
			"tick_interval": 0.0
		}
	})
	var cb: Callable = Callable(self, "_on_buff_removed")
	if not manager.is_connected("buff_removed", cb):
		manager.connect("buff_removed", cb)
	return manager


func _make_unit_augment_manager(buff_manager: RefCounted, units: Array[Node]) -> Node:
	var manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	manager.set("_buff_manager", buff_manager)
	var combat_event_bridge: Variant = manager.get("_combat_event_bridge")
	if combat_event_bridge != null:
		combat_event_bridge.configure(manager)
	var state_service: Variant = manager.get_state_service()
	state_service.reset_battle_state()
	for unit in units:
		state_service.register_battle_unit(unit)
	return manager


func _make_unit(unit_id: String, team_id: int, pos: Vector2) -> MockUnit:
	var unit: MockUnit = MockUnit.new()
	unit.unit_id = unit_id
	unit.unit_name = unit_id
	unit.team_id = team_id
	unit.position = pos

	var components: Node = Node.new()
	components.name = "Components"
	unit.add_child(components)

	var combat: MockUnitCombat = MockUnitCombat.new()
	combat.name = "UnitCombat"
	components.add_child(combat)
	return unit


func _build_aura_context(
	buff_manager: RefCounted,
	units: Array[Node],
	source: Node,
	scope_key: int,
	scope_token: int
) -> Dictionary:
	return {
		"all_units": units,
		"hex_size": 26.0,
		"buff_manager": buff_manager,
		"source": source,
		"target": source,
		"source_bound_aura_scope_key": str(scope_key),
		"source_bound_aura_scope_token": scope_token
	}


func _get_entries_for_unit(buff_manager: RefCounted, target: Node) -> Array:
	var active_by_unit: Dictionary = buff_manager.get("_active_by_unit")
	return active_by_unit.get(target.get_instance_id(), [])


func _entry_has_application_key(entries: Array, application_key: String) -> bool:
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		if str((entry_value as Dictionary).get("application_key", "")).strip_edges() == application_key.strip_edges():
			return true
	return false


func _entry_has_source_id(entries: Array, source_id: int) -> bool:
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		if int((entry_value as Dictionary).get("source_id", -1)) == source_id:
			return true
	return false


func _has_stat_add_effect(effects_variant: Variant, stat: String, value: float) -> bool:
	if not (effects_variant is Array):
		return false
	for effect_value in (effects_variant as Array):
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value as Dictionary
		if str(effect.get("op", "")).strip_edges() != "stat_add":
			continue
		if str(effect.get("stat", "")).strip_edges() != stat.strip_edges():
			continue
		if is_equal_approx(float(effect.get("value", 0.0)), value):
			return true
	return false


func _on_buff_removed(event: Dictionary) -> void:
	_buff_removed_events.append(event.duplicate(true))


func _has_removed_reason(buff_id: String, reason: String) -> bool:
	for event in _buff_removed_events:
		if str(event.get("buff_id", "")).strip_edges() != buff_id.strip_edges():
			continue
		if str(event.get("reason", "")).strip_edges() != reason.strip_edges():
			continue
		return true
	return false


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)


func _assert_eq_int(actual: int, expected: int, message: String) -> void:
	if actual == expected:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s (actual=%d expected=%d)" % [message, actual, expected])
