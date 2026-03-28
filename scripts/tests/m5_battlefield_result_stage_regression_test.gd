extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const OBJECT_POOL_SCRIPT: Script = preload("res://scripts/core/object_pool.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")
const MOD_LOADER_SCRIPT: Script = preload("res://scripts/core/mod_loader.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")

class StubBattleUnit:
	extends Node2D
	var team_id: int = 0
	var deployed_cell: Vector2i = Vector2i.ZERO
	var is_on_bench: bool = false
	var is_in_combat: bool = false
	var last_anim_state: int = -1
	var reset_visual_called: bool = false
	var unit_name: String = "ResultStub"
	var quality: String = "white"
	var star_level: int = 1

	func _init() -> void:
		var components := Node.new()
		components.name = "Components"
		add_child(components)
		var combat := Node.new()
		combat.name = "UnitCombat"
		combat.set("is_alive", true)
		components.add_child(combat)

	func set_team(next_team: int) -> void:
		team_id = next_team
		set("team_id", next_team)

	func set_on_bench_state(on_bench: bool, _slot_index: int) -> void:
		is_on_bench = on_bench
		set("is_on_bench", on_bench)

	func set_compact_visual_mode(_value: bool) -> void:
		pass

	func play_anim_state(state_id: int, _context: Dictionary) -> void:
		last_anim_state = state_id

	func reset_visual_transform() -> void:
		reset_visual_called = true


var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 battlefield result stage regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 battlefield result stage regression tests passed.")
	quit(0)


func _run() -> void:
	await _test_result_stage_panel_and_reset_chain()


func _test_result_stage_panel_and_reset_chain() -> void:
	var ctx: Dictionary = await _create_battlefield()
	var battlefield: Node = ctx.get("battlefield", null)
	var refs: Node = battlefield.get_scene_refs()
	var state: RefCounted = battlefield.get_session_state()
	var coordinator: Node = battlefield.get_coordinator()
	var world_controller: Node = battlefield.get_world_controller()
	var unit_deploy_manager: Node = refs.runtime_unit_deploy_manager

	_assert_true(not bool(state.battle_stats_visible), "stats state should start hidden")
	_assert_true(not refs.battle_stats_panel.visible, "stats panel should start hidden")

	var stub_unit := StubBattleUnit.new()
	stub_unit.name = "ResultStageStub"
	refs.unit_layer.add_child(stub_unit)
	await process_frame
	unit_deploy_manager.deploy_ally_unit_to_cell(stub_unit, Vector2i(0, 0))
	stub_unit.last_anim_state = 6
	stub_unit.reset_visual_called = false

	coordinator.call("_on_battle_ended", 1, {})
	await process_frame
	_assert_true(int(state.stage) == 2, "battle end should switch session state to RESULT")
	_assert_true(bool(state.battle_stats_visible), "result stage should mark stats state visible")
	_assert_true(refs.battle_stats_panel.visible, "result stage should show stats panel")
	_assert_true(int(state.result_winner_team) == 1, "winner team should be recorded on result stage")

	state.pending_stage_advance = true
	refs.battle_stats_panel.call("_on_close_pressed")
	await process_frame
	_assert_true(stub_unit.reset_visual_called, "leaving result stage should reset deployed unit visuals")
	_assert_true(stub_unit.last_anim_state == 0, "leaving result stage should restore idle animation")
	_assert_true(not bool(state.pending_stage_advance), "closing result panel should clear pending stage advance")

	coordinator.call("_on_stage_loaded", {
		"id": "result_stage_followup",
		"name": "Follow Up",
		"index": 2,
		"type": "normal",
		"grid": {},
		"terrains": [],
		"obstacles": [],
		"enemies": [],
		"rewards": {}
	})
	await process_frame
	_assert_true(int(state.stage) == 0, "loading next stage should leave RESULT and return to PREPARATION")
	_assert_true(not bool(state.battle_stats_visible), "loading next stage should clear stats visible state")
	_assert_true(not refs.battle_stats_panel.visible, "loading next stage should hide stats panel")
	_assert_true(int(state.result_winner_team) == 0, "loading next stage should clear previous result winner")

	battlefield.queue_free()
	var runtime_nodes: Variant = ctx.get("runtime_nodes", [])
	if runtime_nodes is Array:
		for node_value in runtime_nodes:
			if not (node_value is Node):
				continue
			var runtime_node: Node = node_value as Node
			if is_instance_valid(runtime_node):
				runtime_node.free()
	var unit_augment_manager: Node = ctx.get("unit_augment_manager", null)
	if unit_augment_manager != null:
		unit_augment_manager.free()
	await process_frame


func _create_battlefield() -> Dictionary:
	var unit_augment_manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	var services: ServiceRegistry = _build_services(unit_augment_manager)
	var runtime_nodes: Array[Node] = [
		services.event_bus,
		services.object_pool,
		services.data_repository,
		services.mod_loader
	]

	var battlefield: Node = BATTLEFIELD_SCENE.instantiate()
	battlefield.bind_app_services(services)
	root.add_child(battlefield)
	await process_frame
	await process_frame

	return {
		"battlefield": battlefield,
		"unit_augment_manager": unit_augment_manager,
		"services": services,
		"runtime_nodes": runtime_nodes
	}


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)


func _build_services(unit_augment_manager: Node) -> ServiceRegistry:
	var services := ServiceRegistry.new()
	var event_bus: Node = EVENT_BUS_SCRIPT.new()
	var object_pool: Node = OBJECT_POOL_SCRIPT.new()
	var data_manager: Node = DATA_MANAGER_SCRIPT.new()
	var mod_loader: Node = MOD_LOADER_SCRIPT.new()
	services.register_event_bus(event_bus)
	services.register_object_pool(object_pool)
	services.register_data_repository(data_manager)
	services.register_mod_loader(mod_loader)
	services.register_unit_augment_manager(unit_augment_manager)
	services.register_app_session(AppSessionState.new())
	for runtime_node in [object_pool, data_manager, mod_loader, unit_augment_manager]:
		if runtime_node.has_method("bind_runtime_services"):
			runtime_node.call("bind_runtime_services", services)
	return services
