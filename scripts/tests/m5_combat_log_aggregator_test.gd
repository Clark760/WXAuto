extends SceneTree

const AGGREGATOR_SCRIPT: Script = preload(
	"res://scripts/app/battlefield/battlefield_combat_log_aggregator.gd"
)

var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 combat log aggregator tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 combat log aggregator tests passed.")
	quit(0)


func _run() -> void:
	_test_empty_flush()
	_test_single_damage()
	_test_merge_same_source_target()
	_test_no_merge_diff_target()
	_test_filter_low_damage()
	_test_threshold_boundary()
	_test_death_no_merge()
	_test_skill_cast_output()
	_test_self_heal_wording()
	_test_heal_other_wording()
	_test_team_markers()
	_test_flush_clears_pending()
	_test_skill_damage_keeps_skill_name()
	_test_mixed_event_types()


func _new_aggregator():
	var aggregator = AGGREGATOR_SCRIPT.new()
	aggregator.initialize(null)
	return aggregator


func _damage_event(src: String, tgt: String, val: int, team: int = 1, skill: String = "") -> Dictionary:
	return {
		"type": 0,
		"source_name": src,
		"target_name": tgt,
		"source_team": team,
		"target_team": 2,
		"source_id": 100,
		"target_id": 200,
		"value": val,
		"skill_name": skill,
		"timestamp": 0.0
	}


func _skill_damage_event(src: String, tgt: String, val: int, skill: String) -> Dictionary:
	var event: Dictionary = _damage_event(src, tgt, val, 1, skill)
	event["type"] = 1
	return event


func _heal_event(src: String, tgt: String, val: int, team: int = 1) -> Dictionary:
	return {
		"type": 2,
		"source_name": src,
		"target_name": tgt,
		"source_team": team,
		"target_team": team,
		"source_id": 101,
		"target_id": 102,
		"value": val,
		"timestamp": 0.0
	}


func _death_event(dead_name: String, killer_name: String) -> Dictionary:
	return {
		"type": 4,
		"source_name": killer_name,
		"target_name": dead_name,
		"source_team": 1,
		"target_team": 2,
		"source_id": 101,
		"target_id": 301,
		"timestamp": 0.0
	}


func _cast_event(src: String, skill: String, team: int = 1) -> Dictionary:
	return {
		"type": 3,
		"source_name": src,
		"source_team": team,
		"source_id": 99,
		"skill_name": skill,
		"timestamp": 0.0
	}


func _test_empty_flush() -> void:
	var aggregator = _new_aggregator()
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.is_empty(), "AG-01: empty flush should return empty")


func _test_single_damage() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("A", "B", 100))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-02: single damage should output one line")
	_assert_true("伤" in str(result[0].get("text", "")), "AG-02: damage line should contain 伤")


func _test_merge_same_source_target() -> void:
	var aggregator = _new_aggregator()
	for i in range(3):
		aggregator.push_event(_damage_event("A", "B", 100))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-03: same source-target should merge")
	var text: String = str(result[0].get("text", ""))
	_assert_true("3" in text, "AG-03: merged text should include count")
	_assert_true("300" in text, "AG-03: merged text should include summed value")


func _test_no_merge_diff_target() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("A", "B", 100))
	aggregator.push_event(_damage_event("A", "C", 100))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() >= 2, "AG-04: different targets should not merge")


func _test_filter_low_damage() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("A", "B", 2))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.is_empty(), "AG-05: low damage should be filtered")


func _test_threshold_boundary() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("A", "B", 5))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-06: threshold damage should pass")


func _test_death_no_merge() -> void:
	var aggregator = _new_aggregator()
	for i in range(3):
		aggregator.push_event(_death_event("敌人%d" % i, "主角"))
	var result: Array = aggregator.flush_aggregated(0.0)
	var death_count: int = 0
	for entry in result:
		if str(entry.get("event_type", "")) == "death":
			death_count += 1
	_assert_true(death_count == 3, "AG-07: death events should not merge")


func _test_skill_cast_output() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_cast_event("张三丰", "太极拳"))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-08: skill cast should output one line")
	var text: String = str(result[0].get("text", ""))
	_assert_true("发动" in text, "AG-08: should contain 发动")
	_assert_true("太极拳" in text, "AG-08: should contain skill name")


func _test_self_heal_wording() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_heal_event("A", "A", 80))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-09: self heal should output one line")
	_assert_true("恢复" in str(result[0].get("text", "")), "AG-09: self heal should say 恢复")


func _test_heal_other_wording() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_heal_event("A", "B", 80))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-10: heal other should output one line")
	_assert_true("治疗" in str(result[0].get("text", "")), "AG-10: heal other should say 治疗")


func _test_team_markers() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("Hero", "Boss", 100, 1))
	aggregator.push_event(_damage_event("Boss", "Hero", 100, 2))
	var result: Array = aggregator.flush_aggregated(0.0)
	var has_ally_marker: bool = false
	var has_enemy_marker: bool = false
	for entry in result:
		var text: String = str(entry.get("text", ""))
		if text.begins_with("▶"):
			has_ally_marker = true
		if text.begins_with("◀"):
			has_enemy_marker = true
	_assert_true(has_ally_marker, "AG-11: ally line should have ▶")
	_assert_true(has_enemy_marker, "AG-11: enemy line should have ◀")


func _test_flush_clears_pending() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("A", "B", 100))
	aggregator.flush_aggregated(0.0)
	var second: Array = aggregator.flush_aggregated(0.0)
	_assert_true(second.is_empty(), "AG-12: second flush without new events should be empty")


func _test_skill_damage_keeps_skill_name() -> void:
	var aggregator = _new_aggregator()
	for i in range(3):
		aggregator.push_event(_skill_damage_event("A", "B", 50, "太极剑法"))
	var result: Array = aggregator.flush_aggregated(0.0)
	_assert_true(result.size() == 1, "AG-13: skill damage should merge into one")
	_assert_true(
		"太极剑法" in str(result[0].get("text", "")),
		"AG-13: merged skill damage should keep skill name"
	)


func _test_mixed_event_types() -> void:
	var aggregator = _new_aggregator()
	aggregator.push_event(_damage_event("A", "B", 100))
	aggregator.push_event(_death_event("C", "A"))
	aggregator.push_event(_cast_event("A", "X技能"))
	var result: Array = aggregator.flush_aggregated(0.0)
	var types: Dictionary = {}
	for entry in result:
		types[str(entry.get("event_type", ""))] = true
	_assert_true(types.size() >= 3, "AG-14: mixed events should contain >=3 event types")


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
