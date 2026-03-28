extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")
const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const OBJECT_POOL_SCRIPT: Script = preload("res://scripts/core/object_pool.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")
const MOD_LOADER_SCRIPT: Script = preload("res://scripts/core/mod_loader.gd")
const UNIT_AUGMENT_MANAGER_SCRIPT: Script = preload("res://scripts/unit_augment/unit_augment_manager.gd")
const NEW_ROOT_SCRIPT_PATH: String = "res://scripts/app/battlefield/battlefield_scene.gd"
const LEGACY_BATTLEFIELD_SCENE_PATH: String = "res://scenes/battle/" + "battlefield.tscn"
const LEGACY_ENTRY_TOKEN: String = "res://scenes/battle/" + "battlefield.tscn"
const LEGACY_SCRIPT_PATHS: Array[String] = [
	"res://scripts/board/" + "battlefield.gd",
	"res://scripts/battle/" + "battlefield_runtime.gd",
	"res://scripts/ui/" + "battlefield_ui.gd",
	"res://scripts/combat/" + "battle_flow.gd",
	"res://scripts/board/" + "terrain_manager.gd"
]
const LEGACY_SCRIPT_UID_PATHS: Array[String] = [
	"res://scripts/board/" + "battlefield.gd.uid",
	"res://scripts/battle/" + "battlefield_runtime.gd.uid",
	"res://scripts/ui/" + "battlefield_ui.gd.uid",
	"res://scripts/combat/" + "battle_flow.gd.uid",
	"res://scripts/board/" + "terrain_manager.gd.uid"
]

var _failed: int = 0


func _init() -> void:
	await _run()


func _run() -> void:
	var unit_augment_manager: Node = UNIT_AUGMENT_MANAGER_SCRIPT.new()
	var service_bundle: Dictionary = _build_services(unit_augment_manager)
	var services: ServiceRegistry = service_bundle.get("services", null)

	var battlefield: Node = BATTLEFIELD_SCENE.instantiate()
	battlefield.bind_app_services(services)
	root.add_child(battlefield)
	await process_frame
	await process_frame

	_assert_true(battlefield != null, "battlefield_scene should instantiate")
	_assert_true(
		str((battlefield.get_script() as Script).resource_path) == NEW_ROOT_SCRIPT_PATH,
		"battlefield_scene root should use the new composition script"
	)
	_assert_true(battlefield.get_node_or_null("BattlefieldSceneRefs") != null, "BattlefieldSceneRefs node exists")
	_assert_true(battlefield.get_node_or_null("BattlefieldCoordinator") != null, "BattlefieldCoordinator node exists")
	_assert_true(
		battlefield.get_node_or_null("BattlefieldWorldController") != null,
		"BattlefieldWorldController node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("BattlefieldHudPresenter") != null,
		"BattlefieldHudPresenter node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeEconomyManager") != null,
		"RuntimeEconomyManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeShopManager") != null,
		"RuntimeShopManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeStageManager") != null,
		"RuntimeStageManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeUnitDeployManager") != null,
		"RuntimeUnitDeployManager node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeDragController") != null,
		"RuntimeDragController node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("RuntimeBattlefieldRenderer") != null,
		"RuntimeBattlefieldRenderer node exists"
	)
	_assert_true(
		battlefield.get_node_or_null("DetailLayer/BattleStatsPanel") != null,
		"BattleStatsPanel node exists"
	)
	_assert_true(
		battlefield.get_scene_refs() != null and battlefield.get_scene_refs().has_required_scene_nodes(),
		"scene refs should capture required scene nodes"
	)
	_assert_true(
		battlefield.get_scene_refs() != null and battlefield.get_scene_refs().has_required_runtime_nodes(),
		"scene refs should capture required runtime nodes"
	)
	_assert_true(
		battlefield.get_session_state() != null and battlefield.get_session_state().scene_ready,
		"session state should be created and marked ready"
	)
	_assert_true(
		battlefield.get_coordinator() != null and battlefield.get_coordinator().is_initialized(),
		"BattlefieldCoordinator should finish composition initialization"
	)
	_assert_true(
		battlefield.get_world_controller() != null and battlefield.get_world_controller().is_initialized(),
		"BattlefieldWorldController should finish composition initialization"
	)
	_assert_true(
		battlefield.get_hud_presenter() != null and battlefield.get_hud_presenter().is_initialized(),
		"BattlefieldHudPresenter should finish composition initialization"
	)
	_assert_true(
		battlefield.get_scene_refs() != null and battlefield.get_scene_refs().bench_ui != null,
		"scene refs should expose bench_ui for world interaction"
	)
	_assert_true(
		battlefield.get_session_state() != null
		and int(battlefield.get_session_state().stage) == 0
		and bool(battlefield.get_session_state().bottom_expanded),
		"session state should enter preparation stage with expanded bottom panel"
	)
	_assert_true(
		not FileAccess.file_exists(LEGACY_BATTLEFIELD_SCENE_PATH),
		"legacy battlefield scene file should be deleted in Batch 4"
	)
	_assert_true(
		_find_legacy_entry_refs().is_empty(),
		"scripts/scenes should not reference the legacy battlefield scene path"
	)
	for legacy_script_path in LEGACY_SCRIPT_PATHS:
		_assert_true(
			not FileAccess.file_exists(legacy_script_path),
			"legacy battlefield chain script should be deleted: %s" % legacy_script_path
		)
	for legacy_uid_path in LEGACY_SCRIPT_UID_PATHS:
		_assert_true(
			not FileAccess.file_exists(legacy_uid_path),
			"legacy battlefield chain uid should be deleted: %s" % legacy_uid_path
		)
	_assert_true(
		_find_legacy_script_refs().is_empty(),
		"scripts/scenes should not reference the deleted legacy battlefield script chain"
	)

	battlefield.queue_free()
	_cleanup_runtime_nodes(service_bundle)
	await process_frame

	if _failed > 0:
		push_error("Battlefield scene composition smoke test failed: %d" % _failed)
		quit(1)
		return

	print("Battlefield scene composition smoke test passed.")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error(message)


