extends SceneTree

const RING_BUFFER_SCRIPT: Script = preload("res://scripts/battle/battle_log_ring_buffer.gd")

var _failed: int = 0


func _init() -> void:
	_run()
	if _failed > 0:
		push_error("M5 combat log ring buffer tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 combat log ring buffer tests passed.")
	quit(0)


func _run() -> void:
	_test_push_and_drain_single()
	_test_push_and_drain_multiple_order()
	_test_overflow_keeps_capacity()
	_test_stale_reader_skips_overwritten()
	_test_drain_since_current_head_is_empty()
	_test_clear_resets_all()
	_test_write_head_monotonic()


func _test_push_and_drain_single() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	buffer.push({"type": 0, "value": 7})
	var drained: Array = buffer.drain_since(0)
	_assert_true(drained.size() == 1, "RB-01: single push should drain one event")


func _test_push_and_drain_multiple_order() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	for i in range(10):
		buffer.push({"type": 0, "value": i})
	var drained: Array = buffer.drain_since(0)
	_assert_true(drained.size() == 10, "RB-02: ten pushes should drain ten events")
	for i in range(10):
		_assert_true(int(drained[i].get("value", -1)) == i, "RB-02: drain order mismatch at %d" % i)


func _test_overflow_keeps_capacity() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	var capacity: int = int(buffer.RING_CAPACITY)
	for i in range(capacity + 32):
		buffer.push({"type": 0, "value": i})
	var drained: Array = buffer.drain_since(0)
	_assert_true(
		drained.size() == capacity,
		"RB-03: overflow should keep capacity items, got %d" % drained.size()
	)


func _test_stale_reader_skips_overwritten() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	var capacity: int = int(buffer.RING_CAPACITY)
	for i in range(capacity + 20):
		buffer.push({"type": 0, "value": i})
	var drained: Array = buffer.drain_since(0)
	_assert_true(drained.size() == capacity, "RB-04: stale reader should only get latest capacity")
	_assert_true(
		int(drained[0].get("value", -1)) == 20,
		"RB-04: oldest retained value should be 20 after overflow"
	)


func _test_drain_since_current_head_is_empty() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	for i in range(5):
		buffer.push({"type": 0, "value": i})
	var drained: Array = buffer.drain_since(buffer.get_write_head())
	_assert_true(drained.is_empty(), "RB-05: drain from current head should be empty")


func _test_clear_resets_all() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	for i in range(5):
		buffer.push({"type": 0, "value": i})
	buffer.clear()
	_assert_true(buffer.get_write_head() == 0, "RB-06: clear should reset write head")
	_assert_true(buffer.drain_since(0).is_empty(), "RB-06: clear should remove all events")


func _test_write_head_monotonic() -> void:
	var buffer = RING_BUFFER_SCRIPT.new()
	for i in range(17):
		buffer.push({"type": 0, "value": i})
	_assert_true(buffer.get_write_head() == 17, "RB-07: write head should equal push count")


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
