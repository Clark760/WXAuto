extends SceneTree

const EVENT_BUS_SCRIPT: Script = preload("res://scripts/core/event_bus.gd")
const STAGE_MANAGER_SCRIPT: Script = preload("res://scripts/stage/stage_manager.gd")

var _failed: int = 0
var _global_events: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	_run()
	if _failed > 0:
		push_error("M5 global trigger bus tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 global trigger bus tests passed.")
	quit(0)


func _run() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var root_node: Node = tree.root if tree != null else self.root
	var event_bus: Node = root_node.get_node_or_null("EventBus")
	var owns_event_bus: bool = false
	if event_bus == null:
		event_bus = EVENT_BUS_SCRIPT.new()
		event_bus.name = "EventBus"
		root_node.add_child(event_bus)
		owns_event_bus = true

	var stage_manager: Node = STAGE_MANAGER_SCRIPT.new()
	stage_manager.name = "StageManager"
	root_node.add_child(stage_manager)

	var cb_global: Callable = Callable(self, "_on_global_trigger")
	event_bus.connect("global_trigger_fired", cb_global)

	stage_manager.set("_stage_map", {
		"stage_test": {
			"id": "stage_test",
			"chapter": 1,
			"index": 1,
			"type": "normal",
			"rewards": {}
		}
	})
	stage_manager.set("_ordered_stage_ids", ["stage_test"])

	var started: bool = bool(stage_manager.call("start_stage", "stage_test"))
	_assert_true(started, "start_stage should succeed")
	stage_manager.call("notify_stage_combat_started")
	stage_manager.call("on_battle_ended", 1, {})
	stage_manager.call("start_stage", "stage_test")
	stage_manager.call("on_battle_ended", 2, {})

	_assert_trigger_exists("on_preparation_started")
	_assert_trigger_exists("on_stage_combat_started")
	_assert_trigger_exists("on_stage_completed")
	_assert_trigger_exists("on_stage_failed")

	_assert_payload_has("on_preparation_started", "stage_id")
	_assert_payload_has("on_preparation_started", "config")
	_assert_payload_has("on_stage_combat_started", "config")
	_assert_payload_has("on_stage_completed", "rewards")
	_assert_payload_has("on_stage_failed", "winner_team")

	if cb_global.is_valid() and event_bus.is_connected("global_trigger_fired", cb_global):
		event_bus.disconnect("global_trigger_fired", cb_global)
	if owns_event_bus:
		event_bus.queue_free()
	stage_manager.queue_free()


func _on_global_trigger(trigger_name: String, payload: Dictionary) -> void:
	_global_events.append({
		"name": trigger_name,
		"payload": payload.duplicate(true)
	})


func _assert_trigger_exists(trigger_name: String) -> void:
	for event in _global_events:
		if str(event.get("name", "")).strip_edges().to_lower() == trigger_name.strip_edges().to_lower():
			return
	_failed += 1
	push_error("ASSERT FAILED: global trigger missing -> %s" % trigger_name)


func _assert_payload_has(trigger_name: String, key: String) -> void:
	for event in _global_events:
		if str(event.get("name", "")).strip_edges().to_lower() != trigger_name.strip_edges().to_lower():
			continue
		var payload: Dictionary = event.get("payload", {})
		if payload.has(key):
			return
	_failed += 1
	push_error("ASSERT FAILED: payload missing key `%s` for trigger `%s`" % [key, trigger_name])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
