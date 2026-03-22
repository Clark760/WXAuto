extends SceneTree

const BUFF_MANAGER_SCRIPT: Script = preload("res://scripts/gongfa/buff_manager.gd")


class DummyUnit:
	extends Node
	var unit_id: String = ""
	var unit_name: String = ""
	var team_id: int = 0


var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 buff source bucket tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 buff source bucket tests passed.")
	quit(0)


func _run() -> void:
	var manager = BUFF_MANAGER_SCRIPT.new()
	manager.call("set_buff_definitions", {
		"test_dot": {
			"id": "test_dot",
			"type": "debuff",
			"stackable": true,
			"max_stacks": 5,
			"default_duration": 5.0,
			"effects": [],
			"tick_effects": [{"op": "damage_target", "value": 10.0, "damage_type": "internal"}],
			"tick_interval": 1.0
		}
	})

	var target: DummyUnit = _make_unit("target", "Target", 2)
	var source_a: DummyUnit = _make_unit("src_a", "Source A", 1)
	var source_b: DummyUnit = _make_unit("src_b", "Source B", 1)

	_assert_true(bool(manager.call("apply_buff", target, "test_dot", 5.0, source_a)), "apply source A")
	_assert_true(bool(manager.call("apply_buff", target, "test_dot", 5.0, source_b)), "apply source B")
	_assert_true(bool(manager.call("apply_buff", target, "test_dot", 5.0, source_a)), "reapply source A")

	var active_by_unit: Dictionary = manager.get("_active_by_unit")
	var entries: Array = active_by_unit.get(target.get_instance_id(), [])
	_assert_true(entries.size() == 2, "same buff should be bucketed by source_id")

	var stacks_a: int = 0
	var stacks_b: int = 0
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var sid: int = int(entry.get("source_id", -1))
		if sid == source_a.get_instance_id():
			stacks_a = int(entry.get("stacks", 0))
		elif sid == source_b.get_instance_id():
			stacks_b = int(entry.get("stacks", 0))
	_assert_true(stacks_a == 2, "source A bucket should stack independently")
	_assert_true(stacks_b == 1, "source B bucket should stay separate")

	var tick_result: Dictionary = manager.call("tick", 1.1, {"all_units": [target]})
	var tick_requests: Array = tick_result.get("tick_requests", [])
	var seen_source_ids: Dictionary = {}
	for req_value in tick_requests:
		if not (req_value is Dictionary):
			continue
		var req: Dictionary = req_value
		if int(req.get("target_id", -1)) != target.get_instance_id():
			continue
		if str(req.get("buff_id", "")) != "test_dot":
			continue
		seen_source_ids[int(req.get("source_id", -1))] = true
	_assert_true(seen_source_ids.has(source_a.get_instance_id()), "tick should include source A bucket")
	_assert_true(seen_source_ids.has(source_b.get_instance_id()), "tick should include source B bucket")

	target.free()
	source_a.free()
	source_b.free()


func _make_unit(uid: String, uname: String, team: int) -> DummyUnit:
	var unit := DummyUnit.new()
	unit.unit_id = uid
	unit.unit_name = uname
	unit.team_id = team
	return unit


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
