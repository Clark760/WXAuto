extends SceneTree

const BATTLEFIELD_SCENE: PackedScene = preload("res://scenes/battle/battlefield_scene.tscn")

var _failed: int = 0


func _init() -> void:
	await _run()
	if _failed > 0:
		push_error("M5 battlefield input conflict regression tests failed: %d" % _failed)
		quit(1)
		return
	print("M5 battlefield input conflict regression tests passed.")
	quit(0)


func _run() -> void:
	await _test_bench_wheel_has_priority_over_world_zoom()
	await _test_escape_close_chain_priority()
	await _test_hud_hit_test_covers_runtime_panels()


func _test_bench_wheel_has_priority_over_world_zoom() -> void:
	var ctx: Dictionary = await _create_battlefield()
	var battlefield: Node = ctx.get("battlefield", null)
	var refs: Node = battlefield.get_scene_refs()
	var state: RefCounted = battlefield.get_session_state()
	var world_controller: Node = battlefield.get_world_controller()

	var bench_center: Vector2 = refs.bench_ui.get_global_rect().get_center()
	var original_zoom: float = float(state.world_zoom)
	world_controller.handle_input(_wheel_event(bench_center, MOUSE_BUTTON_WHEEL_UP))
	_assert_true(is_equal_approx(float(state.world_zoom), original_zoom), "wheel over bench should not zoom world")

	world_controller.handle_input(_wheel_event(Vector2(64.0, 64.0), MOUSE_BUTTON_WHEEL_UP))
	_assert_true(float(state.world_zoom) > original_zoom, "wheel outside bench should still zoom world")

	await _cleanup_battlefield(ctx)


func _test_escape_close_chain_priority() -> void:
	var ctx: Dictionary = await _create_battlefield()
	var battlefield: Node = ctx.get("battlefield", null)
	var refs: Node = battlefield.get_scene_refs()
	var state: RefCounted = battlefield.get_session_state()
	var hud_presenter: Node = battlefield.get_hud_presenter()

	state.detail_visible = true
	state.shop_visible = true
	refs.unit_detail_panel.visible = true
	refs.shop_panel.visible = true
	refs.item_tooltip.visible = true

	hud_presenter.handle_unhandled_input(_escape_event())
	_assert_true(not refs.item_tooltip.visible, "first ESC should close item tooltip first")
	_assert_true(refs.unit_detail_panel.visible, "first ESC should keep detail panel open")
	_assert_true(refs.shop_panel.visible, "first ESC should keep shop panel open")

	hud_presenter.handle_unhandled_input(_escape_event())
	_assert_true(not bool(state.detail_visible), "second ESC should clear detail state")
	_assert_true(not refs.unit_detail_panel.visible, "second ESC should close detail panel")
	_assert_true(refs.shop_panel.visible, "second ESC should still keep shop panel open")

	hud_presenter.handle_unhandled_input(_escape_event())
	_assert_true(not bool(state.shop_visible), "third ESC should clear shop state")
	_assert_true(not refs.shop_panel.visible, "third ESC should close shop panel")

	await _cleanup_battlefield(ctx)


func _test_hud_hit_test_covers_runtime_panels() -> void:
	var ctx: Dictionary = await _create_battlefield()
	var battlefield: Node = ctx.get("battlefield", null)
	var refs: Node = battlefield.get_scene_refs()
	var hud_presenter: Node = battlefield.get_hud_presenter()

	var controls: Array[Control] = [
		refs.shop_panel,
		refs.inventory_panel,
		refs.unit_detail_panel,
		refs.item_tooltip,
		refs.battle_stats_panel,
		refs.recycle_drop_zone
	]
	for control in controls:
		_assert_true(control != null, "runtime HUD control should exist")
		if control == null:
			continue
		control.visible = true
	await process_frame
	for control in controls:
		if control == null:
			continue
		var center: Vector2 = control.get_global_rect().get_center()
		_assert_true(
			hud_presenter.is_mouse_event_over_hud(center),
			"HUD hit test should consume %s" % control.name
		)

	await _cleanup_battlefield(ctx)


func _create_battlefield() -> Dictionary:
	var unit_augment_manager := Node.new()
	unit_augment_manager.name = "UnitAugmentManager"
	root.add_child(unit_augment_manager)

	var battlefield: Node = BATTLEFIELD_SCENE.instantiate()
	root.add_child(battlefield)
	await process_frame
	await process_frame

	return {
		"battlefield": battlefield,
		"unit_augment_manager": unit_augment_manager
	}


func _cleanup_battlefield(ctx: Dictionary) -> void:
	var battlefield: Node = ctx.get("battlefield", null)
	if battlefield != null:
		battlefield.queue_free()
	var singleton: Node = ctx.get("unit_augment_manager", null)
	if singleton != null:
		singleton.queue_free()
	await process_frame


func _wheel_event(position: Vector2, button_index: int) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.position = position
	event.button_index = button_index
	event.pressed = true
	return event


func _escape_event() -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	return event


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failed += 1
	push_error("ASSERT FAILED: %s" % message)
