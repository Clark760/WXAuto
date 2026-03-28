extends SceneTree

const VFX_FACTORY_SCRIPT: Script = preload("res://scripts/vfx/vfx_factory.gd")
const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const OBJECT_POOL_SCRIPT: Script = preload("res://scripts/core/object_pool.gd")
const DATA_MANAGER_SCRIPT: Script = preload("res://scripts/data/data_manager.gd")

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 vfx damage text regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 vfx damage text regression tests passed.")
	quit(0)


func _run() -> void:
	await _test_damage_texts_are_not_dropped_when_busy()


func _test_damage_texts_are_not_dropped_when_busy() -> void:
	var services := ServiceRegistry.new()
	var event_bus: Node = EVENT_BUS_SCRIPT.new()
	var object_pool: Node = OBJECT_POOL_SCRIPT.new()
	var data_manager: Node = DATA_MANAGER_SCRIPT.new()
	services.register_event_bus(event_bus)
	services.register_object_pool(object_pool)
	services.register_data_repository(data_manager)

	for runtime_node in [object_pool, data_manager]:
		if runtime_node.has_method("bind_runtime_services"):
			runtime_node.call("bind_runtime_services", services)

	root.add_child(event_bus)
	root.add_child(object_pool)
	root.add_child(data_manager)

	var vfx: Node2D = VFX_FACTORY_SCRIPT.new()
	vfx.set("max_active_damage_texts", 1)
	vfx.set("damage_text_skip_ratio_when_busy", 0.95)
	if vfx.has_method("bind_runtime_services"):
		vfx.call("bind_runtime_services", services)
	root.add_child(vfx)
	await process_frame
	await process_frame

	for index in range(8):
		var x: float = 32.0 + float(index % 4) * 18.0
		var y: float = 32.0 + float(index / 4) * 24.0
		vfx.call("spawn_damage_text", Vector2(x, y), float(index + 1), false, false)

	await process_frame
	var snapshot: Dictionary = vfx.call("get_runtime_activity_snapshot")
	_assert_true(
		int(snapshot.get("active_texts", -1)) == 8,
		"damage text spawning must not drop entries because of busy throttling"
	)

	vfx.queue_free()
	event_bus.queue_free()
	object_pool.queue_free()
	data_manager.queue_free()
	await process_frame


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
