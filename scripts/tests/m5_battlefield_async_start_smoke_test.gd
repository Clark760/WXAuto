extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const OBJECT_POOL_SCRIPT: Script = preload("res://scripts/core/object_pool.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")
const MOD_LOADER_SCRIPT: Script = preload("res://scripts/core/mod_loader.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 battlefield async start smoke test failed: %d" % _failed)
		quit(1)
		return
	print("M5 battlefield async start smoke test passed.")
	quit(0)


func _run() -> void:
	var ctx: Dictionary = await _create_battlefield()
	var battlefield: Node = ctx.get("battlefield", null)
	var refs: Node = battlefield.get_scene_refs()
	var coordinator: Node = battlefield.get_coordinator()
	var combat_manager: Node = refs.combat_manager
	var bench_ui: Node = refs.bench_ui
	var unit_factory: Node = refs.unit_factory

	var unit_ids: Array = unit_factory.get_unit_ids()
	_assert_true(not unit_ids.is_empty(), "unit factory should provide recruitable units")
	if unit_ids.is_empty():
		await _cleanup_battlefield(ctx)
		return

	var recruit_unit: Node = unit_factory.acquire_unit(str(unit_ids[0]), -1, refs.unit_layer)
	_assert_true(recruit_unit != null, "acquire recruit unit for async start smoke")
	if recruit_unit != null:
		recruit_unit.set_team(1)
		recruit_unit.set("is_in_combat", false)
		bench_ui.add_unit(recruit_unit)

	coordinator.enemy_wave_size = 12
	coordinator.battle_start_enemy_spawn_batch_size = 4
	coordinator.request_battle_start()

	var started: bool = false
	for _frame in range(120):
		await process_frame
		if combat_manager != null and bool(combat_manager.is_battle_running()):
			started = true
			break
	_assert_true(started, "request_battle_start should asynchronously enter combat")

	if combat_manager != null and bool(combat_manager.is_battle_running()):
		combat_manager.stop_battle("async_start_smoke", 0)
		await process_frame
		await process_frame

	await _cleanup_battlefield(ctx)


func _create_battlefield() -> Dictionary:
	var unit_augment_manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	var services: ServiceRegistry = _build_services(unit_augment_manager)
	var runtime_nodes: Array[Node] = [
		services.event_bus,
		services.object_pool,
		services.data_repository,
		services.mod_loader
	]
	var data_manager: Node = services.data_repository
	if data_manager != null and data_manager.has_method("load_base_data"):
		data_manager.load_base_data()
	var mod_loader: Node = services.mod_loader
	if mod_loader != null and mod_loader.has_method("load_and_apply_mods"):
		mod_loader.load_and_apply_mods()
	if unit_augment_manager.has_method("reload_from_data"):
		unit_augment_manager.reload_from_data()

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


func _cleanup_battlefield(ctx: Dictionary) -> void:
	var battlefield: Node = ctx.get("battlefield", null)
	if battlefield != null:
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


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