func _build_services(unit_augment_manager: Node) -> Dictionary:
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
	return {
		"services": services,
		"runtime_nodes": [event_bus, object_pool, data_manager, mod_loader, unit_augment_manager]
	}


func _cleanup_runtime_nodes(service_bundle: Dictionary) -> void:
	var runtime_nodes: Variant = service_bundle.get("runtime_nodes", [])
	if not (runtime_nodes is Array):
		return
	for node_value in runtime_nodes:
		if not (node_value is Node):
			continue
		var runtime_node: Node = node_value as Node
		if is_instance_valid(runtime_node):
			runtime_node.free()


func _find_legacy_entry_refs() -> Array[String]:
	var matches: Array[String] = []
	_collect_legacy_token_refs("res://scripts", matches, [LEGACY_ENTRY_TOKEN])
	_collect_legacy_token_refs("res://scenes", matches, [LEGACY_ENTRY_TOKEN])
	return matches


func _find_legacy_script_refs() -> Array[String]:
	var matches: Array[String] = []
	var tokens: Array[String] = LEGACY_SCRIPT_PATHS.duplicate()
	tokens.append_array(LEGACY_SCRIPT_UID_PATHS)
	_collect_legacy_token_refs("res://scripts", matches, tokens)
	_collect_legacy_token_refs("res://scenes", matches, tokens)
	return matches


func _collect_legacy_token_refs(
	dir_path: String,
	matches: Array[String],
	tokens: Array[String]
) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		var child_path: String = "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			_collect_legacy_token_refs(child_path, matches, tokens)
			continue
		if not entry.ends_with(".gd") and not entry.ends_with(".tscn"):
			continue
		var file: FileAccess = FileAccess.open(child_path, FileAccess.READ)
		if file == null:
			continue
		var content: String = file.get_as_text()
		for token in tokens:
			if content.contains(token):
				matches.append("%s => %s" % [child_path, token])
				break
