extends SceneTree

const UNIT_BASE_SCENE: PackedScene = preload("res://scenes/units/unit_base.tscn")

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 unit move visual regression test failed: %d" % _failed)
		quit(1)
		return
	print("M5 unit move visual regression test passed.")
	quit(0)


func _run() -> void:
	await _test_quick_cell_step_resets_move_visual_and_snaps_to_target()


func _test_quick_cell_step_resets_move_visual_and_snaps_to_target() -> void:
	var unit: Node2D = UNIT_BASE_SCENE.instantiate() as Node2D
	root.add_child(unit)
	for _step in range(2):
		await process_frame

	var visual_root: Node2D = unit.get_node("VisualRoot") as Node2D
	var targets: Array[Vector2] = [
		Vector2(32.0, 24.0),
		Vector2(96.0, 48.0),
		Vector2(160.0, 72.0)
	]

	for target_world in targets:
		unit.call("play_anim_state", 1, {})
		unit.call("play_quick_cell_step", target_world, 0.05)
		await create_timer(0.12).timeout
		await process_frame

		unit.call("set_loop_animation_enabled", false)
		await process_frame

		_assert_vec2_close(unit.position, target_world, 0.05, "quick step root position should snap to target")
		_assert_vec2_close(visual_root.position, Vector2.ZERO, 0.05, "quick step should clear visual local offset")
		_assert_vec2_close(visual_root.scale, Vector2.ONE, 0.01, "quick step should restore visual local scale")
		_assert_float_close(visual_root.rotation, 0.0, 0.01, "quick step should restore visual local rotation")

		unit.call("set_loop_animation_enabled", true)
		await process_frame

	unit.queue_free()
	await process_frame


func _assert_vec2_close(actual: Vector2, expected: Vector2, tolerance: float, message: String) -> void:
	if actual.distance_to(expected) <= tolerance:
		return
	_failed += 1
	push_error("%s actual=%s expected=%s" % [message, actual, expected])


func _assert_float_close(actual: float, expected: float, tolerance: float, message: String) -> void:
	if is_equal_approx(actual, expected) or absf(actual - expected) <= tolerance:
		return
	_failed += 1
	push_error("%s actual=%s expected=%s" % [message, actual, expected])
