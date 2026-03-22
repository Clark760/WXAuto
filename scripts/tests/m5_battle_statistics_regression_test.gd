extends SceneTree

const BATTLE_STATISTICS_SCRIPT: Script = preload("res://scripts/battle/battle_statistics.gd")

var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 battle statistics regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 battle statistics regression tests passed.")
	quit(0)


func _run() -> void:
	var stats: Node = BATTLE_STATISTICS_SCRIPT.new()
	stats.call("clear_stats")

	stats.call("record_damage", null, null, 120.0, {
		"unit_id": "dot_source",
		"unit_name": "DOT Source",
		"team_id": 1
	}, {
		"unit_id": "dot_target",
		"unit_name": "DOT Target",
		"team_id": 2
	})

	var rows_deal: Array = stats.call("get_ranked_stats", "damage_dealt", 10, 1, 1)
	var rows_taken: Array = stats.call("get_ranked_stats", "damage_taken", 10, 1, 2)
	_assert_true(not rows_deal.is_empty(), "fallback source should record damage_dealt")
	_assert_true(not rows_taken.is_empty(), "fallback target should record damage_taken")

	stats.call("record_stat", null, "damage_taken_total", 200.0, {
		"unit_id": "tank_1",
		"unit_name": "Tank One",
		"team_id": 1
	})
	stats.call("record_stat", null, "shield_absorbed", 80.0, {
		"unit_id": "tank_1",
		"unit_name": "Tank One",
		"team_id": 1
	})
	stats.call("record_stat", null, "damage_immune_blocked", 30.0, {
		"unit_id": "tank_1",
		"unit_name": "Tank One",
		"team_id": 1
	})

	var rows_tank: Array = stats.call("get_ranked_stats", "damage_taken_total", 10, 1, 1)
	_assert_true(not rows_tank.is_empty(), "damage_taken_total ranking should be available")
	if not rows_tank.is_empty():
		var row: Dictionary = rows_tank[0]
		_assert_true(int(row.get("damage_taken_total", 0)) >= 200, "damage_taken_total accumulated")
		_assert_true(int(row.get("shield_absorbed", 0)) >= 80, "shield_absorbed accumulated")
		_assert_true(int(row.get("damage_immune_blocked", 0)) >= 30, "damage_immune_blocked accumulated")
	stats.free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
