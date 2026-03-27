extends SceneTree

const UNIT_BASE_SCENE: PackedScene = preload("res://scenes/units/unit_base.tscn")

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 result victory/idle regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 result victory/idle regression tests passed.")
	quit(0)


func _run() -> void:
	await _test_idle_animation_restarts_after_reset()
	await _test_result_style_labels_visible_after_leave_combat()


func _test_idle_animation_restarts_after_reset() -> void:
	var unit: Node = UNIT_BASE_SCENE.instantiate()
	root.add_child(unit)
	await process_frame

	unit.set("unit_name", "RegressionUnit")
	unit.call("play_anim_state", 0, {})
	await process_frame

	var animator: Node = unit.get_node_or_null("SpriteAnimator")
	_assert_true(animator != null, "unit must contain SpriteAnimator")
	if animator == null:
		unit.queue_free()
		await process_frame
		return

	_assert_true(animator.is_processing(), "IDLE loop should process before reset")

	unit.call("reset_visual_transform")
	unit.call("play_anim_state", 0, {})
	await process_frame
	_assert_true(animator.is_processing(), "IDLE loop should restart processing after reset")

	var visual_root: Node2D = unit.get_node_or_null("VisualRoot") as Node2D
	_assert_true(visual_root != null, "unit must contain VisualRoot")
	if visual_root != null:
		var y0: float = visual_root.position.y
		await process_frame
		await process_frame
		var y1: float = visual_root.position.y
		_assert_true(absf(y1 - y0) > 0.001, "idle pose should animate vertically after reset")

	unit.queue_free()
	await process_frame


func _test_result_style_labels_visible_after_leave_combat() -> void:
	var unit: Node = UNIT_BASE_SCENE.instantiate()
	root.add_child(unit)
	await process_frame

	unit.set("unit_name", "ResultLabelUnit")
	unit.call("enter_combat")
	unit.call("set_compact_visual_mode", true)
	unit.call("leave_combat")

	var name_label: Label = unit.get_node_or_null("VisualRoot/NameLabel") as Label
	var star_label: Label = unit.get_node_or_null("VisualRoot/StarLabel") as Label
	_assert_true(name_label != null and star_label != null, "unit labels should exist")
	if name_label == null or star_label == null:
		unit.queue_free()
		await process_frame
		return

	_assert_true(not name_label.visible and not star_label.visible, "compact mode should hide labels after combat")

	# 模拟 RESULT 阶段展示策略：不使用 compact，显示姓名和星级。
	unit.call("set_compact_visual_mode", false)
	_assert_true(name_label.visible and star_label.visible, "result presentation should show name/star labels")

	unit.queue_free()
	await process_frame


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
