extends SceneTree

const APP_ROOT_SCENE: PackedScene = preload("res://scenes/app/app_root.tscn")
const MAIN_SCENE_PATH: String = "res://scenes/main/main.tscn"

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("AppRoot smoke test failed: %d" % _failed)
		quit(1)
		return
	print("AppRoot smoke test passed.")
	quit(0)


func _run() -> void:
	var project_text: String = _read_text("res://project.godot")
	_assert_true(
		project_text.find('run/main_scene="res://scenes/app/app_root.tscn"') != -1,
		"project main scene should point to AppRoot"
	)
	_assert_true(project_text.find("[autoload]") == -1, "project should not keep autoload providers")

	var app_root: Node = APP_ROOT_SCENE.instantiate()
	root.add_child(app_root)
	for _step in range(4):
		await process_frame

	var services_host: Node = app_root.get_node_or_null("Services")
	_assert_true(services_host != null, "Services node should exist")
	_assert_true(
		services_host != null and services_host.get_node_or_null("EventBus") != null,
		"EventBus should be created under Services"
	)
	_assert_true(
		services_host != null and services_host.get_node_or_null("ObjectPool") != null,
		"ObjectPool should be created under Services"
	)
	_assert_true(
		services_host != null and services_host.get_node_or_null("DataManager") != null,
		"DataManager should be created under Services"
	)
	_assert_true(
		services_host != null and services_host.get_node_or_null("ModLoader") != null,
		"ModLoader should be created under Services"
	)
	_assert_true(
		services_host != null and services_host.get_node_or_null("UnitAugmentManager") != null,
		"UnitAugmentManager should be created under Services"
	)
	_assert_true(root.get_node_or_null("EventBus") == null, "EventBus should not be mounted directly under root")
	_assert_true(root.get_node_or_null("DataManager") == null, "DataManager should not be mounted directly under root")

	var services: ServiceRegistry = app_root.get_services()
	_assert_true(services != null, "AppRoot should expose ServiceRegistry")
	_assert_true(
		services != null and services.has_required_services(),
		"ServiceRegistry should hold the Batch 1 runtime services"
	)

	var scene_host: Node = app_root.get_node_or_null("SceneHost")
	_assert_true(scene_host != null, "SceneHost node should exist")
	_assert_true(scene_host != null and scene_host.get_child_count() == 1, "SceneHost should load one content scene")
	if scene_host == null or scene_host.get_child_count() == 0:
		await _cleanup_app_root(app_root)
		return

	var main_scene: Node = scene_host.get_child(0)
	_assert_true(main_scene.name == "MainScene", "AppRoot should enter main scene after bootstrap")
	_assert_true(
		services.app_session.current_scene_path == MAIN_SCENE_PATH,
		"AppSessionState should track the loaded content scene"
	)
	_assert_true(
		services.app_session.get_phase_name() == "MAIN_MENU",
		"AppSessionState should end bootstrap in MAIN_MENU"
	)

	await _cleanup_app_root(app_root)


func _cleanup_app_root(app_root: Node) -> void:
	if app_root != null:
		app_root.queue_free()
		await process_frame


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert_true(false, "cannot open file: %s" % path)
		return ""
	return file.get_as_text()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
